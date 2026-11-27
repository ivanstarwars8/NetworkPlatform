// Verified on Linux only (Swift 5.10.1, swift test).
import CoreAbstraction
import DomainModels
import Foundation
import XCTest
@testable import EngineXray

final class XrayCoreTests: XCTestCase {
    private let config = CoreConfiguration(coreID: XrayCore.identifier, format: "json", payload: Data(#"{"inbounds":[{"protocol":"tun"}]}"#.utf8))

    private func settings() -> XrayCoreSettings {
        var settings = XrayCoreSettings()
        settings.pump.readTimeoutMilliseconds = 20
        settings.logReadTimeoutMilliseconds = 20
        return settings
    }

    private func options(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testDescriptorCarriesBridgeVersionAndNoHotReload() {
        let descriptor = XrayCore.makeDescriptor(bridge: FakeBridge())
        XCTAssertEqual(descriptor.id, "xray")
        XCTAssertEqual(descriptor.version, "26.11.9")
        XCTAssertFalse(descriptor.capabilities.features.contains(.hotReload))
        XCTAssertTrue(descriptor.capabilities.features.contains(.trafficStatistics))
    }

    func testStartInFlowModeRunsThePumpAndStopEndsIt() async throws {
        let bridge = FakeBridge()
        let io = FakePacketIO()
        let core = XrayCore(bridge: bridge, packetIO: io, settings: settings())
        try await core.start(config, options: CoreStartOptions(mtu: 1400, memoryLimitBytes: 32 << 20))

        let sent = bridge.read { $0.startCalls.first }
        XCTAssertEqual(sent?.config, config.payload, "the configuration goes to the bridge unchanged")
        let opts = options(sent?.options ?? Data())
        let tun = opts["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "flow")
        XCTAssertEqual(tun?["mtu"] as? Int, 1400)
        XCTAssertNil(tun?["fd"])
        XCTAssertEqual((opts["memory"] as? [String: Any])?["limitBytes"] as? Int, 32 << 20)
        XCTAssertEqual(opts["startTimeoutMs"] as? Int, 15000)
        XCTAssertEqual(opts["stopTimeoutMs"] as? Int, 4000)
        XCTAssertEqual(opts["logLevel"] as? String, "warning")

        let up = packet(version: 4, size: 64, fill: 3)
        io.supply([up])
        XCTAssertTrue(bridge.waitForInbound(count: 1))
        let down = packet(version: 6, size: 80, fill: 4)
        bridge.queueOutbound([down])
        XCTAssertTrue(io.waitForWritten(count: 1))
        XCTAssertTrue(eventually { core.pumpCounters?.inboundPackets == 1 }, "counters are updated after the bridge call")

        let health = await core.health()
        XCTAssertEqual(health.status, .healthy)

        try await core.stop()
        XCTAssertNil(core.pumpCounters)
        XCTAssertEqual(bridge.read { $0.stopCalls }, 1)
        let after = await core.health()
        XCTAssertEqual(after.status, .unknown)
    }

    func testFileDescriptorSelectsFdModeWithoutPump() async throws {
        let bridge = FakeBridge()
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        try await core.start(config, options: CoreStartOptions(tunnelFileDescriptor: 7, mtu: 1500))
        let tun = options(bridge.read { $0.startCalls[0].options })["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "fd")
        XCTAssertEqual(tun?["fd"] as? Int, 7)
        XCTAssertNil(core.pumpCounters)
        try await core.stop()
    }

    func testNoPacketIOMeansNoTunOptions() async throws {
        let bridge = FakeBridge()
        let core = XrayCore(bridge: bridge, packetIO: nil, settings: settings())
        try await core.start(config, options: .none)
        XCTAssertNil(options(bridge.read { $0.startCalls[0].options })["tun"])
        XCTAssertNil(options(bridge.read { $0.startCalls[0].options })["memory"])
        try await core.stop()
    }

    func testPacketTunnelSettingsNameTheMobileProfileAndRepeatNoValues() async throws {
        XCTAssertEqual(XrayCoreSettings.packetTunnel.memoryProfile, .mobile)
        XCTAssertNil(XrayCoreSettings.packetTunnel.memoryLimitBytes, "the bridge holds the profile's limit")
        XCTAssertNil(XrayCoreSettings.packetTunnel.gcPercent, "the bridge holds the profile's GC percentage")
        XCTAssertNil(XrayCoreSettings.packetTunnel.outQueueBytes, "the bridge holds the profile's queue size")

        var tunnelSettings = XrayCoreSettings.packetTunnel
        tunnelSettings.pump = settings().pump
        tunnelSettings.logReadTimeoutMilliseconds = 20
        let bridge = FakeBridge()
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: tunnelSettings)

        _ = try await core.validate(config)
        let checked = options(bridge.read { $0.validateCalls[0].options })
        XCTAssertEqual(checked["memory"] as? [String: String], ["profile": "mobile"], "geodata is refused when checking too")

        try await core.start(config, options: CoreStartOptions(mtu: 1500))
        let sent = options(bridge.read { $0.startCalls[0].options })
        XCTAssertEqual(sent["memory"] as? [String: String], ["profile": "mobile"], "only the profile name, no 32 MiB / GOGC 50")
        let tun = sent["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "flow")
        XCTAssertNil(tun?["outQueueBytes"], "the profile's queue size applies")
        try await core.stop()
    }

    func testStartFailuresAreNormalised() async {
        let cases: [(String, (CoreError) -> Bool)] = [
            (#"{"code":4,"error":"bad outbound"}"#, { if case .invalidConfiguration = $0 { return true }; return false }),
            (#"{"code":5,"error":"api section"}"#, { if case .invalidConfiguration = $0 { return true }; return false }),
            (#"{"code":7,"error":"start timeout"}"#, { if case .timedOut(.start, 15) = $0 { return true }; return false }),
            (#"{"code":8,"error":"cancelled"}"#, { if case .cancelled(.start) = $0 { return true }; return false }),
            (#"{"code":6,"error":"listen failed"}"#, {
                if case let .operationFailed(.start, message) = $0 { return message == "start_failed: listen failed" }
                return false
            }),
            ("not json", { if case .operationFailed(.start, _) = $0 { return true }; return false }),
        ]
        for (reply, matches) in cases {
            let bridge = FakeBridge()
            bridge.set { $0.startReply = reply }
            let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
            do {
                try await core.start(config, options: .none)
                XCTFail("start must fail for \(reply)")
            } catch let error as CoreError {
                XCTAssertTrue(matches(error), "\(reply) -> \(error)")
            } catch {
                XCTFail("not a CoreError: \(error)")
            }
            XCTAssertNil(core.pumpCounters)
            // Stop after a failed start is allowed and harmless.
            try? await core.stop()
        }
    }

    func testLongMessagesAreClipped() {
        let error = XrayCore.coreError(.internalError, message: String(repeating: "x", count: 5000), during: .stop, timeout: nil)
        guard case let .operationFailed(_, message) = error else { return XCTFail() }
        XCTAssertLessThanOrEqual(message.count, CoreError.maximumMessageLength + 3)
    }

    func testWrongABIOrFormatIsRefusedBeforeTheBridge() async {
        let bridge = FakeBridge()
        bridge.set { $0.abi = 2 }
        let core = XrayCore(bridge: bridge, packetIO: nil, settings: settings())
        do {
            try await core.start(config, options: .none)
            XCTFail()
        } catch {}
        let yaml = CoreConfiguration(coreID: XrayCore.identifier, format: "yaml", payload: Data("a".utf8))
        let other = XrayCore(bridge: FakeBridge(), packetIO: nil, settings: settings())
        do {
            try await other.start(yaml, options: .none)
            XCTFail()
        } catch let error as CoreError {
            guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail()
        }
        XCTAssertEqual(bridge.read { $0.startCalls.count }, 0)
    }

    func testCancellationInterruptsABlockedStart() async throws {
        let bridge = FakeBridge()
        bridge.set { $0.startBlocksUntilStop = true }
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        let task = Task { try await core.start(config, options: .none) }
        XCTAssertTrue(eventually { bridge.read { $0.startCalls.count } == 1 })
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled start must not succeed")
        } catch let error as CoreError {
            guard case .cancelled(.start) = error else { return XCTFail("\(error)") }
        }
        XCTAssertGreaterThanOrEqual(bridge.read { $0.stopCalls }, 1, "npb_stop interrupted the start")
    }

    func testLifecycleDeadlineInterruptsAStuckStart() async throws {
        let bridge = FakeBridge()
        bridge.set { $0.startBlocksUntilStop = true }
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        let lifecycle = CoreLifecycle(core: core)
        do {
            try await lifecycle.start(config, options: .none, timeout: 0.2)
            XCTFail()
        } catch let error as CoreError {
            guard case .timedOut(.start, _) = error else { return XCTFail("\(error)") }
        }
        try await lifecycle.shutdown(timeout: 5)
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertGreaterThanOrEqual(bridge.read { $0.stopCalls }, 1)
    }

    func testValidateMapsConfigurationErrorsToReport() async throws {
        let bridge = FakeBridge()
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings())
        let ok = try await core.validate(config)
        XCTAssertTrue(ok.isValid)
        let tun = options(bridge.read { $0.validateCalls[0].options })["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "flow", "checked in the mode it will run in")

        bridge.set { $0.validateReply = #"{"code":5,"error":"tun.mode=flow needs exactly one tun inbound in the config"}"# }
        let bad = try await core.validate(config)
        XCTAssertFalse(bad.isValid)
        XCTAssertTrue(bad.errors[0].message.hasPrefix("config_unsupported:"))

        bridge.set { $0.validateReply = #"{"code":10,"error":"panic"}"# }
        do {
            _ = try await core.validate(config)
            XCTFail()
        } catch let error as CoreError {
            guard case .operationFailed(.validate, _) = error else { return XCTFail("\(error)") }
        }
    }

    func testStatisticsSumInboundsAndKeepOutbounds() async throws {
        let bridge = FakeBridge()
        let core = XrayCore(bridge: bridge, packetIO: nil, settings: settings(), clock: { Date(timeIntervalSince1970: 10) })
        try await core.start(config, options: .none)
        let stats = try await core.statistics()
        XCTAssertEqual(stats.traffic, TrafficCounters(uplinkBytes: 100, downlinkBytes: 2000))
        XCTAssertEqual(stats.outbounds["proxy"], TrafficCounters(uplinkBytes: 150, downlinkBytes: 2100))
        XCTAssertEqual(stats.outbounds.count, 2)
        XCTAssertEqual(stats.uptime, 1.5)
        XCTAssertEqual(stats.capturedAt, Date(timeIntervalSince1970: 10))
        try await core.stop()
        do {
            _ = try await core.statistics()
            XCTFail()
        } catch let error as CoreError {
            guard case .notRunning = error else { return XCTFail("\(error)") }
        }
    }

    func testEngineCrashIsReportedAndHealthTurnsUnhealthy() async throws {
        let bridge = FakeBridge()
        let messages = Locked<[String]>([])
        let events = XrayCoreEvents(unexpectedExit: { message in
            messages.mutate { $0.append(message) }
        })
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings(), events: events)
        try await core.start(config, options: .none)
        bridge.crash()
        XCTAssertTrue(eventually {
            let seen = messages.value
            return seen.count == 1 && seen[0].contains("closed")
        })
        let health = await core.health()
        XCTAssertEqual(health.status, .unhealthy)
        try await core.stop()
    }

    func testCrashDrivesLifecycleToFailedThroughTheHost() async throws {
        let bridge = FakeBridge()
        let box = LifecycleBox()
        let events = XrayCoreEvents(unexpectedExit: { message in
            Task { await box.lifecycle?.reportUnexpectedExit(message) }
        })
        let core = XrayCore(bridge: bridge, packetIO: FakePacketIO(), settings: settings(), events: events)
        let lifecycle = CoreLifecycle(core: core)
        await box.set(lifecycle)
        try await lifecycle.start(config, options: .none, timeout: 5)
        bridge.crash()
        var failed = false
        for _ in 0..<500 {
            if await lifecycle.state == .failed { failed = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(failed)
        try await lifecycle.shutdown(timeout: 5)
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testDegradedWhenTheSystemRefusesWrites() async throws {
        let bridge = FakeBridge()
        let io = FakePacketIO()
        io.writeResult = false
        let core = XrayCore(bridge: bridge, packetIO: io, settings: settings())
        try await core.start(config, options: .none)
        bridge.queueOutbound([packet(version: 4, size: 20, fill: 1)])
        XCTAssertTrue(eventually { core.pumpCounters?.outboundWriteFailures == 1 })
        let first = await core.health()
        XCTAssertEqual(first.status, .degraded)
        let second = await core.health()
        XCTAssertEqual(second.status, .healthy, "only failures since the previous check degrade")
        try await core.stop()
    }

    func testReloadIsNotOffered() async {
        let core = XrayCore(bridge: FakeBridge(), packetIO: nil, settings: settings())
        do {
            try await core.reload(config)
            XCTFail()
        } catch let error as CoreError {
            XCTAssertEqual(error, .unsupportedFeature(.hotReload))
        } catch {
            XCTFail()
        }
    }

    func testLogRecordsReachTheSinkAndGapsAreCounted() async throws {
        let bridge = FakeBridge()
        let received = Locked<[XrayLogRecord]>([])
        let events = XrayCoreEvents(log: { record in
            received.mutate { $0.append(record) }
        })
        let core = XrayCore(bridge: bridge, packetIO: nil, settings: settings(), events: events)
        try await core.start(config, options: .none)
        bridge.queueLog(#"{"seq":1,"t":5,"lvl":"warning","kind":"core","msg":"one"}"#)
        bridge.queueLog(#"{"seq":4,"t":6,"kind":"access","msg":"two"}"#)
        XCTAssertTrue(eventually { received.value.count == 2 })
        let records = received.value
        XCTAssertEqual(records.map { $0.message }, ["one", "two"])
        XCTAssertEqual(records[0].level, "warning")
        XCTAssertNil(records[1].level)
        try await core.stop()
    }

    func testRegistryStartsTheEngineInsteadOfCoreNotRegistered() async throws {
        let registry = CoreRegistry()
        let bridge = FakeBridge()
        let descriptor = XrayCore.makeDescriptor(bridge: bridge)
        try registry.register(descriptor) { XrayCore(bridge: bridge, packetIO: nil, descriptor: descriptor) }
        let core = try registry.makeCore("xray")
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(config, options: .none, timeout: 5)
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        try await lifecycle.shutdown(timeout: 5)
    }
}

actor LifecycleBox {
    var lifecycle: CoreLifecycle?

    func set(_ lifecycle: CoreLifecycle) {
        self.lifecycle = lifecycle
    }
}

/// Exports the start options the extension sends to the bridge, for the end-to-end run on Linux
/// (`Cores/BuildScripts/bridge-tunlab.sh compiled`). Writes NP_EXPORT_DIR/bridge-options.json when set.
final class XrayBridgeOptionsExportTests: XCTestCase {
    func testExportPacketTunnelBridgeOptions() throws {
        let core = XrayCore(bridge: FakeBridge(), packetIO: FakePacketIO(), settings: .packetTunnel)
        // The MTU the extension passes is the plan's, i.e. TunnelAddressing's (TunnelSession: `request.network.mtu`).
        let options = core.bridgeOptions(for: CoreStartOptions(mtu: TunnelAddressing.standard.mtu), validating: false)
        XCTAssertEqual(options.memory, XrayBridgeOptions.Memory(profile: "mobile"))
        XCTAssertEqual(options.tun?.mode, "flow")
        XCTAssertEqual(options.tun?.mtu, TunnelAddressing.standard.mtu)
        guard let directory = ProcessInfo.processInfo.environment["NP_EXPORT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try options.encoded().write(to: url.appendingPathComponent("bridge-options.json"))
    }
}
