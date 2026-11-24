// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

final class RouteSimulatorTests: XCTestCase {
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

    func testExplainsWinnerEarlierRulesAndLosers() throws {
        let table = try mixedTable()
        let simulator = try RouteSimulator(table: table)
        let request = RouteRequest(domain: "www.example.com", port: 443)
        let explanation = simulator.explain(request)

        XCTAssertEqual(explanation.request, request)
        XCTAssertEqual(explanation.decision, RouteDecision(action: .proxy("a"), ruleIndex: 1))
        XCTAssertEqual(explanation.matchedRuleIndex, 1)
        XCTAssertEqual(explanation.matchedRule, table.rules[1])
        XCTAssertEqual(explanation.omittedEntries, 0)

        XCTAssertEqual(explanation.trace.count, 3)
        guard explanation.trace.count == 3 else { return }

        let earlier = explanation.trace[0]
        XCTAssertEqual(earlier.ruleIndex, 0)
        XCTAssertEqual(earlier.ruleID, "lan")
        XCTAssertEqual(earlier.outcome, .notMatched)
        XCTAssertTrue(earlier.reason.contains("no IP address"), earlier.reason)
        XCTAssertTrue(earlier.reason.contains("10.0.0.0/8"), earlier.reason)

        let winner = explanation.trace[1]
        XCTAssertEqual(winner.ruleIndex, 1)
        XCTAssertEqual(winner.outcome, .matched)
        XCTAssertTrue(winner.reason.contains("www.example.com"), winner.reason)
        XCTAssertTrue(winner.reason.contains("example.com"), winner.reason)
        XCTAssertTrue(winner.reason.contains("domain trie"), winner.reason)
        XCTAssertTrue(winner.reason.contains("proxy(a)"), winner.reason)

        let loser = explanation.trace[2]
        XCTAssertEqual(loser.ruleIndex, 2)
        XCTAssertEqual(loser.ruleID, "https")
        XCTAssertEqual(loser.outcome, .lowerPriority)
        XCTAssertTrue(loser.reason.contains("port index"), loser.reason)
        XCTAssertTrue(loser.reason.contains("#1"), loser.reason)

        let text = explanation.text
        XCTAssertTrue(text.contains("decision: proxy(a)"), text)
        XCTAssertTrue(text.contains("#0 [lan] notMatched"), text)
        XCTAssertTrue(text.contains("#1 [example] matched"), text)
        XCTAssertTrue(text.contains("#2 [https] lowerPriority"), text)
    }

    func testExplainsFinalAction() throws {
        let simulator = try RouteSimulator(table: try mixedTable())
        let explanation = simulator.explain(RouteRequest(domain: "nothing.test", port: 80, network: .udp))

        XCTAssertTrue(explanation.decision.isFinal)
        XCTAssertEqual(explanation.decision.action, .group("auto"))
        XCTAssertNil(explanation.matchedRule)
        XCTAssertNil(explanation.matchedRuleIndex)
        XCTAssertEqual(explanation.trace.count, 5)
        XCTAssertEqual(explanation.trace.map { $0.outcome }, [.notMatched, .notMatched, .notMatched, .notMatched, .finalAction])
        XCTAssertEqual(explanation.trace.map { $0.ruleIndex }, [0, 1, 2, 3, nil])
        XCTAssertTrue(explanation.trace[1].reason.contains("is not under suffix 'example.com'"), explanation.trace[1].reason)
        XCTAssertTrue(explanation.trace[2].reason.contains("port 80 is not in 443"), explanation.trace[2].reason)
        XCTAssertTrue(explanation.trace[3].reason.contains("does not contain 'ads'"), explanation.trace[3].reason)
        XCTAssertTrue(explanation.trace[4].reason.contains("group(auto)"), explanation.trace[4].reason)
    }

    func testExplainsFallbackWinner() throws {
        let simulator = try RouteSimulator(table: try mixedTable())
        let explanation = simulator.explain(RouteRequest(domain: "ads.test", port: 80))
        XCTAssertEqual(explanation.matchedRuleIndex, 3)
        let winner = try XCTUnwrap(explanation.trace.last)
        XCTAssertEqual(winner.outcome, .matched)
        XCTAssertTrue(winner.reason.contains("contains 'ads'"), winner.reason)
        XCTAssertTrue(winner.reason.contains("ordered fallback list"), winner.reason)
    }

    func testTraceLimitAndOmittedCount() throws {
        var rules: [RoutingRule] = []
        for number in 0..<10 {
            rules.append(makeRule(.domain("miss\(number).test"), .reject))
        }
        rules.append(makeRule(.domain("hit.test"), .direct))
        let simulator = try RouteSimulator(table: RoutingTable(rules: rules), traceLimit: 2)
        let explanation = simulator.explain(RouteRequest(domain: "hit.test"))

        XCTAssertEqual(explanation.matchedRuleIndex, 10)
        XCTAssertEqual(explanation.omittedEntries, 8)
        XCTAssertEqual(explanation.trace.map { $0.ruleIndex }, [0, 1, 10])
        XCTAssertEqual(explanation.trace.map { $0.outcome }, [.notMatched, .notMatched, .matched])
        XCTAssertTrue(explanation.text.contains("8 earlier non-matching rules not shown"))

        let unlimited = try RouteSimulator(table: RoutingTable(rules: rules), traceLimit: 1000)
        XCTAssertEqual(unlimited.explain(RouteRequest(domain: "hit.test")).trace.count, 11)
        XCTAssertEqual(unlimited.explain(RouteRequest(domain: "hit.test")).omittedEntries, 0)
    }

    func testDisabledRuleInTrace() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainSuffix("test"), .reject, enabled: false),
            makeRule(.domainSuffix("test"), .direct),
        ])
        let explanation = try RouteSimulator(table: table).explain(RouteRequest(domain: "a.test"))
        XCTAssertEqual(explanation.matchedRuleIndex, 1)
        XCTAssertEqual(explanation.trace.first?.outcome, .disabled)
        XCTAssertEqual(explanation.trace.first?.reason, "rule is disabled")
    }

    func testExplainsPriorityOverLongerPrefix() throws {
        let table = RoutingTable(rules: [
            makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .direct),
            makeRule(.ipCIDR(try makeCIDR("10.1.0.0/16")), .reject),
        ])
        let explanation = try RouteSimulator(table: table).explain(RouteRequest(ip: try makeIP("10.1.2.3")))
        XCTAssertEqual(explanation.matchedRuleIndex, 0)
        let winner = try XCTUnwrap(explanation.trace.first)
        XCTAssertTrue(winner.reason.contains("inside 10.0.0.0/8"), winner.reason)
        XCTAssertTrue(winner.reason.contains("most specific prefix /16"), winner.reason)
        XCTAssertTrue(winner.reason.contains("rule #1"), winner.reason)
    }

    func testExplainsLogicalConditions() throws {
        let table = RoutingTable(rules: [
            makeRule(.and([.domainSuffix("example.com"), .port(PortRange(443))]), .reject),
            makeRule(.not(.network(.udp)), .direct),
        ])
        let simulator = try RouteSimulator(table: table)
        let explanation = simulator.explain(RouteRequest(domain: "example.com", port: 80, network: .tcp))
        XCTAssertEqual(explanation.matchedRuleIndex, 1)
        XCTAssertEqual(explanation.trace.count, 2)
        XCTAssertTrue(explanation.trace[0].reason.contains("AND failed"), explanation.trace[0].reason)
        XCTAssertTrue(explanation.trace[0].reason.contains("port 80 is not in 443"), explanation.trace[0].reason)
        XCTAssertTrue(explanation.trace[1].reason.contains("NOT holds"), explanation.trace[1].reason)

        let udp = simulator.explain(RouteRequest(domain: "example.com", port: 80, network: .udp))
        XCTAssertTrue(udp.decision.isFinal)
        XCTAssertTrue(udp.trace[1].reason.contains("NOT failed"), udp.trace[1].reason)
    }

    func testExplainAgreesWithRouter() throws {
        let table = try mixedTable()
        let router = try CompiledRouter(table: table)
        let simulator = RouteSimulator(router: router)
        let requests = [
            RouteRequest(domain: "www.example.com", ip: try makeIP("10.1.1.1"), port: 443, network: .tcp),
            RouteRequest(domain: "ads.test", port: 443),
            RouteRequest(domain: "ads.test"),
            RouteRequest(ip: try makeIP("192.0.2.1")),
            RouteRequest(),
        ]
        for request in requests {
            XCTAssertEqual(simulator.explain(request).decision, router.match(request), "\(request)")
        }
    }
}

final class ConflictDetectorTests: XCTestCase {
    func testFindsShadowedDomainAndCIDRRules() throws {
        let table = RoutingTable(rules: [
            /* 0 */ makeRule(.domainSuffix("example.com"), .direct),
            /* 1 */ makeRule(.domain("www.example.com"), .reject, id: "www"),
            /* 2 */ makeRule(.domainSuffix("sub.example.com"), .direct),
            /* 3 */ makeRule(.domainSuffix("example.org"), .direct),
            /* 4 */ makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .proxy("p")),
            /* 5 */ makeRule(.ipCIDR(try makeCIDR("10.1.0.0/16")), .reject),
            /* 6 */ makeRule(.ipCIDR(try makeCIDR("10.0.0.0/7")), .direct),
            /* 7 */ makeRule(.or([.domainSuffix("a.example.com"), .ipCIDR(try makeCIDR("10.2.3.0/24"))]), .direct),
            /* 8 */ makeRule(.or([.domainSuffix("x.example.com"), .domainKeyword("k")]), .direct),
            /* 9 */ makeRule(.domainSuffix("example.com"), .direct),
            /* 10 */ makeRule(.domainSuffix(".example.com"), .direct),
            /* 11 */ makeRule(.and([.domainSuffix("example.com"), .port(PortRange(443))]), .direct),
            /* 12 */ makeRule(.domain("example.org"), .direct),
            /* 13 */ makeRule(.domainSuffix("unrelated.net"), .reject),
        ])
        let conflicts = try ConflictDetector.shadowedRules(in: table)
        XCTAssertEqual(conflicts.map { $0.ruleIndex }, [1, 2, 5, 7, 9, 10, 12])

        var byIndex: [Int: RuleConflict] = [:]
        for conflict in conflicts {
            byIndex[conflict.ruleIndex] = conflict
        }
        XCTAssertEqual(byIndex[1]?.coveredBy, [0])
        XCTAssertEqual(byIndex[1]?.sameAction, false)
        XCTAssertEqual(byIndex[1]?.ruleID, "www")
        XCTAssertEqual(byIndex[2]?.coveredBy, [0])
        XCTAssertEqual(byIndex[2]?.sameAction, true)
        XCTAssertEqual(byIndex[5]?.coveredBy, [4])
        XCTAssertEqual(byIndex[5]?.sameAction, false)
        XCTAssertEqual(byIndex[7]?.coveredBy, [0, 4])
        XCTAssertEqual(byIndex[7]?.sameAction, false)
        XCTAssertEqual(byIndex[9]?.coveredBy, [0])
        XCTAssertEqual(byIndex[10]?.coveredBy, [0])
        XCTAssertEqual(byIndex[12]?.coveredBy, [3])
        XCTAssertEqual(byIndex[12]?.sameAction, true)
        for conflict in conflicts {
            XCTAssertFalse(conflict.explanation.isEmpty)
        }
        XCTAssertTrue(byIndex[5]?.explanation.contains("10.1.0.0/16") ?? false)
        XCTAssertTrue(byIndex[5]?.explanation.contains("rule #4") ?? false)
    }

    /// Every reported rule must really be unreachable: no request matches it
    /// first. Checked with the linear reference matcher on targeted requests.
    func testReportedRulesNeverWin() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainSuffix("example.com"), .direct),
            makeRule(.domain("www.example.com"), .reject),
            makeRule(.domainSuffix("deep.sub.example.com"), .reject),
            makeRule(.ipCIDR(try makeCIDR("2001:db8::/32")), .direct),
            makeRule(.ipCIDR(try makeCIDR("2001:db8:1::/48")), .reject),
        ])
        let conflicts = try ConflictDetector.shadowedRules(in: table)
        XCTAssertEqual(conflicts.map { $0.ruleIndex }, [1, 2, 4])
        let linear = try LinearRouteMatcher(table: table)
        let requests = [
            RouteRequest(domain: "www.example.com"),
            RouteRequest(domain: "deep.sub.example.com"),
            RouteRequest(domain: "x.deep.sub.example.com"),
            RouteRequest(ip: try makeIP("2001:db8:1::1")),
            RouteRequest(ip: try makeIP("2001:db8:1:ffff::1")),
        ]
        for request in requests {
            let winner = linear.match(request).ruleIndex
            XCTAssertNotNil(winner)
            XCTAssertFalse(conflicts.contains { $0.ruleIndex == winner }, "\(request) reached a shadowed rule")
        }
    }

    func testStrictAndInclusiveSuffixCoverage() throws {
        // ".example.com" (subdomains only) does not cover "example.com".
        let notCovered = RoutingTable(rules: [
            makeRule(.domainSuffix(".example.com"), .direct),
            makeRule(.domainSuffix("example.com"), .reject),
        ])
        XCTAssertTrue(try ConflictDetector.shadowedRules(in: notCovered).isEmpty)

        // ".com" covers everything under com, including "example.com".
        let covered = RoutingTable(rules: [
            makeRule(.domainSuffix(".com"), .direct),
            makeRule(.domainSuffix("example.com"), .reject),
            makeRule(.domain("example.com"), .reject),
            makeRule(.domain("com"), .reject),
        ])
        XCTAssertEqual(try ConflictDetector.shadowedRules(in: covered).map { $0.ruleIndex }, [1, 2])

        // An exact rule never covers a suffix rule.
        let exactFirst = RoutingTable(rules: [
            makeRule(.domain("example.com"), .direct),
            makeRule(.domainSuffix("example.com"), .reject),
        ])
        XCTAssertTrue(try ConflictDetector.shadowedRules(in: exactFirst).isEmpty)
    }

    func testThingsThatMustNotBeReported() throws {
        let table = RoutingTable(rules: [
            // Disabled rules shadow nothing and are not reported.
            makeRule(.domainSuffix("com"), .reject, enabled: false),
            makeRule(.domainSuffix("a.com"), .direct),
            makeRule(.domainSuffix("b.a.com"), .direct, enabled: false),
            // Conditional rules shadow nothing.
            makeRule(.and([.domainSuffix("org"), .port(PortRange(443))]), .direct),
            makeRule(.domainSuffix("example.org"), .reject),
            // Address families are independent.
            makeRule(.ipCIDR(try makeCIDR("::/0")), .direct),
            makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .reject),
            // Wider after narrower is fine.
            makeRule(.ipCIDR(try makeCIDR("192.168.1.0/24")), .direct),
            makeRule(.ipCIDR(try makeCIDR("192.168.0.0/16")), .reject),
            // Label boundary: "badexample.net" is not under "example.net".
            makeRule(.domainSuffix("example.net"), .direct),
            makeRule(.domainSuffix("badexample.net"), .reject),
            // Partly covered OR is still reachable.
            makeRule(.or([.domainSuffix("x.a.com"), .domainSuffix("other.io")]), .reject),
        ])
        XCTAssertEqual(try ConflictDetector.shadowedRules(in: table), [])
    }

    func testCatchAllPrefixShadowsFamily() throws {
        let table = RoutingTable(rules: [
            makeRule(.ipCIDR(try makeCIDR("0.0.0.0/0")), .direct),
            makeRule(.ipCIDR(try makeCIDR("10.0.0.0/8")), .reject),
            makeRule(.ipCIDR(try makeCIDR("::ffff:192.168.0.0/112")), .reject),
            makeRule(.ipCIDR(try makeCIDR("2001:db8::/32")), .reject),
        ])
        XCTAssertEqual(try ConflictDetector.shadowedRules(in: table).map { $0.ruleIndex }, [1, 2])
    }

    func testRuleSetMembersCount() throws {
        let table = RoutingTable(
            rules: [
                makeRule(.ruleSet("big"), .direct),
                makeRule(.domainSuffix("cdn.example.com"), .reject),
                makeRule(.domainSuffix("example.io"), .reject),
            ],
            ruleSets: [RuleSet(tag: "big", conditions: [.domainSuffix("example.com"), .domainSuffix("example.net")])]
        )
        XCTAssertEqual(try ConflictDetector.shadowedRules(in: table).map { $0.ruleIndex }, [1])
    }

    func testInvalidTableThrows() {
        let table = RoutingTable(rules: [makeRule(.domain(""), .direct)])
        XCTAssertThrowsError(try ConflictDetector.shadowedRules(in: table))
    }
}
