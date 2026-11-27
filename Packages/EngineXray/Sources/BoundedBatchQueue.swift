// Verified on Linux only (Swift 5.10.1, swift test). Not yet run on Apple platforms.
import Foundation

/// A bounded FIFO between the `readPackets` completion handler (producer) and the thread that writes into
/// the bridge (consumer), with the flow control of the device side built in.
///
/// Backpressure: the producer never blocks (it runs on the system's callback queue). It offers a batch and
/// learns whether it may ask the system for the next one right away. When the queue is full it must not;
/// the queue remembers that the read is paused, and the consumer is told to re-arm the read as soon as it
/// takes a batch out. While no read is armed the packets wait in the kernel's utun queue, which is the
/// bounded buffer the documented design relies on (Documentation/Architecture/tun-integration.md §3).
///
/// Thread-safe. `close()` wakes a waiting consumer and refuses every later offer.
public final class BoundedBatchQueue<Element>: @unchecked Sendable {
    public enum OfferResult: Equatable {
        /// Accepted; there is room for another batch, read again now.
        case acceptedRearm
        /// Accepted; the queue is now full, the consumer re-arms the read later.
        case acceptedPaused
        /// The queue is closed; the batch was dropped and nothing must be re-armed.
        case closed
        /// The queue was full (the producer read without being allowed to); the batch was dropped and the
        /// read stays paused until the consumer re-arms it.
        case refusedFull
    }

    public let capacity: Int
    private let condition = NSCondition()
    private var ring: [Element?]
    private var head = 0
    private var count = 0
    private var closed = false
    private var readPaused = false

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.ring = [Element?](repeating: nil, count: self.capacity)
    }

    /// Never blocks. A full queue cannot receive an offer: the producer only offers after an armed read
    /// completed, and a read is armed only while there is room. If it happens anyway the new batch is
    /// dropped (`.refusedFull`) and the read stays paused.
    public func offer(_ element: Element) -> OfferResult {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return .closed }
        guard count < capacity else {
            readPaused = true
            return .refusedFull
        }
        ring[(head + count) % capacity] = element
        count += 1
        condition.signal()
        if count < capacity {
            return .acceptedRearm
        }
        readPaused = true
        return .acceptedPaused
    }

    /// Waits up to `timeout` seconds (nil: until an element arrives or the queue closes) for the next
    /// element. `rearm` is `true` when the producer was paused and the caller must re-arm the read now.
    public func take(timeout: TimeInterval?) -> (element: Element?, rearm: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while count == 0, !closed {
            if let deadline = deadline {
                if !condition.wait(until: deadline) { break }
            } else {
                condition.wait()
            }
        }
        guard count > 0 else { return (nil, false) }
        let element = ring[head]
        ring[head] = nil
        head = (head + 1) % capacity
        count -= 1
        let rearm = readPaused && !closed
        if rearm { readPaused = false }
        return (element, rearm)
    }

    /// Drops what is queued and wakes every waiter. Idempotent.
    public func close() {
        condition.lock()
        closed = true
        for index in ring.indices { ring[index] = nil }
        count = 0
        readPaused = false
        condition.broadcast()
        condition.unlock()
    }

    public var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    public var queuedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }
}
