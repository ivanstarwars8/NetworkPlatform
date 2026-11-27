// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Not yet run on Apple platforms.
import Foundation

/// Drains the bridge's log ring (`npb_log_read`) on its own thread and hands each record to a sink.
///
/// The ring never blocks the core; records lost to overflow show as gaps in `seq`, which are counted here.
/// The sink receives the core's messages as they are: they may contain destination addresses, so the host
/// must log them as private (ADR-0003 §4).
final class XrayLogReader: @unchecked Sendable {
    private let bridge: any XrayBridgeABI
    private let timeoutMilliseconds: Int32
    private let bufferBytes: Int
    private let sink: @Sendable (XrayLogRecord) -> Void

    private let lock = NSLock()
    private var running = false
    private var started = false
    private var lastSeq: UInt64?
    private var missed: UInt64 = 0
    private var delivered: UInt64 = 0
    private let done = DispatchSemaphore(value: 0)

    init(bridge: any XrayBridgeABI, settings: XrayCoreSettings, sink: @escaping @Sendable (XrayLogRecord) -> Void) {
        self.bridge = bridge
        self.timeoutMilliseconds = settings.logReadTimeoutMilliseconds
        self.bufferBytes = max(4096, settings.logBufferBytes)
        self.sink = sink
    }

    /// Records delivered and records known to be lost (gaps in `seq`).
    var counts: (delivered: UInt64, missed: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (delivered, missed)
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            self.loop()
            self.done.signal()
        }
        thread.name = "np.xray.log"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Asks the thread to finish and waits for it at most one read timeout plus a margin.
    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }
        let wait = Double(timeoutMilliseconds) / 1000 + 1
        _ = done.wait(timeout: .now() + wait)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func loop() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferBytes, alignment: 8)
        defer { buffer.deallocate() }
        let decoder = JSONDecoder()
        while isRunning {
            let result = bridge.readLog(into: buffer, timeoutMilliseconds: timeoutMilliseconds)
            if result <= 0 {
                if result < 0 { return }  // only buffer_too_small, impossible with >= 4 KiB
                continue
            }
            var lineStart = 0
            let end = min(Int(result), bufferBytes)
            for index in 0..<end where buffer[index] == 0x0A {
                if index > lineStart {
                    let line = Data(UnsafeRawBufferPointer(rebasing: buffer[lineStart..<index]))
                    if let record = try? decoder.decode(XrayLogRecord.self, from: line) {
                        account(record)
                        sink(record)
                    }
                }
                lineStart = index + 1
            }
        }
    }

    private func account(_ record: XrayLogRecord) {
        lock.lock()
        if let last = lastSeq, record.seq > last &+ 1 {
            missed &+= record.seq - last - 1
        }
        lastSeq = record.seq
        delivered &+= 1
        lock.unlock()
    }
}
