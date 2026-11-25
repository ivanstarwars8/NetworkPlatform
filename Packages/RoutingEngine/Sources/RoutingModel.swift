// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

// MARK: - Request

/// Transport-layer network of a connection.
public enum NetworkKind: String, Hashable, Sendable, Codable, CaseIterable {
    case tcp
    case udp
}

/// An inclusive destination port range. A single port is a range of one.
public struct PortRange: Hashable, Sendable {
    public let lower: UInt16
    public let upper: UInt16

    public init(_ port: UInt16) {
        self.lower = port
        self.upper = port
    }

    /// Returns `nil` when `lower > upper`.
    public init?(lower: UInt16, upper: UInt16) {
        guard lower <= upper else { return nil }
        self.lower = lower
        self.upper = upper
    }

    /// Parses `"443"`, `"1000-2000"` or `"1000:2000"`.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 11 else { return nil }
        var parts: [[UInt8]] = [[]]
        for byte in bytes {
            if byte == 0x2D || byte == 0x3A {
                guard parts.count == 1 else { return nil }
                parts.append([])
            } else {
                parts[parts.count - 1].append(byte)
            }
        }
        guard let first = PortRange.parsePort(parts[0]) else { return nil }
        if parts.count == 1 {
            self.init(first)
            return
        }
        guard let second = PortRange.parsePort(parts[1]) else { return nil }
        self.init(lower: first, upper: second)
    }

    public func contains(_ port: UInt16) -> Bool {
        port >= lower && port <= upper
    }

    private static func parsePort(_ bytes: [UInt8]) -> UInt16? {
        guard !bytes.isEmpty, bytes.count <= 5 else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        guard value <= 65535 else { return nil }
        return UInt16(value)
    }
}

extension PortRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case lower
        case upper
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lower = try container.decode(UInt16.self, forKey: .lower)
        let upper = try container.decode(UInt16.self, forKey: .upper)
        guard lower <= upper else {
            throw DecodingError.dataCorruptedError(
                forKey: .upper,
                in: container,
                debugDescription: "Port range bounds are reversed"
            )
        }
        self.lower = lower
        self.upper = upper
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lower, forKey: .lower)
        try container.encode(upper, forKey: .upper)
    }
}

extension PortRange: CustomStringConvertible {
    public var description: String {
        lower == upper ? "\(lower)" : "\(lower)-\(upper)"
    }
}

/// What the router knows about one connection.
///
/// The fields mirror what the engine's router sees. A condition on a missing
/// text or address field does not match. A missing port is port 0, exactly
/// as in the engine (a rule for the range `0-1023` matches it).
public struct RouteRequest: Hashable, Sendable {
    /// Host names longer than this (in UTF-8 bytes, after normalisation) are
    /// dropped: they cannot be valid DNS names.
    public static let maximumDomainLength = 253
    /// At most this many resolved addresses are kept.
    public static let maximumResolvedIPs = 64

    /// Lower-cased host name, or `nil`. A trailing dot is kept: the engine
    /// compares the name as it arrived, so `example.com.` is not under the
    /// suffix `example.com`.
    public let domain: String?
    /// Destination address; IPv4-mapped IPv6 is stored as IPv4.
    public let ip: IPAddress?
    /// What DNS returns for `domain`. Only consulted when the table's
    /// `domainStrategy` asks for resolution; empty means "resolution failed
    /// or was not simulated".
    public let resolvedIPs: [IPAddress]
    public let port: UInt16?
    public let network: NetworkKind?
    /// Source address of the connection as the inbound saw it.
    public let sourceIP: IPAddress?
    public let sourcePort: UInt16?
    /// Tag of the inbound that accepted the connection.
    public let inboundTag: String?
    /// Authenticated user (e-mail / name) of the inbound, if any.
    public let user: String?
    /// Protocol the engine sniffed from the first bytes (`http`, `tls`,
    /// `quic`, `bittorrent`, ...), if any.
    public let sniffedProtocol: String?

    public init(
        domain: String? = nil,
        ip: IPAddress? = nil,
        port: UInt16? = nil,
        network: NetworkKind? = nil,
        resolvedIPs: [IPAddress] = [],
        sourceIP: IPAddress? = nil,
        sourcePort: UInt16? = nil,
        inboundTag: String? = nil,
        user: String? = nil,
        sniffedProtocol: String? = nil
    ) {
        if let raw = domain, let normalised = DomainName.normaliseRequest(raw) {
            self.domain = normalised
        } else {
            self.domain = nil
        }
        self.ip = ip?.unmapped
        self.resolvedIPs = resolvedIPs.prefix(RouteRequest.maximumResolvedIPs).map { $0.unmapped }
        self.port = port
        self.network = network
        self.sourceIP = sourceIP?.unmapped
        self.sourcePort = sourcePort
        self.inboundTag = (inboundTag?.isEmpty ?? true) ? nil : inboundTag
        self.user = (user?.isEmpty ?? true) ? nil : user
        self.sniffedProtocol = (sniffedProtocol?.isEmpty ?? true) ? nil : sniffedProtocol
    }
}

extension RouteRequest: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if let domain = domain { parts.append("domain=\(domain)") }
        if let ip = ip { parts.append("ip=\(ip)") }
        if let port = port { parts.append("port=\(port)") }
        if let network = network { parts.append("network=\(network.rawValue)") }
        if !resolvedIPs.isEmpty {
            parts.append("resolved=" + resolvedIPs.map { "\($0)" }.joined(separator: ","))
        }
        if let sourceIP = sourceIP { parts.append("source=\(sourceIP)") }
        if let sourcePort = sourcePort { parts.append("sourcePort=\(sourcePort)") }
        if let inboundTag = inboundTag { parts.append("inbound=\(inboundTag)") }
        if let user = user { parts.append("user=\(user)") }
        if let sniffedProtocol = sniffedProtocol { parts.append("protocol=\(sniffedProtocol)") }
        return parts.isEmpty ? "(empty request)" : parts.joined(separator: " ")
    }
}

/// Host-name normalisation for rules and requests.
enum DomainName {
    /// Request side: lower-cases (the engine lower-cases the name before
    /// matching) and nothing else. Empty names, names longer than
    /// `RouteRequest.maximumDomainLength` and names with whitespace or
    /// control characters yield `nil`.
    static func normaliseRequest(_ raw: String) -> String? {
        let count = raw.utf8.count
        guard count > 0, count <= RouteRequest.maximumDomainLength else { return nil }
        let text = raw.lowercased()
        if text.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) {
            return nil
        }
        if text == "." { return nil }
        return text
    }

    /// Rule side: lower-cases, strips one trailing dot, rejects empty names,
    /// names longer than `RouteRequest.maximumDomainLength` and names with
    /// whitespace or control characters.
    static func normalise(_ raw: String) -> String? {
        guard raw.utf8.count <= RouteRequest.maximumDomainLength + 1 else { return nil }
        var text = raw.lowercased()
        if text.hasSuffix(".") {
            text.removeLast()
        }
        let count = text.utf8.count
        guard count > 0, count <= RouteRequest.maximumDomainLength else { return nil }
        if text.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) {
            return nil
        }
        return text
    }
}

// MARK: - Rules

/// A condition tree. Leaves test one property of the request; `and`, `or`
/// and `not` combine them.
///
/// Semantics of the leaves:
/// - `domain`: the whole host name equals the value (case-insensitive).
/// - `domainSuffix("example.com")`: matches `example.com` and every
///   subdomain, on a label boundary (`badexample.com` does not match).
///   `domainSuffix(".example.com")` matches subdomains only.
/// - `domainKeyword`: the host name contains the value.
/// - `domainRegex`: `LinearRegex` unanchored match on the host name.
/// - `ipCIDR`: some target address is inside the prefix. Target addresses
///   are the destination address, or the resolved addresses of the domain
///   when the table's `domainStrategy` asks for them.
/// - `ipNotIn`: there is a target address outside every listed prefix. This
///   is the engine's negated address match, with its two quirks kept: it is
///   false when the request has no target address at all, and an address is
///   only considered when the list has at least one prefix of its family
///   (`ipNotIn([fc00::/7])` never matches an IPv4 address). It is not
///   `not(ipCIDR)`.
/// - `port`: destination port is inside the range (a missing port is 0).
/// - `network`: transport network equals the value.
/// - `sourceCIDR`, `sourcePort`: the same for the connection's source.
/// - `inboundTag`, `user`: exact, case-sensitive comparison.
/// - `sniffedProtocol`: the sniffed protocol starts with the value
///   (`http` matches `http1` and `http2`).
/// - `ruleSet`: any condition of the referenced inline rule set matches.
/// - `and([])` is true, `or([])` is false.
/// - `not` is plain boolean negation. The engines have no general negation,
///   so a table that uses it cannot be lowered (see `RuleLowering`).
public indirect enum RuleCondition: Hashable, Sendable, Codable {
    case domain(String)
    case domainSuffix(String)
    case domainKeyword(String)
    case domainRegex(String)
    case ipCIDR(IPCIDR)
    case ipNotIn([IPCIDR])
    case port(PortRange)
    case network(NetworkKind)
    case sourceCIDR(IPCIDR)
    case sourcePort(PortRange)
    case inboundTag(String)
    case user(String)
    case sniffedProtocol(String)
    case ruleSet(String)
    case and([RuleCondition])
    case or([RuleCondition])
    case not(RuleCondition)
}

/// What to do with a matched connection.
public enum RouteAction: Hashable, Sendable, Codable {
    /// Connect without a proxy.
    case direct
    /// Refuse the connection.
    case reject
    /// Send through the outbound with this tag.
    case proxy(String)
    /// Send through the outbound group (selector / balancer) with this tag.
    case group(String)
    /// Send through a chain of outbounds, first hop first.
    case chain([String])

    /// Longest accepted chain.
    public static let maximumChainLength = 8
    /// Longest accepted tag, in UTF-8 bytes.
    public static let maximumTagLength = 128

    /// Outbound and group tags this action refers to.
    public var referencedTags: [String] {
        switch self {
        case .direct, .reject: return []
        case let .proxy(tag): return [tag]
        case let .group(tag): return [tag]
        case let .chain(tags): return tags
        }
    }

    /// Returns a description of the problem, or `nil` when the action is
    /// well-formed.
    public var validationProblem: String? {
        switch self {
        case .direct, .reject:
            return nil
        case let .proxy(tag), let .group(tag):
            return RouteAction.tagProblem(tag)
        case let .chain(tags):
            if tags.isEmpty { return "chain has no hops" }
            if tags.count > RouteAction.maximumChainLength {
                return "chain has more than \(RouteAction.maximumChainLength) hops"
            }
            for tag in tags {
                if let problem = RouteAction.tagProblem(tag) { return problem }
            }
            return nil
        }
    }

    private static func tagProblem(_ tag: String) -> String? {
        if tag.isEmpty { return "tag is empty" }
        if tag.utf8.count > maximumTagLength { return "tag is longer than \(maximumTagLength) bytes" }
        return nil
    }
}

extension RouteAction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .direct: return "direct"
        case .reject: return "reject"
        case let .proxy(tag): return "proxy(\(tag))"
        case let .group(tag): return "group(\(tag))"
        case let .chain(tags): return "chain(\(tags.joined(separator: " -> ")))"
        }
    }
}

/// One routing rule. Its priority is its position in `RoutingTable.rules`.
public struct RoutingRule: Hashable, Sendable, Codable {
    /// Optional stable identifier for UI and diagnostics.
    public var id: String?
    public var condition: RuleCondition
    public var action: RouteAction
    /// Disabled rules keep their index but never match.
    public var isEnabled: Bool

    public init(id: String? = nil, condition: RuleCondition, action: RouteAction, isEnabled: Bool = true) {
        self.id = id
        self.condition = condition
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// A named list of conditions that rules can reference with
/// `RuleCondition.ruleSet`. The set matches when any condition matches.
/// Only inline sets exist here: downloading and decoding remote or binary
/// rule sets is not this module's job.
public struct RuleSet: Hashable, Sendable, Codable {
    public var tag: String
    public var conditions: [RuleCondition]

    public init(tag: String, conditions: [RuleCondition]) {
        self.tag = tag
        self.conditions = conditions
    }
}

/// When the router may replace a domain by its resolved addresses for
/// address rules. Semantics follow the engine's router.
public enum DomainStrategy: String, Hashable, Sendable, Codable, CaseIterable {
    /// Never resolve: a connection to a domain has no target address, so
    /// address rules do not match it.
    case asIs
    /// Evaluate all rules without resolving; only if nothing matched and the
    /// request has a domain, resolve it and evaluate all rules again.
    case ipIfNonMatch
    /// Address rules see the resolved addresses of the domain from the
    /// first rule on.
    case ipOnDemand
}

/// An ordered rule list with a default action. First match wins.
public struct RoutingTable: Hashable, Sendable, Codable {
    public var rules: [RoutingRule]
    public var ruleSets: [RuleSet]
    /// Action for connections no rule matched.
    public var finalAction: RouteAction
    public var domainStrategy: DomainStrategy

    public init(
        rules: [RoutingRule] = [],
        ruleSets: [RuleSet] = [],
        finalAction: RouteAction = .direct,
        domainStrategy: DomainStrategy = .asIs
    ) {
        self.rules = rules
        self.ruleSets = ruleSets
        self.finalAction = finalAction
        self.domainStrategy = domainStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case rules, ruleSets, finalAction, domainStrategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode([RoutingRule].self, forKey: .rules)
        ruleSets = try container.decode([RuleSet].self, forKey: .ruleSets)
        finalAction = try container.decode(RouteAction.self, forKey: .finalAction)
        // Tables stored before the field existed never resolved.
        domainStrategy = try container.decodeIfPresent(DomainStrategy.self, forKey: .domainStrategy) ?? .asIs
    }
}

// MARK: - Decision

/// Result of routing one request.
public struct RouteDecision: Hashable, Sendable {
    public let action: RouteAction
    /// Index of the winning rule in `RoutingTable.rules`, or `nil` when the
    /// final action was used.
    public let ruleIndex: Int?

    /// `true` when the decision was made on the second pass of
    /// `DomainStrategy.ipIfNonMatch`, that is with resolved addresses.
    public let usedSecondPass: Bool

    public var isFinal: Bool { ruleIndex == nil }

    public init(action: RouteAction, ruleIndex: Int?, usedSecondPass: Bool = false) {
        self.action = action
        self.ruleIndex = ruleIndex
        self.usedSecondPass = usedSecondPass
    }
}

// MARK: - Limits and errors

/// Upper bounds applied while compiling a table. A table may come from an
/// imported profile, so every dimension is bounded.
public struct RoutingLimits: Hashable, Sendable {
    public var maximumRules: Int
    /// Maximum nesting of `and` / `or` / `not` / rule-set references.
    public var maximumConditionDepth: Int
    /// Maximum number of condition nodes in the whole table after rule sets
    /// are expanded.
    public var maximumConditionNodes: Int
    public var maximumRuleSets: Int

    public init(
        maximumRules: Int = 500_000,
        maximumConditionDepth: Int = 16,
        maximumConditionNodes: Int = 2_000_000,
        maximumRuleSets: Int = 10_000
    ) {
        self.maximumRules = maximumRules
        self.maximumConditionDepth = maximumConditionDepth
        self.maximumConditionNodes = maximumConditionNodes
        self.maximumRuleSets = maximumRuleSets
    }

    public static let standard = RoutingLimits()
}

public enum RoutingCompileError: Error, Equatable, Sendable {
    case tooManyRules(count: Int, limit: Int)
    case tooManyRuleSets(count: Int, limit: Int)
    case duplicateRuleSet(tag: String)
    case tableTooLarge(limit: Int)
    case conditionTooDeep(ruleIndex: Int, limit: Int)
    case invalidDomain(ruleIndex: Int, value: String)
    case invalidKeyword(ruleIndex: Int, value: String)
    /// An empty or overlong inbound tag, user or protocol value, or an
    /// empty `ipNotIn` list.
    case invalidValue(ruleIndex: Int, reason: String)
    case invalidRegex(ruleIndex: Int, pattern: String, reason: String)
    case unknownRuleSet(ruleIndex: Int, tag: String)
    case ruleSetCycle(ruleIndex: Int, tag: String)
    /// `ruleIndex` is `nil` for the final action.
    case invalidAction(ruleIndex: Int?, reason: String)
}

extension RoutingCompileError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .tooManyRules(count, limit):
            return "table has \(count) rules, the limit is \(limit)"
        case let .tooManyRuleSets(count, limit):
            return "table has \(count) rule sets, the limit is \(limit)"
        case let .duplicateRuleSet(tag):
            return "rule set '\(tag)' is defined more than once"
        case let .tableTooLarge(limit):
            return "table expands to more than \(limit) condition nodes"
        case let .conditionTooDeep(ruleIndex, limit):
            return "rule #\(ruleIndex): condition is nested deeper than \(limit)"
        case let .invalidDomain(ruleIndex, value):
            return "rule #\(ruleIndex): invalid domain '\(value.prefix(64))'"
        case let .invalidKeyword(ruleIndex, value):
            return "rule #\(ruleIndex): invalid keyword '\(value.prefix(64))'"
        case let .invalidValue(ruleIndex, reason):
            return "rule #\(ruleIndex): \(reason)"
        case let .invalidRegex(ruleIndex, pattern, reason):
            return "rule #\(ruleIndex): invalid regex '\(pattern.prefix(64))': \(reason)"
        case let .unknownRuleSet(ruleIndex, tag):
            return "rule #\(ruleIndex): unknown rule set '\(tag.prefix(64))'"
        case let .ruleSetCycle(ruleIndex, tag):
            return "rule #\(ruleIndex): rule set '\(tag.prefix(64))' refers to itself"
        case let .invalidAction(ruleIndex, reason):
            if let ruleIndex = ruleIndex {
                return "rule #\(ruleIndex): invalid action: \(reason)"
            }
            return "final action is invalid: \(reason)"
        }
    }
}
