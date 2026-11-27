// Verified on Linux only (Swift 5.10.1, swift test).
import CoreAbstraction
import DomainModels
import EngineBridge
import EngineBridgeTestSupport
import Foundation
import XCTest
@testable import EngineMihomo

/// The Mihomo adapter against a fake bridge that answers with the Mihomo bridge's payload shapes
/// (Cores/MihomoBridge/engine: ConfigSummary, Stats, version with "engine").
final class MihomoCoreTests: XCTestCase {
    private let config = CoreConfiguration(
        coreID: MihomoCore.identifier,
        format: "yaml",
        payload: Data("mode: rule\nrules:\n  - MATCH,DIRECT\ntun:\n  enable: true\n  stack: mips\n".utf8)
    )

    private func mihomoBridge() -> FakeBridge {
        let bridge = FakeBridge()
        bridge.set {
            $0.versionReply = #"{"code":0,"data":{"abi":1,"engine":"mihomo","core":"v1.19.34","go":"go1.27.4"}}"#
            $0.validateReply = #"{"code":0,"data":{"mode":"rule","logLevel":"warning","proxies":0,"proxyProviders":0,"ruleProviders":0,"rules":1,"listeners":0,"hasTun":true,"depth":"parse"}}"#
            $0.statsReply = #"{"code":0,"data":{"uptimeMs":2500,"total":{"tag":"","uplink":300,"downlink":4000},"connections":3,"idleClosedTcp":1,"idleClosedUdp":2,"tun":{"rxPackets":5}}}"#
        }
        return bridge
    }

    private func settings() -> MihomoCoreSettings {
        var settings = MihomoCoreSettings()
        settings.bridge.pump.readTimeoutMilliseconds = 20
        settings.bridge.logReadTimeoutMilliseconds = 20
        return settings
    }

    private func options(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testDescriptorCarriesTheMihomoVersion() {
        let descriptor = MihomoCore.makeDescriptor(bridge: mihomoBridge())
        XCTAssertEqual(descriptor.id, "mihomo")
        XCTAssertEqual(descriptor.displayName, "Mihomo")
        XCTAssertEqual(descriptor.version, "v1.19.34")
        XCTAssertFalse(descriptor.capabilities.features.contains(.hotReload))
        XCTAssertFalse(descriptor.capabilities.features.contains(.perOutboundStatistics), "the core counts per connection only")
        XCTAssertTrue(descriptor.capabilities.protocols.contains(.vless))
    }

    func testStartRunsThePumpWithMihomoOptionsAndStopEndsIt() async throws {
        let bridge = mihomoBridge()
        let io = FakePacketIO()
        var custom = settings()
        custom.homeDirectory = "/tmp/home"
        custom.tcpIdleTimeout = 120
        custom.udpIdleTimeout = 15
        custom.inQueueBytes = 1 << 20
        let core = MihomoCore(bridge: bridge, packetIO: io, settings: custom)
        try await core.start(config, options: CoreStartOptions(mtu: 1400, memoryLimitBytes: 40 << 20))

        let sent = bridge.read { $0.startCalls.first }
        XCTAssertEqual(sent?.config, config.payload, "the YAML goes to the bridge unchanged")
        let opts = options(sent?.options ?? Data())
        XCTAssertEqual(Set(opts.keys), ["startTimeoutMs", "stopTimeoutMs", "logLevel", "homeDir", "tcpIdleTimeoutMs", "udpIdleTimeoutMs", "memory", "tun"])
        XCTAssertNil(opts["accessLog"], "the Mihomo bridge refuses the Xray bridge's fields")
        XCTAssertEqual(opts["homeDir"] as? String, "/tmp/home")
        XCTAssertEqual(opts["tcpIdleTimeoutMs"] as? Int, 120_000)
        XCTAssertEqual(opts["udpIdleTimeoutMs"] as? Int, 15_000)
        let tun = opts["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "flow")
        XCTAssertEqual(tun?["mtu"] as? Int, 1400)
        XCTAssertEqual(tun?["inQueueBytes"] as? Int, 1 << 20)
        XCTAssertNil(tun?["fd"])
        XCTAssertEqual((opts["memory"] as? [String: Any])?["limitBytes"] as? Int, 40 << 20)

        io.supply([packet(version: 4, size: 64, fill: 3)])
        XCTAssertTrue(bridge.waitForInbound(count: 1))
        bridge.queueOutbound([packet(version: 6, size: 80, fill: 4)])
        XCTAssertTrue(io.waitForWritten(count: 1))
        XCTAssertEqual(io.written.last?.families, [.ipv6])
        let health = await core.health()
        XCTAssertEqual(health.status, .healthy)

        try await core.stop()
        XCTAssertNil(core.pumpCounters)
        XCTAssertEqual(bridge.read { $0.stopCalls }, 1)
    }

    func testPacketTunnelSettingsNameOnlyTheMobileProfile() async throws {
        var tunnelSettings = MihomoCoreSettings.packetTunnel
        XCTAssertEqual(tunnelSettings.bridge.memoryProfile, .mobile)
        XCTAssertNil(tunnelSettings.tcpIdleTimeout, "the bridge holds the profile's idle timeouts")
        XCTAssertNil(tunnelSettings.udpIdleTimeout)
        XCTAssertNil(tunnelSettings.bridge.memoryLimitBytes)
        tunnelSettings.bridge.pump = settings().bridge.pump
        let bridge = mihomoBridge()
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: tunnelSettings)

        _ = try await core.validate(config)
        let checked = options(bridge.read { $0.validateCalls[0].options })
        XCTAssertEqual(checked["memory"] as? [String: String], ["profile": "mobile"])
        XCTAssertEqual((checked["tun"] as? [String: Any])?["mode"] as? String, "flow", "checked in the mode it will run in")
        XCTAssertNil(checked["tcpIdleTimeoutMs"])

        try await core.start(config, options: CoreStartOptions(mtu: TunnelAddressing.standard.mtu))
        let sent = options(bridge.read { $0.startCalls[0].options })
        XCTAssertEqual(sent["memory"] as? [String: String], ["profile": "mobile"], "only the profile name")
        XCTAssertNil(sent["homeDir"], "the bridge default unless the host names one")
        XCTAssertEqual((sent["tun"] as? [String: Any])?["mtu"] as? Int, TunnelAddressing.standard.mtu)
        try await core.stop()
    }

    func testFileDescriptorAndWrongFormatAreRefusedBeforeTheBridge() async {
        let bridge = mihomoBridge()
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        do {
            try await core.start(config, options: CoreStartOptions(tunnelFileDescriptor: 7, mtu: 1500))
            XCTFail("the Mihomo bridge has no fd mode")
        } catch let error as CoreError {
            guard case .operationFailed(.start, _) = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
        let toml = CoreConfiguration(coreID: MihomoCore.identifier, format: "toml", payload: Data("a".utf8))
        do {
            try await core.start(toml, options: .none)
            XCTFail()
        } catch let error as CoreError {
            guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail()
        }
        let report = try? await core.validate(toml)
        XCTAssertEqual(report?.isValid, false)
        XCTAssertEqual(bridge.read { $0.startCalls.count }, 0)
        XCTAssertEqual(bridge.read { $0.validateCalls.count }, 0)
        // JSON is accepted as well: the bridge parses both.
        let json = CoreConfiguration(coreID: MihomoCore.identifier, format: "json", payload: Data("{}".utf8))
        let valid = try? await core.validate(json)
        XCTAssertEqual(valid?.isValid, true)
    }

    func testOverriddenSettingsBecomeWarningsNotSilence() async throws {
        let bridge = mihomoBridge()
        bridge.set {
            $0.validateReply = #"{"code":0,"data":{"mode":"rule","rules":1,"hasTun":true,"depth":"parse","overridden":["find-process-mode: strict -> off (no process lookup inside an extension)","tun.device: ignored"]}}"#
        }
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        let report = try await core.validate(config)
        XCTAssertTrue(report.isValid, "overrides do not make the configuration invalid")
        XCTAssertEqual(report.warnings.map { $0.message }, [
            "overridden by the bridge: find-process-mode: strict -> off (no process lookup inside an extension)",
            "overridden by the bridge: tun.device: ignored",
        ])
    }

    func testValidateMapsErrorsLikeTheXrayAdapter() async throws {
        let bridge = mihomoBridge()
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        bridge.set { $0.validateReply = #"{"code":5,"error":"tun.stack must be mips"}"# }
        let bad = try await core.validate(config)
        XCTAssertFalse(bad.isValid)
        XCTAssertEqual(bad.errors.first?.message, "config_unsupported: tun.stack must be mips")

        // A check while the engine runs: the bridge refuses with invalid_state.
        bridge.set { $0.validateReply = #"{"code":2,"error":"validate while an engine is active"}"# }
        do {
            _ = try await core.validate(config)
            XCTFail()
        } catch let error as CoreError {
            guard case let .operationFailed(.validate, message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("invalid_state:"))
        }
    }

    func testStatisticsUseTheTotalAndTheConnectionCount() async throws {
        let bridge = mihomoBridge()
        let core = MihomoCore(bridge: bridge, packetIO: nil, settings: settings(), clock: { Date(timeIntervalSince1970: 20) })
        try await core.start(config, options: .none)
        XCTAssertNil(options(bridge.read { $0.startCalls[0].options })["tun"], "no packet flow, no tun options")
        let stats = try await core.statistics()
        XCTAssertEqual(stats.traffic, TrafficCounters(uplinkBytes: 300, downlinkBytes: 4000))
        XCTAssertEqual(stats.outbounds, [:])
        XCTAssertEqual(stats.activeConnections, 3)
        XCTAssertEqual(stats.uptime, 2.5)
        XCTAssertEqual(stats.capturedAt, Date(timeIntervalSince1970: 20))
        try await core.stop()
        do {
            _ = try await core.statistics()
            XCTFail()
        } catch let error as CoreError {
            guard case .notRunning = error else { return XCTFail("\(error)") }
        }
    }

    func testCancellationInterruptsABlockedStart() async throws {
        let bridge = mihomoBridge()
        bridge.set { $0.startBlocksUntilStop = true }
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        let task = Task { try await core.start(config, options: .none) }
        XCTAssertTrue(eventually { bridge.read { $0.startCalls.count } == 1 })
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled start must not succeed")
        } catch let error as CoreError {
            guard case .cancelled(.start) = error else { return XCTFail("\(error)") }
        }
        XCTAssertGreaterThanOrEqual(bridge.read { $0.stopCalls }, 1)
    }

    func testCrashIsReportedWithTheEngineName() async throws {
        let bridge = mihomoBridge()
        let messages = Locked<[String]>([])
        let events = BridgeCoreEvents(unexpectedExit: { message in messages.mutate { $0.append(message) } })
        let core = MihomoCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings(), events: events)
        try await core.start(config, options: .none)
        bridge.crash()
        XCTAssertTrue(eventually { messages.value.first?.hasPrefix("mihomo packet device stopped") == true })
        let health = await core.health()
        XCTAssertEqual(health.status, .unhealthy)
        try await core.stop()
    }

    func testRegistryAndLifecycleRunTheMihomoEngine() async throws {
        let registry = CoreRegistry()
        let bridge = mihomoBridge()
        let descriptor = MihomoCore.makeDescriptor(bridge: bridge)
        try registry.register(descriptor) { MihomoCore(bridge: bridge, packetIO: nil, descriptor: descriptor) }
        let lifecycle = CoreLifecycle(core: try registry.makeCore("mihomo"))
        try await lifecycle.start(config, options: .none, timeout: 5)
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        try await lifecycle.shutdown(timeout: 5)
        XCTAssertThrowsError(try registry.makeCore("xray"), "only the engine of this extension is registered")
    }
}
