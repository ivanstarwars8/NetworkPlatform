// Identifier and time types used by the decision layer.
//
// The module has no dependencies on the rest of the package on purpose: the
// decision layer must be testable in isolation and must not learn engine
// types (ADR-0001 §5). Callers map their own model onto these small inputs.
//
// PRIVACY: identifiers appear verbatim in `Explanation` values, which are meant
// to be logged. They must be opaque tokens (a UUID, an index), never a server
// address, a host name or a credential.

/// Opaque identifier of an engine (for example the Xray-based or the
/// sing-box-based one). The decision layer does not interpret the value.
public struct EngineID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: EngineID, rhs: EngineID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Opaque identifier of a server (an exit node), independent of how it is reached.
public struct ServerID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: ServerID, rhs: ServerID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// Opaque identifier of a protocol/transport combination inside one engine
/// (for example "vless+reality+tcp" or "hysteria2"). Two candidates that
/// differ only in `ServerID` are reached the same way.
public struct TransportID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public static func < (lhs: TransportID, rhs: TransportID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// One selectable configuration: an engine, a transport inside it, and a server.
///
/// The three coordinates correspond to the three decision levels, which are
/// kept strictly separate (see `SwitchLevel`).
public struct Candidate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let engine: EngineID
    public let transport: TransportID
    public let server: ServerID

    public init(engine: EngineID, transport: TransportID, server: ServerID) {
        self.engine = engine
        self.transport = transport
        self.server = server
    }

    /// Total order used only for deterministic tie-breaking.
    public static func < (lhs: Candidate, rhs: Candidate) -> Bool {
        if lhs.engine != rhs.engine { return lhs.engine < rhs.engine }
        if lhs.transport != rhs.transport { return lhs.transport < rhs.transport }
        return lhs.server < rhs.server
    }

    public var description: String { "\(engine)/\(transport)/\(server)" }
}

/// A candidate together with the static preferences the profile attaches to it.
///
/// The caller passes only candidates that satisfy the active profile (protocol
/// supported by that engine, allowed by the user, and so on). The decision
/// layer never invents candidates.
public struct CandidateDescriptor: Hashable, Sendable, Codable {
    public let candidate: Candidate
    /// Relative weight for `SelectionStrategy.weighted`. Values `<= 0` or
    /// non-finite are treated as `0` (the candidate is then chosen only when
    /// nothing else is available).
    public let weight: Double
    /// Rank for `SelectionStrategy.failover` and `.manualPriority`.
    /// Lower is preferred.
    public let priority: Int

    public init(_ candidate: Candidate, weight: Double = 1, priority: Int = 0) {
        self.candidate = candidate
        self.weight = (weight.isFinite && weight > 0) ? weight : 0
        self.priority = priority
    }
}

/// A point on a monotonic time line, in seconds.
///
/// This is the injected clock: the decision layer never reads the system time
/// and owns no timers. Every operation that depends on time takes an `Instant`
/// from the caller, and the caller is expected to pass non-decreasing values.
public struct Instant: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let seconds: Double

    public init(seconds: Double) { self.seconds = seconds }

    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.seconds < rhs.seconds }
    public static func + (lhs: Instant, rhs: Double) -> Instant { Instant(seconds: lhs.seconds + rhs) }

    /// Elapsed seconds since `earlier`, never negative.
    public func duration(since earlier: Instant) -> Double { max(0, seconds - earlier.seconds) }

    public var description: String { "t=\(seconds)s" }
}

/// The kind of network path the device currently uses.
///
/// Measurements, circuit breakers and the last-known-good configuration are
/// tracked per class: what was learned on Wi-Fi says little about cellular.
public enum NetworkClass: String, Hashable, Sendable, Codable, CaseIterable {
    case wifi
    case cellular
    /// Wired Ethernet. Uses the Wi-Fi policy.
    case wired
    /// Unknown path. Uses the (more conservative) cellular policy.
    case unknown
}

/// The three decision levels. They are evaluated in this order and never mixed.
public enum SwitchLevel: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// (a) Another server, same engine, same transport.
    case server
    /// (b) Another protocol/transport, same engine (the server may change too).
    case transport
    /// (c) Another engine. Restarts the tunnel extension: **every connection
    /// that goes through the tunnel is terminated**. No TCP session, QUIC
    /// connection or in-flight request survives an engine switch, and nothing
    /// in this module promises otherwise.
    case engine

    private var rank: Int {
        switch self {
        case .server: return 0
        case .transport: return 1
        case .engine: return 2
        }
    }

    public static func < (lhs: SwitchLevel, rhs: SwitchLevel) -> Bool { lhs.rank < rhs.rank }

    /// The level of a change between two candidates, `nil` if they are equal.
    public static func between(_ old: Candidate, _ new: Candidate) -> SwitchLevel? {
        if old.engine != new.engine { return .engine }
        if old.transport != new.transport { return .transport }
        if old.server != new.server { return .server }
        return nil
    }
}
