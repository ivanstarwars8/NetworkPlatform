// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation
@testable import RoutingEngine

// The corpus of the differential test against the engine's real router.
//
// It is generated deterministically here, evaluated by `CompiledRouter`, and
// stored as JSON in `Benchmarks/RoutingParity/testdata/corpus.json`. The Go
// harness next to that file feeds the same flat rules and requests to the
// engine's router and compares the decisions. The file format is neutral:
// no engine configuration syntax appears in it.

struct CorpusDomain: Codable, Equatable {
    var kind: String
    var value: String
}

struct CorpusPortRange: Codable, Equatable {
    var lower: Int
    var upper: Int
}

struct CorpusRule: Codable, Equatable {
    var tag: String
    var action: String
    var domains: [CorpusDomain]?
    var ips: [String]?
    var excludedIPs: [String]?
    var ports: [CorpusPortRange]?
    var networks: [String]?
    var sourceIPs: [String]?
    var sourcePorts: [CorpusPortRange]?
    var inboundTags: [String]?
    var users: [String]?
    var protocols: [String]?
}

struct CorpusDecision: Codable, Equatable {
    /// Index of the winning rule; absent for the final action.
    var rule: Int?
    var action: String
}

struct CorpusRequest: Codable, Equatable {
    var domain: String?
    var ip: String?
    var resolvedIPs: [String]?
    var port: Int?
    var network: String?
    var sourceIP: String?
    var sourcePort: Int?
    var inboundTag: String?
    var user: String?
    var `protocol`: String?
    var swift: CorpusDecision
    /// Absent: the engine must agree. "differ": a documented difference.
    var expect: String?
    var reason: String?
}

struct CorpusTable: Codable, Equatable {
    var name: String
    var domainStrategy: String
    /// `false`: there is no catch-all rule and "no rule matched" in the
    /// engine means the final action (its default outbound).
    var finalIsRule: Bool
    var finalAction: String
    var groups: [String: [String]]
    var rules: [CorpusRule]
    var requests: [CorpusRequest]
}

struct Corpus: Codable, Equatable {
    var version: Int
    var tables: [CorpusTable]

    /// One JSON value per line, so that diffs of the stored file stay
    /// readable. Decoding does not depend on the layout.
    func encodedText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func line<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var text = "{\"version\":\(version),\"tables\":[\n"
        for (tableIndex, table) in tables.enumerated() {
            text += "{\"name\":\(try line(table.name)),\"domainStrategy\":\(try line(table.domainStrategy)),"
            text += "\"finalIsRule\":\(table.finalIsRule),\"finalAction\":\(try line(table.finalAction)),"
            text += "\"groups\":\(try line(table.groups)),\n\"rules\":[\n"
            text += try table.rules.map { try line($0) }.joined(separator: ",\n")
            text += "\n],\n\"requests\":[\n"
            text += try table.requests.map { try line($0) }.joined(separator: ",\n")
            text += "\n]}" + (tableIndex == tables.count - 1 ? "\n" : ",\n")
        }
        text += "]}\n"
        return text
    }
}

enum CorpusText {
    static func action(_ action: RouteAction) -> String {
        switch action {
        case .direct: return "direct"
        case .reject: return "reject"
        case let .proxy(tag): return "proxy:" + tag
        case let .group(tag): return "group:" + tag
        case let .chain(tags): return "chain:" + tags.joined(separator: ">")
        }
    }

    static func ranges(_ ranges: [PortRange]) -> [CorpusPortRange]? {
        ranges.isEmpty ? nil : ranges.map { CorpusPortRange(lower: Int($0.lower), upper: Int($0.upper)) }
    }

    static func list(_ values: [String]) -> [String]? {
        values.isEmpty ? nil : values
    }

    static func rule(_ rule: FlatRule) -> CorpusRule {
        CorpusRule(
            tag: rule.tag,
            action: action(rule.action),
            domains: rule.domains.isEmpty ? nil : rule.domains.map { CorpusDomain(kind: $0.kind.rawValue, value: $0.value) },
            ips: list(rule.ips.map { "\($0)" }),
            excludedIPs: list(rule.excludedIPs.map { "\($0)" }),
            ports: ranges(rule.ports),
            networks: list(rule.networks.map { $0.rawValue }),
            sourceIPs: list(rule.sourceIPs.map { "\($0)" }),
            sourcePorts: ranges(rule.sourcePorts),
            inboundTags: list(rule.inboundTags),
            users: list(rule.users),
            protocols: list(rule.sniffedProtocols)
        )
    }

    /// `rawDomain` is the name as it would arrive at the engine (before the
    /// request normalisation done by `RouteRequest`).
    static func request(
        _ request: RouteRequest,
        rawDomain: String?,
        decision: RouteDecision,
        expect: String? = nil,
        reason: String? = nil
    ) -> CorpusRequest {
        CorpusRequest(
            domain: rawDomain,
            ip: request.ip.map { "\($0)" },
            resolvedIPs: list(request.resolvedIPs.map { "\($0)" }),
            port: request.port.map { Int($0) },
            network: request.network?.rawValue,
            sourceIP: request.sourceIP.map { "\($0)" },
            sourcePort: request.sourcePort.map { Int($0) },
            inboundTag: request.inboundTag,
            user: request.user,
            protocol: request.sniffedProtocol,
            swift: CorpusDecision(rule: decision.ruleIndex, action: action(decision.action)),
            expect: expect,
            reason: reason
        )
    }
}

/// Generates tables every rule of which has a flat form, from a small
/// vocabulary so that rules overlap and priorities matter.
struct ParityGenerator {
    var rng: LCG

    static let groups: [String: [String]] = ["auto": ["node-a", "node-b"], "solo": ["node-c"]]

    static let topLevel = ["com", "org", "net", "io"]
    static let second = ["example", "test", "ads", "cdn", "mail", "google"]
    static let third = ["www", "api", "a", "b", "img"]
    static let keywords = ["ad", "mail", "oo", "cdn.", "x", "e.c", "-", "API"]
    static let patterns = [
        "^a", "ads?\\.", "\\.io$", "^(www|api)\\.", "[0-9]", "t.st", "^[a-z]+\\.[a-z]+$",
        "(?i)MAIL", "^.{12,}$", "img.*org$", "^UPPER", "\\.(com|net)$", "^[^.]+$", "a{2,3}|b\\d",
    ]
    static let inbounds = ["tun", "socks-in", "http-in"]
    static let users = ["alice@example.com", "bob", "Bob"]
    static let protocols = ["http", "tls", "quic", "bittorrent", "http1", "h"]
    static let sniffed = ["http1", "http2", "tls", "quic", "bittorrent", "dns"]

    init(seed: UInt64) {
        rng = LCG(seed: seed)
    }

    mutating func domain() -> String {
        var labels: [String] = []
        let depth = rng.below(4)
        if depth >= 3 { labels.append(rng.pick(ParityGenerator.third) + (rng.chance(10) ? "\(rng.below(10))" : "")) }
        if depth >= 2 { labels.append(rng.pick(ParityGenerator.third)) }
        if depth >= 1 { labels.append(rng.pick(ParityGenerator.second)) }
        labels.append(rng.pick(ParityGenerator.topLevel))
        return labels.joined(separator: ".")
    }

    mutating func v4() -> IPAddress {
        let top: UInt32 = rng.pick([10, 10, 10, 172, 192])
        return .v4((top << 24) | (UInt32(rng.below(4)) << 16) | (UInt32(rng.below(4)) << 8) | UInt32(rng.below(256)))
    }

    mutating func v6() -> IPAddress {
        let high = UInt64(0x2001_0DB8_0000_0000) | (UInt64(rng.below(4)) << 16) | UInt64(rng.below(4))
        let low = rng.chance(50) ? rng.bits64() : (UInt64(rng.below(4)) << 62)
        return .v6(high: high, low: low)
    }

    mutating func address() -> IPAddress {
        rng.chance(70) ? v4() : v6()
    }

    mutating func cidr() -> IPCIDR {
        let made: IPCIDR?
        if rng.chance(65) {
            made = IPCIDR(address: v4(), prefixLength: rng.pick([0, 8, 15, 16, 16, 20, 22, 22, 24, 24, 24, 28, 32, 32]))
        } else {
            made = IPCIDR(address: v6(), prefixLength: rng.pick([0, 32, 47, 48, 48, 56, 64, 64, 65, 96, 128, 128]))
        }
        guard let value = made else { preconditionFailure("generator produced an invalid prefix") }
        return value
    }

    mutating func portRange() -> PortRange {
        if rng.chance(50) {
            return PortRange(UInt16(rng.pick([0, 53, 80, 443, 8080, rng.below(2100)])))
        }
        let lower = rng.below(2000)
        let upper = min(65535, lower + rng.below(rng.chance(90) ? 300 : 60000))
        return PortRange(lower: UInt16(lower), upper: UInt16(upper)) ?? PortRange(UInt16(lower))
    }

    /// Engine fields; a conjunction takes at most one leaf group per field.
    enum Field: CaseIterable {
        case domain, address, port, network, sourceAddress, sourcePort, inbound, user, sniffed
    }

    mutating func leaf(_ field: Field) -> RuleCondition {
        switch field {
        case .domain:
            switch rng.below(10) {
            case 0, 1: return .domain(domain())
            case 2, 3, 4: return .domainSuffix(domain())
            case 5: return .domainSuffix("." + domain())
            case 6, 7: return .domainKeyword(rng.pick(ParityGenerator.keywords))
            default: return .domainRegex(rng.pick(ParityGenerator.patterns))
            }
        case .address:
            if rng.chance(22) {
                var prefixes: [IPCIDR] = []
                for _ in 0..<(1 + rng.below(3)) { prefixes.append(cidr()) }
                return .ipNotIn(prefixes)
            }
            return .ipCIDR(cidr())
        case .port: return .port(portRange())
        case .network: return .network(rng.chance(50) ? .tcp : .udp)
        case .sourceAddress: return .sourceCIDR(cidr())
        case .sourcePort: return .sourcePort(portRange())
        case .inbound: return .inboundTag(rng.pick(ParityGenerator.inbounds))
        case .user: return .user(rng.pick(ParityGenerator.users))
        case .sniffed: return .sniffedProtocol(rng.pick(ParityGenerator.protocols))
        }
    }

    mutating func commonField() -> Field {
        rng.pick([.domain, .domain, .domain, .address, .address, .port, .network, .sourceAddress, .sourcePort, .inbound, .user, .sniffed])
    }

    /// One field: a leaf or an OR of leaves of that field.
    mutating func group(_ field: Field) -> RuleCondition {
        if rng.chance(60) { return leaf(field) }
        var items: [RuleCondition] = []
        for _ in 0..<(2 + rng.below(3)) { items.append(leaf(field)) }
        return .or(items)
    }

    mutating func conjunction() -> RuleCondition {
        var fields = Field.allCases
        var items: [RuleCondition] = []
        for _ in 0..<(2 + rng.below(2)) {
            let field = fields.remove(at: rng.below(fields.count))
            items.append(group(field))
        }
        return .and(items)
    }

    /// Mostly address rules: tables made of these leave domain requests
    /// unmatched without resolution, which is what the domain strategies
    /// differ on.
    mutating func addressCondition() -> RuleCondition {
        switch rng.below(10) {
        case 0...4: return leaf(.address)
        case 5: return group(.address)
        case 6: return .and([leaf(.address), leaf(.network)])
        case 7: return .and([group(.address), leaf(.port)])
        case 8: return .domainSuffix(domain())
        default: return .and([leaf(.domain), leaf(.address)])
        }
    }

    mutating func condition(allowCatchAll: Bool) -> RuleCondition {
        switch rng.below(20) {
        case 0...6: return leaf(commonField())
        case 7...9: return group(commonField())
        case 10...13: return conjunction()
        case 14, 15:
            // OR over different fields: lowers to several flat rules.
            return .or([leaf(commonField()), conjunction(), leaf(commonField())])
        case 16: return .ruleSet(rng.pick(["set0", "set1", "set2"]))
        case 17:
            // AND over an OR of conjunction-free alternatives of two fields.
            return .and([.or([leaf(.domain), leaf(.domain)]), .or([leaf(.port), leaf(.port)]), leaf(.network)])
        case 18: return .or([])
        default:
            return allowCatchAll ? .and([]) : leaf(.domain)
        }
    }

    mutating func action() -> RouteAction {
        switch rng.below(8) {
        case 0: return .direct
        case 1: return .reject
        case 2: return .group("auto")
        case 3: return .group("solo")
        case 4: return .chain(["hop\(rng.below(3))", "exit"])
        default: return .proxy("p\(rng.below(5))")
        }
    }

    mutating func addressTable(ruleCount: Int, strategy: DomainStrategy) -> RoutingTable {
        var rules: [RoutingRule] = []
        for number in 0..<ruleCount {
            rules.append(RoutingRule(id: "r\(number)", condition: addressCondition(), action: action()))
        }
        return RoutingTable(rules: rules, finalAction: .proxy("final"), domainStrategy: strategy)
    }

    mutating func table(ruleCount: Int, strategy: DomainStrategy) -> RoutingTable {
        var ruleSets: [RuleSet] = []
        for tag in ["set0", "set1", "set2"] {
            // A rule set is an OR, so its members may be of any field.
            var members: [RuleCondition] = []
            let sameField = rng.chance(50) ? commonField() : nil
            for _ in 0..<(3 + rng.below(12)) {
                members.append(leaf(sameField ?? commonField()))
            }
            ruleSets.append(RuleSet(tag: tag, conditions: members))
        }
        var rules: [RoutingRule] = []
        for number in 0..<ruleCount {
            rules.append(RoutingRule(
                id: "r\(number)",
                condition: condition(allowCatchAll: number >= ruleCount * 9 / 10),
                action: action(),
                isEnabled: !rng.chance(5)
            ))
        }
        // With ipIfNonMatch the final action has to be a single outbound.
        let final: RouteAction = strategy == .ipIfNonMatch ? .proxy("final") : (rng.chance(50) ? .proxy("final") : .group("solo"))
        return RoutingTable(rules: rules, ruleSets: ruleSets, finalAction: final, domainStrategy: strategy)
    }

    /// A request the engine can be given: it has a destination (domain or
    /// address) and a network. Returns the raw domain text too.
    mutating func request() -> (request: RouteRequest, rawDomain: String?) {
        var host: String?
        if rng.chance(75) {
            var name = domain()
            if rng.chance(10) { name = name.uppercased() }
            if rng.chance(8) { name += "." }
            host = name
        }
        var ip: IPAddress?
        if host == nil || rng.chance(25) {
            ip = address()
            if rng.chance(10), case let .v4(value) = ip ?? .v4(0) {
                // IPv4-mapped IPv6 must behave exactly like the IPv4 address.
                ip = .v6(high: 0, low: 0x0000_FFFF_0000_0000 | UInt64(value))
            }
        }
        var resolved: [IPAddress] = []
        if host != nil, rng.chance(75) {
            for _ in 0..<(1 + rng.below(3)) { resolved.append(address()) }
        }
        let port: UInt16? = rng.chance(92) ? UInt16(rng.pick([0, 53, 80, 443, 8080, rng.below(2400)])) : nil
        var sourceIP: IPAddress?
        var sourcePort: UInt16?
        if rng.chance(60) {
            sourceIP = address()
            sourcePort = rng.chance(85) ? UInt16(rng.pick([53, 80, 443, 8080, rng.below(2400)])) : nil
        }
        let request = RouteRequest(
            domain: host,
            ip: ip,
            port: port,
            network: rng.chance(65) ? .tcp : .udp,
            resolvedIPs: resolved,
            sourceIP: sourceIP,
            sourcePort: sourcePort,
            inboundTag: rng.chance(70) ? rng.pick(ParityGenerator.inbounds) : nil,
            user: rng.chance(40) ? rng.pick(ParityGenerator.users + ["carol"]) : nil,
            sniffedProtocol: rng.chance(50) ? rng.pick(ParityGenerator.sniffed) : nil
        )
        return (request, host)
    }
}

/// Builds the whole corpus. Also returns the tables so that tests can
/// cross-check the three Swift evaluators on them.
enum ParityCorpusBuilder {
    struct Built {
        var corpus: Corpus
        var tables: [(table: RoutingTable, lowered: LoweredTable, requests: [RouteRequest])]
    }

    static func corpusTable(
        name: String,
        table: RoutingTable,
        requests: [(request: RouteRequest, rawDomain: String?, expect: String?, reason: String?)]
    ) throws -> (CorpusTable, LoweredTable) {
        let lowered = try RuleLowering.lower(table)
        precondition(lowered.isLossless, "corpus table \(name) has rules without a flat form: \(lowered.issues)")
        let router = try CompiledRouter(table: table)
        let encoded = requests.map {
            CorpusText.request($0.request, rawDomain: $0.rawDomain, decision: router.match($0.request), expect: $0.expect, reason: $0.reason)
        }
        let result = CorpusTable(
            name: name,
            domainStrategy: table.domainStrategy.rawValue,
            finalIsRule: lowered.finalIsCatchAllRule,
            finalAction: CorpusText.action(table.finalAction),
            groups: ParityGenerator.groups,
            rules: lowered.rules.map { CorpusText.rule($0) },
            requests: encoded
        )
        return (result, lowered)
    }

    static func build() throws -> Built {
        var built = Built(corpus: Corpus(version: 1, tables: []), tables: [])
        var generator = ParityGenerator(seed: 0x2026_1125_C0DE)

        let plan: [(String, DomainStrategy, Int, Int)] = [
            ("mixed-asis-1", .asIs, 40, 420),
            ("mixed-asis-2", .asIs, 90, 420),
            ("mixed-ipifnonmatch-1", .ipIfNonMatch, 40, 420),
            ("mixed-ipifnonmatch-2", .ipIfNonMatch, 90, 420),
            ("mixed-ipondemand-1", .ipOnDemand, 40, 420),
            ("mixed-ipondemand-2", .ipOnDemand, 90, 420),
            ("sparse-asis", .asIs, 6, 150),
            ("sparse-ipifnonmatch", .ipIfNonMatch, 6, 150),
            ("sparse-ipondemand", .ipOnDemand, 6, 150),
            ("address-asis", .asIs, 14, 260),
            ("address-ipifnonmatch", .ipIfNonMatch, 14, 260),
            ("address-ipondemand", .ipOnDemand, 14, 260),
        ]
        for (name, strategy, ruleCount, requestCount) in plan {
            let table = name.hasPrefix("address-")
                ? generator.addressTable(ruleCount: ruleCount, strategy: strategy)
                : generator.table(ruleCount: ruleCount, strategy: strategy)
            var requests: [(request: RouteRequest, rawDomain: String?, expect: String?, reason: String?)] = []
            for _ in 0..<requestCount {
                let made = generator.request()
                requests.append((made.request, made.rawDomain, nil, nil))
            }
            let (encoded, lowered) = try corpusTable(name: name, table: table, requests: requests)
            built.corpus.tables.append(encoded)
            built.tables.append((table, lowered, requests.map { $0.request }))
        }

        let (edges, edgesLowered, edgeTable, edgeRequests) = try edgeCases()
        built.corpus.tables.append(edges)
        built.tables.append((edgeTable, edgesLowered, edgeRequests))
        let (known, knownLowered, knownTable, knownRequests) = try knownDifferences()
        built.corpus.tables.append(known)
        built.tables.append((knownTable, knownLowered, knownRequests))
        return built
    }

    private static func cidr(_ text: String) -> IPCIDR {
        guard let value = IPCIDR(text) else { preconditionFailure("bad corpus prefix \(text)") }
        return value
    }

    private static func ip(_ text: String) -> IPAddress {
        guard let value = IPAddress(text) else { preconditionFailure("bad corpus address \(text)") }
        return value
    }

    /// Hand-written cases for the behaviours found while comparing with the
    /// engine; the engine must agree on all of them.
    static func edgeCases() throws -> (CorpusTable, LoweredTable, RoutingTable, [RouteRequest]) {
        let table = RoutingTable(rules: [
            makeRule(.domain("Exact.Example.com."), .proxy("full")),
            makeRule(.domainSuffix("example.org"), .proxy("suffix")),
            makeRule(.domainSuffix(".strict.net"), .proxy("strict")),
            makeRule(.domainRegex("^UP"), .proxy("regex-upper")),
            makeRule(.domainRegex("(?i)^MiX"), .proxy("regex-fold")),
            makeRule(.domainKeyword("KeyW"), .proxy("keyword")),
            makeRule(.port(PortRange(lower: 0, upper: 10) ?? PortRange(0)), .proxy("low-port")),
            makeRule(.ipNotIn([cidr("fc00::/7")]), .proxy("not-ula")),
            makeRule(.ipNotIn([cidr("10.0.0.0/8"), cidr("192.168.0.0/16")]), .proxy("not-private")),
            makeRule(.sniffedProtocol("http"), .proxy("http")),
            makeRule(.and([.inboundTag("tun"), .user("bob"), .sourceCIDR(cidr("10.0.0.0/8"))]), .group("auto")),
            makeRule(.or([.ipCIDR(cidr("192.168.0.0/16")), .ipNotIn([cidr("192.0.0.0/8")]), .ipNotIn([cidr("2001:db8::/32")])]), .proxy("mixed-ip")),
            makeRule(.ipCIDR(cidr("::ffff:192.168.7.0/120")), .proxy("mapped-prefix")),
        ], finalAction: .group("solo"), domainStrategy: .asIs)

        func request(
            _ domain: String? = nil, ip address: String? = nil, port: UInt16? = 443, network: NetworkKind = .tcp,
            source: String? = nil, inbound: String? = nil, user: String? = nil, sniffed: String? = nil
        ) -> (request: RouteRequest, rawDomain: String?, expect: String?, reason: String?) {
            (RouteRequest(
                domain: domain, ip: address.map { ip($0) }, port: port, network: network,
                sourceIP: source.map { ip($0) }, inboundTag: inbound, user: user, sniffedProtocol: sniffed
            ), domain, nil, nil)
        }
        let requests = [
            request("exact.example.com"),
            request("EXACT.EXAMPLE.COM"),
            request("exact.example.com."),
            request("a.example.org"),
            request("a.example.org."),
            request("badexample.org"),
            request("x.strict.net"),
            request("strict.net"),
            request("x..strict.net"),
            request("upper.com"),
            request("mixed.com"),
            request("xkeywx.com"),
            request("noport.com", port: nil),
            request("zero.com", port: 0),
            request(ip: "9.9.9.9"),
            request(ip: "2001:db8::1"),
            request(ip: "fc00::1"),
            request(ip: "10.1.1.1"),
            request(ip: "192.168.7.7"),
            request(ip: "::ffff:192.168.7.7"),
            request(ip: "192.0.2.1"),
            request(ip: "::ffff:9.9.9.9"),
            request("plain.com", sniffed: "http1"),
            request("plain.com", sniffed: "tls"),
            request("plain.com", sniffed: "h"),
            request("plain.com", source: "10.9.9.9", inbound: "tun", user: "bob"),
            request("plain.com", source: "10.9.9.9", inbound: "tun", user: "Bob"),
            request("plain.com", source: "11.9.9.9", inbound: "tun", user: "bob"),
            request("plain.com", network: .udp),
        ]
        let (encoded, lowered) = try corpusTable(name: "edge-cases", table: table, requests: requests)
        return (encoded, lowered, table, requests.map { $0.request })
    }

    /// Requests on which the simulator and the engine are known to differ.
    /// The Go harness checks that they really do, so that this list cannot
    /// silently go stale. Each one is explained in routing-parity.md.
    static func knownDifferences() throws -> (CorpusTable, LoweredTable, RoutingTable, [RouteRequest]) {
        let table = RoutingTable(rules: [
            makeRule(.domainKeyword("example"), .proxy("keyword")),
            makeRule(.port(PortRange(lower: 0, upper: 10) ?? PortRange(0)), .proxy("low-port")),
        ], finalAction: .proxy("final"), domainStrategy: .asIs)
        let overlong = String(repeating: "a", count: 260) + ".example.com"
        let requests: [(request: RouteRequest, rawDomain: String?, expect: String?, reason: String?)] = [
            (RouteRequest(domain: "www.example.com", port: 443), "www.example.com", "differ",
             "K1: a request without a transport network. The engine then has no destination at all "
                + "(no domain, port 0); the simulator still evaluates the fields it was given."),
            (RouteRequest(domain: overlong, port: 443, network: .tcp), overlong, "differ",
             "K2: a name longer than 253 bytes is not a DNS name; the simulator drops it, the engine matches it as text."),
            (RouteRequest(domain: "my example.com", port: 443, network: .tcp), "my example.com", "differ",
             "K3: a name with whitespace is dropped by the simulator; the engine matches it as text."),
        ]
        let (encoded, lowered) = try corpusTable(name: "known-differences", table: table, requests: requests)
        return (encoded, lowered, table, requests.map { $0.request })
    }
}
