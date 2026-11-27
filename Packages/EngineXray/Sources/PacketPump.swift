// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge and a fake packet flow).
// Never run against NEPacketTunnelFlow or the real bridge.
import Foundation

/// The packet side of the tunnel interface, as the pump needs it. On Apple platforms it is
/// `NEPacketTunnelFlow` (`PacketTunnelFlowIO`); tests use a fake.
public protocol TunnelPacketIO: AnyObject, Sendable {
    /// Asks for the next batch of packets the system captured. `handler` is called exactly once, on a queue
    /// of the implementation's choosing, possibly long after the call; it must not block.
    func readPackets(_ handler: @escaping @Sendable ([Data]) -> Void)
    /// Hands packets to the system. `families[i]` belongs to `packets[i]`. Returns `false` when the system
    /// refused the batch.
    func writePackets(_ packets: [Data], families: [PacketAddressFamily]) -> Bool
}

/// Sizes and timings of the pump. Limits of this project, chosen by reasoning, not by measurement on a
/// device (`readPackets` batch sizes and the cost of the Swift-to-Go transition on arm64 are unmeasured).
public struct PacketPumpConfiguration: Hashable, Sendable {
    /// Batches from `readPackets` waiting for the bridge. 1 is the strictly serial design of
    /// tun-integration.md §3 (read, write, read); 2 lets the system fill the next batch while the previous
    /// one is in the bridge. Memory bound: `queueDepth` arrays of `Data` the system already allocated.
    public var queueDepth: Int = 2
    /// Framing buffer for `npb_tun_write`; a larger batch is written in several calls.
    public var inboundBufferBytes: Int = 256 * 1024
    /// Buffer for `npb_tun_read`; at least one maximum-size frame.
    public var outboundBufferBytes: Int = 256 * 1024
    /// How long one `npb_tun_read` waits; bounds how long the reader thread takes to notice a stop.
    public var readTimeoutMilliseconds: Int32 = 200
    /// How long `stop` waits for the pump threads.
    public var joinTimeout: TimeInterval = 2

    public init() {}

    public static let standard = PacketPumpConfiguration()
}

/// What the pump has done. Batches are counted, not timed: the counters are updated once per batch.
public struct PacketPumpCounters: Hashable, Sendable, Codable {
    // Device -> core.
    public var inboundBatches: UInt64 = 0
    public var inboundPackets: UInt64 = 0
    public var inboundBytes: UInt64 = 0
    /// Empty packets or packets longer than a frame can carry; dropped.
    public var inboundInvalid: UInt64 = 0
    /// Packets the bridge did not consume (it returned fewer than were framed, or an error).
    public var inboundRejected: UInt64 = 0
    /// Packets that arrived after the pump began to stop; dropped.
    public var inboundAfterStop: UInt64 = 0
    /// Times the read was paused because the queue was full (backpressure).
    public var inboundPauses: UInt64 = 0
    // Core -> device.
    public var outboundBatches: UInt64 = 0
    public var outboundPackets: UInt64 = 0
    public var outboundBytes: UInt64 = 0
    public var outboundUnknownFamily: UInt64 = 0
    public var outboundTruncated: UInt64 = 0
    /// Batches `writePackets` refused.
    public var outboundWriteFailures: UInt64 = 0
    /// The last error code the bridge returned to the pump, if any.
    public var lastBridgeError: Int32?

    public init() {}
}

/// Moves packets between the tunnel interface and the bridge in batches, without parsing them.
///
///     readPackets -> BoundedBatchQueue -> [writer thread] frame -> npb_tun_write
///     npb_tun_read -> [reader thread] split frames -> writePackets
///
/// Both bridge calls may block, so each direction has its own thread instead of a task of the Swift
/// cooperative pool. Allocations: the framing buffer and the read buffer are allocated once per pump; on
/// the way out one `Data` per packet is unavoidable because `writePackets` takes `[Data]`.
///
/// Stop: `beginStop` closes the queue (the writer exits) and sets a flag the reader checks after every
/// `npb_tun_read`, which returns within `readTimeoutMilliseconds` or at once with `closed` when the engine
/// stops. A `readPackets` completion that arrives later is dropped and does not re-arm. `join` waits for
/// both threads within `joinTimeout`.
public final class PacketPump: @unchecked Sendable {
    public enum State: String, Sendable {
        case idle
        case running
        case stopping
        case stopped
    }

    private let bridge: any XrayBridgeABI
    private let io: any TunnelPacketIO
    private let configuration: PacketPumpConfiguration
    private let onEngineGone: @Sendable (XrayBridgeCode) -> Void
    private let queue: BoundedBatchQueue<[Data]>

    private let lock = NSLock()
    private var stateValue: State = .idle
    private var countersValue = PacketPumpCounters()
    private var engineGoneReported = false
    private let writerDone = DispatchSemaphore(value: 0)
    private let readerDone = DispatchSemaphore(value: 0)

    /// `onEngineGone` is called at most once, from a pump thread, when the bridge reports that the packet
    /// device closed or no engine runs while the pump was not stopping: the engine stopped on its own.
    public init(
        bridge: any XrayBridgeABI,
        io: any TunnelPacketIO,
        configuration: PacketPumpConfiguration = .standard,
        onEngineGone: @escaping @Sendable (XrayBridgeCode) -> Void
    ) {
        self.bridge = bridge
        self.io = io
        self.configuration = configuration
        self.onEngineGone = onEngineGone
        self.queue = BoundedBatchQueue(capacity: configuration.queueDepth)
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    public var counters: PacketPumpCounters {
        lock.lock()
        defer { lock.unlock() }
        return countersValue
    }

    /// Starts both threads and arms the first read. Only once per pump.
    public func start() {
        lock.lock()
        guard stateValue == .idle else {
            lock.unlock()
            return
        }
        stateValue = .running
        lock.unlock()

        let writer = Thread { [self] in
            self.writerLoop()
            self.writerDone.signal()
        }
        writer.name = "np.xray.pump.in"
        writer.qualityOfService = .userInitiated
        let reader = Thread { [self] in
            self.readerLoop()
            self.readerDone.signal()
        }
        reader.name = "np.xray.pump.out"
        reader.qualityOfService = .userInitiated
        writer.start()
        reader.start()
        armRead()
    }

    /// Tells both threads to finish. Does not wait. Idempotent.
    public func beginStop() {
        lock.lock()
        let wasRunning = stateValue == .running
        if stateValue == .running || stateValue == .idle {
            stateValue = wasRunning ? .stopping : .stopped
        }
        lock.unlock()
        queue.close()
    }

    /// Waits for both threads. Returns `false` when one of them did not finish within `joinTimeout` (it is
    /// then stuck in a bridge call; it holds no lock and finishes when the call returns).
    @discardableResult
    public func join() -> Bool {
        lock.lock()
        let current = stateValue
        lock.unlock()
        guard current == .stopping else { return true }
        let deadline = DispatchTime.now() + configuration.joinTimeout
        let writerFinished = writerDone.wait(timeout: deadline) == .success
        let readerFinished = readerDone.wait(timeout: deadline) == .success
        if writerFinished, readerFinished {
            lock.lock()
            stateValue = .stopped
            lock.unlock()
            return true
        }
        // Put back what was taken, so that a second join can still succeed.
        if writerFinished { writerDone.signal() }
        if readerFinished { readerDone.signal() }
        return false
    }

    /// `beginStop` + `join`.
    @discardableResult
    public func stop() -> Bool {
        beginStop()
        return join()
    }

    // MARK: Device -> core

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateValue == .running
    }

    private func armRead() {
        guard isRunning else { return }
        io.readPackets { [weak self] packets in
            self?.received(packets)
        }
    }

    private func received(_ packets: [Data]) {
        guard isRunning else {
            update { $0.inboundAfterStop &+= UInt64(packets.count) }
            return
        }
        switch queue.offer(packets) {
        case .acceptedRearm:
            armRead()
        case .acceptedPaused:
            update { $0.inboundPauses &+= 1 }
        case .closed:
            update { $0.inboundAfterStop &+= UInt64(packets.count) }
        case .refusedFull:
            update { $0.inboundRejected &+= UInt64(packets.count) }
        }
    }

    private func writerLoop() {
        var encoder = PacketBatchEncoder(capacity: configuration.inboundBufferBytes)
        while true {
            let (taken, rearm) = queue.take(timeout: nil)
            if rearm {
                // Room again: let the system fill the next batch while this one goes to the bridge.
                armRead()
            }
            guard let batch = taken else { return }
            var invalid: UInt64 = 0
            var sentPackets: UInt64 = 0
            var sentBytes: UInt64 = 0
            var rejected: UInt64 = 0
            var lastError: Int32?
            encoder.reset()
            for packet in batch {
                var result = encoder.append(packet)
                if result == .full {
                    flush(&encoder, sent: &sentPackets, bytes: &sentBytes, rejected: &rejected, lastError: &lastError)
                    result = encoder.append(packet)
                }
                if result == .invalid { invalid &+= 1 }
            }
            flush(&encoder, sent: &sentPackets, bytes: &sentBytes, rejected: &rejected, lastError: &lastError)
            update {
                $0.inboundBatches &+= 1
                $0.inboundPackets &+= sentPackets
                $0.inboundBytes &+= sentBytes
                $0.inboundInvalid &+= invalid
                $0.inboundRejected &+= rejected
                if let code = lastError { $0.lastBridgeError = code }
            }
        }
    }

    private func flush(
        _ encoder: inout PacketBatchEncoder,
        sent: inout UInt64,
        bytes: inout UInt64,
        rejected: inout UInt64,
        lastError: inout Int32?
    ) {
        guard !encoder.isEmpty else { return }
        let framed = encoder.packetCount
        let framedBytes = encoder.byteCount - framed * PacketFrame.headerSize
        let result = encoder.withFramedBytes { bridge.tunWrite($0) }
        encoder.reset()
        if result < 0 {
            let code = XrayBridgeCode.fromDataPlane(result)
            rejected &+= UInt64(framed)
            lastError = code.rawValue
            if code == .notRunning || code == .closed {
                reportEngineGone(code)
            }
            return
        }
        let consumed = min(Int(result), framed)
        sent &+= UInt64(consumed)
        // The byte count of a partial batch is not known without walking the frames; partial results only
        // happen on a malformed frame, which the encoder does not produce.
        bytes &+= consumed == framed ? UInt64(framedBytes) : 0
        rejected &+= UInt64(framed - consumed)
    }

    // MARK: Core -> device

    private func readerLoop() {
        let capacity = max(configuration.outboundBufferBytes, PacketFrame.headerSize + PacketFrame.maximumPacketBytes)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var packets: [Data] = []
        var families: [PacketAddressFamily] = []
        while isRunning {
            let result = bridge.tunRead(into: buffer, timeoutMilliseconds: configuration.readTimeoutMilliseconds)
            if result == 0 { continue }
            if result < 0 {
                let code = XrayBridgeCode.fromDataPlane(result)
                update { $0.lastBridgeError = code.rawValue }
                guard isRunning else { return }
                // Every error ends the reader: with a buffer of a maximum-size frame, `buffer_too_small`
                // cannot happen, and the others mean the device is gone.
                reportEngineGone(code)
                return
            }
            let filled = UnsafeRawBufferPointer(rebasing: buffer[0..<min(Int(result), capacity)])
            packets.removeAll(keepingCapacity: true)
            families.removeAll(keepingCapacity: true)
            var bytes: UInt64 = 0
            let outcome = PacketBatchDecoder.decode(filled) { packet, family in
                packets.append(Data(packet))
                families.append(family)
                bytes &+= UInt64(packet.count)
            }
            let written = packets.isEmpty ? true : io.writePackets(packets, families: families)
            update {
                $0.outboundBatches &+= 1
                $0.outboundPackets &+= UInt64(outcome.packets)
                $0.outboundBytes &+= bytes
                $0.outboundUnknownFamily &+= UInt64(outcome.unknownFamily)
                if outcome.truncated { $0.outboundTruncated &+= 1 }
                if !written { $0.outboundWriteFailures &+= 1 }
            }
        }
    }

    // MARK: Helpers

    private func update(_ body: (inout PacketPumpCounters) -> Void) {
        lock.lock()
        body(&countersValue)
        lock.unlock()
    }

    private func reportEngineGone(_ code: XrayBridgeCode) {
        lock.lock()
        let report = stateValue == .running && !engineGoneReported
        if report { engineGoneReported = true }
        lock.unlock()
        if report { onEngineGone(code) }
    }
}
