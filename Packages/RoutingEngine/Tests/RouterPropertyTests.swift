// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

/// Generates rule tables and requests from a small vocabulary so that rules
/// overlap often: a property test over disjoint rules would prove nothing.
struct RoutingFuzzer {
    var rng: LCG
    /// Rules that match (nearly) everything - a bare NOT, an empty AND - are
    /// only generated near the end of a table; earlier they would make every
    /// later rule unreachable and the comparison trivial.
    var allowCatchAll = false

    static let topLevel = ["com", "org", "net", "io"]
    static let second = ["example", "test", "ads", "cdn", "mail", "google"]
    static let third = ["www", "api", "a", "b", "img"]
    static let keywords = ["ad", "mail", "oo", "cdn.", "x", "e.c", "-"]
    static let patterns = [
        "^a", "ads?\\.", "\\.io$", "^(www|api)\\.", "[0-9]", "t.st", "^[a-z]+\\.[a-z]+$",
        "(?i)MAIL", "^.{12,}$", "img.*org$",
    ]
    static let ruleSetTags = ["set0", "set1", "set2", "set3"]

    init(seed: UInt64) {
        rng = LCG(seed: seed)
    }

    mutating func domain() -> String {
        var labels: [String] = []
        let depth = rng.below(4)
        if depth >= 3 { labels.append(rng.pick(RoutingFuzzer.third) + (rng.chance(10) ? "\(rng.below(10))" : "")) }
        if depth >= 2 { labels.append(rng.pick(RoutingFuzzer.third)) }
        if depth >= 1 { labels.append(rng.pick(RoutingFuzzer.second)) }
        labels.append(rng.pick(RoutingFuzzer.topLevel))
        return labels.joined(separator: ".")
    }

    mutating func v4() -> UInt32 {
        let top: UInt32 = rng.chance(85) ? 10 : 172
        return (top << 24) | (UInt32(rng.below(4)) << 16) | (UInt32(rng.below(4)) << 8) | UInt32(rng.below(256))
    }

    mutating func v6() -> (high: UInt64, low: UInt64) {
        let high = UInt64(0x2001_0DB8_0000_0000) | (UInt64(rng.below(4)) << 16) | UInt64(rng.below(4))
        let low = rng.chance(50) ? rng.bits64() : (UInt64(rng.below(4)) << 62)
        return (high, low)
    }

    mutating func cidr() -> IPCIDR {
        let made: IPCIDR?
        if rng.chance(65) {
            made = IPCIDR(address: .v4(v4()), prefixLength: rng.pick([0, 8, 15, 16, 16, 20, 22, 22, 24, 24, 24, 28, 32, 32]))
        } else {
            let address = v6()
            made = IPCIDR(
                address: .v6(high: address.high, low: address.low),
                prefixLength: rng.pick([0, 32, 47, 48, 48, 56, 64, 64, 65, 96, 128, 128])
            )
        }
        guard let value = made else {
            // Unreachable: every length above is valid for its family.
            preconditionFailure("generator produced an invalid prefix")
        }
        return value
    }

    mutating func portRange() -> PortRange {
        if rng.chance(50) {
            return PortRange(UInt16(rng.pick([53, 80, 443, 8080, rng.below(2100)])))
        }
        let lower = rng.below(2000)
        let upper = min(65535, lower + rng.below(rng.chance(90) ? 300 : 60000))
        return PortRange(lower: UInt16(lower), upper: UInt16(upper)) ?? PortRange(UInt16(lower))
    }

    mutating func atom(allowNonIndexable: Bool) -> RuleCondition {
        switch rng.below(allowNonIndexable ? 10 : 7) {
        case 0: return .domain(domain())
        case 1, 2: return .domainSuffix((rng.chance(25) ? "." : "") + domain())
        case 3, 4: return .ipCIDR(cidr())
        case 5: return .port(portRange())
        case 6: return .network(rng.chance(50) ? .tcp : .udp)
        case 7, 8: return .domainKeyword(rng.pick(RoutingFuzzer.keywords))
        default: return .domainRegex(rng.pick(RoutingFuzzer.patterns))
        }
    }

    mutating func condition(depth: Int, allowNonIndexable: Bool) -> RuleCondition {
        if depth >= 3 || rng.chance(65) {
            return atom(allowNonIndexable: allowNonIndexable)
        }
        if !allowNonIndexable {
            if rng.chance(40) {
                return .ruleSet(rng.pick(RoutingFuzzer.ruleSetTags))
            }
            return .or(children(depth: depth, minimum: 1, allowNonIndexable: false))
        }
        switch rng.below(6) {
        case 0:
            return .ruleSet(rng.pick(RoutingFuzzer.ruleSetTags))
        case 1:
            return .or(children(depth: depth, minimum: 1, allowNonIndexable: true))
        case 2, 3:
            var members = children(depth: depth, minimum: 2, allowNonIndexable: true)
            if rng.chance(40) {
                members.append(.not(condition(depth: depth + 1, allowNonIndexable: true)))
            }
            return .and(members)
        case 4:
            return .or([
                .and(children(depth: depth + 1, minimum: 1, allowNonIndexable: true)),
                atom(allowNonIndexable: true),
            ])
        default:
            if allowCatchAll {
                switch rng.below(3) {
                case 0: return .not(condition(depth: depth + 1, allowNonIndexable: true))
                case 1: return .and([])
                default: return .or([])
                }
            }
            return .and([atom(allowNonIndexable: true), .not(atom(allowNonIndexable: true))])
        }
    }

    mutating func children(depth: Int, minimum: Int, allowNonIndexable: Bool) -> [RuleCondition] {
        var result: [RuleCondition] = []
        let count = minimum + rng.below(3)
        for _ in 0..<count {
            result.append(condition(depth: depth + 1, allowNonIndexable: allowNonIndexable))
        }
        return result
    }

    mutating func action() -> RouteAction {
        switch rng.below(6) {
        case 0: return .direct
        case 1: return .reject
        case 2: return .group("auto")
        case 3: return .chain(["hop\(rng.below(3))", "exit"])
        default: return .proxy("p\(rng.below(5))")
        }
    }

    mutating func table(ruleCount: Int, allowNonIndexable: Bool) -> RoutingTable {
        var ruleSets: [RuleSet] = []
        for tag in RoutingFuzzer.ruleSetTags {
            var members: [RuleCondition] = []
            let size = 3 + rng.below(20)
            for _ in 0..<size {
                members.append(atom(allowNonIndexable: allowNonIndexable))
            }
            ruleSets.append(RuleSet(tag: tag, conditions: members))
        }
        var rules: [RoutingRule] = []
        rules.reserveCapacity(ruleCount)
        for number in 0..<ruleCount {
            allowCatchAll = number >= ruleCount * 4 / 5
            rules.append(RoutingRule(
                id: "r\(number)",
                condition: condition(depth: 0, allowNonIndexable: allowNonIndexable),
                action: action(),
                isEnabled: !rng.chance(5)
            ))
        }
        allowCatchAll = false
        return RoutingTable(rules: rules, ruleSets: ruleSets, finalAction: .proxy("final"))
    }

    mutating func request() -> RouteRequest {
        var host: String?
        if rng.chance(80) {
            var name = domain()
            if rng.chance(10) { name = name.uppercased() }
            if rng.chance(10) { name += "." }
            host = name
        }
        var ip: IPAddress?
        if rng.chance(60) {
            if rng.chance(60) {
                ip = .v4(v4())
            } else if rng.chance(15) {
                // IPv4-mapped IPv6 must behave exactly like the IPv4 address.
                ip = .v6(high: 0, low: 0x0000_FFFF_0000_0000 | UInt64(v4()))
            } else {
                let address = v6()
                ip = .v6(high: address.high, low: address.low)
            }
        }
        let port: UInt16? = rng.chance(80) ? UInt16(rng.pick([53, 80, 443, 8080, rng.below(2400)])) : nil
        let network: NetworkKind? = rng.chance(70) ? (rng.chance(60) ? .tcp : .udp) : nil
        return RouteRequest(domain: host, ip: ip, port: port, network: network)
    }
}

final class RouterPropertyTests: XCTestCase {
    private func describe(_ decision: RouteDecision) -> String {
        if let index = decision.ruleIndex {
            return "rule #\(index)"
        }
        return "final"
    }

    /// Runs `requestCount` requests through both matchers and returns how
    /// many distinct rules won, failing on the first few disagreements.
    private func compare(
        table: RoutingTable,
        fuzzer: inout RoutingFuzzer,
        requestCount: Int,
        label: String
    ) throws -> (distinctWinners: Int, finals: Int) {
        let compiled = try CompiledRouter(table: table)
        let linear = try LinearRouteMatcher(table: table)
        let simulator = RouteSimulator(router: compiled, traceLimit: 4)
        var winners = Set<Int>()
        var finals = 0
        var mismatches = 0
        for step in 0..<requestCount {
            let request = fuzzer.request()
            let expected = linear.match(request)
            let actual = compiled.match(request)
            if actual != expected {
                mismatches += 1
                if mismatches <= 5 {
                    XCTFail("\(label): \(request): indexed \(describe(actual)) vs linear \(describe(expected))")
                }
            }
            if let index = expected.ruleIndex {
                winners.insert(index)
            } else {
                finals += 1
            }
            // The simulator must report the same decision as the router.
            if step % 7 == 0 {
                let explanation = simulator.explain(request)
                if explanation.decision != actual {
                    XCTFail("\(label): explain disagrees with match for \(request)")
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(label): \(mismatches) of \(requestCount) requests disagree")
        return (winners.count, finals)
    }

    /// Mixed tables: every condition kind, nesting, rule sets, disabled rules.
    func testIndexedMatcherEqualsLinearReferenceOnMixedTables() throws {
        var fuzzer = RoutingFuzzer(seed: 0x5EED_2026_1124)
        var totalRules = 0
        var totalRequests = 0
        var totalWinners = 0
        for round in 0..<6 {
            let table = fuzzer.table(ruleCount: 500, allowNonIndexable: true)
            totalRules += table.rules.count
            let result = try compare(table: table, fuzzer: &fuzzer, requestCount: 700, label: "mixed round \(round)")
            totalRequests += 700
            totalWinners += result.distinctWinners
        }
        // Sanity: the generator must produce contested tables, otherwise
        // agreement would be trivial.
        XCTAssertGreaterThan(totalWinners, 12, "too few distinct winning rules")
        XCTAssertEqual(totalRules, 3000)
        XCTAssertEqual(totalRequests, 4200)
    }

    /// Tables without keyword / regex / AND / NOT: everything goes through
    /// the tries and the port index, nothing through the fallback list.
    func testIndexedMatcherEqualsLinearReferenceOnFullyIndexedTables() throws {
        var fuzzer = RoutingFuzzer(seed: 0x0BAD_C0DE_0042)
        var totalWinners = 0
        for round in 0..<4 {
            let table = fuzzer.table(ruleCount: 600, allowNonIndexable: false)
            let compiled = try CompiledRouter(table: table)
            XCTAssertEqual(compiled.statistics.fallbackRules, 0, "round \(round) must be fully indexed")
            let result = try compare(table: table, fuzzer: &fuzzer, requestCount: 800, label: "indexed round \(round)")
            totalWinners += result.distinctWinners
        }
        XCTAssertGreaterThan(totalWinners, 12, "too few distinct winning rules")
    }

    /// Sparse tables: few rules, so the final action and late rules win often.
    func testIndexedMatcherEqualsLinearReferenceOnSparseTables() throws {
        var fuzzer = RoutingFuzzer(seed: 0x7777_0000_1234)
        var finals = 0
        for round in 0..<40 {
            let table = fuzzer.table(ruleCount: 1 + fuzzer.rng.below(12), allowNonIndexable: true)
            let result = try compare(table: table, fuzzer: &fuzzer, requestCount: 60, label: "sparse round \(round)")
            finals += result.finals
        }
        XCTAssertGreaterThan(finals, 50, "the final action must be exercised too")
    }

    /// The generator itself must be deterministic, otherwise failures could
    /// not be reproduced.
    func testFuzzerIsDeterministic() {
        var first = RoutingFuzzer(seed: 42)
        var second = RoutingFuzzer(seed: 42)
        XCTAssertEqual(first.table(ruleCount: 50, allowNonIndexable: true), second.table(ruleCount: 50, allowNonIndexable: true))
        for _ in 0..<50 {
            XCTAssertEqual(first.request(), second.request())
        }
        var other = RoutingFuzzer(seed: 43)
        XCTAssertNotEqual(first.table(ruleCount: 50, allowNonIndexable: true), other.table(ruleCount: 50, allowNonIndexable: true))
    }
}

final class RouterPerformanceTests: XCTestCase {
    private static let suffixRuleCount = 100_000

    private func bigTable() -> RoutingTable {
        var rules: [RoutingRule] = []
        rules.reserveCapacity(RouterPerformanceTests.suffixRuleCount)
        for number in 0..<RouterPerformanceTests.suffixRuleCount {
            rules.append(RoutingRule(
                condition: .domainSuffix("h\(number).s\(number % 1000).zone\(number % 7).test"),
                action: .proxy("p\(number % 4)")
            ))
        }
        return RoutingTable(rules: rules, finalAction: .direct)
    }

    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    func testHundredThousandSuffixRules() throws {
        let table = bigTable()
        var compiledRouter: CompiledRouter?
        let compileTime = try seconds {
            compiledRouter = try CompiledRouter(table: table)
        }
        let router = try XCTUnwrap(compiledRouter)
        XCTAssertEqual(router.statistics.ruleCount, RouterPerformanceTests.suffixRuleCount)
        XCTAssertEqual(router.statistics.fallbackRules, 0)

        // Correctness on hits (the expected index is known by construction)
        // and on misses.
        let lookups = 20_000
        var requests: [RouteRequest] = []
        var expected: [Int?] = []
        requests.reserveCapacity(lookups)
        for step in 0..<lookups {
            let number = (step * 7919) % RouterPerformanceTests.suffixRuleCount
            if step % 4 == 3 {
                // Same shape, but the zone label does not match any rule.
                requests.append(RouteRequest(domain: "www.h\(number).s\(number % 1000).zone9.test"))
                expected.append(nil)
            } else {
                let prefix = step % 2 == 0 ? "www.cdn." : ""
                requests.append(RouteRequest(domain: "\(prefix)h\(number).s\(number % 1000).zone\(number % 7).test"))
                expected.append(number)
            }
        }

        var wrong = 0
        let indexedTime = seconds {
            for (position, request) in requests.enumerated() {
                if router.match(request).ruleIndex != expected[position] { wrong += 1 }
            }
        }
        XCTAssertEqual(wrong, 0)

        // Reference: a linear scan over the same table for a handful of
        // requests that match late rules (or nothing).
        let linear = router.reference
        var sample: [RouteRequest] = []
        for number in stride(from: 99_990, to: 99_999, by: 3) {
            sample.append(RouteRequest(domain: "x.h\(number).s\(number % 1000).zone\(number % 7).test"))
        }
        sample.append(RouteRequest(domain: "no.such.domain.example"))

        var linearResults: [RouteDecision] = []
        let linearTime = seconds {
            for request in sample {
                linearResults.append(linear.match(request))
            }
        }
        var indexedResults: [RouteDecision] = []
        // Repeat the indexed lookups so that the measured interval is not
        // dominated by timer resolution.
        let repeats = 200
        let indexedSampleTime = seconds {
            for round in 0..<repeats {
                for request in sample {
                    let decision = router.match(request)
                    if round == 0 { indexedResults.append(decision) }
                }
            }
        }
        XCTAssertEqual(indexedResults, linearResults)

        let perLookupIndexed = indexedSampleTime / Double(repeats * sample.count)
        let perLookupLinear = linearTime / Double(sample.count)
        print("""
        [RoutingEngine perf] rules=\(RouterPerformanceTests.suffixRuleCount) \
        compile=\(compileTime)s trieNodes=\(router.statistics.domainTrieNodes) \
        \(lookups) lookups=\(indexedTime)s indexed/lookup=\(perLookupIndexed)s linear/lookup=\(perLookupLinear)s
        """)

        // Generous absolute bounds (debug builds on slow CI machines) plus a
        // relative bound that actually proves the index is used.
        XCTAssertLessThan(compileTime, 120, "compiling 100k suffix rules is unreasonably slow")
        XCTAssertLessThan(indexedTime, 30, "20k lookups in a 100k-rule table are unreasonably slow")
        XCTAssertLessThan(
            perLookupIndexed * 20,
            perLookupLinear,
            "the indexed matcher must be at least 20x faster than a linear scan on 100k rules"
        )
    }

    func testLookupCostDoesNotGrowWithRuleCount() throws {
        // Same lookups against 1k and 100k rules: with an index the cost per
        // lookup depends on the name, not on the table size.
        func table(_ count: Int) -> RoutingTable {
            var rules: [RoutingRule] = []
            rules.reserveCapacity(count)
            for number in 0..<count {
                rules.append(RoutingRule(condition: .domainSuffix("h\(number).grow.test"), action: .reject))
            }
            return RoutingTable(rules: rules)
        }
        let small = try CompiledRouter(table: table(1_000))
        let large = try CompiledRouter(table: table(100_000))
        var requests: [RouteRequest] = []
        for number in 0..<1_000 {
            requests.append(RouteRequest(domain: "a.h\(number).grow.test"))
        }
        func run(_ router: CompiledRouter) -> Double {
            var hits = 0
            let time = seconds {
                for _ in 0..<20 {
                    for request in requests where router.match(request).ruleIndex != nil {
                        hits += 1
                    }
                }
            }
            XCTAssertEqual(hits, 20 * requests.count)
            return time
        }
        _ = run(small) // warm-up
        let smallTime = run(small)
        let largeTime = run(large)
        print("[RoutingEngine perf] 20k lookups: 1k rules \(smallTime)s, 100k rules \(largeTime)s")
        // A linear matcher would be ~100x slower on the large table; allow a
        // wide margin for cache effects and noisy machines.
        XCTAssertLessThan(largeTime, smallTime * 10 + 0.5)
    }
}
