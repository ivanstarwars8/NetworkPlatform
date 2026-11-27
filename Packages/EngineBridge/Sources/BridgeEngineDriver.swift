// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never run against a real bridge or
// inside a Packet Tunnel extension.
import CoreAbstraction
import Foundation

/// Settings of an adapter that are not part of the configuration document and that both bridges share. Limits
/// of this project, not of the platform or of the cores.
public struct BridgeCoreSettings: Sendable {
    /// Log level passed to the bridge. Core records may carry destination addresses (ADR-0003 §4), so the
    /// default keeps the volume low.
    public var logLevel: String = "warning"
    /// The bridge's own start deadline. Shorter than the host's (`TunnelDeadlines.engineStart`, 20 s), so
    /// that the bridge gives up and cleans up before the host stops waiting.
    public var startTimeout: TimeInterval = 15
    /// The bridge's own stop deadline. Shorter than the host's (`TunnelDeadlines.engineStop`, 5 s).
    public var stopTimeout: TimeInterval = 4
    /// Memory profile of the bridge (`memory.profile`). The bridge holds the profile's values (memory
    /// limit, GC percentage, queue sizes, flow cap, idle timeouts); the adapter names the profile and never
    /// repeats them. The fields below override single values of the profile when set.
    public var memoryProfile: BridgeMemoryProfile?
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
    /// Buffer of `npb_log_read`; the bridges need at least 4 KiB.
    public var logBufferBytes: Int = 16 * 1024

    public init() {}

    /// The settings of a Packet Tunnel extension: the bridge's `mobile` memory profile, measured for a
    /// process with a budget of about 50 MiB (`Documentation/Performance/memory-budget.md`, §10 for Mihomo).
    public static var packetTunnel: BridgeCoreSettings {
        var settings = BridgeCoreSettings()
        settings.memoryProfile = .mobile
        return settings
    }
}

/// Memory profiles both bridges define (`engine/options.go`, `MemoryProfile`).
public enum BridgeMemoryProfile: String, Sendable {
    /// Values live in each bridge (`Mobile*` constants); not repeated here.
    case mobile
}

/// Callbacks of an adapter. Called from the adapter's threads; they must return quickly.
public struct BridgeCoreEvents: Sendable {
    /// The engine stopped while it was supposed to run. The host reports this to `CoreLifecycle`
    /// (`reportUnexpectedExit`) so that the watchdog takes the tunnel down.
    public var unexpectedExit: (@Sendable (String) -> Void)?
    /// One record of the bridge's log ring.
    public var log: (@Sendable (BridgeLogRecord) -> Void)?

    public init(unexpectedExit: (@Sendable (String) -> Void)? = nil, log: (@Sendable (BridgeLogRecord) -> Void)? = nil) {
        self.unexpectedExit = unexpectedExit
        self.log = log
    }
}

/// Result of `BridgeEngineDriver.validate`.
package enum BridgeValidation {
    /// The bridge accepted the configuration; the reply text carries the engine's summary.
    case accepted(reply: String)
    /// A configuration error, already turned into issues.
    case rejected(CoreValidationReport)
}

/// The lifecycle both adapters share over the C ABI: blocking calls on their own threads, start interrupted by
/// `npb_stop` on cancellation, the packet pump in `tun.mode = "flow"`, the log reader, the watchdog report when
/// the packet device closes by itself, health and error normalisation. The engine adapters (`XrayCore`,
/// `MihomoCore`) add only what differs per engine: configuration format, bridge options, the summary of a check
/// and the shape of the statistics.
package final class BridgeEngineDriver: @unchecked Sendable {
    private enum Phase: String {
        case idle, starting, running, stopping
    }

    /// Short engine name: thread names and messages.
    package let engine: String
    private let bridge: any BridgeABI
    private let packetIO: (any TunnelPacketIO)?
    private let settings: BridgeCoreSettings
    private let events: BridgeCoreEvents
    package let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var pump: PacketPump?
    private var logReader: BridgeLogReader?
    private var engineGone: BridgeCode?
    private var lastHealthCounters = PacketPumpCounters()

    package init(
        engine: String,
        bridge: any BridgeABI,
        packetIO: (any TunnelPacketIO)?,
        settings: BridgeCoreSettings,
        events: BridgeCoreEvents,
        clock: @escaping @Sendable () -> Date
    ) {
        self.engine = engine
        self.bridge = bridge
        self.packetIO = packetIO
        self.settings = settings
        self.events = events
        self.clock = clock
    }

    /// Whether the adapter has a packet flow (flow mode) at all.
    package var hasPacketIO: Bool { packetIO != nil }

    /// Counters of the packet pump of the current run, `nil` when no pump runs.
    package var pumpCounters: PacketPumpCounters? {
        withLock { pump?.counters }
    }

    /// The core version the linked bridge reports, "unknown" when the reply cannot be read.
    package static func coreVersion(of bridge: any BridgeABI) -> String {
        BridgeReply<BridgeVersion>.decode(bridge.version()).data?.core ?? "unknown"
    }

    // MARK: Operations

    package func validate(configuration payload: Data, options: Data) async throws -> BridgeValidation {
        let bridge = self.bridge
        let text = await BridgeBlockingCall.run(name: "np.\(engine).validate") {
            bridge.validate(configuration: payload, options: options)
        }
        let reply = BridgeReply<BridgeNoPayload>.decode(text)
        if reply.code == .ok {
            return .accepted(reply: text)
        }
        let error = BridgeEngineDriver.coreError(reply.code, message: reply.error, during: .validate, timeout: nil)
        if case let .invalidConfiguration(issues) = error {
            return .rejected(CoreValidationReport(issues: issues))
        }
        throw error
    }

    /// Starts the engine; with `runPump` and a packet flow, the pump moves packets once the bridge runs.
    package func start(configuration payload: Data, options encodedOptions: Data, runPump: Bool) async throws {
        let abi = bridge.abiVersion()
        guard abi == BridgeContract.abiVersion else {
            throw CoreError.operationFailed(
                operation: .start,
                message: "\(engine) bridge ABI \(abi), the adapter needs \(BridgeContract.abiVersion)"
            )
        }

        let claimed: (busy: Phase?, logs: BridgeLogReader?) = withLock {
            guard phase == .idle else { return (phase, nil) }
            phase = .starting
            engineGone = nil
            lastHealthCounters = PacketPumpCounters()
            let logs = events.log.map {
                BridgeLogReader(
                    bridge: self.bridge,
                    engine: self.engine,
                    timeoutMilliseconds: settings.logReadTimeoutMilliseconds,
                    bufferBytes: settings.logBufferBytes,
                    sink: $0
                )
            }
            logReader = logs
            return (nil, logs)
        }
        if let busy = claimed.busy {
            throw CoreError.operationFailed(operation: .start, message: "the adapter is \(busy.rawValue)")
        }
        let logs = claimed.logs
        logs?.start()

        let bridge = self.bridge
        let engine = self.engine
        let stopMilliseconds = BridgeEngineDriver.milliseconds(settings.stopTimeout)
        let text = await withTaskCancellationHandler {
            await BridgeBlockingCall.run(name: "np.\(engine).start") {
                bridge.start(configuration: payload, options: encodedOptions)
            }
        } onCancel: {
            // `npb_stop` interrupts a start in progress. On its own thread: the cancelling task must not
            // block in Go.
            let interrupter = Thread {
                _ = bridge.stop(timeoutMilliseconds: stopMilliseconds)
            }
            interrupter.name = "np.\(engine).interrupt"
            interrupter.start()
        }
        let reply = BridgeReply<BridgeNoPayload>.decode(text)
        guard reply.code == .ok else {
            withLock {
                phase = .idle
                logReader = nil
            }
            if let logs = logs {
                await BridgeBlockingCall.run(name: "np.\(engine).log.stop") { logs.stop() }
            }
            throw BridgeEngineDriver.coreError(reply.code, message: reply.error, during: .start, timeout: settings.startTimeout)
        }

        var newPump: PacketPump?
        if runPump, let io = packetIO {
            newPump = PacketPump(bridge: bridge, engine: engine, io: io, configuration: settings.pump) { [weak self] code in
                self?.packetDeviceGone(code)
            }
        }
        withLock {
            pump = newPump
            phase = .running
        }
        newPump?.start()
    }

    package func stop() async throws {
        let (currentPump, logs): (PacketPump?, BridgeLogReader?) = withLock {
            phase = .stopping
            return (pump, logReader)
        }

        // The pump first, so that the device closing under it is not taken for an engine that died.
        currentPump?.beginStop()
        let bridge = self.bridge
        let milliseconds = BridgeEngineDriver.milliseconds(settings.stopTimeout)
        let (text, joined) = await BridgeBlockingCall.run(name: "np.\(engine).stop") { () -> (String, Bool) in
            let text = bridge.stop(timeoutMilliseconds: milliseconds)
            let joined = currentPump?.join() ?? true
            logs?.stop()
            return (text, joined)
        }

        withLock {
            pump = nil
            logReader = nil
            phase = .idle
        }

        let reply = BridgeReply<BridgeNoPayload>.decode(text)
        guard reply.code == .ok else {
            throw BridgeEngineDriver.coreError(reply.code, message: reply.error, during: .stop, timeout: settings.stopTimeout)
        }
        if !joined {
            throw CoreError.operationFailed(operation: .stop, message: "packet pump threads did not finish in time")
        }
    }

    /// `npb_observe` mapped to the engine-neutral observation; the JSON shape is the same in both bridges.
    package func groupObservations() throws -> [CoreGroupObservation] {
        let reply = BridgeReply<BridgeObservation>.decode(bridge.observe())
        guard reply.code == .ok, let observation = reply.data else {
            let code = reply.code == .ok ? BridgeCode.internalError : reply.code
            throw BridgeEngineDriver.coreError(code, message: reply.error, during: .statistics, timeout: nil)
        }
        return BridgeEngineDriver.map(observation)
    }

    /// `npb_select`. A `nil` member is sent as the empty string: the group chooses again.
    package func selectGroupMember(group: String, member: String?) throws {
        let reply = BridgeReply<BridgeNoPayload>.decode(bridge.select(group: group, member: member ?? ""))
        guard reply.code == .ok else {
            throw BridgeEngineDriver.coreError(reply.code, message: reply.error, during: .statistics, timeout: nil)
        }
    }

    package static func map(_ observation: BridgeObservation) -> [CoreGroupObservation] {
        func date(_ milliseconds: Int64?) -> Date? {
            guard let milliseconds = milliseconds, milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
        func nonEmpty(_ text: String?) -> String? {
            guard let text = text, !text.isEmpty else { return nil }
            return text
        }
        return (observation.groups ?? []).map { group in
            CoreGroupObservation(
                tag: group.tag,
                kind: group.kind ?? "",
                current: nonEmpty(group.now),
                pinned: nonEmpty(group.fixed),
                members: (group.members ?? []).map { member in
                    let alive = member.alive ?? false
                    let delay = member.delayMs.flatMap { $0 > 0 && alive ? Int(clamping: $0) : nil }
                    return CoreGroupMember(
                        tag: member.tag, alive: alive, delayMilliseconds: delay,
                        lastTry: date(member.lastTryUnixMs), lastSeen: date(member.lastSeenUnixMs)
                    )
                }
            )
        }
    }

    /// `npb_stats` decoded into the engine's payload type, or the normalised error.
    package func statistics<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        let reply = BridgeReply<Payload>.decode(bridge.stats())
        guard reply.code == .ok, let stats = reply.data else {
            let code = reply.code == .ok ? BridgeCode.internalError : reply.code
            throw BridgeEngineDriver.coreError(code, message: reply.error, during: .statistics, timeout: nil)
        }
        return stats
    }

    package func health() async -> CoreHealth {
        let now = clock()
        let (currentPhase, currentPump, gone, previous) = withLock { (phase, pump, engineGone, lastHealthCounters) }

        guard currentPhase == .running else {
            return CoreHealth(status: .unknown, detail: "the adapter is \(currentPhase.rawValue)", checkedAt: now)
        }
        if let code = gone {
            let error = CoreError.unexpectedExit(message: "packet device: \(code)")
            return CoreHealth(status: .unhealthy, detail: error.description, checkedAt: now, lastError: error)
        }
        let reply = BridgeReply<BridgeHealth>.decode(bridge.health())
        guard reply.code == .ok, let health = reply.data else {
            let error = BridgeEngineDriver.coreError(reply.code == .ok ? .internalError : reply.code, message: reply.error, during: .health, timeout: nil)
            return CoreHealth(status: .unhealthy, detail: error.description, checkedAt: now, lastError: error)
        }
        guard health.state == "running", health.coreRunning != false else {
            var lastError: CoreError?
            if let code = health.lastErrorCode, code != 0 {
                lastError = BridgeEngineDriver.coreError(BridgeCode(rawValue: code), message: health.lastError ?? "", during: .health, timeout: nil)
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

    private func packetDeviceGone(_ code: BridgeCode) {
        lock.lock()
        let report = phase == .running && engineGone == nil
        if report { engineGone = code }
        lock.unlock()
        if report {
            events.unexpectedExit?("\(engine) packet device stopped: \(code)")
        }
    }

    // MARK: Shared helpers

    /// Translates a bridge result code into the one error type that leaves an adapter.
    package static func coreError(_ code: BridgeCode, message: String, during operation: CoreOperation, timeout: TimeInterval?) -> CoreError {
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

    package static func clip(_ text: String) -> String {
        if text.count <= CoreError.maximumMessageLength { return text }
        return String(text.prefix(CoreError.maximumMessageLength)) + "..."
    }

    package static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int32(clamping: Int64(min(seconds * 1000, Double(Int32.max))))
    }

    /// Adds a signed bridge counter to an unsigned total, saturating.
    package static func add(_ total: UInt64, _ value: Int64) -> UInt64 {
        guard value > 0 else { return total }
        let (sum, overflow) = total.addingReportingOverflow(UInt64(value))
        return overflow ? UInt64.max : sum
    }

    /// The format check both adapters make before the bridge sees anything.
    package static func formatIssue(_ configuration: CoreConfiguration, accepted: [String]) -> CoreValidationIssue? {
        guard accepted.contains(configuration.format.lowercased()) else {
            return CoreValidationIssue(
                severity: .error,
                message: "configuration format '\(configuration.format)' is not "
                    + accepted.map { "'\($0)'" }.joined(separator: " or ")
            )
        }
        return nil
    }
}

package extension Int32 {
    /// `nil` for 0, so that a zero deadline is left out of the options and the bridge's default applies.
    var nonZero: Int? { self == 0 ? nil : Int(self) }
}

/// Runs a blocking bridge call on its own thread and resumes the caller when it returns, so that Go never
/// blocks a thread of the Swift cooperative pool.
enum BridgeBlockingCall {
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
