import ConfigurationEngine
import DomainModels
import Foundation

/// How often a subscription is refreshed without the user asking. The app refreshes when it starts and the
/// last update is older than the interval, and (iOS) asks the system for a background refresh at that time;
/// there is no polling loop.
public enum SubscriptionInterval: Int, CaseIterable, Codable, Hashable, Sendable {
    case manual = 0
    case sixHours = 21_600
    case twelveHours = 43_200
    case day = 86_400

    public var seconds: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .manual: return "Только вручную"
        case .sixHours: return "Каждые 6 часов"
        case .twelveHours: return "Каждые 12 часов"
        case .day: return "Раз в сутки"
        }
    }
}

/// What changed in a profile after a refresh. Counts and server names only; never addresses or secrets.
public struct SubscriptionDiff: Hashable, Sendable, Codable {
    public var added: [String]
    public var removed: [String]
    public var changed: [String]
    public var unchanged: Int

    public init(added: [String] = [], removed: [String] = [], changed: [String] = [], unchanged: Int = 0) {
        self.added = added
        self.removed = removed
        self.changed = changed
        self.unchanged = unchanged
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    /// One Russian sentence for the subscription screen.
    public var summary: String {
        if isEmpty { return "Изменений нет: \(unchanged) \(Plural.servers(unchanged))." }
        var parts: [String] = []
        if !added.isEmpty { parts.append("добавлено \(added.count)") }
        if !removed.isEmpty { parts.append("удалено \(removed.count)") }
        if !changed.isEmpty { parts.append("изменено \(changed.count)") }
        return parts.joined(separator: ", ").capitalizedFirst + "."
    }
}

/// The outcome of the last refresh attempt, shown on the subscription screen.
public enum SubscriptionOutcome: Hashable, Sendable, Codable {
    /// The server answered with a new body; `diff` says what changed.
    case updated(SubscriptionDiff)
    /// The server answered 304 Not Modified.
    case notModified
    /// The attempt failed; the message says what happened and is safe to show (no address, no token).
    case failed(String)
}

/// The edits the user made to servers of a subscription profile, kept across refreshes. Keyed by
/// `ServerIdentity`, so an edit follows its server when the provider reorders or renames the list.
public struct SubscriptionEdits: Hashable, Sendable, Codable {
    /// Display names the user gave.
    public var names: [String: String]
    /// Servers the user hid; they are left out of the profile on every refresh.
    public var hidden: Set<String>

    public init(names: [String: String] = [:], hidden: Set<String> = []) {
        self.names = names
        self.hidden = hidden
    }

    public var isEmpty: Bool { names.isEmpty && hidden.isEmpty }
}

/// Everything known about one subscription profile besides the profile itself. The address lives in the
/// profile's source; it is never copied here or into messages.
public struct SubscriptionRecord: Hashable, Sendable, Codable {
    public var profileID: UUID
    public var interval: SubscriptionInterval
    /// Validators of the last successful answer, sent back as If-None-Match / If-Modified-Since.
    public var entityTag: String?
    public var lastModified: String?
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastOutcome: SubscriptionOutcome?
    public var edits: SubscriptionEdits

    public init(profileID: UUID, interval: SubscriptionInterval = .day) {
        self.profileID = profileID
        self.interval = interval
        self.edits = SubscriptionEdits()
    }

    /// The subscription should be refreshed at `now`: automatic refresh is on and the last success is older
    /// than the interval (or there never was one). A failed attempt is retried at the next launch or
    /// background window, not in a loop.
    public func isStale(at now: Date) -> Bool {
        guard let seconds = interval.seconds else { return false }
        guard let success = lastSuccess else { return true }
        return now.timeIntervalSince(success) >= seconds
    }

    /// When the next automatic refresh is due, `nil` when refresh is manual.
    public func nextRefresh(after now: Date) -> Date? {
        guard let seconds = interval.seconds else { return nil }
        guard let success = lastSuccess else { return now }
        return max(now, success.addingTimeInterval(seconds))
    }
}

/// The HTTP rules of a subscription download, independent of `URLSession` so they can be tested on Linux.
public enum SubscriptionHTTP {
    /// Limits of this project.
    public static let timeoutSeconds: TimeInterval = 30
    public static var maximumBodyBytes: Int { ImportLimits.standard.maximumSubscriptionBytes }

    /// Conditional request headers from the last success. Only the validators; no identifying headers.
    public static func requestHeaders(for record: SubscriptionRecord?) -> [String: String] {
        var headers: [String: String] = [:]
        if let tag = record?.entityTag, !tag.isEmpty { headers["If-None-Match"] = tag }
        if let modified = record?.lastModified, !modified.isEmpty { headers["If-Modified-Since"] = modified }
        return headers
    }

    /// What a download produced.
    public enum Result: Equatable, Sendable {
        case body(String, entityTag: String?, lastModified: String?)
        case notModified
    }

    /// A download that failed, with a message safe to show.
    public struct Failure: Error, Equatable, Sendable {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    /// Interprets an answer. `headers` names are matched case-insensitively. `body` may be cut at the limit
    /// by the caller; `declaredLength` is the Content-Length when known.
    public static func interpret(status: Int, headers: [String: String], body: Data, declaredLength: Int64? = nil) throws -> Result {
        if status == 304 { return .notModified }
        guard (200..<300).contains(status) else {
            throw Failure("сервер ответил HTTP \(status)")
        }
        if let declared = declaredLength, declared > Int64(maximumBodyBytes) {
            throw Failure("ответ больше \(maximumBodyBytes / 1024) КБ")
        }
        guard body.count <= maximumBodyBytes else {
            throw Failure("ответ больше \(maximumBodyBytes / 1024) КБ")
        }
        guard !body.isEmpty else {
            throw Failure("сервер вернул пустой ответ")
        }
        guard let text = String(data: body, encoding: .utf8) else {
            throw Failure("ответ не текст UTF-8")
        }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        return .body(text, entityTag: header("ETag"), lastModified: header("Last-Modified"))
    }
}

enum Plural {
    /// «сервер», «сервера», «серверов» for a count.
    static func servers(_ count: Int) -> String {
        let tens = count % 100
        let ones = count % 10
        if (11...14).contains(tens) { return "серверов" }
        switch ones {
        case 1: return "сервер"
        case 2, 3, 4: return "сервера"
        default: return "серверов"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
