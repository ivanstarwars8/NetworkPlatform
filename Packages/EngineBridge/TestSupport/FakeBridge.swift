// Verified on Linux only (Swift 5.10.1, swift test).
// Test doubles shared by the tests of EngineBridge, EngineXray and EngineMihomo (no product links this module).
import EngineBridge
import Foundation

/// A stand-in for the Go bridge that keeps the ABI's observable rules: control-plane JSON replies, frames
/// in both directions, `npb_tun_read` that waits up to its timeout and returns `closed` (-13) when the
/// engine stops, `npb_stop` that interrupts a blocked start.
public final class FakeBridge: BridgeABI, @unchecked Sendable {
    private let condition = NSCondition()

    public init() {}

    public var abi: Int32 = 1
    /// Defaults to the Xray bridge's reply; the Mihomo tests set the Mihomo bridge's.
    public var versionReply = #"{"code":0,"data":{"abi":1,"core":"26.11.9","go":"go1.27.4"}}"#
    public var startReply = #"{"code":0}"#
    public var stopReply = #"{"code":0}"#
    public var validateReply = #"{"code":0,"data":{"inbounds":[],"outbounds":[],"hasTun":true,"depth":"instance"}}"#
    public var statsReply = #"{"code":0,"data":{"uptimeMs":1500,"inbounds":[{"tag":"tun-in","uplink":100,"downlink":2000}],"outbounds":[{"tag":"proxy","uplink":150,"downlink":2100},{"tag":"direct","uplink":0,"downlink":0}]}}"#
    /// Reply of `npb_observe` while running.
    public var observeReply = #"{"code":0,"data":{"groups":[]}}"#
    /// Reply of `npb_select` while running.
    public var selectReply = #"{"code":0}"#
    public private(set) var selectCalls: [(group: String, member: String)] = []
    /// When set, `start` blocks until `stop` is called and then returns this reply.
    public var startBlocksUntilStop = false
    /// A value for every `tunWrite` call instead of the packet count (negative = error code).
    public var tunWriteOverride: Int32?

    public private(set) var running = false
    public private(set) var startCalls: [(config: Data, options: Data)] = []
    public private(set) var validateCalls: [(config: Data, options: Data)] = []
    public private(set) var stopCalls = 0
    private var tunWriteCallsValue = 0

    public var tunWriteCalls: Int {
        condition.lock()
        defer { condition.unlock() }
        return tunWriteCallsValue
    }
    /// Packets the engine received, in order.
    public private(set) var inbound: [Data] = []
    private var outbound: [Data] = []
    private var logs: [String] = []
    private var stopSignalled = false

    // MARK: Test controls

    public func queueOutbound(_ packets: [Data]) {
        condition.lock()
        outbound.append(contentsOf: packets)
        condition.broadcast()
        condition.unlock()
    }

    public func queueLog(_ line: String) {
        condition.lock()
        logs.append(line)
        condition.broadcast()
        condition.unlock()
    }

    /// The engine dies on its own: the packet device closes.
    public func crash() {
        condition.lock()
        running = false
        condition.broadcast()
        condition.unlock()
    }

    public func inboundSnapshot() -> [Data] {
        condition.lock()
        defer { condition.unlock() }
        return inbound
    }

    public func waitForInbound(count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while inbound.count < count {
            if !condition.wait(until: deadline) { return inbound.count >= count }
        }
        return true
    }

    public func read<T>(_ body: (FakeBridge) -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body(self)
    }

    public func set(_ body: (FakeBridge) -> Void) {
        condition.lock()
        body(self)
        condition.unlock()
    }

    // MARK: ABI

    public func abiVersion() -> Int32 { abi }

    public func version() -> String {
        condition.lock()
        defer { condition.unlock() }
        return versionReply
    }

    public func validate(configuration: Data, options: Data) -> String {
        condition.lock()
        defer { condition.unlock() }
        validateCalls.append((configuration, options))
        return validateReply
    }

    public func start(configuration: Data, options: Data) -> String {
        condition.lock()
        defer { condition.unlock() }
        startCalls.append((configuration, options))
        stopSignalled = false
        if startBlocksUntilStop {
            while !stopSignalled { condition.wait() }
            return #"{"code":8,"error":"start cancelled by stop"}"#
        }
        if startReply.contains(#""code":0"#) {
            running = true
        }
        return startReply
    }

    public func stop(timeoutMilliseconds: Int32) -> String {
        condition.lock()
        defer { condition.unlock() }
        stopCalls += 1
        running = false
        stopSignalled = true
        condition.broadcast()
        return stopReply
    }

    public func stats() -> String {
        condition.lock()
        defer { condition.unlock() }
        return running ? statsReply : #"{"code":11,"error":"not running"}"#
    }

    public func observe() -> String {
        condition.lock()
        defer { condition.unlock() }
        return running ? observeReply : #"{"code":11,"error":"engine is not running"}"#
    }

    public func select(group: String, member: String) -> String {
        condition.lock()
        defer { condition.unlock() }
        guard running else { return #"{"code":11,"error":"engine is not running"}"# }
        selectCalls.append((group, member))
        return selectReply
    }

    public var connectionsReply = #"{"code":0,"data":{"total":1,"items":[{"id":"c1","network":"tcp","destination":"example.com:443","rule":"Match","chain":["group-0001","proxy-0001"],"upload":10,"download":20,"startMs":1700000000000}]}}"#
    public private(set) var lastConnectionsLimit: Int32?

    public func connections(limit: Int32) -> String {
        condition.lock()
        defer { condition.unlock() }
        lastConnectionsLimit = limit
        return running ? connectionsReply : #"{"code":11,"error":"not running"}"#
    }

    public func health() -> String {
        condition.lock()
        defer { condition.unlock() }
        let state = running ? "running" : "idle"
        return #"{"code":0,"data":{"state":"\#(state)","coreRunning":\#(running),"lastErrorCode":0}}"#
    }

    public func memory() -> String { #"{"code":0,"data":{}}"# }

    public func state() -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        return running ? 2 : 0
    }

    public func readLog(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        guard buffer.count >= 4096 else { return -12 }
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMilliseconds) / 1000)
        condition.lock()
        defer { condition.unlock() }
        while logs.isEmpty {
            if !condition.wait(until: deadline) { return 0 }
        }
        var written = 0
        while let line = logs.first {
            let bytes = Array(line.utf8) + [0x0A]
            guard written + bytes.count <= buffer.count else { break }
            for (index, byte) in bytes.enumerated() { buffer[written + index] = byte }
            written += bytes.count
            logs.removeFirst()
        }
        return Int32(written)
    }

    public func tunWrite(_ batch: UnsafeMutableRawBufferPointer) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        tunWriteCallsValue += 1
        if let override = tunWriteOverride { return override }
        guard running else { return -11 }
        var count: Int32 = 0
        PacketBatchDecoderRaw.frames(UnsafeRawBufferPointer(batch)) { packet in
            inbound.append(Data(packet))
            count += 1
        }
        // Scribble over the batch, as the bridge is allowed to.
        for index in 0..<batch.count { batch[index] = 0xEE }
        condition.broadcast()
        return count
    }

    public func tunRead(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        let deadline = Date(timeIntervalSinceNow: Double(timeoutMilliseconds) / 1000)
        condition.lock()
        defer { condition.unlock() }
        while outbound.isEmpty {
            if !running { return -13 }
            if !condition.wait(until: deadline) { return running ? 0 : -13 }
        }
        var written = 0
        while let packet = outbound.first, written + 2 + packet.count <= buffer.count {
            buffer[written] = UInt8(truncatingIfNeeded: packet.count)
            buffer[written + 1] = UInt8(truncatingIfNeeded: packet.count >> 8)
            for (index, byte) in packet.enumerated() { buffer[written + 2 + index] = byte }
            written += 2 + packet.count
            outbound.removeFirst()
        }
        return Int32(written)
    }
}

/// Frame splitting without the family check, for the fake (the engine side takes any frame).
public enum PacketBatchDecoderRaw {
    public static func frames(_ bytes: UnsafeRawBufferPointer, emit: (UnsafeRawBufferPointer) -> Void) {
        var offset = 0
        while bytes.count - offset >= 2 {
            let size = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            let start = offset + 2
            guard size > 0, size <= bytes.count - start else { return }
            emit(UnsafeRawBufferPointer(rebasing: bytes[start..<(start + size)]))
            offset = start + size
        }
    }
}

/// A fake `NEPacketTunnelFlow`: the test supplies batches for `readPackets`, written batches are recorded.
public final class FakePacketIO: TunnelPacketIO, @unchecked Sendable {
    public init() {}

    private let condition = NSCondition()
    private var pendingBatches: [[Data]] = []
    private var waitingHandler: (@Sendable ([Data]) -> Void)?
    private var readCallsValue = 0
    private var writtenValue: [(packets: [Data], families: [PacketAddressFamily])] = []
    private var writeResultValue = true

    public var readCalls: Int {
        condition.lock()
        defer { condition.unlock() }
        return readCallsValue
    }

    public var written: [(packets: [Data], families: [PacketAddressFamily])] {
        condition.lock()
        defer { condition.unlock() }
        return writtenValue
    }

    public var writeResult: Bool {
        get {
            condition.lock()
            defer { condition.unlock() }
            return writeResultValue
        }
        set {
            condition.lock()
            writeResultValue = newValue
            condition.unlock()
        }
    }

    /// Supplies a batch to the next (or the currently armed) read.
    public func supply(_ batch: [Data]) {
        condition.lock()
        if let handler = waitingHandler {
            waitingHandler = nil
            condition.unlock()
            handler(batch)
            return
        }
        pendingBatches.append(batch)
        condition.unlock()
    }

    /// Whether a read is armed and waiting for packets.
    public var hasArmedRead: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waitingHandler != nil
    }

    /// Completes an armed read (used to simulate a completion arriving after stop).
    public func completeArmedRead(with batch: [Data]) -> Bool {
        condition.lock()
        guard let handler = waitingHandler else {
            condition.unlock()
            return false
        }
        waitingHandler = nil
        condition.unlock()
        handler(batch)
        return true
    }

    public func readPackets(_ handler: @escaping @Sendable ([Data]) -> Void) {
        condition.lock()
        readCallsValue += 1
        if !pendingBatches.isEmpty {
            let batch = pendingBatches.removeFirst()
            condition.unlock()
            // Asynchronously, like the system.
            DispatchQueue.global().async { handler(batch) }
            return
        }
        waitingHandler = handler
        condition.unlock()
    }

    public func writePackets(_ packets: [Data], families: [PacketAddressFamily]) -> Bool {
        condition.lock()
        writtenValue.append((packets, families))
        let result = writeResultValue
        condition.broadcast()
        condition.unlock()
        return result
    }

    public func writtenPackets() -> [Data] {
        condition.lock()
        defer { condition.unlock() }
        return writtenValue.flatMap { $0.packets }
    }

    public func waitForWritten(count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while writtenValue.reduce(0, { $0 + $1.packets.count }) < count {
            if !condition.wait(until: deadline) { break }
        }
        return writtenValue.reduce(0, { $0 + $1.packets.count }) >= count
    }
}

/// A minimal IPv4 or IPv6 packet: the version nibble and filler bytes. The pump never looks further.
public func packet(version: UInt8, size: Int, fill: UInt8) -> Data {
    var bytes = [UInt8](repeating: fill, count: size)
    bytes[0] = version << 4 | 5
    return Data(bytes)
}

/// Polls `condition` until it holds or `timeout` passes.
public func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

/// A value shared between test code and callbacks on other threads.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) {
        stored = value
    }

    public var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
