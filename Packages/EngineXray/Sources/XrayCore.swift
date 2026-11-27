// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never run against the real
// bridge or inside a Packet Tunnel extension.
import CoreAbstraction
import Foundation

/// Settings of the adapter that are not part of the configuration document. Limits of this project, not
/// of the platform or of the core.
public struct XrayCoreSettings: Sendable {
    /// Log level passed to the bridge. Core records may carry destination addresses (ADR-0003 §4), so the
    /// default keeps the volume low.
    public var logLevel: String = "warning"
    /// The bridge's own start deadline. Shorter than the host's (`TunnelDeadlines.engineStart`, 20 s), so
    /// that the bridge gives up and cleans up before the host stops waiting.
    public var startTimeout: TimeInterval = 15
    /// The bridge's own stop deadline. Shorter than the host's (`TunnelDeadlines.engineStop`, 5 s).
    public var stopTimeout: TimeInterval = 4
    /// Memory profile of the bridge (`memory.profile`). The bridge holds the profile's values (memory
    /// limit, GC percentage, queue sizes, flow cap); the adapter names the profile and never repeats
    /// them. The fields below override single values of the profile when set.
    public var memoryProfile: XrayBridgeMemoryProfile?
    /// Used when `CoreStartOptions.memoryLimitBytes` is `nil`. `nil` leaves the profile's value, or the
    /// Go runtime as it is when no profile is set.
    public var memoryLimitBytes: UInt64?
    /// Go GC percentage; `nil` keeps the profile's value or the runtime default.
    public var gcPercent: Int?
    /// Capacity of the bridge's core-to-device queue (`tun.outQueueBytes`); `nil` keeps the profile's
    /// value or the bridge default.
    public var outQueueBytes: Int?
    public var pump = PacketPumpConfiguration.standard
    /// How long one `npb_log_read` waits; bounds how long the log thread takes to notice a stop.
    public var logReadTimeoutMilliseconds: Int32 = 250
    /// Buffer of `npb_log_read`; the bridge needs at least 4 KiB.
    public var logBufferBytes: Int = 16 * 1024

    public init() {}

    /// The settings of the Packet Tunnel extension: the bridge's `mobile` memory profile, measured for a
    /// process with a budget of about 50 MiB (`Documentation/Performance/memory-budget.md`).
    public static var packetTunnel: XrayCoreSettings {
        var settings = XrayCoreSettings()
        settings.memoryProfile = .mobile
        return settings
    }
}

/// Memory profiles the bridge defines (`Cores/Bridge/engine/options.go`, `MemoryProfile`).
public enum XrayBridgeMemoryProfile: String, Sendable {
    /// Limit 40 MiB, GC 25 %, out queue 512 KiB, 512 flows, log queue 128, no geodata (values live in the
    /// bridge; listed here only for the reader).
    case mobile
}

/// Callbacks of the adapter. Called from the adapter's threads; they must return quickly.
public struct XrayCoreEvents: Sendable {
    /// The engine stopped while it was supposed to run. The host reports this to `CoreLifecycle`
    /// (`reportUnexpectedExit`) so that the watchdog takes the tunnel down.
    public var unexpectedExit: (@Sendable (String) -> Void)?
    /// One record of the bridge's log ring.
    public var log: (@Sendable (XrayLogRecord) -> Void)?

    public init(unexpectedExit: (@Sendable (String) -> Void)? = nil, log: (@Sendable (XrayLogRecord) -> Void)? = nil) {
        self.unexpectedExit = unexpectedExit
        self.log = log
    }
}

/// The `NetworkCore` adapter of the Xray bridge (ADR-0001 §5).
///
/// - Configuration: the compiled Xray JSON is passed to the bridge as it is; nothing is rewritten.
///   Run-time parameters (tun mode, MTU, memory, deadlines) travel as bridge options.
/// - Packets: with a `TunnelPacketIO` the bridge runs in `tun.mode = "flow"` and a `PacketPump` moves the
///   batches; with `CoreStartOptions.tunnelFileDescriptor` it runs in `tun.mode = "fd"` and reads the
///   device itself (not located on Apple yet, ADR-0001 §4, risk R-08).
/// - Blocking bridge calls run on their own threads; `start` is interrupted on cancellation with
///   `npb_stop`, which the bridge documents as interrupting a start in progress.
/// - Reload is not offered: the bridge replaces the configuration by stop + start, which drops every
///   connection and recreates the packet device, so the host restarts the core instead (no `.hotReload`).
/// - Errors leave as `CoreError`: configuration codes become `.invalidConfiguration`, the bridge's
///   timeout and cancellation become `.timedOut` / `.cancelled`, the rest `.operationFailed` with the
///   bridge's code name and a bounded message.
public final class XrayCore: NetworkCore, @unchecked Sendable {
    public static let identifier: CoreIdentifier = "xray"
    /// The configuration format this adapter accepts.
    public static let configurationFormat = "json"

    public static let baseCapabilities = CoreCapabilities(
        protocols: [.vless, .vmess, .trojan, .shadowsocks],
        transports: [.tcp, .websocket, .httpUpgrade, .grpc, .xhttp, .mkcp],
        features: [.configurationValidation, .trafficStatistics, .perOutboundStatistics]
    )

    /// The descriptor with the core version the linked bridge reports.
    public static func makeDescriptor(bridge: any XrayBridgeABI) -> CoreDescriptor {
        let reply = XrayBridgeReply<XrayBridgeVersion>.decode(bridge.version())
        let version = reply.data?.core ?? "unknown"
        return CoreDescriptor(id: identifier, displayName: "Xray-core", version: version, capabilities: baseCapabilities)
    }

    private enum Phase: String {
        case idle, starting, running, stopping
    }

    public let descriptor: CoreDescriptor
    private let bridge: any XrayBridgeABI
    private let packetIO: (any TunnelPacketIO)?
    private let settings: XrayCoreSettings
    private let events: XrayCoreEvents
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var pump: PacketPump?
    private var logReader: XrayLogReader?
    private var startedAt: Date?
    private var engineGone: XrayBridgeCode?
    private var lastHealthCounters = PacketPumpCounters()

    public init(
        bridge: any XrayBridgeABI,
        packetIO: (any TunnelPacketIO)?,
        descriptor: CoreDescriptor? = nil,
        settings: XrayCoreSettings = XrayCoreSettings(),
        events: XrayCoreEvents = XrayCoreEvents(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.packetIO = packetIO
        self.descriptor = descriptor ?? XrayCore.makeDescriptor(bridge: bridge)
        self.settings = settings
        self.events = events
        self.clock = clock
    }

    /// Counters of the packet pump of the current run, `nil` when no pump runs.
    public var pumpCounters: PacketPumpCounters? {
        lock.lock()
        defer { lock.unlock() }
        return pump?.counters
    }

    // MARK: NetworkCore

    public func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport {
        if let issue = formatIssue(configuration) {
            return CoreValidationReport(issues: [issue])
        }
        let payload = configuration.payload
        let options = bridgeOptions(for: .none, validating: true).encoded()
        let bridge = self.bridge
        let text = await XrayBlockingCall.run(name: "np.xray.validate") {
            bridge.validate(configuration: payload, options: options)
        }
        let reply = XrayBridgeReply<XrayConfigSummary>.decode(text)
        if reply.code == .ok {
            return .valid
        }
        let error = XrayCore.coreError(reply.code, message: reply.error, during: .validate, timeout: nil)
        if case let .invalidConfiguration(issues) = error {
            return CoreValidationReport(issues: issues)
        }
        throw error
    }

    public func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
        if let issue = formatIssue(configuration) {
            throw CoreError.invalidConfiguration(issues: [issue])
        }
        let abi = bridge.abiVersion()
        guard abi == XrayBridgeContract.abiVersion else {
            throw CoreError.operationFailed(
                operation: .start,
                message: "bridge ABI \(abi), the adapter needs \(XrayBridgeContract.abiVersion)"
            )
        }

        let claimed: (busy: Phase?, logs: XrayLogReader?) = withLock {
            guard phase == .idle else { return (phase, nil) }
            phase = .starting
            engineGone = nil
            lastHealthCounters = PacketPumpCounters()
            let logs = events.log.map { XrayLogReader(bridge: self.bridge, settings: settings, sink: $0) }
            logReader = logs
            return (nil, logs)
        }
        if let busy = claimed.busy {
            throw CoreError.operationFailed(operation: .start, message: "the adapter is \(busy.rawValue)")
        }
        let logs = claimed.logs
        logs?.start()

        let payload = configuration.payload
        let encodedOptions = bridgeOptions(for: options, validating: false).encoded()
        let bridge = self.bridge
        let stopMilliseconds = XrayCore.milliseconds(settings.stopTimeout)
        let text = await withTaskCancellationHandler {
            await XrayBlockingCall.run(name: "np.xray.start") {
                bridge.start(configuration: payload, options: encodedOptions)
            }
        } onCancel: {
            // `npb_stop` interrupts a start in progress. On its own thread: the cancelling task must not
            // block in Go.
            let interrupter = Thread {
                _ = bridge.stop(timeoutMilliseconds: stopMilliseconds)
            }
            interrupter.name = "np.xray.interrupt"
            interrupter.start()
        }
        let reply = XrayBridgeReply<XrayNoPayload>.decode(text)
        guard reply.code == .ok else {
            withLock {
                phase = .idle
                logReader = nil
            }
            if let logs = logs {
                await XrayBlockingCall.run(name: "np.xray.log.stop") { logs.stop() }
            }
            throw XrayCore.coreError(reply.code, message: reply.error, during: .start, timeout: settings.startTimeout)
        }

        var newPump: PacketPump?
        if options.tunnelFileDescriptor == nil, let io = packetIO {
            newPump = PacketPump(bridge: bridge, io: io, configuration: settings.pump) { [weak self] code in
                self?.packetDeviceGone(code)
            }
        }
        let now = clock()
        withLock {
            pump = newPump
            startedAt = now
            phase = .running
        }
        newPump?.start()
    }

    public func stop() async throws {
        let (currentPump, logs): (PacketPump?, XrayLogReader?) = withLock {
            phase = .stopping
            return (pump, logReader)
        }

        // The pump first, so that the device closing under it is not taken for an engine that died.
        currentPump?.beginStop()
        let bridge = self.bridge
        let milliseconds = XrayCore.milliseconds(settings.stopTimeout)
        let (text, joined) = await XrayBlockingCall.run(name: "np.xray.stop") { () -> (String, Bool) in
            let text = bridge.stop(timeoutMilliseconds: milliseconds)
            let joined = currentPump?.join() ?? true
            logs?.stop()
            return (text, joined)
        }

        withLock {
            pump = nil
            logReader = nil
            startedAt = nil
            phase = .idle
        }

        let reply = XrayBridgeReply<XrayNoPayload>.decode(text)
        guard reply.code == .ok else {
            throw XrayCore.coreError(reply.code, message: reply.error, during: .stop, timeout: settings.stopTimeout)
        }
        if !joined {
            throw CoreError.operationFailed(operation: .stop, message: "packet pump threads did not finish in time")
        }
    }

    public func reload(_ configuration: CoreConfiguration) async throws {
        throw CoreError.unsupportedFeature(.hotReload)
    }

    public func statistics() async throws -> CoreStatistics {
        let reply = XrayBridgeReply<XrayBridgeStats>.decode(bridge.stats())
        guard reply.code == .ok, let stats = reply.data else {
            let code = reply.code == .ok ? XrayBridgeCode.internalError : reply.code
            throw XrayCore.coreError(code, message: reply.error, during: .statistics, timeout: nil)
        }
        var total = TrafficCounters()
        // Inbound counters are the bytes the core exchanged with the device: the user's traffic.
        for counter in stats.inbounds ?? [] {
            total.uplinkBytes = XrayCore.add(total.uplinkBytes, counter.uplink)
            total.downlinkBytes = XrayCore.add(total.downlinkBytes, counter.downlink)
        }
        var outbounds: [String: TrafficCounters] = [:]
        for counter in stats.outbounds ?? [] {
            var entry = outbounds[counter.tag] ?? TrafficCounters()
            entry.uplinkBytes = XrayCore.add(entry.uplinkBytes, counter.uplink)
            entry.downlinkBytes = XrayCore.add(entry.downlinkBytes, counter.downlink)
            outbounds[counter.tag] = entry
        }
        return CoreStatistics(
            capturedAt: clock(),
            traffic: total,
            outbounds: outbounds,
            activeConnections: nil,
            memoryFootprintBytes: nil,
            uptime: stats.uptimeMs.map { TimeInterval($0) / 1000 }
        )
    }

    public func health() async -> CoreHealth {
        let now = clock()
        let (currentPhase, currentPump, gone, previous) = withLock { (phase, pump, engineGone, lastHealthCounters) }

        guard currentPhase == .running else {
            return CoreHealth(status: .unknown, detail: "the adapter is \(currentPhase.rawValue)", checkedAt: now)
        }
        if let code = gone {
            let error = CoreError.unexpectedExit(message: "packet device: \(code)")
            return CoreHealth(status: .unhealthy, detail: error.description, checkedAt: now, lastError: error)
        }
        let reply = XrayBridgeReply<XrayBridgeHealth>.decode(bridge.health())
        guard reply.code == .ok, let health = reply.data else {
            let error = XrayCore.coreError(reply.code == .ok ? .internalError : reply.code, message: reply.error, during: .health, timeout: nil)
            return CoreHealth(status: .unhealthy, detail: error.description, checkedAt: now, lastError: error)
        }
        guard health.state == "running", health.coreRunning != false else {
            var lastError: CoreError?
            if let code = health.lastErrorCode, code != 0 {
                lastError = XrayCore.coreError(XrayBridgeCode(rawValue: code), message: health.lastError ?? "", during: .health, timeout: nil)
            }
            return CoreHealth(
                status: .unhealthy,
                detail: "bridge state \(health.state ?? "unknown"), core running \(health.coreRunning ?? false)",
                checkedAt: now,
                lastError: lastError
            )
        }
        guard let pumpNow = currentPump else {
            return CoreHealth(status: .healthy, detail: "no packet pump (fd mode or no tunnel)", checkedAt: now)
        }
        guard pumpNow.state == .running else {
            return CoreHealth(status: .unhealthy, detail: "packet pump is \(pumpNow.state.rawValue)", checkedAt: now)
        }
        let counters = pumpNow.counters
        withLock { lastHealthCounters = counters }
        let newRejected = counters.inboundRejected &- previous.inboundRejected
        let newWriteFailures = counters.outboundWriteFailures &- previous.outboundWriteFailures
        let summary = "in \(counters.inboundPackets) packets, out \(counters.outboundPackets) packets"
        if newRejected > 0 || newWriteFailures > 0 {
            return CoreHealth(
                status: .degraded,
                detail: "\(summary); since the last check \(newRejected) packets rejected by the bridge, "
                    + "\(newWriteFailures) batches refused by the system",
                checkedAt: now
            )
        }
        return CoreHealth(status: .healthy, detail: summary, checkedAt: now)
    }

    /// Synchronous scoped locking, usable from the async methods (NSLock.lock/unlock are not).
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Errors

    /// Translates a bridge result code into the one error type that leaves the adapter.
    static func coreError(_ code: XrayBridgeCode, message: String, during operation: CoreOperation, timeout: TimeInterval?) -> CoreError {
        let text = clip("\(code): \(message)")
        switch code {
        case .configParse, .configBuild, .configUnsupported:
            return .invalidConfiguration(issues: [CoreValidationIssue(severity: .error, message: text)])
        case .timeout:
            return .timedOut(operation: operation, seconds: timeout ?? 0)
        case .cancelled:
            return .cancelled(operation: operation)
        case .notRunning:
            return .notRunning(state: .idle)
        default:
            return .operationFailed(operation: operation, message: text)
        }
    }

    static func clip(_ text: String) -> String {
        if text.count <= CoreError.maximumMessageLength { return text }
        return String(text.prefix(CoreError.maximumMessageLength)) + "..."
    }

    // MARK: Helpers

    private func formatIssue(_ configuration: CoreConfiguration) -> CoreValidationIssue? {
        guard configuration.format.lowercased() == XrayCore.configurationFormat else {
            return CoreValidationIssue(
                severity: .error,
                message: "configuration format '\(configuration.format)' is not '\(XrayCore.configurationFormat)'"
            )
        }
        return nil
    }

    /// The bridge options for a start (or, with `validating`, for a check in the same tun mode: in flow
    /// mode the bridge replaces the config's tun inbound and refuses a config without one, and a check in
    /// another mode would let the core construct a system tun inbound).
    func bridgeOptions(for options: CoreStartOptions, validating: Bool) -> XrayBridgeOptions {
        var result = XrayBridgeOptions()
        result.startTimeoutMs = XrayCore.milliseconds(settings.startTimeout).nonZero
        result.stopTimeoutMs = XrayCore.milliseconds(settings.stopTimeout).nonZero
        result.logLevel = settings.logLevel
        var tun = XrayBridgeOptions.Tun()
        if let descriptor = options.tunnelFileDescriptor {
            tun.mode = "fd"
            tun.fd = descriptor
        } else if packetIO != nil {
            tun.mode = "flow"
        }
        if tun.mode != nil {
            tun.mtu = options.mtu
            tun.outQueueBytes = settings.outQueueBytes
            result.tun = tun
        }
        // The profile also when validating: under `mobile` the bridge refuses geodata, which a check must
        // report the same way a start would.
        var memory = XrayBridgeOptions.Memory(profile: settings.memoryProfile?.rawValue)
        if !validating {
            memory.limitBytes = (options.memoryLimitBytes ?? settings.memoryLimitBytes).map { Int64(clamping: $0) }
            memory.gcPercent = settings.gcPercent
        }
        if memory != XrayBridgeOptions.Memory() {
            result.memory = memory
        }
        return result
    }

    private func packetDeviceGone(_ code: XrayBridgeCode) {
        lock.lock()
        let report = phase == .running && engineGone == nil
        if report { engineGone = code }
        lock.unlock()
        if report {
            events.unexpectedExit?("xray packet device stopped: \(code)")
        }
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int32(clamping: Int64(min(seconds * 1000, Double(Int32.max))))
    }

    private static func add(_ total: UInt64, _ value: Int64) -> UInt64 {
        guard value > 0 else { return total }
        let (sum, overflow) = total.addingReportingOverflow(UInt64(value))
        return overflow ? UInt64.max : sum
    }
}

private extension Int32 {
    var nonZero: Int? { self == 0 ? nil : Int(self) }
}

/// Runs a blocking bridge call on its own thread and resumes the caller when it returns, so that Go never
/// blocks a thread of the Swift cooperative pool.
enum XrayBlockingCall {
    static func run<T>(name: String, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.name = name
            thread.start()
        }
    }
}
