// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

/// Semantics that were aligned with the engine's router, the lowering to
/// flat rules, and the stored corpus of the differential test.
final class EngineParityTests: XCTestCase {
    private func cidr(_ text: String) throws -> IPCIDR { try makeCIDR(text) }
    private func ip(_ text: String) throws -> IPAddress { try makeIP(text) }

    // MARK: Request semantics

    func testRequestDomainIsLowercasedAndKeepsTrailingDot() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainSuffix("Example.COM."), .proxy("suffix")),
            makeRule(.domainKeyword("example"), .proxy("keyword")),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(domain: "WWW.EXAMPLE.COM")).ruleIndex, 0)
        // The rule value loses its dot at compile time; the request keeps it
        // and therefore only the keyword rule sees a match.
        XCTAssertEqual(router.match(RouteRequest(domain: "www.example.com.")).ruleIndex, 1)
    }

    func testMissingPortIsPortZero() throws {
        let range = try XCTUnwrap(PortRange(lower: 0, upper: 1023))
        let table = RoutingTable(rules: [
            makeRule(.sourcePort(PortRange(0)), .proxy("source-zero")),
            makeRule(.port(range), .proxy("low")),
        ])
        let router = try CompiledRouter(table: table)
        let linear = try LinearRouteMatcher(table: table)
        for request in [RouteRequest(domain: "a.test", sourcePort: 5), RouteRequest(domain: "a.test", port: 0, sourcePort: 5)] {
            XCTAssertEqual(router.match(request).ruleIndex, 1)
            XCTAssertEqual(linear.match(request).ruleIndex, 1)
        }
        XCTAssertEqual(router.match(RouteRequest(domain: "a.test", port: 2000)).ruleIndex, 0)
        XCTAssertTrue(router.match(RouteRequest(domain: "a.test", port: 2000, sourcePort: 7)).isFinal)
    }

    func testSourceInboundUserAndProtocolConditions() throws {
        let table = RoutingTable(rules: [
            makeRule(.inboundTag("tun"), .proxy("inbound")),
            makeRule(.user("bob"), .proxy("user")),
            makeRule(.sniffedProtocol("http"), .proxy("protocol")),
            makeRule(.sourceCIDR(try cidr("10.0.0.0/8")), .proxy("source")),
        ])
        let router = try CompiledRouter(table: table)
        XCTAssertEqual(router.match(RouteRequest(inboundTag: "tun")).ruleIndex, 0)
        XCTAssertTrue(router.match(RouteRequest(inboundTag: "TUN")).isFinal)
        XCTAssertEqual(router.match(RouteRequest(user: "bob")).ruleIndex, 1)
        XCTAssertTrue(router.match(RouteRequest(user: "Bob")).isFinal)
        // The protocol value is a prefix of the sniffed name.
        XCTAssertEqual(router.match(RouteRequest(sniffedProtocol: "http1")).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(sniffedProtocol: "http")).ruleIndex, 2)
        XCTAssertTrue(router.match(RouteRequest(sniffedProtocol: "tls")).isFinal)
        XCTAssertTrue(router.match(RouteRequest(sniffedProtocol: "h")).isFinal)
        XCTAssertEqual(router.match(RouteRequest(sourceIP: try ip("10.2.3.4"))).ruleIndex, 3)
        XCTAssertEqual(router.match(RouteRequest(sourceIP: try ip("::ffff:10.2.3.4"))).ruleIndex, 3)
        XCTAssertTrue(router.match(RouteRequest(ip: try ip("10.2.3.4"))).isFinal)

        XCTAssertThrowsError(try CompiledRouter(table: RoutingTable(rules: [makeRule(.inboundTag(""), .direct)])))
        XCTAssertThrowsError(try CompiledRouter(table: RoutingTable(rules: [makeRule(.ipNotIn([]), .direct)])))
    }

    func testIPNotInFollowsTheEngine() throws {
        let table = RoutingTable(rules: [
            makeRule(.ipNotIn([try cidr("fc00::/7")]), .proxy("not-ula")),
            makeRule(.ipNotIn([try cidr("10.0.0.0/8"), try cidr("192.168.0.0/16")]), .proxy("not-private")),
        ])
        let router = try CompiledRouter(table: table)
        // No target address: a negated address match is false, unlike NOT.
        XCTAssertTrue(router.match(RouteRequest(domain: "example.com")).isFinal)
        // An IPv4 address is not considered by a list without IPv4 prefixes.
        XCTAssertEqual(router.match(RouteRequest(ip: try ip("9.9.9.9"))).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(ip: try ip("2001:db8::1"))).ruleIndex, 0)
        XCTAssertTrue(router.match(RouteRequest(ip: try ip("fc00::1"))).isFinal)
        XCTAssertTrue(router.match(RouteRequest(ip: try ip("10.1.1.1"))).isFinal)

        let negated = try CompiledRouter(table: RoutingTable(rules: [
            makeRule(.not(.ipCIDR(try cidr("10.0.0.0/8"))), .proxy("boolean-not")),
        ]))
        XCTAssertEqual(negated.match(RouteRequest(domain: "example.com")).ruleIndex, 0)
    }

    func testDomainStrategies() throws {
        func table(_ strategy: DomainStrategy) throws -> RoutingTable {
            RoutingTable(rules: [
                makeRule(.ipCIDR(try cidr("10.0.0.0/8")), .proxy("lan")),
                makeRule(.domainSuffix("late.com"), .proxy("domain")),
                makeRule(.ipNotIn([try cidr("192.168.0.0/16"), try cidr("172.16.0.0/12")]), .proxy("public")),
            ], finalAction: .direct, domainStrategy: strategy)
        }
        let lan = [try ip("10.1.1.1")]
        let hidden = RouteRequest(domain: "late.com", resolvedIPs: lan)
        let other = RouteRequest(domain: "other.com", resolvedIPs: lan)
        let mixed = RouteRequest(domain: "other.com", resolvedIPs: [try ip("192.168.1.1"), try ip("8.8.8.8")])
        let allPrivate = RouteRequest(domain: "other.com", resolvedIPs: [try ip("192.168.1.1"), try ip("172.16.0.1")])
        let failed = RouteRequest(domain: "other.com", ip: try ip("192.168.2.2"))
        let sniffed = RouteRequest(domain: "other.com", ip: try ip("10.2.2.2"), resolvedIPs: [try ip("8.8.8.8")])

        for strategy in DomainStrategy.allCases {
            let compiled = try CompiledRouter(table: try table(strategy))
            let linear = try LinearRouteMatcher(table: try table(strategy))
            for request in [hidden, other, mixed, allPrivate, failed, sniffed] {
                XCTAssertEqual(compiled.match(request), linear.match(request), "\(strategy) \(request)")
            }
        }

        let asIs = try CompiledRouter(table: try table(.asIs))
        XCTAssertEqual(asIs.match(hidden).ruleIndex, 1)
        XCTAssertTrue(asIs.match(other).isFinal)
        XCTAssertTrue(asIs.match(mixed).isFinal)
        XCTAssertEqual(asIs.match(sniffed).ruleIndex, 0)

        let ifNonMatch = try CompiledRouter(table: try table(.ipIfNonMatch))
        // The domain rule wins on the first pass although an earlier address
        // rule would match the resolved address.
        XCTAssertEqual(ifNonMatch.match(hidden).ruleIndex, 1)
        XCTAssertFalse(ifNonMatch.match(hidden).usedSecondPass)
        XCTAssertEqual(ifNonMatch.match(other).ruleIndex, 0)
        XCTAssertTrue(ifNonMatch.match(other).usedSecondPass)
        // Any resolved address may satisfy an address rule.
        XCTAssertEqual(ifNonMatch.match(mixed).ruleIndex, 2)
        XCTAssertTrue(ifNonMatch.match(allPrivate).isFinal)
        // Failed resolution: the second pass sees the destination address.
        XCTAssertTrue(ifNonMatch.match(failed).isFinal)
        // A destination address is used on the first pass, unresolved.
        XCTAssertEqual(ifNonMatch.match(sniffed).ruleIndex, 0)
        XCTAssertFalse(ifNonMatch.match(sniffed).usedSecondPass)

        let onDemand = try CompiledRouter(table: try table(.ipOnDemand))
        // Address rules see resolved addresses from the first rule on.
        XCTAssertEqual(onDemand.match(hidden).ruleIndex, 0)
        XCTAssertEqual(onDemand.match(other).ruleIndex, 0)
        XCTAssertEqual(onDemand.match(mixed).ruleIndex, 2)
        // A successful lookup replaces the destination address.
        XCTAssertEqual(onDemand.match(sniffed).ruleIndex, 2)
        XCTAssertTrue(onDemand.match(failed).isFinal)

        let explanation = RouteSimulator(router: ifNonMatch).explain(other)
        XCTAssertEqual(explanation.decision, ifNonMatch.match(other))
        XCTAssertTrue(explanation.text.contains("second pass"), explanation.text)
    }

    func testTableWithoutDomainStrategyDecodesAsAsIs() throws {
        let json = #"{"rules":[],"ruleSets":[],"finalAction":{"direct":{}}}"#
        let table = try JSONDecoder().decode(RoutingTable.self, from: Data(json.utf8))
        XCTAssertEqual(table.domainStrategy, .asIs)
        let encoded = try JSONEncoder().encode(RoutingTable(domainStrategy: .ipOnDemand))
        XCTAssertEqual(try JSONDecoder().decode(RoutingTable.self, from: encoded).domainStrategy, .ipOnDemand)
    }

    // MARK: Lowering

    func testLoweringShapes() throws {
        let table = RoutingTable(rules: [
            makeRule(.or([.domain("A.test"), .domainSuffix("b.test"), .domainKeyword("KW")]), .direct),
            makeRule(.or([.domain("a.test"), .port(PortRange(53)), .domainSuffix("c.test")]), .reject),
            makeRule(.and([.or([.domainSuffix("x.test"), .domainSuffix(".y.test")]), .network(.udp), .port(PortRange(443))]), .proxy("p")),
            makeRule(.and([]), .proxy("all"), enabled: false),
            makeRule(.or([]), .proxy("never")),
            makeRule(.or([.ipCIDR(try cidr("10.0.0.0/8")), .ipNotIn([try cidr("192.168.0.0/16")]), .ipNotIn([try cidr("172.16.0.0/12")])]), .group("g")),
            makeRule(.and([]), .proxy("all")),
        ], finalAction: .group("g"))
        let lowered = try RuleLowering.lower(table)
        XCTAssertTrue(lowered.isLossless)
        XCTAssertTrue(lowered.finalIsCatchAllRule)
        XCTAssertEqual(lowered.rules.map { $0.tag }, ["r0.0", "r1.0", "r1.1", "r1.2", "r2.0", "r5.0", "r5.1", "r6.0", "final"])

        XCTAssertEqual(lowered.rules[0].domains, [
            FlatDomain(kind: .full, value: "a.test"),
            FlatDomain(kind: .suffix, value: "b.test"),
            FlatDomain(kind: .keyword, value: "kw"),
        ])
        XCTAssertEqual(lowered.rules[2].ports, [PortRange(53)])
        XCTAssertEqual(lowered.rules[4].domains, [
            FlatDomain(kind: .suffix, value: "x.test"),
            FlatDomain(kind: .regex, value: "^.+\\.y\\.test$"),
        ])
        XCTAssertEqual(lowered.rules[4].networks, [.udp])
        XCTAssertEqual(lowered.rules[4].ports, [PortRange(443)])
        // A positive list and one exclusion list share a rule; the second
        // exclusion list needs its own.
        XCTAssertEqual(lowered.rules[5].ips.count, 1)
        XCTAssertEqual(lowered.rules[5].excludedIPs, [try cidr("192.168.0.0/16")])
        XCTAssertEqual(lowered.rules[6].excludedIPs, [try cidr("172.16.0.0/12")])
        XCTAssertEqual(lowered.rules[7].networks, [.tcp, .udp])
        XCTAssertEqual(lowered.rules[8].action, .group("g"))
        XCTAssertNil(lowered.rules[8].sourceRuleIndex)
    }

    func testLoweringReportsWhatHasNoFlatForm() throws {
        let table = RoutingTable(rules: [
            makeRule(.not(.network(.udp)), .direct),
            makeRule(.and([.domainSuffix("a.test"), .domainKeyword("b")]), .direct),
            makeRule(.and([.ipCIDR(try cidr("10.0.0.0/8")), .ipNotIn([try cidr("10.1.0.0/16")])]), .direct),
            makeRule(.domain("ok.test"), .direct),
        ], finalAction: .group("g"), domainStrategy: .ipIfNonMatch)
        let lowered = try RuleLowering.lower(table)
        XCTAssertFalse(lowered.isLossless)
        XCTAssertFalse(lowered.finalIsCatchAllRule)
        XCTAssertEqual(lowered.rules.map { $0.tag }, ["r3.0"])
        XCTAssertEqual(lowered.issues.map { $0.ruleIndex }, [0, 1, 2, nil])
        XCTAssertEqual(lowered.issues.map { $0.kind }, [
            .negation, .sameFieldConjunction, .sameFieldConjunction, .finalGroupNeedsCatchAll,
        ])

        // More alternatives than the limit are refused, not truncated.
        var alternatives: [RuleCondition] = []
        for number in 0...RuleLowering.maximumPartsPerRule {
            alternatives.append(number % 2 == 0 ? .domain("a\(number).test") : .port(PortRange(UInt16(number))))
        }
        let wide = try RuleLowering.lower(RoutingTable(rules: [makeRule(.or(alternatives), .direct)]))
        XCTAssertEqual(wide.issues.map { $0.kind }, [.tooManyAlternatives])
        XCTAssertEqual(wide.rules.map { $0.tag }, ["final"])
    }

    /// The three Swift evaluators - indexed router, linear reference and the
    /// flat rules produced by lowering - must agree on every corpus table.
    func testLoweredRulesAreEquivalentToTheTable() throws {
        let built = try ParityCorpusBuilder.build()
        var checked = 0
        var secondPass = 0
        var winners = Set<String>()
        for (number, entry) in built.tables.enumerated() {
            let name = built.corpus.tables[number].name
            let compiled = try CompiledRouter(table: entry.table)
            let linear = try LinearRouteMatcher(table: entry.table)
            let simulator = RouteSimulator(router: compiled, traceLimit: 4)
            var mismatches = 0
            for (step, request) in entry.requests.enumerated() {
                let decision = compiled.match(request)
                if decision != linear.match(request) {
                    mismatches += 1
                    if mismatches <= 3 { XCTFail("\(name): indexed and linear disagree on \(request)") }
                }
                if step % 5 == 0, simulator.explain(request).decision != decision {
                    XCTFail("\(name): explain disagrees with match on \(request)")
                }
                if decision.usedSecondPass { secondPass += 1 }
                // Flat rules need a network for their catch-alls.
                guard request.network != nil else { continue }
                let expected: String?
                if let index = decision.ruleIndex {
                    expected = "r\(index)"
                } else {
                    expected = entry.lowered.finalIsCatchAllRule ? "final" : nil
                }
                let tag = entry.lowered.firstMatchTag(request)
                let actual = tag.map { $0 == "final" ? $0 : String($0.prefix(while: { $0 != "." })) }
                if actual != expected {
                    mismatches += 1
                    if mismatches <= 3 {
                        XCTFail("\(name): flat rules give \(tag ?? "nothing"), table gives \(expected ?? "final action") for \(request)")
                    }
                }
                winners.insert("\(number):\(expected ?? "default")")
                checked += 1
            }
            XCTAssertEqual(mismatches, 0, name)
        }
        XCTAssertGreaterThan(checked, 3000)
        // The corpus must be contested, otherwise agreement proves little.
        XCTAssertGreaterThan(winners.count, 120, "too few distinct winning rules")
        XCTAssertGreaterThan(secondPass, 40, "the second pass of ipIfNonMatch must be exercised")
    }

    // MARK: Stored corpus

    static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RoutingEngine
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Benchmarks/RoutingParity/testdata/corpus.json")
    }

    /// The stored corpus is what the Go harness compared with the engine. If
    /// the Swift semantics or the generator change, this test fails until
    /// the corpus is regenerated (`NP_PARITY_WRITE=1`) and the Go harness is
    /// run again on the new file.
    func testStoredCorpusIsCurrent() throws {
        let built = try ParityCorpusBuilder.build()
        let url = EngineParityTests.corpusURL
        if ProcessInfo.processInfo.environment["NP_PARITY_WRITE"] == "1" {
            try built.corpus.encodedText().write(to: url, atomically: true, encoding: .utf8)
        }
        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertEqual(stored.tables.count, built.corpus.tables.count)
        for (stored, fresh) in zip(stored.tables, built.corpus.tables) {
            XCTAssertEqual(stored.rules, fresh.rules, "rules of \(fresh.name) changed")
            XCTAssertEqual(stored.requests.count, fresh.requests.count, fresh.name)
            var changed = 0
            for (old, new) in zip(stored.requests, fresh.requests) where old != new {
                changed += 1
                if changed <= 3 { XCTFail("\(fresh.name): stored \(old) is now \(new)") }
            }
            XCTAssertEqual(changed, 0, "\(fresh.name): \(changed) requests changed")
        }
        XCTAssertEqual(stored, built.corpus)
        // Guard against an accidentally tiny corpus.
        XCTAssertGreaterThan(stored.tables.reduce(0) { $0 + $1.requests.count }, 3000)
    }
}
