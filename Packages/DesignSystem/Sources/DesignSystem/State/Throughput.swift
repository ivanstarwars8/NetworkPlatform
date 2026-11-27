// Live speed from the engine's byte counters. The extension reports cumulative counters (`.statistics`);
// the app samples them at most once per second while the connection screen is visible and derives the
// speed from two consecutive samples. Nothing is estimated: no samples, no number.

/// One reading of the cumulative counters.
public struct TrafficSample: Equatable, Sendable {
    public var uplinkBytes: UInt64
    public var downlinkBytes: UInt64
    /// Monotonic time of the reading, in seconds.
    public var time: Double

    public init(uplinkBytes: UInt64, downlinkBytes: UInt64, time: Double) {
        self.uplinkBytes = uplinkBytes
        self.downlinkBytes = downlinkBytes
        self.time = time
    }
}

/// Speed in both directions, bits per second.
public struct Throughput: Equatable, Sendable {
    public var downBitsPerSecond: Double
    public var upBitsPerSecond: Double

    public init(downBitsPerSecond: Double, upBitsPerSecond: Double) {
        self.downBitsPerSecond = downBitsPerSecond
        self.upBitsPerSecond = upBitsPerSecond
    }
}

/// Turns consecutive samples into a speed.
public struct ThroughputMeter: Sendable {
    /// Samples further apart than this are not combined: the screen was hidden or the query stalled, and an
    /// average over the gap would be a different quantity than "now".
    public static let maximumInterval: Double = 5

    private var previous: TrafficSample?

    public init() {}

    /// Adds a sample; returns the speed since the previous one, or `nil` when there is no valid previous
    /// sample (first reading, a gap, time going backwards, counters reset by an engine restart).
    public mutating func add(_ sample: TrafficSample) -> Throughput? {
        defer { previous = sample }
        guard let last = previous else { return nil }
        let interval = sample.time - last.time
        guard interval > 0, interval <= ThroughputMeter.maximumInterval,
              sample.uplinkBytes >= last.uplinkBytes, sample.downlinkBytes >= last.downlinkBytes else {
            return nil
        }
        return Throughput(
            downBitsPerSecond: Double(sample.downlinkBytes - last.downlinkBytes) * 8 / interval,
            upBitsPerSecond: Double(sample.uplinkBytes - last.uplinkBytes) * 8 / interval
        )
    }

    /// Forgets the previous sample (the tunnel went down or the screen was hidden).
    public mutating func reset() {
        previous = nil
    }
}

/// Russian formatting of numbers for the UI, independent of the device locale (the UI copy is Russian).
public enum UnitFormat {
    /// A speed as a number and a unit: `("8,4", "Мбит/с")`. Decimal units (network convention).
    /// One decimal below 10, whole numbers above.
    public static func speed(bitsPerSecond: Double) -> (value: String, unit: String) {
        let units = ["бит/с", "Кбит/с", "Мбит/с", "Гбит/с"]
        var value = max(0, bitsPerSecond.isFinite ? bitsPerSecond : 0)
        var index = 0
        while index < units.count - 1, rounded(value) >= 1000 {
            value /= 1000
            index += 1
        }
        if index == 0 {
            return (String(Int(value.rounded())), units[0])
        }
        return (number(value), units[index])
    }

    /// A byte count with binary multiples and Russian units: `"1,5 МБ"`.
    public static func bytes(_ count: UInt64) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var value = Double(count)
        var index = 0
        while index < units.count - 1, rounded(value) >= 1024 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(count) \(units[0])"
        }
        return "\(number(value)) \(units[index])"
    }

    /// A duration in whole units, the two largest non-zero ones: "45 с", "3 мин 05 с", "2 ч 07 мин", "3 д 4 ч".
    public static func duration(seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let days = total / 86_400, hours = total / 3_600 % 24, minutes = total / 60 % 60, secs = total % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if days > 0 { return hours > 0 ? "\(days) д \(hours) ч" : "\(days) д" }
        if hours > 0 { return "\(hours) ч \(two(minutes)) мин" }
        if minutes > 0 { return "\(minutes) мин \(two(secs)) с" }
        return "\(secs) с"
    }

    /// The value as it will be displayed, for unit promotion: 999.96 shows as "1000", so it is promoted.
    private static func rounded(_ value: Double) -> Double {
        value < 10 ? (value * 10).rounded() / 10 : value.rounded()
    }

    /// One decimal below 10 (decimal comma), whole number otherwise.
    static func number(_ value: Double) -> String {
        if value < 10 {
            let tenths = Int((value * 10).rounded())
            if tenths >= 100 { return "10" }
            return "\(tenths / 10),\(tenths % 10)"
        }
        return String(Int(value.rounded()))
    }
}

/// Russian plural forms: 1 сервер, 2 сервера, 5 серверов.
public enum RussianPlural {
    public static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count) % 100
        if (11...14).contains(n) { return many }
        switch n % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }

    /// `"3 сервера"`.
    public static func phrase(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) \(form(count, one: one, few: few, many: many))"
    }
}
