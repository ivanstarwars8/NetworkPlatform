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
        XCTAssertEqual(AppArea.tools.destinations(at: .pro), [.engineDiagnostics])
        XCTAssertTrue(AppArea.tools.destinations(at: .basic).isEmpty)
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
