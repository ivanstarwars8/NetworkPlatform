// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

func makeRule(_ condition: RuleCondition, _ action: RouteAction, id: String? = nil, enabled: Bool = true) -> RoutingRule {
    RoutingRule(id: id, condition: condition, action: action, isEnabled: enabled)
}

func makeCIDR(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> IPCIDR {
    try XCTUnwrap(IPCIDR(text), "bad test CIDR \(text)", file: file, line: line)
}

func makeIP(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> IPAddress {
    try XCTUnwrap(IPAddress(text), "bad test address \(text)", file: file, line: line)
}

final class RouterTests: XCTestCase {
    /// Four rules, one per lookup structure, in a deliberately mixed order.
    private func mixedTable() throws -> RoutingTable {
        RoutingTable(
            rules: [
                makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .reject, id: "lan"),
                makeRule(.domainSuffix("example.com"), .proxy("a"), id: "example"),
                makeRule(.port(PortRange(443)), .direct, id: "https"),
                makeRule(.domainKeyword("ads"), .reject, id: "ads"),
            ],
            finalAction: .group("auto")
        )
    }

    func testFirstMatchWinsAcrossIndexes() throws {
        let router = try CompiledRouter(table: try mixedTable())

        let all = RouteRequest(domain: "www.example.com", ip: try makeIP("10.1.1.1"), port: 443, network: .tcp)
        XCTAssertEqual(router.match(all), RouteDecision(action: .reject, ruleIndex: 0))

        let noIP = RouteRequest(domain: "www.example.com", port: 443)
        XCTAssertEqual(router.match(noIP), RouteDecision(action: .proxy("a"), ruleIndex: 1))

        let portBeforeKeyword = RouteRequest(domain: "ads.test", port: 443)
        XCTAssertEqual(router.match(portBeforeKeyword), RouteDecision(action: .direct, ruleIndex: 2))

        let keyword = RouteRequest(domain: "ads.test", port: 80)
        XCTAssertEqual(router.match(keyword), RouteDecision(action: .reject, ruleIndex: 3))

        let nothing = RouteRequest(domain: "x.test", port: 80)
        let decision = router.match(nothing)
        XCTAssertEqual(decision, RouteDecision(action: .group("auto"), ruleIndex: nil))
        XCTAssertTrue(decision.isFinal)

        XCTAssertEqual(router.match(RouteRequest()), RouteDecision(action: .group("auto"), ruleIndex: nil))
    }

    func testFallbackRuleBeatsLaterIndexedRule() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainKeyword("track"), .reject),
            makeRule(.domainSuffix("example.com"), .direct),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "track.example.com")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "www.example.com")).ruleIndex, 1)
        XCTAssertNil(router.match(RouteRequest(domain: "example.org")).ruleIndex)
    }

    func testDomainSemantics() throws {
        let table = RoutingTable(rules: [
            makeRule(.domain("exact.example.org"), .proxy("exact")),
            makeRule(.domainSuffix(".strict.test"), .proxy("strict")),
            makeRule(.domainSuffix("example.com"), .proxy("suffix")),
            makeRule(.domainRegex("^cdn[0-9]+\\."), .proxy("regex")),
        ])
        let router = try CompiledRouter(table: table)
        func index(_ domain: String) -> Int? {
            router.match(RouteRequest(domain: domain)).ruleIndex
        }
        XCTAssertEqual(index("exact.example.org"), 0)
        XCTAssertNil(index("www.exact.example.org"))
        XCTAssertNil(index("example.org"))

        XCTAssertEqual(index("a.strict.test"), 1)
        XCTAssertEqual(index("a.b.strict.test"), 1)
        XCTAssertNil(index("strict.test"))
        XCTAssertNil(index("notstrict.test"))

        XCTAssertEqual(index("example.com"), 2)
        XCTAssertEqual(index("a.b.example.com"), 2)
        XCTAssertNil(index("badexample.com"))
        XCTAssertNil(index("example.com.evil.test"))

        XCTAssertEqual(index("cdn42.something.net"), 3)
        XCTAssertNil(index("cdn.something.net"))
    }

    func testRequestNormalisation() throws {
        let table = RoutingTable(rules: [
            makeRule(.domain("WWW.Example.COM"), .reject),
            makeRule(.domainSuffix("Example.ORG."), .reject),
            makeRule(.domainKeyword("TRACK"), .reject),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "www.example.com")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "WWW.EXAMPLE.COM.")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "A.example.org")).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(domain: "my-Tracker.net")).ruleIndex, 2)

        XCTAssertEqual(RouteRequest(domain: "WWW.Example.COM.").domain, "www.example.com")
        XCTAssertNil(RouteRequest(domain: "").domain)
        XCTAssertNil(RouteRequest(domain: ".").domain)
        XCTAssertNil(RouteRequest(domain: "bad host").domain)
        // Overlong names cannot be DNS names and are dropped.
        let overlong = String(repeating: "a", count: 300) + ".example.com"
        XCTAssertNil(RouteRequest(domain: overlong).domain)
        XCTAssertTrue(router.match(RouteRequest(domain: overlong)).isFinal)
    }

    func testIPRules() throws {
        let table = RoutingTable(rules: [
            makeRule(.ipCIDR(try makeCIDR("192.168.0.0/16")), .direct),
            makeRule(.ipCIDR(try makeCIDR("2001:db8::/32")), .proxy("v6")),
            makeRule(.ipCIDR(try makeCIDR("0.0.0.0/0")), .proxy("any4")),
        ], finalAction: .reject)
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("192.168.7.7"))).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("2001:db8:1::5"))).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("8.8.8.8"))).ruleIndex, 2)
        XCTAssertNil(router.match(RouteRequest(ip: try makeIP("2001:db9::1"))).ruleIndex)
        // IPv4-mapped IPv6 destinations are routed as IPv4.
        let mapped = RouteRequest(ip: try makeIP("::ffff:192.168.7.7"))
        XCTAssertEqual(mapped.ip, try makeIP("192.168.7.7"))
        XCTAssertEqual(router.match(mapped).ruleIndex, 0)
        // A request with only a domain matches no IP rule.
        XCTAssertNil(router.match(RouteRequest(domain: "example.com")).ruleIndex)
    }

    func testLowerIndexWinsOverLongerPrefix() throws {
        let table = RoutingTable(rules: [
            makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .direct),
            makeRule(.ipCIDR(try makeCIDR("10.1.0.0/16")), .reject),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("10.1.2.3"))).ruleIndex, 0)

        let reversed = RoutingTable(rules: [
            makeRule(.ipCIDR(try makeCIDR("10.1.0.0/16")), .reject),
            makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .direct),
        ])
        let reversedRouter = try CompiledRouter(table: reversed)
        XCTAssertEqual(reversedRouter.match(RouteRequest(ip: try makeIP("10.1.2.3"))).ruleIndex, 0)
        XCTAssertEqual(reversedRouter.match(RouteRequest(ip: try makeIP("10.2.2.3"))).ruleIndex, 1)
    }

    func testPortAndNetworkRules() throws {
        let range = try XCTUnwrap(PortRange(lower: 6881, upper: 6889))
        let table = RoutingTable(rules: [
            makeRule(.port(range), .reject),
            makeRule(.network(.udp), .proxy("udp")),
            makeRule(.port(PortRange(53)), .direct),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(port: 6881, network: .udp)).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(port: 6889, network: .tcp)).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(port: 6890, network: .udp)).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(port: 53, network: .udp)).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(port: 53, network: .tcp)).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(port: 53)).ruleIndex, 2)
        XCTAssertNil(router.match(RouteRequest(port: 80, network: .tcp)).ruleIndex)
        XCTAssertNil(router.match(RouteRequest(network: .tcp)).ruleIndex)
    }

    func testLogicalRules() throws {
        let table = RoutingTable(rules: [
            makeRule(.and([.domainSuffix("example.com"), .port(PortRange(443))]), .proxy("and")),
            makeRule(.and([.domainSuffix("example.com"), .not(.network(.udp))]), .proxy("not")),
            makeRule(.or([.domain("a.test"), .domainKeyword("zzz"), .ipCIDR(try makeCIDR("192.168.0.0/16"))]), .proxy("or")),
            makeRule(.domainSuffix("test"), .proxy("suffix")),
            makeRule(.and([]), .proxy("always")),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "example.com", port: 443, network: .udp)).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "example.com", port: 80, network: .tcp)).ruleIndex, 1)
        // A missing field makes the positive condition false, so NOT holds.
        XCTAssertEqual(router.match(RouteRequest(domain: "example.com", port: 80)).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(domain: "a.test")).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(domain: "zzz.test")).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("192.168.1.1"))).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(domain: "b.test")).ruleIndex, 3)
        // Rule 4 is an empty AND: it matches everything that got this far.
        XCTAssertEqual(router.match(RouteRequest(domain: "example.com", port: 80, network: .udp)).ruleIndex, 4)
        XCTAssertEqual(router.match(RouteRequest()).ruleIndex, 4)
    }

    func testEmptyOrNeverMatches() throws {
        let table = RoutingTable(rules: [makeRule(.or([]), .reject)], finalAction: .direct)
        let router = try CompiledRouter(table: table)
        XCTAssertTrue(router.match(RouteRequest(domain: "example.com", port: 1)).isFinal)
        XCTAssertEqual(router.statistics.fallbackRules, 0)
    }

    func testRuleSets() throws {
        let table = RoutingTable(
            rules: [
                makeRule(.ruleSet("block"), .reject),
                makeRule(.and([.ruleSet("lan"), .port(PortRange(22))]), .direct),
                makeRule(.not(.ruleSet("ads")), .proxy("clean")),
            ],
            ruleSets: [
                RuleSet(tag: "ads", conditions: [.domainSuffix("ads.example"), .domainKeyword("adserver")]),
                RuleSet(tag: "lan", conditions: [.ipCIDR(try makeCIDR("10.0.0.0/8")), .ipCIDR(try makeCIDR("fd00::/8"))]),
                RuleSet(tag: "block", conditions: [.ruleSet("ads"), .domain("blocked.test")]),
            ],
            finalAction: .direct
        )
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "x.ads.example")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "my-adserver.net")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "blocked.test")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("10.0.0.5"), port: 22)).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("fd12::1"), port: 22)).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(ip: try makeIP("10.0.0.5"), port: 23)).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(domain: "fine.test")).ruleIndex, 2)
        // Rule 0 is a mixed OR: the suffix and exact parts are indexed, the
        // keyword part stays in the fallback list; rules 1 and 2 are fallback.
        XCTAssertEqual(router.statistics.fallbackRules, 3)
    }

    func testRuleSetErrors() throws {
        let unknown = RoutingTable(rules: [makeRule(.ruleSet("nope"), .reject)])
        XCTAssertThrowsError(try CompiledRouter(table: unknown)) { error in
            XCTAssertEqual(error as? RoutingCompileError, .unknownRuleSet(ruleIndex: 0, tag: "nope"))
        }

        let cyclic = RoutingTable(
            rules: [makeRule(.domain("ok.test"), .direct), makeRule(.ruleSet("a"), .reject)],
            ruleSets: [
                RuleSet(tag: "a", conditions: [.ruleSet("b")]),
                RuleSet(tag: "b", conditions: [.not(.ruleSet("a"))]),
            ]
        )
        XCTAssertThrowsError(try CompiledRouter(table: cyclic)) { error in
            XCTAssertEqual(error as? RoutingCompileError, .ruleSetCycle(ruleIndex: 1, tag: "a"))
        }

        let selfReference = RoutingTable(
            rules: [makeRule(.ruleSet("a"), .reject)],
            ruleSets: [RuleSet(tag: "a", conditions: [.ruleSet("a")])]
        )
        XCTAssertThrowsError(try CompiledRouter(table: selfReference)) { error in
            XCTAssertEqual(error as? RoutingCompileError, .ruleSetCycle(ruleIndex: 0, tag: "a"))
        }

        let duplicate = RoutingTable(
            rules: [],
            ruleSets: [RuleSet(tag: "a", conditions: []), RuleSet(tag: "a", conditions: [])]
        )
        XCTAssertThrowsError(try CompiledRouter(table: duplicate)) { error in
            XCTAssertEqual(error as? RoutingCompileError, .duplicateRuleSet(tag: "a"))
        }
    }

    func testDisabledRulesKeepTheirIndex() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainSuffix("com"), .reject, enabled: false),
            makeRule(.domainSuffix("com"), .direct),
            makeRule(.domainKeyword("x"), .reject, enabled: false),
        ], finalAction: .proxy("p"))
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "example.com")), RouteDecision(action: .direct, ruleIndex: 1))
        XCTAssertTrue(router.match(RouteRequest(domain: "x.org")).isFinal)
        XCTAssertEqual(router.statistics.ruleCount, 3)
        XCTAssertEqual(router.statistics.enabledRuleCount, 1)
        XCTAssertEqual(router.statistics.fallbackRules, 0)
    }

    func testDisabledRulesAreStillValidated() {
        let table = RoutingTable(rules: [makeRule(.domainRegex("("), .reject, enabled: false)])
        XCTAssertThrowsError(try CompiledRouter(table: table))
    }

    func testActionsAreReturnedVerbatim() throws {
        let table = RoutingTable(rules: [
            makeRule(.domain("chain.test"), .chain(["hop1", "hop2", "exit"])),
            makeRule(.domain("group.test"), .group("auto")),
        ], finalAction: .proxy("default"))
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "chain.test")).action, .chain(["hop1", "hop2", "exit"]))
        XCTAssertEqual(router.match(RouteRequest(domain: "group.test")).action, .group("auto"))
        XCTAssertEqual(router.match(RouteRequest(domain: "none.test")).action, .proxy("default"))
        XCTAssertEqual(router.referencedTags, ["hop1", "hop2", "exit", "auto", "default"])
        XCTAssertEqual(RouteAction.chain(["a", "b"]).description, "chain(a -> b)")
    }

    func testInvalidInputIsRejectedAtCompileTime() throws {
        func compileError(_ table: RoutingTable, limits: RoutingLimits = .standard) -> RoutingCompileError? {
            do {
                _ = try CompiledRouter(table: table, limits: limits)
                return nil
            } catch {
                return error as? RoutingCompileError
            }
        }
        func single(_ condition: RuleCondition, _ action: RouteAction = .direct) -> RoutingTable {
            RoutingTable(rules: [makeRule(.domain("ok.test"), .direct), makeRule(condition, action)])
        }

        XCTAssertEqual(compileError(single(.domain(""))), .invalidDomain(ruleIndex: 1, value: ""))
        XCTAssertEqual(compileError(single(.domain("bad host"))), .invalidDomain(ruleIndex: 1, value: "bad host"))
        XCTAssertEqual(compileError(single(.domainSuffix("."))), .invalidDomain(ruleIndex: 1, value: "."))
        XCTAssertEqual(compileError(single(.domainSuffix(""))), .invalidDomain(ruleIndex: 1, value: ""))
        XCTAssertEqual(compileError(single(.domainSuffix("..com"))), .invalidDomain(ruleIndex: 1, value: "..com"))
        let longName = String(repeating: "a", count: 254)
        XCTAssertEqual(compileError(single(.domain(longName))), .invalidDomain(ruleIndex: 1, value: longName))
        XCTAssertEqual(compileError(single(.domainKeyword(""))), .invalidKeyword(ruleIndex: 1, value: ""))

        if case let .invalidRegex(ruleIndex, pattern, _)? = compileError(single(.domainRegex("(unclosed"))) {
            XCTAssertEqual(ruleIndex, 1)
            XCTAssertEqual(pattern, "(unclosed")
        } else {
            XCTFail("expected invalidRegex")
        }
        if case .invalidRegex? = compileError(single(.domainRegex("(?=look)ahead"))) {
            // Unsupported syntax must be an error, never a silent mismatch.
        } else {
            XCTFail("expected invalidRegex for lookahead")
        }

        if case let .invalidAction(ruleIndex, _)? = compileError(single(.domain("a.test"), .proxy(""))) {
            XCTAssertEqual(ruleIndex, 1)
        } else {
            XCTFail("expected invalidAction for empty tag")
        }
        if case .invalidAction? = compileError(single(.domain("a.test"), .chain([]))) {
        } else {
            XCTFail("expected invalidAction for empty chain")
        }
        let longChain = [String](repeating: "hop", count: RouteAction.maximumChainLength + 1)
        if case .invalidAction? = compileError(single(.domain("a.test"), .chain(longChain))) {
        } else {
            XCTFail("expected invalidAction for long chain")
        }
        if case let .invalidAction(ruleIndex, _)? = compileError(RoutingTable(finalAction: .group(""))) {
            XCTAssertNil(ruleIndex)
        } else {
            XCTFail("expected invalidAction for the final action")
        }

        var small = RoutingLimits()
        small.maximumRules = 1
        XCTAssertEqual(compileError(single(.domain("a.test")), limits: small), .tooManyRules(count: 2, limit: 1))

        var nested: RuleCondition = .domain("deep.test")
        for _ in 0..<20 {
            nested = .not(nested)
        }
        XCTAssertEqual(compileError(single(nested)), .conditionTooDeep(ruleIndex: 1, limit: 16))

        var tiny = RoutingLimits()
        tiny.maximumConditionNodes = 3
        let wide = single(.or([.domain("a.test"), .domain("b.test"), .domain("c.test")]))
        XCTAssertEqual(compileError(wide, limits: tiny), .tableTooLarge(limit: 3))

        var noSets = RoutingLimits()
        noSets.maximumRuleSets = 0
        let withSet = RoutingTable(ruleSets: [RuleSet(tag: "a", conditions: [])])
        XCTAssertEqual(compileError(withSet, limits: noSets), .tooManyRuleSets(count: 1, limit: 0))

        XCTAssertFalse(RoutingCompileError.invalidDomain(ruleIndex: 1, value: "x").description.isEmpty)
    }

    func testDepthLimitAllowsReasonableNesting() throws {
        var nested: RuleCondition = .domain("deep.test")
        for _ in 0..<16 {
            nested = .not(nested)
        }
        let router = try CompiledRouter(table: RoutingTable(rules: [makeRule(nested, .reject)]))
        // Sixteen negations cancel out.
        XCTAssertEqual(router.match(RouteRequest(domain: "deep.test")).ruleIndex, 0)
        XCTAssertNil(router.match(RouteRequest(domain: "other.test")).ruleIndex)
    }

    func testTableCodableRoundTrip() throws {
        let table = RoutingTable(
            rules: [
                makeRule(.domain("a.test"), .direct, id: "one"),
                makeRule(.domainSuffix(".b.test"), .reject),
                makeRule(.domainKeyword("kw"), .proxy("p")),
                makeRule(.domainRegex("^x+$"), .group("g")),
                makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .chain(["a", "b"])),
                makeRule(.ipCIDR(try makeCIDR("2001:db8::/32")), .direct),
                makeRule(.port(try XCTUnwrap(PortRange(lower: 1, upper: 1024))), .direct),
                makeRule(.network(.udp), .reject, enabled: false),
                makeRule(.and([.ruleSet("s"), .not(.or([.network(.tcp), .port(PortRange(80))]))]), .direct),
            ],
            ruleSets: [RuleSet(tag: "s", conditions: [.domainSuffix("s.test")])],
            finalAction: .group("final")
        )
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(RoutingTable.self, from: data)
        XCTAssertEqual(decoded, table)
        XCTAssertNoThrow(try CompiledRouter(table: decoded))
    }

    func testStatistics() throws {
        let router = try CompiledRouter(table: try mixedTable())
        XCTAssertEqual(router.statistics.ruleCount, 4)
        XCTAssertEqual(router.statistics.enabledRuleCount, 4)
        XCTAssertEqual(router.statistics.cidrEntries, 1)
        XCTAssertEqual(router.statistics.fallbackRules, 1)
        // root + "com" + "example"
        XCTAssertEqual(router.statistics.domainTrieNodes, 3)
        // [0, 443) none, [443, 444) rule, [444, 65536) none
        XCTAssertEqual(router.statistics.portSegments, 3)
        XCTAssertEqual(router.rules.count, 4)
        XCTAssertEqual(router.finalAction, .group("auto"))
    }

    func testLinearMatcherAgreesOnHandWrittenTable() throws {
        let table = try mixedTable()
        let router = try CompiledRouter(table: table)
        let linear = try LinearRouteMatcher(table: table)
        let requests = [
            RouteRequest(domain: "www.example.com", ip: try makeIP("10.1.1.1"), port: 443, network: .tcp),
            RouteRequest(domain: "www.example.com", port: 443),
            RouteRequest(domain: "ads.test", port: 443),
            RouteRequest(domain: "ads.test", port: 80),
            RouteRequest(domain: "x.test", port: 80),
            RouteRequest(),
        ]
        for request in requests {
            XCTAssertEqual(router.match(request), linear.match(request), "\(request)")
        }
    }

    // MARK: Hit counters

    func testHitCounters() throws {
        let router = try CompiledRouter(table: try mixedTable())
        let counters = HitCounters(ruleCount: router.rules.count)
        _ = router.match(RouteRequest(domain: "www.example.com"), counters: counters)
        _ = router.match(RouteRequest(domain: "example.com"), counters: counters)
        _ = router.match(RouteRequest(port: 443), counters: counters)
        _ = router.match(RouteRequest(domain: "nothing.test"), counters: counters)

        XCTAssertEqual(counters.hits(forRule: 0), 0)
        XCTAssertEqual(counters.hits(forRule: 1), 2)
        XCTAssertEqual(counters.hits(forRule: 2), 1)
        XCTAssertEqual(counters.finalActionHits, 1)
        XCTAssertEqual(counters.snapshot().ruleHits, [0, 2, 1, 0])
        XCTAssertEqual(counters.snapshot().total, 4)
        // Out-of-range indexes are ignored rather than trapping.
        XCTAssertEqual(counters.hits(forRule: 99), 0)
        XCTAssertEqual(counters.hits(forRule: -1), 0)
        counters.record(RouteDecision(action: .direct, ruleIndex: 99))
        XCTAssertEqual(counters.snapshot().total, 4)

        counters.reset()
        XCTAssertEqual(counters.snapshot().total, 0)
        XCTAssertEqual(counters.finalActionHits, 0)
    }

    func testHitCountersAreThreadSafe() throws {
        let router = try CompiledRouter(table: try mixedTable())
        let counters = HitCounters(ruleCount: router.rules.count)
        let requests = [
            RouteRequest(domain: "www.example.com"),
            RouteRequest(port: 443),
            RouteRequest(domain: "ads.net"),
            RouteRequest(domain: "nothing.test"),
        ]
        let workers = 8
        let perWorker = 2000
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for step in 0..<perWorker {
                _ = router.match(requests[(worker + step) % requests.count], counters: counters)
            }
        }
        let snapshot = counters.snapshot()
        XCTAssertEqual(snapshot.total, UInt64(workers * perWorker))
        // Every worker cycles evenly through the four requests.
        let each = UInt64(workers * perWorker / requests.count)
        XCTAssertEqual(snapshot.ruleHits, [0, each, each, each])
        XCTAssertEqual(snapshot.finalActionHits, each)
    }
}
