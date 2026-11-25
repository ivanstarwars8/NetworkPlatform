// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation

// Lowering turns the condition trees of a `RoutingTable` into flat rules: the
// shape every supported engine routes with. A flat rule is a conjunction of
// fields, and each field is a disjunction of values. The engine-specific
// compiler only has to spell flat rules in its own configuration syntax; it
// never needs to understand condition trees, and the engine never needs a
// Swift component to help it route.

/// How a domain value of a flat rule is compared.
public enum FlatDomainKind: String, Hashable, Sendable, Codable {
    /// The whole name equals the value.
    case full
    /// The name equals the value or ends with `"." + value`.
    case suffix
    /// The name contains the value.
    case keyword
    /// The value is a regular expression (RE2 syntax) searched in the
    /// lower-cased name.
    case regex
}

public struct FlatDomain: Hashable, Sendable, Codable {
    public var kind: FlatDomainKind
    /// Lower-case, without a trailing dot (except for `regex`).
    public var value: String

    public init(kind: FlatDomainKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// One engine rule: every non-empty field must match (AND); inside a field
/// any value may match (OR). The address field is `ips` and `excludedIPs`
/// together: it matches when a target address is inside one of `ips`, or
/// when `excludedIPs` is not empty and a target address is outside all of
/// them (see `RuleCondition.ipNotIn`).
public struct FlatRule: Hashable, Sendable, Codable {
    /// Index of the originating rule in `RoutingTable.rules`; `nil` for the
    /// catch-all that carries the table's final action.
    public var sourceRuleIndex: Int?
    /// A rule whose condition is a disjunction over different fields lowers
    /// to several consecutive flat rules; this is their running number.
    public var part: Int
    public var action: RouteAction

    public var domains: [FlatDomain] = []
    public var ips: [IPCIDR] = []
    public var excludedIPs: [IPCIDR] = []
    public var ports: [PortRange] = []
    public var networks: [NetworkKind] = []
    public var sourceIPs: [IPCIDR] = []
    public var sourcePorts: [PortRange] = []
    public var inboundTags: [String] = []
    public var users: [String] = []
    public var sniffedProtocols: [String] = []

    public init(sourceRuleIndex: Int?, part: Int, action: RouteAction) {
        self.sourceRuleIndex = sourceRuleIndex
        self.part = part
        self.action = action
    }

    /// A stable name for the rule: `r<index>.<part>`, or `final`.
    public var tag: String {
        guard let index = sourceRuleIndex else { return "final" }
        return "r\(index).\(part)"
    }
}

/// Why a rule could not be lowered.
public struct LoweringIssue: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// `not` has no engine equivalent (only `ipNotIn` does).
        case negation
        /// Two conditions on the same field joined by AND: an engine field
        /// is a disjunction, so the conjunction cannot be written.
        case sameFieldConjunction
        /// Expanding AND over OR produced more flat rules than the limit.
        case tooManyAlternatives
        /// With `ipIfNonMatch` the final action has to be the engine's
        /// default outbound (a catch-all rule would match on the first pass
        /// and resolution would never happen), and a group cannot be a
        /// default outbound.
        case finalGroupNeedsCatchAll
    }

    /// `nil` when the issue concerns the final action.
    public var ruleIndex: Int?
    public var kind: Kind
    public var detail: String
}

public struct LoweredTable: Hashable, Sendable, Codable {
    public var domainStrategy: DomainStrategy
    /// In priority order.
    public var rules: [FlatRule]
    /// What happens to a connection no rule matched.
    public var finalAction: RouteAction
    /// `true`: the last element of `rules` is a catch-all carrying
    /// `finalAction`. `false` (only for `ipIfNonMatch`): there is no such
    /// rule and the engine compiler must make `finalAction` the engine's
    /// default outbound. A catch-all rule would match on the first pass and
    /// the engine would never resolve the domain for the second one.
    public var finalIsCatchAllRule: Bool
    /// Rules that have no flat form. Such a rule is absent from `rules`, so
    /// a table with issues must not be handed to an engine: its routing
    /// would differ from what the simulator shows.
    public var issues: [LoweringIssue]

    public var isLossless: Bool { issues.isEmpty }
}

public enum RuleLowering {
    /// Upper bound of flat rules one table rule may expand to.
    public static let maximumPartsPerRule = 256

    /// Lowers a table. Throws only for tables that do not compile at all;
    /// rules without a flat form are reported in `LoweredTable.issues`.
    ///
    /// The result is equivalent to the table for every request that has a
    /// transport network (an always-true condition becomes "network is TCP
    /// or UDP", because an engine rule cannot be empty).
    public static func lower(_ table: RoutingTable, limits: RoutingLimits = .standard) throws -> LoweredTable {
        var resolver = try TableResolver(table: table, limits: limits)
        let resolved = try resolver.resolveAll(table.rules)
        var rules: [FlatRule] = []
        var issues: [LoweringIssue] = []

        for (ruleIndex, condition) in resolved.enumerated() {
            guard let condition = condition else { continue } // disabled
            do {
                let alternatives = try FieldSet.alternatives(of: condition)
                var part = 0
                for fields in alternatives {
                    var rule = FlatRule(sourceRuleIndex: ruleIndex, part: part, action: table.rules[ruleIndex].action)
                    fields.fill(&rule)
                    rules.append(rule)
                    part += 1
                }
            } catch let failure as LoweringFailure {
                issues.append(LoweringIssue(ruleIndex: ruleIndex, kind: failure.kind, detail: failure.detail))
            }
        }

        let finalIsRule = table.domainStrategy != .ipIfNonMatch
        if finalIsRule {
            var final = FlatRule(sourceRuleIndex: nil, part: 0, action: table.finalAction)
            final.networks = [.tcp, .udp]
            rules.append(final)
        } else if case .group = table.finalAction {
            issues.append(LoweringIssue(
                ruleIndex: nil,
                kind: .finalGroupNeedsCatchAll,
                detail: "with ipIfNonMatch the final action must be a single outbound, not a group"
            ))
        }
        return LoweredTable(
            domainStrategy: table.domainStrategy,
            rules: rules,
            finalAction: table.finalAction,
            finalIsCatchAllRule: finalIsRule,
            issues: issues
        )
    }

    /// Escapes a literal for use inside an RE2 pattern.
    static func regexEscaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$":
                result.append("\\")
                result.unicodeScalars.append(scalar)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

struct LoweringFailure: Error {
    let kind: LoweringIssue.Kind
    let detail: String
}

/// The fields of one flat rule under construction.
struct FieldSet {
    var domains: [FlatDomain] = []
    var ips: [IPCIDR] = []
    var excludedIPs: [IPCIDR] = []
    var ports: [PortRange] = []
    var networks: [NetworkKind] = []
    var sourceIPs: [IPCIDR] = []
    var sourcePorts: [PortRange] = []
    var inboundTags: [String] = []
    var users: [String] = []
    var sniffedProtocols: [String] = []

    /// Bit per engine field that has values.
    var usedFields: Int {
        var mask = 0
        if !domains.isEmpty { mask |= 1 }
        if !ips.isEmpty || !excludedIPs.isEmpty { mask |= 2 }
        if !ports.isEmpty { mask |= 4 }
        if !networks.isEmpty { mask |= 8 }
        if !sourceIPs.isEmpty { mask |= 16 }
        if !sourcePorts.isEmpty { mask |= 32 }
        if !inboundTags.isEmpty { mask |= 64 }
        if !users.isEmpty { mask |= 128 }
        if !sniffedProtocols.isEmpty { mask |= 256 }
        return mask
    }

    static let fieldNames = [
        "domain", "address", "port", "network", "source address", "source port", "inbound", "user", "protocol",
    ]

    func fill(_ rule: inout FlatRule) {
        rule.domains = domains
        rule.ips = ips
        rule.excludedIPs = excludedIPs
        rule.ports = ports
        rule.sourceIPs = sourceIPs
        rule.sourcePorts = sourcePorts
        rule.inboundTags = inboundTags
        rule.users = users
        rule.sniffedProtocols = sniffedProtocols
        // An engine rule needs at least one field: an always-true condition
        // becomes "network is TCP or UDP".
        rule.networks = usedFields == 0 ? [.tcp, .udp] : networks
    }

    /// AND of two field sets; fails when both constrain the same field.
    func joined(with other: FieldSet) throws -> FieldSet {
        let shared = usedFields & other.usedFields
        if shared != 0 {
            let position = shared.trailingZeroBitCount
            throw LoweringFailure(
                kind: .sameFieldConjunction,
                detail: "AND joins two conditions on the \(FieldSet.fieldNames[position]) field"
            )
        }
        var result = self
        result.domains += other.domains
        result.ips += other.ips
        result.excludedIPs += other.excludedIPs
        result.ports += other.ports
        result.networks += other.networks
        result.sourceIPs += other.sourceIPs
        result.sourcePorts += other.sourcePorts
        result.inboundTags += other.inboundTags
        result.users += other.users
        result.sniffedProtocols += other.sniffedProtocols
        return result
    }

    /// OR of two field sets as one flat rule, when that is exact: both must
    /// constrain the same single field. Two exclusion lists never merge - an
    /// engine exclusion list is one set, so merging would turn
    /// "outside A or outside B" into "outside A and B".
    func merged(with other: FieldSet) -> FieldSet? {
        let mask = usedFields
        guard mask != 0, mask == other.usedFields, mask & (mask - 1) == 0 else { return nil }
        if !excludedIPs.isEmpty && !other.excludedIPs.isEmpty { return nil }
        var result = self
        result.domains += other.domains
        result.ips += other.ips
        result.excludedIPs += other.excludedIPs
        result.ports += other.ports
        for network in other.networks where !result.networks.contains(network) {
            result.networks.append(network)
        }
        result.sourceIPs += other.sourceIPs
        result.sourcePorts += other.sourcePorts
        result.inboundTags += other.inboundTags
        result.users += other.users
        result.sniffedProtocols += other.sniffedProtocols
        return result
    }

    /// Disjunctive normal form of a condition: the condition holds exactly
    /// when one of the returned field sets holds. An empty result never
    /// matches; an empty field set always matches.
    static func alternatives(of condition: ResolvedCondition) throws -> [FieldSet] {
        var one = FieldSet()
        switch condition {
        case let .domainExact(name):
            one.domains = [FlatDomain(kind: .full, value: ByteText.string(name))]
        case let .domainSuffix(name, strict):
            let text = ByteText.string(name)
            if strict {
                // Subdomains only. Engines disagree about a leading dot in a
                // suffix value, so this is spelled as an anchored pattern.
                one.domains = [FlatDomain(kind: .regex, value: "^.+\\." + RuleLowering.regexEscaped(text) + "$")]
            } else {
                one.domains = [FlatDomain(kind: .suffix, value: text)]
            }
        case let .domainKeyword(keyword):
            one.domains = [FlatDomain(kind: .keyword, value: ByteText.string(keyword))]
        case let .domainRegex(regex):
            one.domains = [FlatDomain(kind: .regex, value: regex.pattern)]
        case let .ipCIDR(cidr):
            one.ips = [cidr]
        case let .ipNotIn(excluded):
            one.excludedIPs = excluded.prefixes
        case let .port(range):
            one.ports = [range]
        case let .network(kind):
            one.networks = [kind]
        case let .sourceCIDR(cidr):
            one.sourceIPs = [cidr]
        case let .sourcePort(range):
            one.sourcePorts = [range]
        case let .inboundTag(tag):
            one.inboundTags = [tag]
        case let .user(name):
            one.users = [name]
        case let .sniffedProtocol(prefix):
            one.sniffedProtocols = [ByteText.string(prefix)]

        case .not:
            throw LoweringFailure(kind: .negation, detail: "NOT has no engine equivalent; use ipNotIn for addresses")

        case let .anyOf(items):
            var result: [FieldSet] = []
            for item in items {
                for fields in try alternatives(of: item) {
                    // Merge with the previous alternative when exact; only
                    // the previous one, so the order of parts is kept.
                    if let last = result.last, let merged = last.merged(with: fields) {
                        result[result.count - 1] = merged
                    } else {
                        result.append(fields)
                    }
                    if result.count > RuleLowering.maximumPartsPerRule {
                        throw LoweringFailure(
                            kind: .tooManyAlternatives,
                            detail: "more than \(RuleLowering.maximumPartsPerRule) flat rules"
                        )
                    }
                }
            }
            return result

        case let .allOf(items):
            var result: [FieldSet] = [FieldSet()]
            for item in items {
                let right = try alternatives(of: item)
                var product: [FieldSet] = []
                product.reserveCapacity(result.count * right.count)
                for left in result {
                    for fields in right {
                        product.append(try left.joined(with: fields))
                        if product.count > RuleLowering.maximumPartsPerRule {
                            throw LoweringFailure(
                                kind: .tooManyAlternatives,
                                detail: "more than \(RuleLowering.maximumPartsPerRule) flat rules"
                            )
                        }
                    }
                }
                result = product
                if result.isEmpty { break }
            }
            return result
        }
        return [one]
    }
}

// MARK: - Flat evaluation

extension FlatRule {
    /// Evaluates the flat rule the way an engine does. Used to check that
    /// lowering preserves meaning; routing itself uses `CompiledRouter`.
    func matches(_ input: EvaluationInput) -> Bool {
        if !networks.isEmpty {
            guard let network = input.network, networks.contains(network) else { return false }
        }
        if !sniffedProtocols.isEmpty {
            guard let sniffed = input.sniffedProtocol else { return false }
            if !sniffedProtocols.contains(where: { sniffed.starts(with: Array($0.utf8)) }) { return false }
        }
        if !ports.isEmpty, !ports.contains(where: { $0.contains(input.port) }) { return false }
        if !sourcePorts.isEmpty, !sourcePorts.contains(where: { $0.contains(input.sourcePort) }) { return false }
        if !inboundTags.isEmpty {
            guard let tag = input.inboundTag, inboundTags.contains(tag) else { return false }
        }
        if !users.isEmpty {
            guard let user = input.user, users.contains(user) else { return false }
        }
        if !sourceIPs.isEmpty {
            guard let source = input.sourceIP, sourceIPs.contains(where: { $0.contains(source) }) else { return false }
        }
        if !ips.isEmpty || !excludedIPs.isEmpty {
            var found = false
            let excluded = ExcludedPrefixes(excludedIPs)
            for ip in input.targetIPs {
                if ips.contains(where: { $0.contains(ip) }) || (!excludedIPs.isEmpty && excluded.isOutside(ip)) {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        if !domains.isEmpty {
            guard let name = input.domain else { return false }
            var found = false
            for domain in domains {
                let value = Array(domain.value.utf8)
                switch domain.kind {
                case .full: found = name == value
                case .suffix: found = ByteText.hasLabelSuffix(name, value, strict: false)
                case .keyword: found = ByteText.contains(name, value)
                case .regex: found = (try? LinearRegex(domain.value))?.matches(utf8: name) ?? false
                }
                if found { break }
            }
            if !found { return false }
        }
        return true
    }
}

extension LoweredTable {
    /// First-match evaluation of the flat rules with the table's domain
    /// strategy. Returns the tag of the matching flat rule, or `nil` when
    /// nothing matched (the engine then uses its default outbound).
    func firstMatchTag(_ request: RouteRequest) -> String? {
        let passes = EvaluationInput.passes(for: request, strategy: domainStrategy)
        for rule in rules where rule.matches(passes.first) {
            return rule.tag
        }
        if let second = passes.second {
            for rule in rules where rule.matches(second) {
                return rule.tag
            }
        }
        return nil
    }
}
