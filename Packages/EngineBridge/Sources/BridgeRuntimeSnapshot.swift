// Verified on Linux only (Swift 5.10, swift test, against a fake bridge). What the engine diagnostics screen shows
// about the Go side of an extension: core and Go versions, runtime memory, goroutines, uptime, the bridge's last
// error. Read on demand (app request, at most every 2 s while the screen is visible), never on the packet path.

import Foundation

/// A snapshot of `npb_version`, `npb_health` and `npb_memory`. Every field is optional: a bridge of another
/// version may leave some out, and nothing is guessed.
public struct BridgeRuntimeSnapshot: Codable, Hashable, Sendable {
    public var abi: Int32?
    public var coreVersion: String?
    public var goVersion: String?
    /// Bridge lifecycle state ("idle", "starting", "running", "stopping").
    public var state: String?
    public var uptimeSeconds: Double?
    /// Live heap after the last GC (`/gc/heap/live:bytes`).
    public var goHeapLiveBytes: UInt64?
    /// Bytes in live and not-yet-swept objects.
    public var goHeapObjectsBytes: UInt64?
    /// Memory the Go runtime holds from the OS (mapped minus released): its share of the process footprint.
    public var goMappedBytes: UInt64?
    public var goStacksBytes: UInt64?
    public var goroutines: UInt64?
    public var gcCycles: UInt64?
    /// Soft memory limit in effect (`GOMEMLIMIT`); `nil` when unlimited.
    public var goMemoryLimitBytes: Int64?
    public var lastErrorCode: Int32?
    /// The bridge's last start/stop error; config values are redacted by the bridge (engine/redact.go).
    public var lastError: String?
    public var logDropped: UInt64?

    public init() {}

    private struct Memory: Decodable {
        let mapped: UInt64?
        let heapObjects: UInt64?
        let heapLive: UInt64?
        let stacks: UInt64?
        let goroutines: UInt64?
        let gcCycles: UInt64?
        let limit: Int64?
    }

    private struct Health: Decodable {
        let state: String?
        let uptimeMs: Int64?
        let lastErrorCode: Int32?
        let lastError: String?
        let goroutines: UInt64?
        let logDropped: UInt64?
    }

    /// Reads the three replies. Cheap (runtime/metrics, no stop-the-world) and valid in every bridge state.
    public static func read(from bridge: BridgeABI) -> BridgeRuntimeSnapshot {
        var snapshot = BridgeRuntimeSnapshot()
        let version = BridgeReply<BridgeVersion>.decode(bridge.version())
        if version.code == .ok, let data = version.data {
            snapshot.abi = data.abi
            snapshot.coreVersion = data.core
            snapshot.goVersion = data.go
        }
        let health = BridgeReply<Health>.decode(bridge.health())
        if health.code == .ok, let data = health.data {
            snapshot.state = data.state
            if let ms = data.uptimeMs, ms > 0 { snapshot.uptimeSeconds = Double(ms) / 1000 }
            if let code = data.lastErrorCode, code != 0 {
                snapshot.lastErrorCode = code
                snapshot.lastError = data.lastError
            }
            snapshot.goroutines = data.goroutines
            snapshot.logDropped = data.logDropped
        }
        let memory = BridgeReply<Memory>.decode(bridge.memory())
        if memory.code == .ok, let data = memory.data {
            snapshot.goMappedBytes = data.mapped
            snapshot.goHeapObjectsBytes = data.heapObjects
            snapshot.goHeapLiveBytes = data.heapLive
            snapshot.goStacksBytes = data.stacks
            snapshot.goroutines = data.goroutines ?? snapshot.goroutines
            snapshot.gcCycles = data.gcCycles
            // math.MaxInt64 means no limit.
            if let limit = data.limit, limit > 0, limit != Int64.max { snapshot.goMemoryLimitBytes = limit }
        }
        return snapshot
    }
}

/// The most recent error-level records of the engine log, bounded in count and length. Filled from the
/// adapter's log callback (already off the packet path), read by the diagnostics request. Thread-safe.
public final class RecentEngineErrors: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var timeUnixMilliseconds: Int64
        public var kind: String
        public var message: String
    }

    public let capacity: Int
    public let maximumMessageLength: Int
    private let lock = NSLock()
    private var entries: [Entry] = []

    public init(capacity: Int = 8, maximumMessageLength: Int = 240) {
        self.capacity = max(1, capacity)
        self.maximumMessageLength = max(16, maximumMessageLength)
    }

    /// Keeps the record when it is an error; other levels are ignored.
    public func note(_ record: BridgeLogRecord) {
        guard record.level == "error" else { return }
        var message = record.message
        if message.count > maximumMessageLength { message = String(message.prefix(maximumMessageLength)) + "…" }
        let entry = Entry(timeUnixMilliseconds: record.timeUnixMilliseconds, kind: record.kind, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    /// Newest last.
    public var snapshot: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
