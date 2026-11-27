import Foundation
import DomainModels
import RoutingEngine

/// Spells a RoutingEngine table in Mihomo's rule syntax (`rules/common/base.go`, `rules/logic/logic.go`).
///
/// The table is first lowered (`RuleLowering`) into flat rules: a conjunction of fields, each a disjunction
/// of values. A flat rule with one field becomes one Mihomo rule per value (same first-match result); a rule
/// with several fields becomes `AND,((…),(…))` with an `OR` per multi-valued field. Anything that cannot be
/// written exactly is an error: a partial rule list would route differently from the simulator.
struct MihomoRuleCompiler {
    let profile: Profile
    let names: [String: String]
    let proxyByTag: [String: [YAMLPair]]
    /// Copies of proxies with `dialer-proxy`, one per chain hop after the first.
    private(set) var chainProxies: [YAMLNode] = []
    private var chainNames: [[String]: String] = [:]

    /// Ranges per `DST-PORT`/`SRC-PORT` payload (`common/utils/ranges.go`).
    static let maximumPortRanges = 28

    init(profile: Profile, names: [String: String], proxyByTag: [String: [YAMLPair]]) {
        self.profile = profile
        self.names = names
        self.proxyByTag = proxyByTag
    }

    private struct Failure: Error {
        let detail: String
    }

    mutating func compile(_ table: RoutingTable, report: inout ConversionReport) -> [String]? {
        let lowered: LoweredTable
        do {
            lowered = try RuleLowering.lower(table)
        } catch {
            report.add("options.routing", .invalid, .error, "Routing table does not compile: \(error)")
            return nil
        }
        var failed = false
        for issue in lowered.issues {
            let path = issue.ruleIndex.map { "options.routing.rules[\($0)]" } ?? "options.routing.finalAction"
            report.add(path, .unsupported, .error, "Rule has no engine form (\(issue.kind.rawValue)): \(issue.detail)")
            failed = true
        }
        if failed { return nil }

        var rules: [String] = []
        var secondPass: [String] = []
        let resolveMode: (noResolve: Bool, twoPasses: Bool)
        switch lowered.domainStrategy {
        case .asIs: resolveMode = (true, false)
        case .ipOnDemand: resolveMode = (false, false)
        case .ipIfNonMatch: resolveMode = (true, true)
        }
        var usesAddresses = false
        for rule in lowered.rules {
            let path = rule.sourceRuleIndex.map { "options.routing.rules[\($0)]" } ?? "options.routing.finalAction"
            do {
                let target = try self.target(rule.action)
                rules += try spell(rule, target: target, noResolve: resolveMode.noResolve)
                if !rule.ips.isEmpty || !rule.excludedIPs.isEmpty {
                    usesAddresses = true
                    if resolveMode.twoPasses {
                        secondPass += try spell(rule, target: target, noResolve: false)
                    }
                }
            } catch let failure as Failure {
                report.add(path, .unsupported, .error, failure.detail)
                failed = true
            } catch {
                report.add(path, .unsupported, .error, "\(error)")
                failed = true
            }
        }
        if failed { return nil }
        rules += secondPass
        if !lowered.finalIsCatchAllRule {
            do {
                rules.append("MATCH,\(try target(lowered.finalAction))")
            } catch let failure as Failure {
                report.add("options.routing.finalAction", .unsupported, .error, failure.detail)
                return nil
            } catch {
                return nil
            }
        }
        if usesAddresses {
            report.add(
                "options.routing", .approximated, .info,
                "Address rules see one destination address: inside the tunnel the connection's own address (also when the domain is known from the resolver), otherwise the first resolved address"
            )
        }
        if lowered.rules.contains(where: { !$0.domains.isEmpty }) {
            report.add(
                "options.routing", .approximated, .info,
                "Domain rules match connections whose address came from the tunnel's resolver (DNS mapping) or that name a domain; sniffing is off"
            )
        }
        if !chainProxies.isEmpty {
            report.add("options.routing", .untested, .info, "Chains are compiled to proxies with 'dialer-proxy'; not covered by the end-to-end lab run")
        }
        return rules
    }

    // MARK: - Targets

    private mutating func target(_ action: RouteAction) throws -> String {
        switch action {
        case .direct: return MihomoConfigCompiler.directTarget
        case .reject: return MihomoConfigCompiler.rejectTarget
        case .proxy(let tag):
            guard profile.outbound(tagged: tag) != nil else { throw Failure(detail: "Action names an outbound that does not exist") }
            guard let name = names[tag] else { throw Failure(detail: "Action names an outbound that could not be compiled") }
            return name
        case .group(let tag):
            guard profile.group(tagged: tag) != nil else { throw Failure(detail: "Action names a group that does not exist") }
            guard let name = names[tag] else { throw Failure(detail: "Action names a group that could not be compiled") }
            return name
        case .chain(let tags):
            if let known = chainNames[tags] { return known }
            guard let first = tags.first, let firstName = names[first] else {
                throw Failure(detail: "The first hop of a chain could not be compiled")
            }
            var previous = firstName
            for (hop, tag) in tags.enumerated().dropFirst() {
                guard let pairs = proxyByTag[tag] else {
                    throw Failure(detail: "Chain hop \(hop) must be a compiled outbound (a group cannot dial through another proxy)")
                }
                let name = "chain-\(MihomoConfigCompiler.padded(chainNames.count))-\(hop)"
                var copy = pairs.filter { $0.key != "name" && $0.key != "dialer-proxy" }
                copy.insert(YAMLPair("name", .string(name)), at: 0)
                copy.append(YAMLPair("dialer-proxy", .string(previous)))
                chainProxies.append(.mapping(copy))
                previous = name
            }
            chainNames[tags] = previous
            return previous
        }
    }

    // MARK: - Conditions

    /// One flat rule as Mihomo rule lines.
    private func spell(_ rule: FlatRule, target: String, noResolve: Bool) throws -> [String] {
        var fields: [[String]] = []
        let resolve = noResolve ? ",no-resolve" : ""

        if !rule.domains.isEmpty {
            fields.append(try rule.domains.map { domain in
                let type: String
                switch domain.kind {
                case .full: type = "DOMAIN"
                case .suffix: type = "DOMAIN-SUFFIX"
                case .keyword: type = "DOMAIN-KEYWORD"
                case .regex: type = "DOMAIN-REGEX"
                }
                if domain.kind != .regex && domain.value.contains(",") {
                    throw Failure(detail: "A domain value contains ','")
                }
                return "\(type),\(domain.value)"
            })
        }
        if !rule.ips.isEmpty || !rule.excludedIPs.isEmpty {
            var alternatives = rule.ips.map { MihomoRuleCompiler.cidrCondition($0, prefix: "", resolve: resolve) }
            if !rule.excludedIPs.isEmpty {
                // "a target address exists and lies outside all of them": NOT alone would also match a
                // connection without an address.
                let inside = MihomoRuleCompiler.disjunction(
                    rule.excludedIPs.map { MihomoRuleCompiler.cidrCondition($0, prefix: "", resolve: resolve) }
                )
                let hasAddress = "OR,((IP-CIDR,0.0.0.0/0\(resolve)),(IP-CIDR6,::/0\(resolve)))"
                alternatives.append("AND,((\(hasAddress)),(NOT,((\(inside)))))")
            }
            fields.append(alternatives)
        }
        if !rule.ports.isEmpty { fields.append(MihomoRuleCompiler.portConditions("DST-PORT", rule.ports)) }
        let networks = Set(rule.networks)
        if !networks.isEmpty && networks != [.tcp, .udp] {
            fields.append(rule.networks.map { "NETWORK,\($0.rawValue)" })
        }
        if !rule.sourceIPs.isEmpty {
            fields.append(rule.sourceIPs.map { MihomoRuleCompiler.cidrCondition($0, prefix: "SRC-", resolve: "") })
        }
        if !rule.sourcePorts.isEmpty { fields.append(MihomoRuleCompiler.portConditions("SRC-PORT", rule.sourcePorts)) }
        if !rule.inboundTags.isEmpty {
            throw Failure(detail: "Inbound-tag conditions name Xray inbounds; Mihomo has no matching inbound names")
        }
        if !rule.users.isEmpty {
            throw Failure(detail: "User conditions have no Mihomo equivalent for the tunnel inbound")
        }
        if !rule.sniffedProtocols.isEmpty {
            throw Failure(detail: "Mihomo has no rule on the sniffed protocol")
        }

        if fields.isEmpty {
            return ["MATCH,\(target)"]
        }
        if fields.count == 1 {
            // A standalone rule takes its parameters after the target: TYPE,payload,TARGET,no-resolve.
            return fields[0].map { condition in
                condition.hasSuffix(",no-resolve") && !condition.hasPrefix("AND,")
                    ? "\(condition.dropLast(",no-resolve".count)),\(target),no-resolve"
                    : "\(condition),\(target)"
            }
        }
        for field in fields {
            for condition in field where condition.hasPrefix("DOMAIN-REGEX,") && (condition.contains("(") || condition.contains(")")) {
                throw Failure(detail: "A regular expression with parentheses cannot be combined with other conditions in a Mihomo logic rule")
            }
        }
        let parts = fields.map { field in field.count == 1 ? field[0] : MihomoRuleCompiler.disjunction(field) }
        return ["AND,(" + parts.map { "(\($0))" }.joined(separator: ",") + "),\(target)"]
    }

    static func disjunction(_ conditions: [String]) -> String {
        if conditions.count == 1 { return conditions[0] }
        return "OR,(" + conditions.map { "(\($0))" }.joined(separator: ",") + ")"
    }

    static func cidrCondition(_ cidr: IPCIDR, prefix: String, resolve: String) -> String {
        let isV6: Bool
        if case .v6 = cidr.network { isV6 = true } else { isV6 = false }
        if prefix.isEmpty {
            return "\(isV6 ? "IP-CIDR6" : "IP-CIDR"),\(cidr)\(resolve)"
        }
        return "SRC-IP-CIDR,\(cidr)"
    }

    /// Port ranges, at most `maximumPortRanges` per condition.
    static func portConditions(_ type: String, _ ranges: [RoutingEngine.PortRange]) -> [String] {
        let texts = ranges.map { $0.lower == $0.upper ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }
        return stride(from: 0, to: texts.count, by: maximumPortRanges).map { start in
            "\(type),\(texts[start..<min(start + maximumPortRanges, texts.count)].joined(separator: "/"))"
        }
    }
}
