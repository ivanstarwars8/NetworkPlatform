import ConfigurationEngine
import DomainModels
import Foundation
import RoutingEngine
@testable import RoutingPolicy
import XCTest

/// Settings → table → both engine configurations, and the route simulator's answers against what the
/// compiled configurations would do (a small evaluator of the rule subset the policy produces).
final class RoutingPolicyCompileTests: XCTestCase {
    // Documentation addresses (RFC 5737) and a test key; no real server.
    static let link = "vless://1cc9207f-5dda-4274-bb0d-9d105c95c6e8@192.0.2.1:443?type=tcp&security=reality&sni=www.example.org"
        + "&fp=chrome&pbk=VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4&sid=0a1b&flow=xtls-rprx-vision#lab"

    private func profile() throws -> Profile {
        let outbound = try ShareLinkImporter().importLink(RoutingPolicyCompileTests.link).outbound
        return Profile(name: "p", outbounds: [outbound], selectedTag: outbound.tag)
    }

    private func compile(_ settings: RoutingSettings, ruleSets: [UUID: CompiledRuleSet] = [:]) throws -> CompiledPolicy {
        try RoutingPolicyCompiler(settings: settings, ruleSets: ruleSets).compile(for: profile()).get()
    }

    // MARK: Table

    func testEverythingWithoutRulesIsPassthrough() throws {
        let policy = try compile(RoutingSettings())
        XCTAssertTrue(policy.isPassthrough)
        XCTAssertNil(policy.engineTable, "the compilers keep their plain form")
        XCTAssertEqual(policy.table.finalAction, policy.tunnelAction)
        XCTAssertEqual(policy.tunnelAction, .proxy(try profile().outbounds[0].tag))
    }

    func testOrderOwnRulesThenListsThenPreset() throws {
        var settings = RoutingSettings(preset: .russiaDirect)
        let own = try CustomRule.make(kind: .domainSuffix, text: "mail.ru", target: .tunnel).get()
        let off = try CustomRule.make(kind: .domain, text: "off.example", target: .block, isEnabled: false).get()
        settings.customRules = [own, off]
        let list = RemoteRuleSet(name: "L", url: "https://example.com/l", target: .block)
        let missing = RemoteRuleSet(name: "Нет", url: "https://example.com/m", target: .block)
        settings.remoteRuleSets = [list, missing]
        let policy = try compile(settings, ruleSets: [list.id: CompiledRuleSet(suffixes: ["ads.example"], cidrs: ["198.51.100.0/24"])])
        XCTAssertFalse(policy.isPassthrough)
        XCTAssertEqual(policy.origins, [
            .custom(own.id), .custom(off.id), .remote(list.id),
            .preset(.russiaDirect, groupID: "ru-zones"), .preset(.russiaDirect, groupID: "ru-services"),
        ])
        XCTAssertFalse(policy.table.rules[1].isEnabled)
        XCTAssertEqual(policy.table.domainStrategy, .asIs)
        XCTAssertEqual(policy.notices.count, 1, "the list without entries is named")
        XCTAssertTrue(policy.notices[0].contains("Нет"))
    }

    func testTotalListLimit() throws {
        var settings = RoutingSettings()
        let a = RemoteRuleSet(name: "A", url: "https://example.com/a", target: .direct)
        let b = RemoteRuleSet(name: "B", url: "https://example.com/b", target: .direct)
        settings.remoteRuleSets = [a, b]
        let sets = [a.id: CompiledRuleSet(suffixes: ["a1.example", "a2.example"]), b.id: CompiledRuleSet(suffixes: ["b1.example", "b2.example"])]
        let policy = try RoutingPolicyCompiler(settings: settings, ruleSets: sets, limits: RuleSetLimits(maximumEntriesPerSet: 10, maximumTotalEntries: 3)).compile(for: profile()).get()
        XCTAssertEqual(policy.origins, [.remote(a.id)])
        XCTAssertTrue(policy.notices[0].contains("B"))
    }

    // MARK: Simulator

    func testExplainNamesOriginEntryAndEngineRule() throws {
        var settings = RoutingSettings(preset: .blockedOnly)
        let own = try CustomRule.make(kind: .domainSuffix, text: "music.youtube.com", target: .direct).get()
        settings.customRules = [own]
        let policy = try compile(settings)
        let explainer = try RouteExplainer(policy: policy, bypass: TunnelAddressing.localRoutes)

        let own1 = try explainer.explain(RouteQuery(domain: "MUSIC.youtube.com")).get()
        XCTAssertEqual(own1.target, .direct)
        XCTAssertEqual(own1.origin, .custom(own.id))
        XCTAssertEqual(own1.engineRuleTag, "r0.0")

        let blocked = try explainer.explain(RouteQuery(domain: "www.youtube.com")).get()
        XCTAssertEqual(blocked.target, .tunnel)
        XCTAssertEqual(blocked.origin, .preset(.blockedOnly, groupID: "blocked"))
        XCTAssertEqual(blocked.matchedKind, .domainSuffix)
        XCTAssertEqual(blocked.matchedValue, "youtube.com")
        XCTAssertEqual(blocked.checkedBefore, 1)

        let telegram = try explainer.explain(RouteQuery(address: "149.154.167.51", port: "443")).get()
        XCTAssertEqual(telegram.origin, .preset(.blockedOnly, groupID: "telegram"))
        XCTAssertEqual(telegram.matchedValue, "149.154.160.0/20")
        XCTAssertEqual(telegram.engineRuleTag, "r2.1", "addresses are the second engine rule of the group")

        let other = try explainer.explain(RouteQuery(domain: "example.com")).get()
        XCTAssertEqual(other.target, .direct)
        XCTAssertNil(other.origin)
        XCTAssertEqual(other.engineRuleTag, "final")

        let local = try explainer.explain(RouteQuery(address: "192.168.1.10")).get()
        XCTAssertTrue(local.bypassesTunnel)

        guard case .failure = explainer.explain(RouteQuery()) else { return XCTFail("empty query") }
        guard case .failure = explainer.explain(RouteQuery(domain: "a b")) else { return XCTFail("bad domain") }
        guard case .failure = explainer.explain(RouteQuery(domain: "a.example", port: "x")) else { return XCTFail("bad port") }
    }

    // MARK: Engines agree with the simulator

    private var probes: [Probe] {
        var list: [Probe] = []
        let domains = [
            "yandex.ru", "mail.yandex.ru", "xn--e1afmkfd.xn--p1ai", "vk.com", "m.vk.com", "notvk.com", "example.com",
            "www.youtube.com", "youtube.com.example", "rr1.googlevideo.com", "t.me", "ads.example", "x.ads.example",
            "music.youtube.com", "a.music.youtube.com", "bank.example.org", "torrent.example", "claude.ai",
        ]
        let ips = [nil, "149.154.167.51", "91.108.56.100", "198.51.100.9", "203.0.113.5", "2001:b28:f23d::1", "2001:db8::5"]
        for domain in [nil] + domains {
            for ip in ips where domain != nil || ip != nil {
                for (port, network) in [(UInt16(443), NetworkKind.tcp), (53, .udp), (6881, .udp), (25, .tcp)] {
                    list.append(Probe(domain: domain, ip: ip, port: port, network: network))
                }
            }
        }
        return list
    }

    private func settingsMatrix() throws -> [(RoutingSettings, [UUID: CompiledRuleSet])] {
        var result: [(RoutingSettings, [UUID: CompiledRuleSet])] = []
        let list = RemoteRuleSet(name: "L", url: "https://example.com/l", target: .block)
        let content = CompiledRuleSet(
            suffixes: (0..<20).map { "ads\($0).example" } + ["ads.example"],
            exactDomains: ["bank.example.org"],
            cidrs: (0..<20).map { "198.51.100.\($0 * 8)/29" }
        )
        for preset in RoutingPreset.allCases {
            var settings = RoutingSettings(preset: preset)
            settings.customRules = [
                try CustomRule.make(kind: .domainSuffix, text: "music.youtube.com", target: .direct).get(),
                try CustomRule.make(kind: .domainKeyword, text: "torrent", target: .block).get(),
                try CustomRule.make(kind: .port, text: "6881-6889", target: .direct).get(),
                try CustomRule.make(kind: .network, text: "udp", target: .tunnel, isEnabled: false).get(),
                try CustomRule.make(kind: .ipCIDR, text: "203.0.113.0/24", target: .direct).get(),
                try CustomRule.make(kind: .domain, text: "claude.ai", target: .block).get(),
            ]
            settings.remoteRuleSets = [list]
            result.append((settings, [list.id: content]))
            result.append((RoutingSettings(preset: preset), [:]))
        }
        return result
    }

    func testXrayConfigurationRoutesLikeTheSimulator() throws {
        let profile = try profile()
        for (settings, sets) in try settingsMatrix() {
            let policy = try RoutingPolicyCompiler(settings: settings, ruleSets: sets).compile(for: profile).get()
            let compilation = XrayConfigCompiler(options: policy.xrayOptions()).compile(profile)
            XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
            let config = try XCTUnwrap(compilation.config)
            let rules = try XCTUnwrap(config["routing"]?["rules"]?.arrayValue)
            if !policy.isPassthrough {
                XCTAssertEqual(config["routing"]?["domainStrategy"], .string("AsIs"))
                let tun = config["inbounds"]?.arrayValue?.first { $0["tag"] == .string(XrayConfigCompiler.tunInboundTag) }
                XCTAssertEqual(tun?["sniffing"]?["routeOnly"], .bool(true), "domain rules need the name from the first packet")
            }
            let explainer = try RouteExplainer(policy: policy, bypass: compilation.tunnel?.excludedRoutes ?? [])
            for probe in probes {
                let answer = try explainer.explain(RouteQuery(domain: probe.domain ?? "", address: probe.ip ?? "", port: "\(probe.port)", network: probe.network)).get()
                let engine = try XCTUnwrap(XrayEvaluator.decide(rules, probe: probe), "\(probe)")
                XCTAssertEqual(answer.target, engine.target, "\(settings.preset) \(probe)")
                if !policy.isPassthrough && !answer.bypassesTunnel {
                    XCTAssertEqual(answer.engineRuleTag, engine.tag, "\(settings.preset) \(probe)")
                }
            }
        }
    }

    func testMihomoConfigurationRoutesLikeTheSimulator() throws {
        let profile = try profile()
        var sawProvider = false
        for (settings, sets) in try settingsMatrix() {
            let policy = try RoutingPolicyCompiler(settings: settings, ruleSets: sets).compile(for: profile).get()
            let compilation = MihomoConfigCompiler(options: policy.mihomoOptions()).compile(profile)
            XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
            let document = try XCTUnwrap(compilation.document)
            let rules = try XCTUnwrap(document["rules"]?.sequenceValue).compactMap(\.stringValue)
            if document["rule-providers"] != nil { sawProvider = true }
            let explainer = try RouteExplainer(policy: policy, bypass: compilation.tunnel?.excludedRoutes ?? [])
            for probe in probes {
                let answer = try explainer.explain(RouteQuery(domain: probe.domain ?? "", address: probe.ip ?? "", port: "\(probe.port)", network: probe.network)).get()
                let engine = try XCTUnwrap(MihomoEvaluator.decide(rules, providers: document["rule-providers"], probe: probe), "\(probe)")
                XCTAssertEqual(answer.target, engine, "\(settings.preset) \(probe)")
            }
        }
        XCTAssertTrue(sawProvider, "long lists become inline rule providers")
    }

    // MARK: DNS

    func testDNSSettingsReachBothEngines() throws {
        var settings = RoutingSettings(preset: .russiaDirect)
        settings.dns = DNSSettings(
            servers: ["https://dns.example/dns-query", "9.9.9.9"],
            domainServers: [DomainDNSRule(domain: "example.org", server: "77.88.8.8")],
            ipv6: false, leakProtection: false
        )
        let profile = try profile()
        let policy = try compile(settings)

        let xray = try XCTUnwrap(XrayConfigCompiler(options: policy.xrayOptions()).compile(profile).config)
        let servers = try XCTUnwrap(xray["dns"]?["servers"]?.arrayValue)
        XCTAssertEqual(servers.count, 3)
        XCTAssertEqual(servers[0]["address"], .string("77.88.8.8"))
        XCTAssertEqual(servers[0]["domains"], .array([.string("domain:example.org")]))
        XCTAssertEqual(servers[1], .string("https://dns.example/dns-query"))
        XCTAssertEqual(xray["dns"]?["queryStrategy"], .string("UseIPv4"))
        let rules = try XCTUnwrap(xray["routing"]?["rules"]?.arrayValue)
        XCTAssertFalse(rules.contains { $0["inboundTag"] == .array([.string(XrayConfigCompiler.dnsInternalTag)]) }, "without leak protection the resolver follows the rules")

        let mihomo = try XCTUnwrap(MihomoConfigCompiler(options: policy.mihomoOptions()).compile(profile).document)
        XCTAssertEqual(mihomo["dns"]?["ipv6"], .bool(false))
        XCTAssertEqual(mihomo["dns"]?["respect-rules"], .bool(true))
        XCTAssertNotNil(mihomo["dns"]?["proxy-server-nameserver"], "respect-rules needs it")
        XCTAssertEqual(mihomo["dns"]?["nameserver-policy"]?["+.example.org"], .string("77.88.8.8"))
        XCTAssertEqual(mihomo["dns"]?["nameserver"]?.sequenceValue?.compactMap(\.stringValue), ["https://dns.example/dns-query", "9.9.9.9"])

        // Leak protection on (default): every query pinned to the selected route.
        settings.dns.leakProtection = true
        let protected = try compile(settings)
        let xray2 = try XCTUnwrap(XrayConfigCompiler(options: protected.xrayOptions()).compile(profile).config)
        XCTAssertTrue(try XCTUnwrap(xray2["routing"]?["rules"]?.arrayValue).contains { $0["inboundTag"] == .array([.string(XrayConfigCompiler.dnsInternalTag)]) })
        let mihomo2 = try XCTUnwrap(MihomoConfigCompiler(options: protected.mihomoOptions()).compile(profile).document)
        XCTAssertNil(mihomo2["dns"]?["respect-rules"])
        XCTAssertEqual(mihomo2["dns"]?["nameserver-policy"]?["+.example.org"], .string("77.88.8.8#proxy-0000"))
    }

    /// Writes the configurations of a full policy (every preset, own rules of every kind, a long list, per-domain
    /// DNS, leak protection off) for the real cores: `xray run -test -c` and `mihomo -t -f` on the dev server.
    func testExportPolicyConfigurations() throws {
        guard let directory = ProcessInfo.processInfo.environment["NP_EXPORT_DIR"], !directory.isEmpty else {
            throw XCTSkip("NP_EXPORT_DIR not set")
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let profile = try profile()
        for (index, (settingsBase, sets)) in try settingsMatrix().enumerated() {
            var settings = settingsBase
            settings.dns = DNSSettings(
                servers: ["https://dns.example/dns-query", "9.9.9.9"],
                domainServers: [DomainDNSRule(domain: "example.org", server: "77.88.8.8")],
                ipv6: index % 2 == 0, leakProtection: index % 3 == 0
            )
            let policy = try RoutingPolicyCompiler(settings: settings, ruleSets: sets).compile(for: profile).get()
            let name = "policy-\(index)-\(settings.preset.rawValue)"
            let xray = XrayConfigCompiler(options: policy.xrayOptions()).compile(profile)
            try XCTUnwrap(try xray.jsonText()).write(to: url.appendingPathComponent(name + ".xray.json"), atomically: true, encoding: .utf8)
            let mihomo = MihomoConfigCompiler(options: policy.mihomoOptions()).compile(profile)
            try XCTUnwrap(mihomo.yamlText()).write(to: url.appendingPathComponent(name + ".mihomo.yaml"), atomically: true, encoding: .utf8)
        }
    }

    func testDoTBlocksXrayButNotMihomo() throws {
        var settings = RoutingSettings()
        settings.dns.servers = ["tls://9.9.9.9"]
        let profile = try profile()
        let policy = try compile(settings)
        let xray = XrayConfigCompiler(options: policy.xrayOptions()).compile(profile)
        XCTAssertEqual(xray.report.verdict, .blocked, "Xray has no DoT: the start is refused with a reason")
        XCTAssertTrue(xray.report.issues.contains { $0.detail.contains("DNS over TLS") })
        let mihomo = MihomoConfigCompiler(options: policy.mihomoOptions()).compile(profile)
        XCTAssertNotEqual(mihomo.report.verdict, .blocked)
        XCTAssertEqual(mihomo.document?["dns"]?["nameserver"]?.sequenceValue?.first?.stringValue, "tls://9.9.9.9#proxy-0000")
    }
}

// MARK: - Evaluators of the compiled rule subset

private enum XrayEvaluator {
    static func decide(_ rules: [JSONValue], probe: Probe) -> (target: RuleTarget, tag: String?)? {
        return decide(rules, domain: probe.domain, ip: probe.ip.flatMap(IPAddress.init), port: probe.port, network: probe.network)
    }

    static func decide(_ rules: [JSONValue], domain: String?, ip: IPAddress?, port: UInt16, network: NetworkKind) -> (target: RuleTarget, tag: String?)? {
        for rule in rules {
            if rule["inboundTag"] != nil { continue } // the tunnel's DNS plumbing, not user traffic
            var matched = true
            if let domains = rule["domain"]?.arrayValue?.compactMap(\.stringValue) {
                matched = matched && domain.map { name in
                    domains.contains { value in
                        if value.hasPrefix("full:") { return name == value.dropFirst(5) }
                        if value.hasPrefix("domain:") { let v = String(value.dropFirst(7)); return name == v || name.hasSuffix("." + v) }
                        if value.hasPrefix("keyword:") { return name.contains(value.dropFirst(8)) }
                        XCTFail("unexpected domain form \(value)")
                        return false
                    }
                } ?? false
            }
            if let ips = rule["ip"]?.arrayValue?.compactMap(\.stringValue) {
                matched = matched && ip.map { address in ips.contains { IPCIDR($0)?.contains(address) ?? false } } ?? false
            }
            if let ports = rule["port"]?.stringValue {
                matched = matched && ports.split(separator: ",").contains { RoutingEngine.PortRange(String($0))?.contains(port) ?? false }
            }
            if let networks = rule["network"]?.stringValue {
                matched = matched && networks.split(separator: ",").contains { $0 == network.rawValue }
            }
            if matched {
                let outbound = rule["outboundTag"]?.stringValue
                let target: RuleTarget = outbound == XrayConfigCompiler.directTag ? .direct : (outbound == XrayConfigCompiler.blockTag ? .block : .tunnel)
                return (target, rule["ruleTag"]?.stringValue)
            }
        }
        return nil
    }
}

private struct Probe {
    var domain: String?
    var ip: String?
    var port: UInt16
    var network: NetworkKind
}

private enum MihomoEvaluator {
    static func decide(_ rules: [String], providers: YAMLNode?, probe: Probe) -> RuleTarget? {
        let ip = probe.ip.flatMap(IPAddress.init)
        for line in rules {
            let fields = line.split(separator: ",").map(String.init)
            guard fields.count >= 2 else { continue }
            let type = fields[0]
            let target = type == "MATCH" ? fields[1] : fields[2]
            var matched = false
            switch type {
            case "MATCH": matched = true
            case "DOMAIN": matched = probe.domain == fields[1]
            case "DOMAIN-SUFFIX": matched = probe.domain.map { $0 == fields[1] || $0.hasSuffix("." + fields[1]) } ?? false
            case "DOMAIN-KEYWORD": matched = probe.domain?.contains(fields[1]) ?? false
            case "IP-CIDR", "IP-CIDR6": matched = ip.map { IPCIDR(fields[1])?.contains($0) ?? false } ?? false
            case "DST-PORT": matched = fields[1].split(separator: "/").contains { RoutingEngine.PortRange(String($0))?.contains(probe.port) ?? false }
            case "NETWORK": matched = fields[1] == probe.network.rawValue
            case "RULE-SET":
                guard let provider = providers?[fields[1]] else { XCTFail("missing provider \(fields[1])"); return nil }
                let payload = provider["payload"]?.sequenceValue?.compactMap(\.stringValue) ?? []
                if provider["behavior"]?.stringValue == "domain" {
                    matched = probe.domain.map { name in
                        payload.contains { $0.hasPrefix("+.") ? (name == $0.dropFirst(2) || name.hasSuffix(String($0.dropFirst(1)))) : name == $0 }
                    } ?? false
                } else {
                    matched = ip.map { address in payload.contains { IPCIDR($0)?.contains(address) ?? false } } ?? false
                }
            default:
                XCTFail("unexpected rule \(line)")
                return nil
            }
            if matched {
                switch target {
                case MihomoConfigCompiler.directTarget: return .direct
                case MihomoConfigCompiler.rejectTarget: return .block
                default: return .tunnel
                }
            }
        }
        return nil
    }
}
