// Verified on Linux only (Swift 5.10.1, swift test).
import Foundation
import XCTest
@testable import EngineBridge
import EngineBridgeTestSupport

final class PacketPumpTests: XCTestCase {
    private func makeRunning() -> (FakeBridge, FakePacketIO) {
        let bridge = FakeBridge()
        _ = bridge.start(configuration: Data("{}".utf8), options: Data())
        return (bridge, FakePacketIO())
    }

    private func quickConfiguration() -> PacketPumpConfiguration {
        var configuration = PacketPumpConfiguration()
        configuration.readTimeoutMilliseconds = 20
        return configuration
    }

    func testPacketsFlowBothWaysInOrder() {
        let (bridge, io) = makeRunning()
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in }
        pump.start()

        let up = (0..<50).map { packet(version: $0 % 2 == 0 ? 4 : 6, size: 40 + $0, fill: UInt8($0)) }
        io.supply(Array(up[0..<20]))
        io.supply(Array(up[20..<50]))
        XCTAssertTrue(bridge.waitForInbound(count: 50))
        XCTAssertEqual(bridge.inboundSnapshot(), up)

        let down = (0..<30).map { packet(version: $0 % 3 == 0 ? 6 : 4, size: 60, fill: UInt8($0)) }
        bridge.queueOutbound(down)
        XCTAssertTrue(io.waitForWritten(count: 30))
        XCTAssertEqual(io.writtenPackets(), down)
        let families = io.written.flatMap { $0.families }
        XCTAssertEqual(families, down.map { $0[0] >> 4 == 6 ? .ipv6 : .ipv4 })

        XCTAssertTrue(pump.stop())
        let counters = pump.counters
        XCTAssertEqual(counters.inboundPackets, 50)
        XCTAssertEqual(counters.inboundBytes, UInt64(up.reduce(0) { $0 + $1.count }))
        XCTAssertEqual(counters.inboundBatches, 2)
        XCTAssertEqual(counters.outboundPackets, 30)
        XCTAssertEqual(counters.outboundBytes, 30 * 60)
        XCTAssertEqual(counters.inboundRejected, 0)
        XCTAssertEqual(pump.state, .stopped)
    }

    func testLargeBatchIsSplitAcrossSeveralWrites() {
        let (bridge, io) = makeRunning()
        var configuration = quickConfiguration()
        configuration.inboundBufferBytes = 0  // clamped to one maximum frame: 65537 bytes
        let pump = PacketPump(bridge: bridge, io: io, configuration: configuration) { _ in }
        pump.start()
        let batch = (0..<100).map { packet(version: 4, size: 1500, fill: UInt8($0)) }  // ~150 KB
        io.supply(batch)
        XCTAssertTrue(bridge.waitForInbound(count: 100))
        XCTAssertEqual(bridge.inboundSnapshot(), batch)
        XCTAssertGreaterThanOrEqual(bridge.tunWriteCalls, 3)
        XCTAssertTrue(pump.stop())
    }

    func testInvalidPacketsAreDroppedAndCounted() {
        let (bridge, io) = makeRunning()
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in }
        pump.start()
        let good = packet(version: 4, size: 30, fill: 1)
        io.supply([Data(), good, Data(count: 70_000)])
        XCTAssertTrue(bridge.waitForInbound(count: 1))
        XCTAssertTrue(eventually { pump.counters.inboundBatches == 1 })
        XCTAssertEqual(pump.counters.inboundInvalid, 2)
        XCTAssertEqual(bridge.inboundSnapshot(), [good])
        XCTAssertTrue(pump.stop())
    }

    func testBridgeErrorsAreCountedAndNotRunningReportsEngineGone() {
        let (bridge, io) = makeRunning()
        let gone = expectation(description: "engine gone")
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { code in
            XCTAssertEqual(code, .notRunning)
            gone.fulfill()
        }
        bridge.set { $0.tunWriteOverride = -11 }
        pump.start()
        io.supply([packet(version: 4, size: 30, fill: 1), packet(version: 4, size: 30, fill: 2)])
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(eventually { pump.counters.inboundRejected == 2 })
        XCTAssertEqual(pump.counters.lastBridgeError, 11)
        XCTAssertTrue(pump.stop())
    }

    func testCrashOfTheEngineIsReportedOnceByTheReader() {
        let (bridge, io) = makeRunning()
        let reports = Locked<[BridgeCode]>([])
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { code in
            reports.mutate { $0.append(code) }
        }
        pump.start()
        bridge.crash()
        XCTAssertTrue(eventually { reports.value == [.closed] })
        // A later write failure is not reported a second time.
        bridge.set { $0.tunWriteOverride = -11 }
        io.supply([packet(version: 4, size: 30, fill: 1)])
        XCTAssertTrue(eventually { pump.counters.inboundRejected == 1 })
        XCTAssertEqual(reports.value, [.closed])
        XCTAssertTrue(pump.stop())
    }

    func testStopIsNotReportedAsEngineGone() {
        let (bridge, io) = makeRunning()
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in
            XCTFail("a stop must not be reported as an engine that died")
        }
        pump.start()
        pump.beginStop()
        _ = bridge.stop(timeoutMilliseconds: 0)  // the device closes under the reader
        XCTAssertTrue(pump.join())
        XCTAssertEqual(pump.state, .stopped)
    }

    func testCompletionAfterStopIsDroppedAndDoesNotRearm() {
        let (bridge, io) = makeRunning()
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in }
        pump.start()
        XCTAssertTrue(eventually { io.hasArmedRead })
        let readsBefore = io.readCalls
        XCTAssertTrue(pump.stop())
        XCTAssertTrue(io.completeArmedRead(with: [packet(version: 4, size: 20, fill: 1)]))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(io.readCalls, readsBefore, "no read after stop")
        XCTAssertEqual(pump.counters.inboundAfterStop, 1)
        XCTAssertTrue(bridge.inboundSnapshot().isEmpty)
    }

    func testBackpressureStopsReadingWhileTheBridgeIsBusy() {
        // A bridge whose tunWrite blocks until released: the queue fills and no further read is armed.
        let bridge = BlockingWriteBridge()
        _ = bridge.start(configuration: Data("{}".utf8), options: Data())
        let io = FakePacketIO()
        var configuration = quickConfiguration()
        configuration.queueDepth = 2
        let pump = PacketPump(bridge: bridge, io: io, configuration: configuration) { _ in }
        pump.start()
        io.supply([packet(version: 4, size: 20, fill: 1)])  // taken by the writer, blocks in tunWrite
        XCTAssertTrue(eventually { bridge.blockedWrites == 1 })
        io.supply([packet(version: 4, size: 20, fill: 2)])  // queued (1 of 2)
        XCTAssertTrue(eventually { io.hasArmedRead })
        io.supply([packet(version: 4, size: 20, fill: 3)])  // queued (2 of 2): the read pauses
        XCTAssertTrue(eventually { pump.counters.inboundPauses == 1 })
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(io.hasArmedRead, "a full queue keeps the read paused")
        let readsWhilePaused = io.readCalls
        bridge.release()
        XCTAssertTrue(eventually { bridge.receivedPackets == 3 })
        XCTAssertTrue(eventually { io.hasArmedRead }, "the consumer re-arms the read")
        XCTAssertGreaterThan(io.readCalls, readsWhilePaused)
        XCTAssertTrue(pump.stop())
        XCTAssertEqual(pump.counters.inboundRejected, 0)
    }

    func testWriteFailuresOfTheSystemAreCounted() {
        let (bridge, io) = makeRunning()
        io.writeResult = false
        let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in }
        pump.start()
        bridge.queueOutbound([packet(version: 4, size: 20, fill: 1)])
        XCTAssertTrue(eventually { pump.counters.outboundWriteFailures == 1 })
        XCTAssertTrue(pump.stop())
    }

    func testRepeatedStartStopLeavesNoThreadsBlocked() {
        for _ in 0..<20 {
            let (bridge, io) = makeRunning()
            let pump = PacketPump(bridge: bridge, io: io, configuration: quickConfiguration()) { _ in }
            pump.start()
            io.supply([packet(version: 4, size: 20, fill: 1)])
            pump.beginStop()
            _ = bridge.stop(timeoutMilliseconds: 0)
            XCTAssertTrue(pump.join())
        }
    }
}

/// A bridge whose `tunWrite` blocks until `release()`, to observe backpressure.
final class BlockingWriteBridge: BridgeABI, @unchecked Sendable {
    private let inner = FakeBridge()
    private let condition = NSCondition()
    private var released = false
    private var blockedWritesValue = 0
    private var receivedPacketsValue = 0

    var blockedWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return blockedWritesValue
    }

    var receivedPackets: Int {
        condition.lock()
        defer { condition.unlock() }
        return receivedPacketsValue
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func abiVersion() -> Int32 { inner.abiVersion() }
    func version() -> String { inner.version() }
    func validate(configuration: Data, options: Data) -> String { inner.validate(configuration: configuration, options: options) }
    func start(configuration: Data, options: Data) -> String { inner.start(configuration: configuration, options: options) }
    func stop(timeoutMilliseconds: Int32) -> String {
        release()
        return inner.stop(timeoutMilliseconds: timeoutMilliseconds)
    }
    func stats() -> String { inner.stats() }
    func health() -> String { inner.health() }
    func memory() -> String { inner.memory() }
    func state() -> Int32 { inner.state() }
    func readLog(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        inner.readLog(into: buffer, timeoutMilliseconds: timeoutMilliseconds)
    }
    func tunRead(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        inner.tunRead(into: buffer, timeoutMilliseconds: timeoutMilliseconds)
    }
    func tunWrite(_ batch: UnsafeMutableRawBufferPointer) -> Int32 {
        condition.lock()
        blockedWritesValue += 1
        while !released { condition.wait() }
        condition.unlock()
        let result = inner.tunWrite(batch)
        condition.lock()
        receivedPacketsValue += max(0, Int(result))
        condition.unlock()
        return result
    }
}
