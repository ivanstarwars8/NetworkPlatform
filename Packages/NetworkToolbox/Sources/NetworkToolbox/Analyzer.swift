// State of the traffic analyser, kept in the app and fed by the extension's counters at most once per second
// while the analyser is visible. Everything is bounded; nothing here touches packets.

import Foundation

/// One measured rate point. Rates come from two counter samples (`RateSampler`), never from estimates.
public struct RatePoint: Equatable, Sendable {
    public let time: Date
    public let downBitsPerSecond: Double
    public let upBitsPerSecond: Double
}

/// Turns cumulative byte counters into rates. A counter that goes backwards (engine restarted) or a gap
/// longer than `maximumGap` resets the sampler instead of producing a made-up rate.
public struct RateSampler: Sendable {
    public static let maximumGap: Double = 5

    private var last: (up: UInt64, down: UInt64, time: Double)?

    public init() {}

    public mutating func add(up: UInt64, down: UInt64, monotonicTime: Double, wallTime: Date) -> RatePoint? {
        defer { last = (up, down, monotonicTime) }
        guard let previous = last else { return nil }
        let elapsed = monotonicTime - previous.time
        guard elapsed > 0.2, elapsed <= RateSampler.maximumGap, up >= previous.up, down >= previous.down else { return nil }
        return RatePoint(
            time: wallTime,
            downBitsPerSecond: Double(down - previous.down) * 8 / elapsed,
            upBitsPerSecond: Double(up - previous.up) * 8 / elapsed
        )
    }

    public mutating func reset() {
        last = nil
    }
}

/// A bounded ring of the most recent elements, oldest first.
public struct BoundedHistory<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var last: Element? { storage.isEmpty ? nil : storage[(head + storage.count - 1) % storage.count] }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

public enum TrafficGraph {
    /// Five minutes at one point per second.
    public static let capacity = 300

    /// Upper bound of the vertical axis: the largest rate in the window rounded up to 1, 2 or 5 × 10ⁿ, at least
    /// 8 kbit/s so that an idle tunnel does not draw noise full-height.
    public static func axisMaximum(_ points: [RatePoint]) -> Double {
        let peak = points.map { max($0.downBitsPerSecond, $0.upBitsPerSecond) }.max() ?? 0
        let floor = 8_000.0
        let value = max(peak, floor)
        let exponent = pow(10, (log10(value)).rounded(.down))
        for step in [1.0, 2.0, 5.0, 10.0] where step * exponent >= value {
            return step * exponent
        }
        return 10 * exponent
    }
}

/// Error and network-change events, newest last, bounded. Repeats of the same event collapse into a count.
public struct EventTimeline: Sendable {
    public enum Kind: String, Sendable, Codable {
        case tunnel
        case network
        case error
    }

    public struct Event: Equatable, Sendable, Identifiable {
        public let id: UInt64
        public let kind: Kind
        public var time: Date
        public let text: String
        public var repeats: Int
    }

    public static let capacity = 200

    private var history = BoundedHistory<Event>(capacity: EventTimeline.capacity)
    private var nextID: UInt64 = 1

    public init() {}

    public mutating func record(_ kind: Kind, _ text: String, at time: Date = Date()) {
        let trimmed = String(text.prefix(300))
        if var last = history.last, last.kind == kind, last.text == trimmed {
            last.repeats += 1
            last.time = time
            var items = history.elements
            items[items.count - 1] = last
            history.removeAll()
            items.forEach { history.append($0) }
            return
        }
        history.append(Event(id: nextID, kind: kind, time: time, text: trimmed, repeats: 1))
        nextID &+= 1
    }

    public var events: [Event] { history.elements }

    public func events(of kind: Kind) -> [Event] {
        history.elements.filter { $0.kind == kind }
    }

    public mutating func clear() {
        history.removeAll()
    }
}

/// One connection the engine tracks, engine-neutral. Destinations are the user's data: shown on screen,
/// never written to logs or to the diagnostics bundle.
public struct ConnectionRecord: Equatable, Sendable, Identifiable {
    public let id: String
    public let network: String
    public let destination: String
    public let rule: String?
    public let chain: [String]
    public let uploadBytes: UInt64
    public let downloadBytes: UInt64
    public let started: Date?

    public init(id: String, network: String, destination: String, rule: String?, chain: [String], uploadBytes: UInt64, downloadBytes: UInt64, started: Date?) {
        self.id = id
        self.network = network
        self.destination = destination
        self.rule = rule
        self.chain = chain
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.started = started
    }
}

/// Keeps the last snapshot of active connections and the ones that disappeared since (closed while the
/// analyser was watching). Bounded.
public struct ConnectionTracker: Sendable {
    public static let recentCapacity = 100

    public private(set) var active: [ConnectionRecord] = []
    private var recent = BoundedHistory<ClosedConnection>(capacity: ConnectionTracker.recentCapacity)

    public init() {}

    public mutating func update(_ snapshot: [ConnectionRecord], at time: Date = Date()) {
        let current = Set(snapshot.map(\.id))
        for record in active where !current.contains(record.id) {
            recent.append(ClosedConnection(record: record, closed: time))
        }
        active = snapshot
    }

    /// Closed connections, newest first.
    public var recentlyClosed: [ClosedConnection] {
        recent.elements.reversed()
    }

    public mutating func clear() {
        active = []
        recent.removeAll()
    }
}

public struct ClosedConnection: Equatable, Sendable, Identifiable {
    public let record: ConnectionRecord
    public let closed: Date

    public var id: String { record.id }
}
