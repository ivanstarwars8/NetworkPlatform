import DomainModels
import Foundation
import RoutingEngine

/// What the user asks the route simulator.
public struct RouteQuery: Hashable, Sendable {
    public var domain: String
    public var address: String
    public var port: String
    public var network: NetworkKind

    public init(domain: String = "", address: String = "", port: String = "443", network: NetworkKind = .tcp) {
        self.domain = domain
        self.address = address
        self.port = port
        self.network = network
    }
}

/// The simulator's answer. The decision comes from `RouteSimulator` (the same matcher the differential
/// test checks against Xray's router), over the same table the engine compilers get.
public struct RouteAnswer: Hashable, Sendable {
    public var target: RuleTarget
    /// Index of the winning table rule; `nil` when nothing matched and the preset's final target applies.
    public var ruleIndex: Int?
    public var origin: RuleOrigin?
    /// The entry of the winning rule that matched (for a list: which domain or network).
    public var matchedKind: RuleMatchKind?
    public var matchedValue: String?
    /// Tag of the engine rule that carries the decision (`r<index>.<part>` or `final`): Xray's `ruleTag`.
    public var engineRuleTag: String
    /// Enabled rules before the winner that did not match.
    public var checkedBefore: Int
    /// Disabled rules before the winner (skipped).
    public var disabledBefore: Int
    /// Rules after the winner that match too but lose on order.
    public var shadowedRules: [Int]
    /// The domain as compared (punycode), when one was given.
    public var normalisedDomain: String?
    /// `true` when the address is one the tunnel never carries (local networks, the profile's server
    /// addresses): the system sends it directly before any rule is looked at.
    public var bypassesTunnel: Bool = false
}

public struct RouteExplainer: Sendable {
    public let policy: CompiledPolicy
    private let simulator: RouteSimulator
    private let lowered: LoweredTable
    private let bypass: [IPCIDR]

    /// `bypass`: destinations excluded from the tunnel at the system level (`XrayTunnelPlan.excludedRoutes`:
    /// the profile's server addresses and `TunnelAddressing.localRoutes`); the compiled configurations send
    /// the same list directly.
    public init(policy: CompiledPolicy, bypass: [TunnelRoute] = TunnelAddressing.localRoutes) throws {
        self.policy = policy
        self.bypass = bypass.compactMap { IPCIDR($0.cidr) }
        self.simulator = try RouteSimulator(table: policy.table, traceLimit: 10_000)
        self.lowered = try RuleLowering.lower(policy.table)
    }

    public func explain(_ query: RouteQuery) -> Result<RouteAnswer, PolicyInputError> {
        let domainText = query.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressText = query.address.trimmingCharacters(in: .whitespacesAndNewlines)
        var domain: String?
        if !domainText.isEmpty {
            guard let name = HostName.ascii(domainText) else {
                return .failure(PolicyInputError("Это не похоже на домен. Пример: example.com."))
            }
            domain = name
        }
        var address: IPAddress?
        if !addressText.isEmpty {
            guard let parsed = IPAddress(addressText) else {
                return .failure(PolicyInputError("Адрес — IPv4 или IPv6, например 203.0.113.7."))
            }
            address = parsed
        }
        guard domain != nil || address != nil else {
            return .failure(PolicyInputError("Введите домен, адрес или оба."))
        }
        let portText = query.port.trimmingCharacters(in: .whitespaces)
        guard let port = portText.isEmpty ? UInt16(0) : UInt16(portText) else {
            return .failure(PolicyInputError("Порт — число 0–65535."))
        }
        if let address = address, bypass.contains(where: { $0.contains(address) }) {
            return .success(RouteAnswer(
                target: .direct, ruleIndex: nil, origin: nil, matchedKind: .ipCIDR,
                matchedValue: bypass.first { $0.contains(address) }?.description, engineRuleTag: "bypass",
                checkedBefore: 0, disabledBefore: 0, shadowedRules: [], normalisedDomain: domain, bypassesTunnel: true
            ))
        }
        let request = RouteRequest(domain: domain, ip: address, port: port, network: query.network)
        let explanation = simulator.explain(request)

        let winner = explanation.matchedRuleIndex
        var checked = 0
        var disabled = 0
        var shadowed: [Int] = []
        for entry in explanation.trace {
            switch entry.outcome {
            case .notMatched: checked += 1
            case .disabled: disabled += 1
            case .lowerPriority: if let index = entry.ruleIndex { shadowed.append(index) }
            case .matched, .finalAction: break
            }
        }

        var matchedKind: RuleMatchKind?
        var matchedValue: String?
        var engineTag = "final"
        if let winner = winner {
            if let leaf = RouteExplainer.firstMatchingLeaf(policy.table.rules[winner].condition, domain: domain, address: address, port: port, network: query.network) {
                matchedKind = leaf.kind
                matchedValue = leaf.value
            }
            let parts = lowered.rules.filter { $0.sourceRuleIndex == winner }
            let part = parts.first { flat in
                switch matchedKind {
                case .domain?, .domainSuffix?, .domainKeyword?: return !flat.domains.isEmpty
                case .ipCIDR?: return !flat.ips.isEmpty
                case .port?: return !flat.ports.isEmpty
                case .network?: return !flat.networks.isEmpty
                case nil: return true
                }
            } ?? parts.first
            engineTag = part?.tag ?? "r\(winner).0"
        }

        let action = explanation.decision.action
        let target: RuleTarget
        switch action {
        case .direct: target = .direct
        case .reject: target = .block
        default: target = .tunnel
        }
        return .success(RouteAnswer(
            target: target,
            ruleIndex: winner,
            origin: winner.flatMap { $0 < policy.origins.count ? policy.origins[$0] : nil },
            matchedKind: matchedKind,
            matchedValue: matchedValue,
            engineRuleTag: engineTag,
            checkedBefore: checked + explanation.omittedEntries,
            disabledBefore: disabled,
            shadowedRules: shadowed,
            normalisedDomain: domain
        ))
    }

    /// The first leaf of an `or` tree (or a single leaf) that matches, for naming the entry. The decision
    /// itself never comes from here.
    static func firstMatchingLeaf(
        _ condition: RuleCondition, domain: String?, address: IPAddress?, port: UInt16, network: NetworkKind
    ) -> (kind: RuleMatchKind, value: String)? {
        switch condition {
        case .or(let children):
            for child in children {
                if let leaf = firstMatchingLeaf(child, domain: domain, address: address, port: port, network: network) {
                    return leaf
                }
            }
            return nil
        case .domain(let value):
            return domain == value ? (.domain, value) : nil
        case .domainSuffix(let value):
            guard let domain = domain else { return nil }
            return domain == value || domain.hasSuffix("." + value) ? (.domainSuffix, value) : nil
        case .domainKeyword(let value):
            guard let domain = domain else { return nil }
            return domain.contains(value) ? (.domainKeyword, value) : nil
        case .ipCIDR(let cidr):
            guard let address = address else { return nil }
            return cidr.contains(address) ? (.ipCIDR, cidr.description) : nil
        case .port(let range):
            return range.contains(port) ? (.port, range.lower == range.upper ? "\(range.lower)" : "\(range.lower)-\(range.upper)") : nil
        case .network(let kind):
            return kind == network ? (.network, kind.rawValue) : nil
        default:
            return nil
        }
    }
}
