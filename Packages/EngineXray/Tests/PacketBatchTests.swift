// Verified on Linux only (Swift 5.10.1, swift test).
import Foundation
import XCTest
@testable import EngineXray

final class PacketBatchTests: XCTestCase {
    func testEncoderFramesLittleEndianLengths() {
        var encoder = PacketBatchEncoder(capacity: 0)
        let a = packet(version: 4, size: 300, fill: 1)
        let b = packet(version: 6, size: 3, fill: 2)
        XCTAssertEqual(encoder.append(a), .appended)
        XCTAssertEqual(encoder.append(b), .appended)
        XCTAssertEqual(encoder.packetCount, 2)
        XCTAssertEqual(encoder.byteCount, 2 + 300 + 2 + 3)
        encoder.withFramedBytes { raw in
            XCTAssertEqual(raw.count, 307)
            XCTAssertEqual(raw[0], 0x2C)  // 300 = 0x012C
            XCTAssertEqual(raw[1], 0x01)
            XCTAssertEqual(raw[2], a[0])
            XCTAssertEqual(raw[302], 3)
            XCTAssertEqual(raw[303], 0)
            XCTAssertEqual(Array(raw[304..<307]), Array(b))
        }
    }

    func testEncoderRejectsEmptyAndOversizedAndReportsFull() {
        var encoder = PacketBatchEncoder(capacity: 0)
        XCTAssertEqual(encoder.capacity, 2 + 65535, "capacity is raised to one maximum frame")
        XCTAssertEqual(encoder.append(Data()), .invalid)
        XCTAssertEqual(encoder.append(Data(count: 65536)), .invalid)
        XCTAssertEqual(encoder.append(packet(version: 4, size: 65535, fill: 0)), .appended)
        XCTAssertEqual(encoder.append(packet(version: 4, size: 1, fill: 0)), .full)
        encoder.reset()
        XCTAssertTrue(encoder.isEmpty)
        XCTAssertEqual(encoder.append(packet(version: 4, size: 1, fill: 0)), .appended)
    }

    func testDecoderRoundTripsAndClassifiesFamilies() {
        var encoder = PacketBatchEncoder(capacity: 0)
        let packets = [
            packet(version: 4, size: 20, fill: 9),
            packet(version: 6, size: 40, fill: 8),
            packet(version: 5, size: 10, fill: 7),  // neither IPv4 nor IPv6
            packet(version: 4, size: 1500, fill: 6),
        ]
        for p in packets { XCTAssertEqual(encoder.append(p), .appended) }
        var decoded: [Data] = []
        var families: [PacketAddressFamily] = []
        let outcome = encoder.withFramedBytes { raw in
            PacketBatchDecoder.decode(UnsafeRawBufferPointer(raw)) { bytes, family in
                decoded.append(Data(bytes))
                families.append(family)
            }
        }
        XCTAssertEqual(decoded, [packets[0], packets[1], packets[3]])
        XCTAssertEqual(families, [.ipv4, .ipv6, .ipv4])
        XCTAssertEqual(outcome.packets, 3)
        XCTAssertEqual(outcome.unknownFamily, 1)
        XCTAssertFalse(outcome.truncated)
    }

    func testDecoderStopsAtTruncatedOrZeroFrame() {
        let truncated: [UInt8] = [3, 0, 0x45, 0, 0, 10, 0, 0x45]  // second frame announces 10, has 1
        let outcome = truncated.withUnsafeBytes { raw in
            PacketBatchDecoder.decode(raw) { _, _ in }
        }
        XCTAssertEqual(outcome.packets, 1)
        XCTAssertTrue(outcome.truncated)

        let zero: [UInt8] = [0, 0, 0x45]
        let zeroOutcome = zero.withUnsafeBytes { raw in PacketBatchDecoder.decode(raw) { _, _ in } }
        XCTAssertEqual(zeroOutcome.packets, 0)
        XCTAssertTrue(zeroOutcome.truncated)

        let oneByte: [UInt8] = [5]
        XCTAssertTrue(oneByte.withUnsafeBytes { raw in PacketBatchDecoder.decode(raw) { _, _ in } }.truncated)
    }

    func testAddressFamilyFromVersionNibble() {
        XCTAssertEqual(PacketAddressFamily.of(firstByte: 0x45), .ipv4)
        XCTAssertEqual(PacketAddressFamily.of(firstByte: 0x60), .ipv6)
        XCTAssertNil(PacketAddressFamily.of(firstByte: 0x00))
        XCTAssertNil(PacketAddressFamily.of(firstByte: 0xF0))
    }
}

final class BoundedBatchQueueTests: XCTestCase {
    func testBackpressurePausesAndConsumerRearms() {
        let queue = BoundedBatchQueue<Int>(capacity: 2)
        XCTAssertEqual(queue.offer(1), .acceptedRearm)
        XCTAssertEqual(queue.offer(2), .acceptedPaused, "the second batch fills the queue")
        XCTAssertEqual(queue.offer(3), .refusedFull)
        let first = queue.take(timeout: 0)
        XCTAssertEqual(first.element, 1)
        XCTAssertTrue(first.rearm, "taking from a paused queue re-arms the read once")
        let second = queue.take(timeout: 0)
        XCTAssertEqual(second.element, 2)
        XCTAssertFalse(second.rearm)
        let empty = queue.take(timeout: 0.01)
        XCTAssertNil(empty.element)
    }

    func testFIFOAcrossWrapAround() {
        let queue = BoundedBatchQueue<Int>(capacity: 3)
        var out: [Int] = []
        for value in 0..<10 {
            _ = queue.offer(value)
            if value % 2 == 1 {
                out.append(queue.take(timeout: 0).element!)
                out.append(queue.take(timeout: 0).element!)
            }
        }
        XCTAssertEqual(out, Array(0..<10))
    }

    func testCloseWakesWaiterAndRefusesOffers() {
        let queue = BoundedBatchQueue<Int>(capacity: 1)
        let woke = expectation(description: "consumer woke")
        DispatchQueue.global().async {
            let result = queue.take(timeout: nil)
            XCTAssertNil(result.element)
            woke.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        queue.close()
        wait(for: [woke], timeout: 2)
        XCTAssertEqual(queue.offer(1), .closed)
        XCTAssertTrue(queue.isClosed)
        XCTAssertEqual(queue.queuedCount, 0)
    }

    func testCapacityIsAtLeastOne() {
        let queue = BoundedBatchQueue<Int>(capacity: 0)
        XCTAssertEqual(queue.capacity, 1)
        XCTAssertEqual(queue.offer(1), .acceptedPaused)
    }
}
