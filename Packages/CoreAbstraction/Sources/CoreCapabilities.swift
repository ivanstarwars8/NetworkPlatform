// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

/// Stable identifier of a network core (engine), e.g. `"xray"`.
///
/// The set of cores is a build dimension, not a constant of the architecture
/// (ADR-0001 §3), so this is an open string-backed type rather than an enum.
public struct CoreIdentifier: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: CoreIdentifier, rhs: CoreIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A proxy protocol a core can speak. Open set: names are data taken from the
/// capability table of a concrete core build, not hard-coded knowledge.
public struct CoreProtocol: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: CoreProtocol, rhs: CoreProtocol) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // Names from the model sketch in ADR-0002 §3.
    public static let vless: CoreProtocol = "vless"
    public static let vmess: CoreProtocol = "vmess"
    public static let trojan: CoreProtocol = "trojan"
    public static let shadowsocks: CoreProtocol = "shadowsocks"
    public static let hysteria2: CoreProtocol = "hysteria2"
    public static let wireguard: CoreProtocol = "wireguard"
}

/// A transport a core can carry a proxy protocol over. Open set.
public struct CoreTransport: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: CoreTransport, rhs: CoreTransport) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // Names from the model sketch in ADR-0002 §3.
    public static let tcp: CoreTransport = "tcp"
    public static let websocket: CoreTransport = "websocket"
    public static let httpUpgrade: CoreTransport = "httpUpgrade"
    public static let grpc: CoreTransport = "grpc"
    public static let xhttp: CoreTransport = "xhttp"
    public static let mkcp: CoreTransport = "mkcp"
}

/// An optional ability of a core or of its adapter. Open set.
public struct CoreFeature: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public static func < (lhs: CoreFeature, rhs: CoreFeature) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// `NetworkCore.reload` replaces the configuration without a restart.
    /// A core without it must be stopped and started again.
    public static let hotReload: CoreFeature = "hot-reload"
    /// `NetworkCore.validate` checks more than structure (the core itself
    /// looks at the configuration).
    public static let configurationValidation: CoreFeature = "configuration-validation"
    /// `CoreStatistics` carries total traffic counters.
    public static let trafficStatistics: CoreFeature = "traffic-statistics"
    /// `CoreStatistics.outbounds` is filled.
    public static let perOutboundStatistics: CoreFeature = "per-outbound-statistics"
    /// `CoreStatistics.memoryFootprintBytes` is filled.
    public static let memoryReporting: CoreFeature = "memory-reporting"
    /// The core has outbound groups the user can switch at run time
    /// (ADR-0001 §5: sing-box selector groups stay behind a capability).
    public static let selectorGroups: CoreFeature = "selector-groups"
}

/// What a core can do: three independent sets.
public struct CoreCapabilities: Hashable, Sendable, Codable {
    public var protocols: Set<CoreProtocol>
    public var transports: Set<CoreTransport>
    public var features: Set<CoreFeature>

    public init(
        protocols: Set<CoreProtocol> = [],
        transports: Set<CoreTransport> = [],
        features: Set<CoreFeature> = []
    ) {
        self.protocols = protocols
        self.transports = transports
        self.features = features
    }

    public static let none = CoreCapabilities()

    public var isEmpty: Bool {
        protocols.isEmpty && transports.isEmpty && features.isEmpty
    }

    /// Total number of items in the three sets.
    public var count: Int {
        protocols.count + transports.count + features.count
    }

    /// `true` when every required item is present.
    public func satisfies(_ required: CoreCapabilities) -> Bool {
        required.protocols.isSubset(of: protocols)
            && required.transports.isSubset(of: transports)
            && required.features.isSubset(of: features)
    }

    /// The part of `required` that is absent here.
    public func missing(from required: CoreCapabilities) -> CoreCapabilities {
        CoreCapabilities(
            protocols: required.protocols.subtracting(protocols),
            transports: required.transports.subtracting(transports),
            features: required.features.subtracting(features)
        )
    }

    public func union(_ other: CoreCapabilities) -> CoreCapabilities {
        CoreCapabilities(
            protocols: protocols.union(other.protocols),
            transports: transports.union(other.transports),
            features: features.union(other.features)
        )
    }

    public func intersection(_ other: CoreCapabilities) -> CoreCapabilities {
        CoreCapabilities(
            protocols: protocols.intersection(other.protocols),
            transports: transports.intersection(other.transports),
            features: features.intersection(other.features)
        )
    }
}

extension CoreCapabilities: CustomStringConvertible {
    /// Deterministic text (sorted), e.g.
    /// `protocols [trojan, vless]; transports [tcp]`. Empty sets are left out.
    public var description: String {
        var parts: [String] = []
        if !protocols.isEmpty {
            parts.append("protocols [" + protocols.sorted().map { $0.rawValue }.joined(separator: ", ") + "]")
        }
        if !transports.isEmpty {
            parts.append("transports [" + transports.sorted().map { $0.rawValue }.joined(separator: ", ") + "]")
        }
        if !features.isEmpty {
            parts.append("features [" + features.sorted().map { $0.rawValue }.joined(separator: ", ") + "]")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: "; ")
    }
}

/// Static facts about one core build.
public struct CoreDescriptor: Hashable, Sendable, Codable {
    public let id: CoreIdentifier
    public let displayName: String
    /// Version string exactly as the core reports it. Not parsed here.
    public let version: String
    public let capabilities: CoreCapabilities

    public init(id: CoreIdentifier, displayName: String, version: String, capabilities: CoreCapabilities) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.capabilities = capabilities
    }
}
