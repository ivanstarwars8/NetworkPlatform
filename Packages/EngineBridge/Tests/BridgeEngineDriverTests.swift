// Verified on Linux only (Swift 5.10.1, swift test).
import CoreAbstraction
import EngineBridgeTestSupport
import Foundation
import XCTest
@testable import EngineBridge

/// The parts of the shared driver that do not depend on an engine. The lifecycle itself is exercised through
/// both adapters (XrayCoreTests, MihomoCoreTests), which run the same driver.
final class BridgeEngineDriverTests: XCTestCase {
    func testLongMessagesAreClipped() {
        let error = BridgeEngineDriver.coreError(.internalError, message: String(repeating: "x", count: 5000), during: .stop, timeout: nil)
        guard case let .operationFailed(_, message) = error else { return XCTFail() }
        XCTAssertLessThanOrEqual(message.count, CoreError.maximumMessageLength + 3)
    }

    func testCodesMapToCoreErrors() {
        XCTAssertEqual(
            BridgeEngineDriver.coreError(.configParse, message: "bad", during: .start, timeout: nil),
            .invalidConfiguration(issues: [CoreValidationIssue(severity: .error, message: "config_parse: bad")])
        )
        XCTAssertEqual(BridgeEngineDriver.coreError(.timeout, message: "", during: .start, timeout: 15), .timedOut(operation: .start, seconds: 15))
        XCTAssertEqual(BridgeEngineDriver.coreError(.cancelled, message: "", during: .stop, timeout: nil), .cancelled(operation: .stop))
        XCTAssertEqual(BridgeEngineDriver.coreError(.notRunning, message: "", during: .statistics, timeout: nil), .notRunning(state: .idle))
        XCTAssertEqual(
            BridgeEngineDriver.coreError(BridgeCode(rawValue: 99), message: "?", during: .health, timeout: nil),
            .operationFailed(operation: .health, message: "code_99: ?")
        )
    }

    func testFormatIssueNamesEveryAcceptedFormat() {
        let yaml = CoreConfiguration(coreID: "x", format: "YAML", payload: Data())
        XCTAssertNil(BridgeEngineDriver.formatIssue(yaml, accepted: ["yaml", "json"]), "case-insensitive")
        let toml = CoreConfiguration(coreID: "x", format: "toml", payload: Data())
        XCTAssertEqual(
            BridgeEngineDriver.formatIssue(toml, accepted: ["yaml", "json"])?.message,
            "configuration format 'toml' is not 'yaml' or 'json'"
        )
    }

    func testCoreVersionIsReadFromEitherBridge() {
        let bridge = FakeBridge()
        XCTAssertEqual(BridgeEngineDriver.coreVersion(of: bridge), "26.11.9")
        bridge.set { $0.versionReply = #"{"code":0,"data":{"abi":1,"engine":"mihomo","core":"v1.19.34","go":"go1.27.4"}}"# }
        XCTAssertEqual(BridgeEngineDriver.coreVersion(of: bridge), "v1.19.34")
        bridge.set { $0.versionReply = "garbage" }
        XCTAssertEqual(BridgeEngineDriver.coreVersion(of: bridge), "unknown")
    }

    func testMillisecondsAndSaturatingAdd() {
        XCTAssertEqual(BridgeEngineDriver.milliseconds(1.5), 1500)
        XCTAssertEqual(BridgeEngineDriver.milliseconds(-1), 0)
        XCTAssertEqual(BridgeEngineDriver.milliseconds(.infinity), 0)
        XCTAssertEqual(BridgeEngineDriver.milliseconds(1e12), Int32.max)
        XCTAssertEqual(BridgeEngineDriver.add(UInt64.max - 1, 5), UInt64.max)
        XCTAssertEqual(BridgeEngineDriver.add(10, -3), 10)
    }

    func testDriverRunsPumpAndLogReaderAndStopsThem() async throws {
        let bridge = FakeBridge()
        var settings = BridgeCoreSettings()
        settings.pump.readTimeoutMilliseconds = 20
        settings.logReadTimeoutMilliseconds = 20
        let messages = Locked<[String]>([])
        let events = BridgeCoreEvents(log: { record in
            messages.mutate { $0.append(record.message) }
        })
        let driver = BridgeEngineDriver(engine: "mihomo", bridge: bridge, packetIO: FakePacketIO(), settings: settings, events: events, clock: { Date() })
        try await driver.start(configuration: Data("a".utf8), options: Data("{}".utf8), runPump: true)
        bridge.queueLog(#"{"seq":1,"t":1,"kind":"core","msg":"x"}"#)
        XCTAssertTrue(eventually { messages.value == ["x"] })
        let health = await driver.health()
        XCTAssertEqual(health.status, .healthy)
        XCTAssertNotNil(driver.pumpCounters)
        try await driver.stop()
        XCTAssertNil(driver.pumpCounters)
    }
}
