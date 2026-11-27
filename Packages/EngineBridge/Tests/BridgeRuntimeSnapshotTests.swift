import EngineBridge
import EngineBridgeTestSupport
import XCTest

final class BridgeRuntimeSnapshotTests: XCTestCase {
    func testReadsVersionHealthAndMemory() {
        let bridge = FakeBridge()
        bridge.healthReply = #"{"code":0,"data":{"state":"running","uptimeMs":61500,"coreRunning":true,"lastErrorCode":6,"lastError":"start failed: dial [redacted]","goroutines":40,"logDropped":3}}"#
        bridge.memoryReply = #"{"code":0,"data":{"mapped":31457280,"total":40000000,"heapObjects":9000000,"heapLive":8000000,"heapFree":1,"heapReleased":2,"stacks":524288,"goroutines":42,"gcCycles":17,"limit":41943040,"gcPercent":25}}"#
        let s = BridgeRuntimeSnapshot.read(from: bridge)
        XCTAssertEqual(s.abi, 1)
        XCTAssertEqual(s.coreVersion, "26.11.9")
        XCTAssertEqual(s.goVersion, "go1.27.4")
        XCTAssertEqual(s.state, "running")
        XCTAssertEqual(s.uptimeSeconds, 61.5)
        XCTAssertEqual(s.lastErrorCode, 6)
        XCTAssertEqual(s.lastError, "start failed: dial [redacted]")
        XCTAssertEqual(s.goroutines, 42, "the memory sample wins over health's count")
        XCTAssertEqual(s.goHeapLiveBytes, 8_000_000)
        XCTAssertEqual(s.goHeapObjectsBytes, 9_000_000)
        XCTAssertEqual(s.goMappedBytes, 31_457_280)
        XCTAssertEqual(s.goStacksBytes, 524_288)
        XCTAssertEqual(s.gcCycles, 17)
        XCTAssertEqual(s.goMemoryLimitBytes, 41_943_040)
        XCTAssertEqual(s.logDropped, 3)
    }

    func testMissingOrBrokenRepliesLeaveFieldsEmpty() {
        let bridge = FakeBridge()
        bridge.versionReply = "not json"
        bridge.memoryReply = #"{"code":0,"data":{"limit":9223372036854775807}}"#
        let s = BridgeRuntimeSnapshot.read(from: bridge)
        XCTAssertNil(s.coreVersion)
        XCTAssertEqual(s.state, "idle")
        XCTAssertNil(s.uptimeSeconds, "an idle bridge reports no uptime")
        XCTAssertNil(s.lastError, "code 0 means no error")
        XCTAssertNil(s.goMemoryLimitBytes, "MaxInt64 means no limit")
        XCTAssertNil(s.goHeapLiveBytes)
    }

    func testRecentErrorsKeepsOnlyErrorsBounded() {
        let ring = RecentEngineErrors(capacity: 2, maximumMessageLength: 20)
        ring.note(BridgeLogRecord(seq: 1, timeUnixMilliseconds: 1, level: "info", kind: "core", message: "hello"))
        for i in 0..<3 {
            ring.note(BridgeLogRecord(seq: UInt64(i), timeUnixMilliseconds: Int64(i), level: "error", kind: "core", message: "error number \(i) " + String(repeating: "x", count: 40)))
        }
        let entries = ring.snapshot
        XCTAssertEqual(entries.map(\.timeUnixMilliseconds), [1, 2])
        XCTAssertTrue(entries[0].message.hasSuffix("…"))
        XCTAssertLessThanOrEqual(entries[0].message.count, 21)
        ring.removeAll()
        XCTAssertTrue(ring.snapshot.isEmpty)
    }
}
