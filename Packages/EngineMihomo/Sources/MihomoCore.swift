// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never run against the real
// bridge or inside a Packet Tunnel extension.
import CoreAbstraction
import EngineBridge
import Foundation

/// Settings of the Mihomo adapter: the ones both bridges share plus the Mihomo bridge's own. Limits of this
/// project, not of the platform or of the core.
public struct MihomoCoreSettings: Sendable {
    public var bridge = BridgeCoreSettings()
    /// The core's home directory (`homeDir`: cache.db, provider caches, geodata). Process-wide in the core.
    /// `nil` keeps the bridge default, `<TMPDIR>/np-mihomo`.
    public var homeDirectory: String?
    /// Idle timeouts the bridge's sweeper applies (`engine/idle.go`); `nil` keeps the profile's values.
    public var tcpIdleTimeout: TimeInterval?
    public var udpIdleTimeout: TimeInterval?
    /// Capacity of the bridge's device-to-core queue (`tun.inQueueBytes`); `nil` keeps the bridge default.
    public var inQueueBytes: Int?

    public init() {}

    /// The settings of the Packet Tunnel extension: the bridge's `mobile` profile, whose values live in the
    /// bridge (`Documentation/Performance/memory-budget.md` §10).
    public static var packetTunnel: MihomoCoreSettings {
        var settings = MihomoCoreSettings()
        settings.bridge = .packetTunnel
        return settings
    }
}

/// The `NetworkCore` adapter of the Mihomo bridge (ADR-0001 §5, ADR-0007).
///
/// - Configuration: Clash/Mihomo YAML (or JSON) passed to the bridge as it is. The bridge rewrites settings
///   that cannot work inside an extension and lists each rewrite in `overridden`; a check turns that list into
///   warnings, so that nothing changes silently (ADR-0002).
/// - Packets: only with a `TunnelPacketIO` (`tun.mode = "flow"`, the bridge's own listener on the `mips`
///   stack). The bridge has no fd mode, so a start with a file descriptor is refused before the bridge.
/// - Lifecycle, packet pump, log reader, health and error normalisation are `BridgeEngineDriver`, the same code
///   `XrayCore` runs.
/// - Reload is not offered, as for Xray: the bridge's reload is stop + start.
/// - A check while the engine runs is refused by the bridge (`invalid_state`: parsing would change settings of
///   the running core); it surfaces as `.operationFailed(.validate, ...)`.
public final class MihomoCore: NetworkCore, @unchecked Sendable {
    public static let identifier: CoreIdentifier = "mihomo"
    /// The configuration formats this adapter accepts (the bridge parses both).
    public static let configurationFormats = ["yaml", "json"]

    /// What the core implements (adapter/outbound of the pinned core). Proven end to end by the bridge's tests:
    /// only VLESS+REALITY+Vision and Shadowsocks-2022 against Xray 26.11.9 (Cores/MihomoBridge/README.md).
    public static let baseCapabilities = CoreCapabilities(
        protocols: [.vless, .vmess, .trojan, .shadowsocks, .hysteria2, .wireguard],
        transports: [.tcp, .websocket, .httpUpgrade, .grpc, .xhttp],
        features: [.configurationValidation, .trafficStatistics, .selectorGroups, .connectionList]
    )

    /// The descriptor with the core version the linked bridge reports.
    public static func makeDescriptor(bridge: any BridgeABI) -> CoreDescriptor {
        CoreDescriptor(
            id: identifier,
            displayName: "Mihomo",
            version: BridgeEngineDriver.coreVersion(of: bridge),
            capabilities: baseCapabilities
        )
    }

    public let descriptor: CoreDescriptor
    private let settings: MihomoCoreSettings
    private let driver: BridgeEngineDriver

    public init(
        bridge: any BridgeABI,
        packetIO: (any TunnelPacketIO)?,
        descriptor: CoreDescriptor? = nil,
        settings: MihomoCoreSettings = MihomoCoreSettings(),
        events: BridgeCoreEvents = BridgeCoreEvents(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.descriptor = descriptor ?? MihomoCore.makeDescriptor(bridge: bridge)
        self.settings = settings
        self.driver = BridgeEngineDriver(
            engine: "mihomo",
            bridge: bridge,
            packetIO: packetIO,
            settings: settings.bridge,
            events: events,
            clock: clock
        )
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
        case let .rejected(report):
            return report
        case let .accepted(reply):
            // Each setting the bridge changed or ignored is a warning: the configuration runs, but not exactly
            // as written. The entries name keys and modes, never addresses or secrets.
            let summary = BridgeReply<MihomoConfigSummary>.decode(reply).data
            let warnings = (summary?.overridden ?? []).map {
                CoreValidationIssue(severity: .warning, message: BridgeEngineDriver.clip("overridden by the bridge: \($0)"))
            }
            return CoreValidationReport(issues: warnings)
        }
    }

    public func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
        if let issue = formatIssue(configuration) {
            throw CoreError.invalidConfiguration(issues: [issue])
        }
        if options.tunnelFileDescriptor != nil {
            throw CoreError.operationFailed(
                operation: .start,
                message: "the Mihomo bridge has no fd mode; start it with the packet flow (tun.mode \"flow\")"
            )
        }
        let encoded = bridgeOptions(for: options, validating: false).encoded()
        try await driver.start(configuration: configuration.payload, options: encoded, runPump: true)
    }

    public func stop() async throws {
        try await driver.stop()
    }

    public func reload(_ configuration: CoreConfiguration) async throws {
        throw CoreError.unsupportedFeature(.hotReload)
    }

    public func statistics() async throws -> CoreStatistics {
        let stats = try driver.statistics(MihomoBridgeStats.self)
        var total = TrafficCounters()
        if let counted = stats.total {
            total.uplinkBytes = BridgeEngineDriver.add(0, counted.uplink)
            total.downlinkBytes = BridgeEngineDriver.add(0, counted.downlink)
        }
        return CoreStatistics(
            capturedAt: driver.clock(),
            traffic: total,
            // The core does not count per outbound; an empty map, not invented numbers.
            outbounds: [:],
            activeConnections: stats.connections,
            memoryFootprintBytes: nil,
            uptime: stats.uptimeMs.map { TimeInterval($0) / 1000 }
        )
    }

    /// The core's connection tracker, newest first (`npb_connections`).
    public func connections(limit: Int) async throws -> CoreConnectionSnapshot {
        let list = try driver.connections(MihomoBridgeConnections.self, limit: limit)
        let items = list.items.map { item in
            CoreConnection(
                id: item.id,
                network: item.network,
                destination: item.destination,
                rule: item.rule,
                chain: item.chain ?? [],
                uploadBytes: BridgeEngineDriver.add(0, item.upload),
                downloadBytes: BridgeEngineDriver.add(0, item.download),
                startedAt: item.startMs > 0 ? Date(timeIntervalSince1970: TimeInterval(item.startMs) / 1000) : nil
            )
        }
        return CoreConnectionSnapshot(capturedAt: driver.clock(), total: list.total, items: items)
    }

    public func health() async -> CoreHealth {
        await driver.health()
    }

    // MARK: Helpers

    private func formatIssue(_ configuration: CoreConfiguration) -> CoreValidationIssue? {
        BridgeEngineDriver.formatIssue(configuration, accepted: MihomoCore.configurationFormats)
    }

    /// The bridge options for a start, or, with `validating`, for a check in the same tun mode (the bridge
    /// refuses `tun.enable` without `tun.mode: "flow"`, so a check must name the mode the start will use).
    func bridgeOptions(for options: CoreStartOptions, validating: Bool) -> MihomoBridgeOptions {
        let common = settings.bridge
        var result = MihomoBridgeOptions()
        result.startTimeoutMs = BridgeEngineDriver.milliseconds(common.startTimeout).nonZero
        result.stopTimeoutMs = BridgeEngineDriver.milliseconds(common.stopTimeout).nonZero
        result.logLevel = common.logLevel
        result.homeDir = settings.homeDirectory
        if driver.hasPacketIO {
            var tun = MihomoBridgeOptions.Tun(mode: "flow")
            tun.mtu = options.mtu
            tun.outQueueBytes = common.outQueueBytes
            tun.inQueueBytes = settings.inQueueBytes
            result.tun = tun
        }
        var memory = MihomoBridgeOptions.Memory(profile: common.memoryProfile?.rawValue)
        if !validating {
            memory.limitBytes = (options.memoryLimitBytes ?? common.memoryLimitBytes).map { Int64(clamping: $0) }
            memory.gcPercent = common.gcPercent
            result.tcpIdleTimeoutMs = settings.tcpIdleTimeout.flatMap { BridgeEngineDriver.milliseconds($0).nonZero }
            result.udpIdleTimeoutMs = settings.udpIdleTimeout.flatMap { BridgeEngineDriver.milliseconds($0).nonZero }
        }
        if memory != MihomoBridgeOptions.Memory() {
            result.memory = memory
        }
        return result
    }
}

extension MihomoCore: OutboundGroupControlling {
    /// The groups of the running configuration with the core's own health measurements (`npb_observe`).
    public func groupObservations() async throws -> [CoreGroupObservation] {
        try driver.groupObservations()
    }

    /// Pins a member for new connections without a restart (`npb_select`).
    public func selectGroupMember(group: String, member: String?) async throws {
        try driver.selectGroupMember(group: group, member: member)
    }
}
