// Tests of the app's screen registry (Apps/SharedApp/Features/AppDestination.swift, linked into AppShell/).
import XCTest

final class AppShellTests: XCTestCase {
    func testLevelsAreOrdered() {
        XCTAssertLessThan(ExperienceLevel.basic, .advanced)
        XCTAssertLessThan(ExperienceLevel.advanced, .pro)
    }

    func testBasicLevelShowsTheEverydayScreens() {
        let basic = AppDestination.visible(at: .basic)
        XCTAssertTrue(basic.contains(.connection))
        XCTAssertTrue(basic.contains(.profiles))
        XCTAssertTrue(basic.contains(.settings))
        XCTAssertFalse(basic.contains(.engineDiagnostics), "engine diagnostics is a Профи screen")
        XCTAssertFalse(basic.contains(.toolbox), "the toolbox is a Профи screen")
        XCTAssertFalse(basic.contains(.analyzer), "the analyser is a Профи screen")
    }

    /// Автоподключение lives in the Настройки area after the settings screen itself (the area's first screen is
    /// what its tab opens; the rest are reached from it).
    func testAutomationIsASettingsScreen() {
        XCTAssertEqual(AppArea.settings.destinations(at: .basic), [.settings, .automation])
        XCTAssertEqual(AppDestination.automation.level, .basic)
    }

    func testHigherLevelsIncludeLowerOnes() {
        for lower in ExperienceLevel.allCases {
            for higher in ExperienceLevel.allCases where higher >= lower {
                XCTAssertTrue(Set(AppDestination.visible(at: lower)).isSubset(of: Set(AppDestination.visible(at: higher))))
            }
        }
    }

    /// iPhone tabs: Подключение / Профили / Инструменты (Профи only) / Настройки.
    func testTabs() {
        XCTAssertEqual(AppArea.visible(at: .basic), [.connection, .profiles, .settings])
        XCTAssertEqual(AppArea.visible(at: .pro), [.connection, .profiles, .tools, .settings])
        XCTAssertEqual(AppArea.tools.destinations(at: .pro), [.routeSimulator, .toolbox, .analyzer, .engineDiagnostics])
        XCTAssertTrue(AppArea.tools.destinations(at: .basic).isEmpty)
    }

    /// Расширенный adds the routing rules and DNS under Настройки; the simulator is a Профи tool.
    func testAdvancedLevelAddsRoutingAndDNS() {
        XCTAssertEqual(AppArea.settings.destinations(at: .basic), [.settings])
        XCTAssertEqual(AppArea.settings.destinations(at: .advanced), [.settings, .routingRules, .dns])
        XCTAssertEqual(AppArea.visible(at: .advanced), [.connection, .profiles, .settings], "no tools below Профи")
        XCTAssertTrue(ExperienceLevel.selectable.contains(.advanced))
        XCTAssertEqual(ExperienceLevel.effective(storedRawValue: "advanced"), .advanced)
        XCTAssertEqual(AppDestination.routeSimulator.level, .pro)
    }

    /// A level that adds no screen is not offered (it would be a control that changes nothing).
    func testSelectableLevels() {
        let selectable = ExperienceLevel.selectable
        XCTAssertEqual(selectable.first, .basic)
        for level in selectable where level != .basic {
            XCTAssertTrue(AppDestination.allCases.contains { $0.level == level }, "\(level) adds no screen")
        }
        for level in ExperienceLevel.allCases where !selectable.contains(level) {
            XCTAssertFalse(AppDestination.allCases.contains { $0.level == level })
        }
    }

    func testEffectiveLevel() {
        XCTAssertEqual(ExperienceLevel.effective(storedRawValue: nil), .basic)
        XCTAssertEqual(ExperienceLevel.effective(storedRawValue: "garbage"), .basic)
        XCTAssertEqual(ExperienceLevel.effective(storedRawValue: "pro"), .pro)
        let advanced = ExperienceLevel.effective(storedRawValue: "advanced")
        XCTAssertTrue(ExperienceLevel.selectable.contains(advanced))
        XCTAssertLessThanOrEqual(advanced, .advanced)
    }

    func testCopy() {
        for area in AppArea.allCases {
            XCTAssertNotEqual(area.title, area.title.uppercased())
        }
        for destination in AppDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty)
            XCTAssertFalse(destination.systemImage.isEmpty)
        }
        XCTAssertEqual(Set(AppDestination.allCases.map(\.id)).count, AppDestination.allCases.count)
    }
}
