import XCTest
@testable import DesignSystem

final class ConnectionPhaseTests: XCTestCase {
    func testVPNStatusMapping() {
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 0), .notConfigured)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 1), .disconnected)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 2), .connecting)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 3), .connected)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 4), .reasserting)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 5), .disconnecting)
        XCTAssertEqual(ConnectionPhase(vpnStatusRawValue: 99), .disconnected)
    }

    func testActions() {
        XCTAssertEqual(ConnectionPhase.notConfigured.action, .connect)
        XCTAssertEqual(ConnectionPhase.disconnected.action, .connect)
        XCTAssertEqual(ConnectionPhase.connecting.action, .disconnect)
        XCTAssertEqual(ConnectionPhase.connected.action, .disconnect)
        XCTAssertEqual(ConnectionPhase.reasserting.action, .disconnect)
        XCTAssertEqual(ConnectionPhase.disconnecting.action, .none)
        XCTAssertEqual(ConnectionPhase.connected.actionTitle, "Отключить")
        XCTAssertEqual(ConnectionPhase.connecting.actionTitle, "Отменить")
        XCTAssertEqual(ConnectionPhase.disconnected.actionTitle, "Подключить")
        XCTAssertNil(ConnectionPhase.disconnecting.actionTitle)
    }

    /// Bronze means "working": only the connected phase fills the horn completely.
    func testOnlyConnectedIsFull() {
        for phase in ConnectionPhase.allCases {
            XCTAssertEqual(phase.hornFill == 1, phase == .connected, "\(phase)")
            XCTAssertTrue((0...1).contains(phase.hornFill))
        }
        XCTAssertEqual(ConnectionPhase.disconnected.hornFill, 0)
    }

    func testThroughputOnlyWhenConnected() {
        for phase in ConnectionPhase.allCases {
            XCTAssertEqual(phase.showsThroughput, phase == .connected)
        }
    }

    func testCopyIsSentenceCase() {
        for phase in ConnectionPhase.allCases {
            let word = phase.stateWord
            XCTAssertFalse(word.isEmpty)
            XCTAssertNotEqual(word, word.uppercased(), "\(phase): no all-caps")
            XCTAssertEqual(String(word.prefix(1)), word.prefix(1).uppercased())
            XCTAssertEqual(String(word.dropFirst()), word.dropFirst().lowercased())
        }
    }
}

final class ThroughputTests: XCTestCase {
    func testFirstSampleHasNoSpeed() {
        var meter = ThroughputMeter()
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 100, downlinkBytes: 100, time: 10)))
    }

    func testSpeedFromTwoSamples() throws {
        var meter = ThroughputMeter()
        _ = meter.add(TrafficSample(uplinkBytes: 1_000, downlinkBytes: 10_000, time: 10))
        let speed = try XCTUnwrap(meter.add(TrafficSample(uplinkBytes: 1_500, downlinkBytes: 135_000, time: 11)))
        XCTAssertEqual(speed.upBitsPerSecond, 4_000, accuracy: 1e-9)
        XCTAssertEqual(speed.downBitsPerSecond, 1_000_000, accuracy: 1e-9)
    }

    func testIntervalIsHonoured() throws {
        var meter = ThroughputMeter()
        _ = meter.add(TrafficSample(uplinkBytes: 0, downlinkBytes: 0, time: 0))
        let speed = try XCTUnwrap(meter.add(TrafficSample(uplinkBytes: 0, downlinkBytes: 1_000, time: 2)))
        XCTAssertEqual(speed.downBitsPerSecond, 4_000, accuracy: 1e-9)
    }

    func testCounterResetGivesNoNumber() {
        var meter = ThroughputMeter()
        _ = meter.add(TrafficSample(uplinkBytes: 5_000, downlinkBytes: 5_000, time: 0))
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 10, downlinkBytes: 10, time: 1)), "engine restarted")
        XCTAssertNotNil(meter.add(TrafficSample(uplinkBytes: 20, downlinkBytes: 20, time: 2)), "new baseline")
    }

    func testGapAndTimeTravelGiveNoNumber() {
        var meter = ThroughputMeter()
        _ = meter.add(TrafficSample(uplinkBytes: 0, downlinkBytes: 0, time: 0))
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 10, downlinkBytes: 10, time: 30)), "screen was hidden")
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 20, downlinkBytes: 20, time: 30)), "zero interval")
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 30, downlinkBytes: 30, time: 29)), "time went backwards")
    }

    func testReset() {
        var meter = ThroughputMeter()
        _ = meter.add(TrafficSample(uplinkBytes: 0, downlinkBytes: 0, time: 0))
        meter.reset()
        XCTAssertNil(meter.add(TrafficSample(uplinkBytes: 10, downlinkBytes: 10, time: 1)))
    }
}

final class UnitFormatTests: XCTestCase {
    func testSpeed() {
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 0) == ("0", "бит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 999) == ("999", "бит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 1_000) == ("1,0", "Кбит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 8_440_000) == ("8,4", "Мбит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 48_300_000) == ("48", "Мбит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 999_600) == ("1,0", "Мбит/с"), "rounds up into the next unit")
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 9_960) == ("10", "Кбит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: 2_500_000_000) == ("2,5", "Гбит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: -5) == ("0", "бит/с"))
        XCTAssertTrue(UnitFormat.speed(bitsPerSecond: .nan) == ("0", "бит/с"))
    }

    func testBytes() {
        XCTAssertEqual(UnitFormat.duration(seconds: 0), "0 с")
        XCTAssertEqual(UnitFormat.duration(seconds: 45.9), "45 с")
        XCTAssertEqual(UnitFormat.duration(seconds: 185), "3 мин 05 с")
        XCTAssertEqual(UnitFormat.duration(seconds: 2 * 3_600 + 7 * 60 + 30), "2 ч 07 мин")
        XCTAssertEqual(UnitFormat.duration(seconds: 3 * 86_400 + 4 * 3_600), "3 д 4 ч")
        XCTAssertEqual(UnitFormat.duration(seconds: 86_400), "1 д")
        XCTAssertEqual(UnitFormat.duration(seconds: -5), "0 с")
        XCTAssertEqual(UnitFormat.bytes(0), "0 Б")
        XCTAssertEqual(UnitFormat.bytes(1_023), "1023 Б")
        XCTAssertEqual(UnitFormat.bytes(1_536), "1,5 КБ")
        XCTAssertEqual(UnitFormat.bytes(48 * 1_048_576), "48 МБ")
        XCTAssertEqual(UnitFormat.bytes(3 * 1_073_741_824 / 2), "1,5 ГБ")
    }

    func testPlural() {
        let forms = (0...25).map { RussianPlural.form($0, one: "сервер", few: "сервера", many: "серверов") }
        XCTAssertEqual(forms[0], "серверов")
        XCTAssertEqual(forms[1], "сервер")
        XCTAssertEqual(forms[2], "сервера")
        XCTAssertEqual(forms[4], "сервера")
        XCTAssertEqual(forms[5], "серверов")
        XCTAssertEqual(forms[11], "серверов")
        XCTAssertEqual(forms[12], "серверов")
        XCTAssertEqual(forms[21], "сервер")
        XCTAssertEqual(forms[22], "сервера")
        XCTAssertEqual(RussianPlural.phrase(111, one: "сервер", few: "сервера", many: "серверов"), "111 серверов")
    }
}

final class HornGeometryTests: XCTestCase {
    func testHornsMeetAtTheTopAndMirror() {
        XCTAssertEqual(HornGeometry.left.outer.end, HornGeometry.right.outer.end, "tips meet")
        XCTAssertEqual(HornGeometry.left.outer.end.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.left.outer.end.y, HornGeometry.top, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.left.start.y, HornGeometry.bottom, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.left.inner.end.y, HornGeometry.bottom, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.right.start.x, 1 - HornGeometry.left.start.x, accuracy: 1e-12)
    }

    /// The outline stays inside the unit square and the two horns do not overlap below the tip.
    func testOutlineBounds() {
        for outline in HornGeometry.outlines {
            for p in outline.polygon(steps: 64) {
                XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y), "\(p)")
                XCTAssertTrue((HornGeometry.top - 1e-9...HornGeometry.bottom + 1e-9).contains(p.y))
            }
        }
        for p in HornGeometry.left.polygon(steps: 64) {
            XCTAssertLessThanOrEqual(p.x, 0.5 + 1e-9)
        }
    }

    func testMaskFraction() {
        XCTAssertEqual(HornGeometry.maskFraction(fill: 0), 1 - HornGeometry.bottom, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.maskFraction(fill: 1), 1 - HornGeometry.top, accuracy: 1e-12)
        XCTAssertEqual(HornGeometry.maskFraction(fill: 2), HornGeometry.maskFraction(fill: 1))
        XCTAssertEqual(HornGeometry.maskFraction(fill: -1), HornGeometry.maskFraction(fill: 0))
    }

    /// The icon source (written by Tools/make-app-icon.py) is drawn from the same numbers as the control.
    func testIconSVGMatchesGeometry() throws {
        let svg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Branding/horn.svg")
        let text = try String(contentsOf: svg, encoding: .utf8)
        XCTAssertTrue(text.contains("d=\"\(HornGeometry.svgPathData())\""),
                      "Apps/Branding/horn.svg is out of date: run Tools/make-app-icon.py after changing HornGeometry")
    }
}
