import XCTest
@testable import TunnelAutomation

final class OnDemandPlannerTests: XCTestCase {
    func testDefaultsOnIPhoneConnectEverywhere() {
        let rules = OnDemandPlanner.rules(for: AutomationSettings(), on: .iOS)
        XCTAssertEqual(rules, [
            PlannedRule(.connect, interface: .wifi),
            PlannedRule(.connect, interface: .cellular),
            PlannedRule(.ignore, interface: nil),
        ])
    }

    func testTrustedNetworksComeFirst() {
        var settings = AutomationSettings(trustedNetworks: ["Дом", "Office 5G"])
        var rules = OnDemandPlanner.rules(for: settings, on: .iOS)
        XCTAssertEqual(rules.first, PlannedRule(.ignore, interface: .wifi, ssids: ["Дом", "Office 5G"]))
        settings.disconnectOnTrusted = true
        rules = OnDemandPlanner.rules(for: settings, on: .iOS)
        XCTAssertEqual(rules.first, PlannedRule(.disconnect, interface: .wifi, ssids: ["Дом", "Office 5G"]))
        XCTAssertEqual(rules.last, PlannedRule(.ignore, interface: nil))
    }

    func testUnchosenKindsAreIgnoredNotDisconnected() {
        let settings = AutomationSettings(connectOnWiFi: false, connectOnCellular: true)
        let rules = OnDemandPlanner.rules(for: settings, on: .iOS)
        XCTAssertEqual(rules[0], PlannedRule(.ignore, interface: .wifi))
        XCTAssertEqual(rules[1], PlannedRule(.connect, interface: .cellular))
        XCTAssertFalse(rules.contains { $0.action == .disconnect })
    }

    func testPlatformsOnlyGetTheirInterfaces() {
        let mac = OnDemandPlanner.rules(for: AutomationSettings(), on: .macOS)
        XCTAssertEqual(mac.compactMap(\.interface), [.wifi, .wired])
        let vision = OnDemandPlanner.rules(for: AutomationSettings(trustedNetworks: ["A"]), on: .visionOS)
        XCTAssertEqual(vision.compactMap(\.interface), [.wifi, .wifi])
        XCTAssertFalse(vision.contains { $0.interface == .cellular })
    }

    func testEveryRuleListEndsWithCatchAllIgnore() {
        for platform in AutomationPlatform.allCases {
            for wifi in [true, false] {
                let rules = OnDemandPlanner.rules(for: AutomationSettings(connectOnWiFi: wifi), on: platform)
                XCTAssertEqual(rules.last, PlannedRule(.ignore, interface: nil), "\(platform)")
                XCTAssertEqual(rules.filter { $0.interface == nil }.count, 1)
            }
        }
    }
}

final class OnDemandStateTests: XCTestCase {
    private let on = AutomationSettings(connectOnDemand: true)

    func testOffWhenNotChosen() {
        let state = OnDemandState(hasConnectedOnce: true)
        XCTAssertEqual(state.status(for: AutomationSettings(), on: .iOS), .off)
        XCTAssertFalse(state.systemEnabled(for: AutomationSettings(), on: .iOS))
    }

    func testWaitsForFirstConnection() {
        var state = OnDemandState()
        XCTAssertEqual(state.status(for: on, on: .iOS), .waitingForFirstConnection)
        XCTAssertFalse(state.systemEnabled(for: on, on: .iOS))
        state.tunnelConnected()
        XCTAssertTrue(state.systemEnabled(for: on, on: .iOS))
    }

    func testManualDisconnectSuspendsUntilManualConnect() {
        var state = OnDemandState(hasConnectedOnce: true)
        state.userDisconnected()
        XCTAssertEqual(state.status(for: on, on: .macOS), .suspended)
        state.userConnected()
        XCTAssertEqual(state.status(for: on, on: .macOS), .active)
    }

    func testNoNetworkChosen() {
        let settings = AutomationSettings(connectOnDemand: true, connectOnWiFi: false, connectOnCellular: false)
        XCTAssertEqual(OnDemandState(hasConnectedOnce: true).status(for: settings, on: .iOS), .noNetworkChosen)
        // Wired still connects on a Mac.
        XCTAssertEqual(OnDemandState(hasConnectedOnce: true).status(for: settings, on: .macOS), .active)
    }

    func testNeverOnApplTV() {
        XCTAssertEqual(OnDemandState(hasConnectedOnce: true).status(for: on, on: .tvOS), .off)
    }

    func testNewConfigurationResets() {
        var state = OnDemandState(hasConnectedOnce: true, suspendedByUser: true)
        state.configurationCreated()
        XCTAssertEqual(state, OnDemandState())
    }

    func testReconcileRespectsSystemSwitch() {
        var state = OnDemandState(hasConnectedOnce: true)
        state.reconcile(systemEnabled: false, settings: on, on: .iOS)
        XCTAssertTrue(state.suspendedByUser)

        var waiting = OnDemandState()
        waiting.reconcile(systemEnabled: false, settings: on, on: .iOS)
        XCTAssertFalse(waiting.suspendedByUser, "nothing was expected to be on")

        var agreed = OnDemandState(hasConnectedOnce: true)
        agreed.reconcile(systemEnabled: true, settings: on, on: .iOS)
        XCTAssertFalse(agreed.suspendedByUser)
    }

    func testExplanationsAreRussianSentences() {
        let all: [OnDemandStatus] = [.off, .noNetworkChosen, .waitingForFirstConnection, .suspended, .active]
        for status in all {
            if let text = status.explanation {
                XCTAssertTrue(text.hasSuffix("."))
                XCTAssertNotEqual(text, text.uppercased())
            }
            XCTAssertFalse(status.shortTitle.isEmpty)
        }
    }
}

final class TrustedNetworksTests: XCTestCase {
    func testAddTrimsOuterWhitespaceKeepsInner() {
        XCTAssertEqual(try TrustedNetworks.adding("  My Home  ", to: []).get(), ["My Home"])
    }

    func testRejections() {
        XCTAssertEqual(rejection("   ", []), .empty)
        XCTAssertEqual(rejection(String(repeating: "я", count: 17), []), .tooLong) // 34 bytes
        XCTAssertNil(TrustedNetworks.check(String(repeating: "я", count: 16)))       // 32 bytes
        XCTAssertEqual(rejection("a\nb", []), .controlCharacters)
        XCTAssertEqual(rejection("Дом", ["Дом"]), .duplicate)
        let full = (0..<TrustedNetworks.maximumCount).map { "n\($0)" }
        XCTAssertEqual(rejection("x", full), .listFull)
        XCTAssertEqual(try TrustedNetworks.adding("дом", to: ["Дом"]).get(), ["Дом", "дом"], "case-sensitive like the system")
    }

    func testSanitized() {
        XCTAssertEqual(TrustedNetworks.sanitized(["a", "", "a", "b\n", "c"]), ["a", "c"])
    }

    func testMessagesSayWhatToDo() {
        let all: [TrustedNetworks.Rejection] = [.empty, .tooLong, .controlCharacters, .duplicate, .listFull]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
    }

    private func rejection(_ name: String, _ list: [String]) -> TrustedNetworks.Rejection? {
        if case let .failure(rejection) = TrustedNetworks.adding(name, to: list) { return rejection }
        return nil
    }
}

final class AutomationRecordTests: XCTestCase {
    func testRoundTrip() {
        let record = AutomationRecord(
            settings: AutomationSettings(connectOnDemand: true, connectOnCellular: false, trustedNetworks: ["Дом"], includeAllNetworks: true),
            state: OnDemandState(hasConnectedOnce: true, suspendedByUser: true)
        )
        XCTAssertEqual(AutomationRecord.decode(record.encoded()), record)
    }

    func testMissingOrBadDataGivesDefaults() {
        XCTAssertEqual(AutomationRecord.decode(nil), AutomationRecord())
        XCTAssertEqual(AutomationRecord.decode(Data("not json".utf8)), AutomationRecord())
        let newer = Data(#"{"version":99,"settings":{},"state":{"hasConnectedOnce":true,"suspendedByUser":false}}"#.utf8)
        XCTAssertEqual(AutomationRecord.decode(newer), AutomationRecord())
    }

    func testOlderSettingsFillDefaults() throws {
        let data = Data(#"{"version":1,"settings":{"connectOnDemand":true,"trustedNetworks":["a","a",""]},"state":{"hasConnectedOnce":false,"suspendedByUser":false}}"#.utf8)
        let record = AutomationRecord.decode(data)
        XCTAssertTrue(record.settings.connectOnDemand)
        XCTAssertTrue(record.settings.connectOnWiFi)
        XCTAssertTrue(record.settings.excludeLocalNetworks)
        XCTAssertFalse(record.settings.includeAllNetworks)
        XCTAssertEqual(record.settings.trustedNetworks, ["a"])
    }

    func testDefaultsAreSafe() {
        let defaults = AutomationSettings()
        XCTAssertFalse(defaults.connectOnDemand, "the system never starts the tunnel unless asked")
        XCTAssertFalse(defaults.includeAllNetworks, "no traffic lock unless asked")
        XCTAssertFalse(defaults.disconnectOnTrusted)
    }
}

final class TunnelSettleTests: XCTestCase {
    func testConnectGoal() {
        XCTAssertFalse(TunnelSettle.isSettled(statusRawValue: 1, goal: .connected, sawTransition: false))
        XCTAssertFalse(TunnelSettle.isSettled(statusRawValue: 2, goal: .connected, sawTransition: true))
        XCTAssertTrue(TunnelSettle.isSettled(statusRawValue: 3, goal: .connected, sawTransition: false))
        XCTAssertTrue(TunnelSettle.isSettled(statusRawValue: 1, goal: .connected, sawTransition: true))
    }

    func testDisconnectGoal() {
        XCTAssertTrue(TunnelSettle.isSettled(statusRawValue: 1, goal: .disconnected, sawTransition: false))
        XCTAssertFalse(TunnelSettle.isSettled(statusRawValue: 5, goal: .disconnected, sawTransition: true))
        XCTAssertTrue(TunnelSettle.isTransition(statusRawValue: 5))
        XCTAssertFalse(TunnelSettle.isTransition(statusRawValue: 3))
    }
}

final class PlatformTests: XCTestCase {
    func testOffers() {
        XCTAssertTrue(AutomationPlatform.macOS.offersLaunchAtLogin)
        XCTAssertFalse(AutomationPlatform.iOS.offersLaunchAtLogin)
        XCTAssertFalse(AutomationPlatform.tvOS.offersOnDemand)
        XCTAssertFalse(AutomationPlatform.tvOS.offersShortcuts)
        XCTAssertTrue(AutomationPlatform.iOS.networkKinds.contains(.cellular))
        XCTAssertFalse(AutomationPlatform.macOS.networkKinds.contains(.cellular))
    }
}
