import Foundation

/// A group that chooses among outbounds and other groups.
/// Nesting is expressed by membership: a member may be another group (by tag).
/// `Profile.validate()` rejects dangling members and cycles.
public struct OutboundGroup: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Manual choice.
        case selector
        /// Lowest measured latency.
        case urlTest
        /// First member that passes the health check, in order.
        case fallback
        /// Traffic is distributed among members.
        case loadBalance
    }

    public enum Member: Codable, Hashable, Sendable {
        case outbound(tag: String)
        case group(tag: String)

        public var tag: String {
            switch self {
            case .outbound(let tag): return tag
            case .group(let tag): return tag
            }
        }
    }

    public enum LoadBalanceStrategy: String, Codable, Hashable, Sendable, CaseIterable {
        case roundRobin
        case random
        case leastPing
        case leastLoad
        case consistentHashing
    }

    public struct HealthCheck: Codable, Hashable, Sendable {
        public var url: String
        public var intervalSeconds: Int
        public var timeoutMilliseconds: Int?
        public var toleranceMilliseconds: Int?

        public init(
            url: String,
            intervalSeconds: Int,
            timeoutMilliseconds: Int? = nil,
            toleranceMilliseconds: Int? = nil
        ) {
            self.url = url
            self.intervalSeconds = intervalSeconds
            self.timeoutMilliseconds = timeoutMilliseconds
            self.toleranceMilliseconds = toleranceMilliseconds
        }
    }

    public var tag: String
    public var name: String
    public var kind: Kind
    public var members: [Member]
    /// Initially selected member of a `selector` group.
    public var defaultMemberTag: String?
    public var healthCheck: HealthCheck?
    public var strategy: LoadBalanceStrategy?

    public init(
        tag: String,
        name: String,
        kind: Kind,
        members: [Member],
        defaultMemberTag: String? = nil,
        healthCheck: HealthCheck? = nil,
        strategy: LoadBalanceStrategy? = nil
    ) {
        self.tag = tag
        self.name = name
        self.kind = kind
        self.members = members
        self.defaultMemberTag = defaultMemberTag
        self.healthCheck = healthCheck
        self.strategy = strategy
    }
}
