import Foundation
import DomainModels
import RoutingEngine

/// Spells a RoutingEngine table in Xray's routing syntax (`infra/conf/router.go`).
///
/// The table is lowered (`RuleLowering`) into flat rules: one Xray field rule per flat rule, tagged
/// `r<index>.<part>` (`ruleTag`), the same spelling the differential test against Xray's router checks
/// (`Benchmarks/RoutingParity/parity_test.go`, `xrayRule`). Anything that cannot be written exactly is an
/// error: a partial rule list would route differently from what the simulator shows.
struct XrayRuleCompiler {
    /// The rule fields that send traffic to the profile's main route (`outboundTag` or `balancerTag`).
    let mainTarget: [String: JSONValue]
    /// Tags of the model (the selected outbound or group, after the compiler's fallback) that mean the main route.
    let mainTags: Set<String>
    let profile: Profile
    let emittedTags: [String: String]

    struct Output {
        var rules: [JSONValue]
        var domainStrategy: String
        /// `true` when some rule matches on domains: the tunnel inbound then needs sniffing, because
        /// connections from the tunnel carry only an address.
        var usesDomains: Bool
    }

    private struct Failure: Error {
        let detail: String
    }

    func compile(_ table: RoutingTable, report: inout ConversionReport) -> Output? {
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
        if !lowered.finalIsCatchAllRule {
            // Xray has no final action: it would have to be the first outbound, which is the profile's
            // first proxy here. Not written rather than approximated.
            report.add("options.routing.domainStrategy", .unsupported, .error, "The Xray compiler does not write ipIfNonMatch tables yet; use asIs or ipOnDemand")
            failed = true
        }
        if failed { return nil }

        var rules: [JSONValue] = []
        for rule in lowered.rules {
            let path = rule.sourceRuleIndex.map { "options.routing.rules[\($0)]" } ?? "options.routing.finalAction"
            do {
                rules.append(.object(try spell(rule)))
            } catch let failure as Failure {
                report.add(path, .unsupported, .error, failure.detail)
                failed = true
            } catch {
                report.add(path, .unsupported, .error, "\(error)")
                failed = true
            }
        }
        if failed { return nil }
        let usesDomains = lowered.rules.contains { !$0.domains.isEmpty }
        if usesDomains {
            report.add(
                "options.routing", .approximated, .info,
                "Domain rules match the name the core reads from the first packet of a connection (TLS server name, HTTP host, QUIC); connections without one are matched by address only"
            )
        }
        let strategy: String
        switch lowered.domainStrategy {
        case .asIs: strategy = "AsIs"
        case .ipOnDemand: strategy = "IPOnDemand"
        case .ipIfNonMatch: strategy = "IPIfNonMatch"
        }
        return Output(rules: rules, domainStrategy: strategy, usesDomains: usesDomains)
    }

    private func target(_ action: RouteAction) throws -> [String: JSONValue] {
        switch action {
        case .direct: return ["outboundTag": .string(XrayConfigCompiler.directTag)]
        case .reject: return ["outboundTag": .string(XrayConfigCompiler.blockTag)]
        case .proxy(let tag):
            if mainTags.contains(tag) { return mainTarget }
            guard profile.outbound(tagged: tag) != nil else { throw Failure(detail: "Action names an outbound that does not exist") }
            guard let engineTag = emittedTags[tag] else { throw Failure(detail: "Action names an outbound that could not be compiled") }
            return ["outboundTag": .string(engineTag)]
        case .group(let tag):
            if mainTags.contains(tag) { return mainTarget }
            throw Failure(detail: "The Xray compiler routes to one group only: the selected one")
        case .chain:
            throw Failure(detail: "The Xray compiler does not write chains yet")
        }
    }

    private func spell(_ rule: FlatRule) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = ["type": .string("field"), "ruleTag": .string(rule.tag)]
        out.merge(try target(rule.action)) { current, _ in current }
        if !rule.domains.isEmpty {
            out["domain"] = .array(rule.domains.map { domain in
                switch domain.kind {
                case .full: return .string("full:" + domain.value)
                case .suffix: return .string("domain:" + domain.value)
                case .keyword: return .string("keyword:" + domain.value)
                case .regex: return .string("regexp:" + domain.value)
                }
            })
        }
        if !rule.ips.isEmpty || !rule.excludedIPs.isEmpty {
            out["ip"] = .array(rule.ips.map { .string($0.description) } + rule.excludedIPs.map { .string("!" + $0.description) })
        }
        if !rule.ports.isEmpty { out["port"] = .string(XrayRuleCompiler.portList(rule.ports)) }
        if !rule.networks.isEmpty { out["network"] = .string(rule.networks.map(\.rawValue).joined(separator: ",")) }
        if !rule.sourceIPs.isEmpty { out["sourceIP"] = .array(rule.sourceIPs.map { .string($0.description) }) }
        if !rule.sourcePorts.isEmpty { out["sourcePort"] = .string(XrayRuleCompiler.portList(rule.sourcePorts)) }
        if !rule.inboundTags.isEmpty { out["inboundTag"] = .array(rule.inboundTags.map { .string($0) }) }
        if !rule.users.isEmpty { out["user"] = .array(rule.users.map { .string($0) }) }
        if !rule.sniffedProtocols.isEmpty { out["protocol"] = .array(rule.sniffedProtocols.map { .string($0) }) }
        return out
    }

    /// `"80,443,1000-2000"` (`infra/conf/common.go` PortList).
    static func portList(_ ranges: [RoutingEngine.PortRange]) -> String {
        ranges.map { $0.lower == $0.upper ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }.joined(separator: ",")
    }
}
