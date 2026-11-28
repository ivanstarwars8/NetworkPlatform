// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never run against the real
// bridge or inside a Packet Tunnel extension.
import CoreAbstraction
import EngineBridge
import Foundation

/// The `NetworkCore` adapter of the Xray bridge (ADR-0001 §5).
///
/// - Configuration: the compiled Xray JSON is passed to the bridge as it is; nothing is rewritten.
///   Run-time parameters (tun mode, MTU, memory, deadlines) travel as bridge options.
/// - Packets: with a `TunnelPacketIO` the bridge runs in `tun.mode = "flow"` and a `PacketPump` moves the
///   batches; with `CoreStartOptions.tunnelFileDescriptor` it runs in `tun.mode = "fd"` and reads the
///   device itself (not located on Apple yet, ADR-0001 §4, risk R-08).
/// - Lifecycle, packet pump, log reader, health and error normalisation are `BridgeEngineDriver`
///   (Packages/EngineBridge), shared with `MihomoCore`: blocking bridge calls run on their own threads;
///   `start` is interrupted on cancellation with `npb_stop`.
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
        features: [.configurationValidation, .trafficStatistics, .perOutboundStatistics, .selectorGroups]
    )

    /// The descriptor with the core version the linked bridge reports.
    public static func makeDescriptor(bridge: any BridgeABI) -> CoreDescriptor {
        CoreDescriptor(
            id: identifier,
            displayName: "Xray-core",
            version: BridgeEngineDriver.coreVersion(of: bridge),
            capabilities: baseCapabilities
        )
    }

    public let descriptor: CoreDescriptor
    private let settings: BridgeCoreSettings
    private let driver: BridgeEngineDriver

    public init(
        bridge: any BridgeABI,
        packetIO: (any TunnelPacketIO)?,
        descriptor: CoreDescriptor? = nil,
        settings: BridgeCoreSettings = BridgeCoreSettings(),
        events: BridgeCoreEvents = BridgeCoreEvents(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.descriptor = descriptor ?? XrayCore.makeDescriptor(bridge: bridge)
        self.settings = settings
        self.driver = BridgeEngineDriver(engine: "xray", bridge: bridge, packetIO: packetIO, settings: settings, events: events, clock: clock)
    }

    /// Counters of the packet pump of the current run, `nil` when no pump runs.
    public var pumpCounters: PacketPumpCounters? {
        driver.pumpCounters
    }

    // MARK: NetworkCore

    public func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport {
        if let issue = formatIssue(configuration) {
            return CoreValidationReport(issues: [issue])
        }
        let options = bridgeOptions(for: .none, validating: true).encoded()
        switch try await driver.validate(configuration: configuration.payload, options: options) {
        case .accepted:
            return .valid
        case let .rejected(report):
            return report
        }
    }

    public func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
        if let issue = formatIssue(configuration) {
            throw CoreError.invalidConfiguration(issues: [issue])
        }
        let encoded = bridgeOptions(for: options, validating: false).encoded()
        // fd mode: the bridge reads the device itself, no pump.
        try await driver.start(configuration: configuration.payload, options: encoded, runPump: options.tunnelFileDescriptor == nil)
    }

    public func stop() async throws {
        try await driver.stop()
    }

    public func reload(_ configuration: CoreConfiguration) async throws {
        throw CoreError.unsupportedFeature(.hotReload)
    }

    public func statistics() async throws -> CoreStatistics {
        let stats = try driver.statistics(XrayBridgeStats.self)
        var total = TrafficCounters()
        // Inbound counters are the bytes the core exchanged with the device: the user's traffic.
        for counter in stats.inbounds ?? [] {
            total.uplinkBytes = BridgeEngineDriver.add(total.uplinkBytes, counter.uplink)
            total.downlinkBytes = BridgeEngineDriver.add(total.downlinkBytes, counter.downlink)
        }
        var outbounds: [String: TrafficCounters] = [:]
        for counter in stats.outbounds ?? [] {
            var entry = outbounds[counter.tag] ?? TrafficCounters()
            entry.uplinkBytes = BridgeEngineDriver.add(entry.uplinkBytes, counter.uplink)
            entry.downlinkBytes = BridgeEngineDriver.add(entry.downlinkBytes, counter.downlink)
            outbounds[counter.tag] = entry
        }
        return CoreStatistics(
            capturedAt: driver.clock(),
            traffic: total,
            outbounds: outbounds,
            activeConnections: nil,
            memoryFootprintBytes: nil,
            uptime: stats.uptimeMs.map { TimeInterval($0) / 1000 }
        )
    }

    public func health() async -> CoreHealth {
        await driver.health()
    }

    // MARK: Helpers

    private func formatIssue(_ configuration: CoreConfiguration) -> CoreValidationIssue? {
        BridgeEngineDriver.formatIssue(configuration, accepted: [XrayCore.configurationFormat])
    }

    /// The bridge options for a start (or, with `validating`, for a check in the same tun mode: in flow
    /// mode the bridge replaces the config's tun inbound and refuses a config without one, and a check in
    /// another mode would let the core construct a system tun inbound).
    func bridgeOptions(for options: CoreStartOptions, validating: Bool) -> XrayBridgeOptions {
        var result = XrayBridgeOptions()
        result.startTimeoutMs = BridgeEngineDriver.milliseconds(settings.startTimeout).nonZero
        result.stopTimeoutMs = BridgeEngineDriver.milliseconds(settings.stopTimeout).nonZero
        result.logLevel = settings.logLevel
        var tun = XrayBridgeOptions.Tun()
        if let descriptor = options.tunnelFileDescriptor {
            tun.mode = "fd"
            tun.fd = descriptor
        } else if driver.hasPacketIO {
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
}

extension XrayCore: OutboundGroupControlling {
    /// The groups of the running configuration with the core's own health measurements (`npb_observe`).
    public func groupObservations() async throws -> [CoreGroupObservation] {
        try driver.groupObservations()
    }

    /// Pins a member for new connections without a restart (`npb_select`).
    public func selectGroupMember(group: String, member: String?) async throws {
        try driver.selectGroupMember(group: group, member: member)
    }
}
