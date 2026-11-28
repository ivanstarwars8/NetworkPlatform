// Phases of one HTTPS request, computed from the timestamps the platform records (URLSessionTaskMetrics on
// Apple platforms). Only measured intervals are reported: a phase whose timestamps are missing (reused
// connection, no TLS) is `nil`, never estimated.

import Foundation

public struct HTTPTimestamps: Equatable, Sendable {
    public var fetchStart: Date?
    public var domainLookupStart: Date?
    public var domainLookupEnd: Date?
    public var connectStart: Date?
    public var secureConnectionStart: Date?
    public var secureConnectionEnd: Date?
    public var connectEnd: Date?
    public var requestStart: Date?
    public var responseStart: Date?
    public var responseEnd: Date?
    public var reusedConnection: Bool

    public init(
        fetchStart: Date? = nil, domainLookupStart: Date? = nil, domainLookupEnd: Date? = nil,
        connectStart: Date? = nil, secureConnectionStart: Date? = nil, secureConnectionEnd: Date? = nil,
        connectEnd: Date? = nil, requestStart: Date? = nil, responseStart: Date? = nil, responseEnd: Date? = nil,
        reusedConnection: Bool = false
    ) {
        self.fetchStart = fetchStart
        self.domainLookupStart = domainLookupStart
        self.domainLookupEnd = domainLookupEnd
        self.connectStart = connectStart
        self.secureConnectionStart = secureConnectionStart
        self.secureConnectionEnd = secureConnectionEnd
        self.connectEnd = connectEnd
        self.requestStart = requestStart
        self.responseStart = responseStart
        self.responseEnd = responseEnd
        self.reusedConnection = reusedConnection
    }
}

public struct HTTPPhases: Equatable, Sendable {
    /// Name resolution.
    public var dns: Double?
    /// TCP handshake (connect start to TLS start; connect end when there is no TLS).
    public var connect: Double?
    /// TLS handshake.
    public var tls: Double?
    /// Request sent to first response byte.
    public var firstByte: Double?
    /// Fetch start to the last byte read.
    public var total: Double?

    public init(_ t: HTTPTimestamps) {
        dns = HTTPPhases.interval(t.domainLookupStart, t.domainLookupEnd)
        if t.secureConnectionStart != nil {
            connect = HTTPPhases.interval(t.connectStart, t.secureConnectionStart)
            tls = HTTPPhases.interval(t.secureConnectionStart, t.secureConnectionEnd ?? t.connectEnd)
        } else {
            connect = HTTPPhases.interval(t.connectStart, t.connectEnd)
            tls = nil
        }
        firstByte = HTTPPhases.interval(t.requestStart, t.responseStart)
        total = HTTPPhases.interval(t.fetchStart ?? t.domainLookupStart ?? t.connectStart, t.responseEnd ?? t.responseStart)
    }

    /// `end - start` when both exist and are in order.
    static func interval(_ start: Date?, _ end: Date?) -> Double? {
        guard let start = start, let end = end else { return nil }
        let value = end.timeIntervalSince(start)
        return value >= 0 ? value : nil
    }
}

/// Bounds of the HTTP timing tool (limits of this project).
public enum HTTPProbeLimits {
    /// The body is read up to this many bytes and the request is then cancelled.
    public static let maximumBodyBytes = 64 * 1024
    public static let timeout: Double = 15
}

public enum URLInput {
    /// Normalises user input to an https URL: adds the scheme when missing, refuses other schemes and
    /// credentials in the URL. Plain http is not offered (the app's transport security would refuse it).
    public static func httpsURL(_ text: String) -> Result<URL, URLInputError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= 2048 else { return .failure(.tooLong) }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard components.user == nil, components.password == nil else { return .failure(.credentials) }
        guard let host = components.host, !host.isEmpty, let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }
}

public enum URLInputError: Error, Equatable, Sendable {
    case empty, tooLong, malformed, notHTTPS, credentials

    public var message: String {
        switch self {
        case .empty: return "Введите адрес, например example.com."
        case .tooLong: return "Адрес слишком длинный."
        case .malformed: return "Адрес не разобран. Проверьте написание."
        case .notHTTPS: return "Проверяются только адреса https://."
        case .credentials: return "Уберите логин и пароль из адреса: они не нужны для проверки."
        }
    }
}

public enum HostInput {
    /// Trims the input and checks it is a plausible host name or IP literal. Returns the cleaned host.
    public static func host(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { trimmed = String(trimmed.dropFirst().dropLast()) }
        guard !trimmed.isEmpty, trimmed.count <= ProbeLimits.maximumHostLength else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || "/?#@".unicodeScalars.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    public static func port(_ text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }
}
