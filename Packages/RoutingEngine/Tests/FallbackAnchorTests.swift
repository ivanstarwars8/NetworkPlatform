// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-27). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

final class KeywordAutomatonTests: XCTestCase {
    private func found(_ automaton: KeywordAutomaton, _ text: String) -> [Int32] {
        var result: [Int32] = []
        automaton.collect(Array(text.utf8), into: &result)
        return Array(Set(result)).sorted()
    }

    func testOverlappingKeywords() {
        let words = ["ab", "b", "abc", "bc", "c.d", "abcabd", "zz", "b"]
        let automaton = KeywordAutomaton(keywords: words.enumerated().map { (Array($1.utf8), Int32($0)) })
        XCTAssertEqual(automaton.keywordCount, 8)
        XCTAssertEqual(found(automaton, "xabcx"), [0, 1, 2, 3, 7])
        XCTAssertEqual(found(automaton, "abcabd"), [0, 1, 2, 3, 5, 7])
        XCTAssertEqual(found(automaton, "c.d"), [4])
        XCTAssertEqual(found(automaton, "zaz"), [])
        XCTAssertEqual(found(automaton, "zzz"), [6])
        XCTAssertEqual(found(automaton, ""), [])
        XCTAssertTrue(KeywordAutomaton().isEmpty)
        XCTAssertEqual(found(KeywordAutomaton(), "abc"), [])
    }

    /// Every keyword found by the automaton, and only those, occurs in the
    /// text according to plain substring search.
    func testAgreesWithSubstringSearch() {
        var rng = LCG(seed: 0xAC0_2026)
        let alphabet = Array("ab.c".utf8)
        for _ in 0..<60 {
            var words: [[UInt8]] = []
            for _ in 0..<(1 + rng.below(25)) {
                var word: [UInt8] = []
                for _ in 0..<(1 + rng.below(5)) { word.append(rng.pick(alphabet)) }
                words.append(word)
            }
            let automaton = KeywordAutomaton(keywords: words.enumerated().map { ($1, Int32($0)) })
            for _ in 0..<40 {
                var text: [UInt8] = []
                for _ in 0..<rng.below(24) { text.append(rng.pick(alphabet)) }
                var result: [Int32] = []
                automaton.collect(text, into: &result)
                let expected = words.indices.filter { ByteText.contains(text, words[$0]) }.map { Int32($0) }
                XCTAssertEqual(Array(Set(result)).sorted(), expected)
            }
        }
    }
}

final class FallbackAnchorTests: XCTestCase {
    /// Fallback rules of every anchor kind, interleaved with indexed rules;
    /// the anchored router must pick the same rule as the linear reference.
    func testAnchoredFallbackRules() throws {
        let narrow = try XCTUnwrap(PortRange(lower: 6000, upper: 6010))
        let wide = try XCTUnwrap(PortRange(lower: 1, upper: 60000))
        let table = RoutingTable(rules: [
            makeRule(.and([.domainSuffix("example.com"), .port(PortRange(8443))]), .proxy("r0")),
            makeRule(.and([.domainSuffix(".strict.org"), .network(.udp)]), .proxy("r1")),
            makeRule(.and([.domain("exact.net"), .inboundTag("tun")]), .proxy("r2")),
            makeRule(.domainKeyword("track"), .proxy("r3")),
            makeRule(.and([.domainKeyword("ads"), .port(wide)]), .proxy("r4")),
            makeRule(.and([.ipCIDR(try makeCIDR("10.0.0.0/8")), .network(.udp)]), .proxy("r5")),
            makeRule(.and([.ipCIDR(try makeCIDR("2001:db8::/32")), .port(narrow)]), .proxy("r6")),
            makeRule(.user("bob"), .proxy("r7")),
            makeRule(.and([.sniffedProtocol("bittorrent"), .port(narrow)]), .proxy("r8")),
            makeRule(.and([.sourceCIDR(try makeCIDR("192.168.0.0/16")), .port(wide)]), .proxy("r9")),
            makeRule(.or([.domainRegex("^x[0-9]+\\."), .and([.domainSuffix("late.io"), .port(PortRange(1))]), .domain("plain.io")]), .proxy("r10")),
            makeRule(.domainSuffix("example.com"), .proxy("r11")),
            makeRule(.and([.ipCIDR(try makeCIDR("0.0.0.0/0")), .port(PortRange(0))]), .proxy("r12")),
        ], finalAction: .direct)
        let router = try CompiledRouter(table: table)
        let linear = try LinearRouteMatcher(table: table)
        XCTAssertEqual(router.statistics.fallbackRules, 12)
        // Unanchored: r9 (source prefix with a wide port range) and the
        // regex piece of r10.
        XCTAssertEqual(router.statistics.unanchoredFallbackEntries, 2)
        XCTAssertEqual(router.statistics.anchoredFallbackEntries, 11)

        let cases: [(RouteRequest, Int?)] = [
            (RouteRequest(domain: "a.example.com", port: 8443), 0),
            (RouteRequest(domain: "a.example.com", port: 443), 11),
            (RouteRequest(domain: "example.com.", port: 8443), nil),
            (RouteRequest(domain: "a.strict.org", port: 443, network: .udp), 1),
            (RouteRequest(domain: "strict.org", port: 443, network: .udp), nil),
            (RouteRequest(domain: "exact.net", port: 443, inboundTag: "tun"), 2),
            (RouteRequest(domain: "sub.exact.net", port: 443, inboundTag: "tun"), nil),
            (RouteRequest(domain: "my-tracker.dev", port: 443), 3),
            (RouteRequest(domain: "ads.tracker.example.com", port: 8443), 0),
            (RouteRequest(domain: "ads.site.dev", port: 443), 4),
            (RouteRequest(domain: "ads.site.dev", port: 0), nil),
            (RouteRequest(ip: try makeIP("10.9.9.9"), port: 53, network: .udp), 5),
            (RouteRequest(ip: try makeIP("10.9.9.9"), port: 53, network: .tcp), nil),
            (RouteRequest(ip: try makeIP("2001:db8::7"), port: 6005), 6),
            (RouteRequest(ip: try makeIP("2001:db8::7"), port: 6011), nil),
            (RouteRequest(domain: "other.dev", port: 443, user: "bob"), 7),
            (RouteRequest(domain: "other.dev", port: 6010, sniffedProtocol: "bittorrent"), 8),
            (RouteRequest(domain: "other.dev", port: 443, sourceIP: try makeIP("192.168.1.1")), 9),
            (RouteRequest(domain: "x12.dev", port: 443), 10),
            (RouteRequest(domain: "a.late.io", port: 1), 10),
            (RouteRequest(domain: "plain.io", port: 443), 10),
            (RouteRequest(ip: try makeIP("8.8.8.8")), 12),
            (RouteRequest(domain: "other.dev", port: 443), nil),
        ]
        for (request, expected) in cases {
            XCTAssertEqual(linear.match(request).ruleIndex, expected, "linear \(request)")
            XCTAssertEqual(router.match(request).ruleIndex, expected, "indexed \(request)")
        }

        // With ipIfNonMatch the prefix buckets see the resolved addresses on
        // the second pass.
        var resolving = table
        resolving.domainStrategy = .ipIfNonMatch
        let second = try CompiledRouter(table: resolving)
        let request = RouteRequest(domain: "other.dev", port: 53, network: .udp, resolvedIPs: [try makeIP("8.8.4.4"), try makeIP("10.0.0.1")])
        XCTAssertEqual(second.match(request).ruleIndex, 5)
        XCTAssertEqual(try LinearRouteMatcher(table: resolving).match(request).ruleIndex, 5)
    }
}

final class RegexLiteralAnchorTests: XCTestCase {
    private func literal(_ pattern: String) throws -> String {
        String(decoding: try LinearRegex(pattern).requiredLiteral, as: UTF8.self)
    }

    func testRequiredLiteralExtraction() throws {
        XCTAssertEqual(try literal("^abcdef[0-9]+\\."), "abcdef")
        XCTAssertEqual(try literal("\\.shopping-[a-z]{2,4}\\.(com|net)$"), ".shopping-")
        XCTAssertEqual(try literal("^(ads?|track)[0-9]*\\.example\\."), ".example.")
        XCTAssertEqual(try literal("ab(cd)+ef"), "ab")
        XCTAssertEqual(try literal("x(abc){2}y"), "xabcabcy")
        XCTAssertEqual(try literal("(?i)AbC.x"), "abc")
        XCTAssertEqual(try literal("[Tt]rack"), "track")
        XCTAssertEqual(try literal("foo|bar"), "")
        XCTAssertEqual(try literal("(abc)?def*"), "de")
        XCTAssertEqual(try literal("a*b?.c"), "c")
        XCTAssertEqual(try literal("(?:mail|mail)\\.ru"), "mail.ru")
    }

    /// Property: on lower-case input, every match contains the literal.
    func testLiteralIsNecessary() throws {
        var rng = LCG(seed: 0x11_7E2A1)
        let atoms = ["a", "b", "c", ".", "[ab]", "[^a]", "\\d", "(a|bc)", "(?:ab)", "A", "[Aa]", "x"]
        let quantifiers = ["", "", "", "*", "+", "?", "{2}", "{1,3}", "{0,2}"]
        let alphabet = Array("abcx.1".utf8)
        var checked = 0
        for _ in 0..<400 {
            var pattern = rng.chance(10) ? "(?i)" : ""
            if rng.chance(20) { pattern += "^" }
            for _ in 0..<(1 + rng.below(6)) {
                pattern += rng.pick(atoms) + rng.pick(quantifiers)
                if rng.chance(8) { pattern += "|" }
            }
            if pattern.hasSuffix("|") { pattern += "a" }
            if rng.chance(20) { pattern += "$" }
            guard let regex = try? LinearRegex(pattern) else { continue }
            for _ in 0..<60 {
                var text: [UInt8] = []
                for _ in 0..<rng.below(12) { text.append(rng.pick(alphabet)) }
                if regex.matches(utf8: text) {
                    checked += 1
                    XCTAssertTrue(regex.requiredLiteral.isEmpty || ByteText.contains(text, regex.requiredLiteral),
                                  "\(pattern) matches \(String(decoding: text, as: UTF8.self))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// Regex rules filed under their literal pick the same rule as the
    /// linear reference.
    func testAnchoredRegexRulesAgreeWithLinear() throws {
        let table = RoutingTable(rules: [
            makeRule(.domainRegex("^cdn[0-9]+\\.media"), .proxy("r0")),
            makeRule(.domainRegex("(?i)TRACKER"), .proxy("r1")),
            makeRule(.and([.domainRegex("\\.shop-[a-z]{2}\\.com$"), .port(PortRange(443))]), .proxy("r2")),
            makeRule(.domainRegex("^x[0-9]+$"), .proxy("r3")),
            makeRule(.domainSuffix("media.net"), .proxy("r4")),
            makeRule(.domainRegex("Upper"), .proxy("r5")),
        ], finalAction: .direct)
        let router = try CompiledRouter(table: table)
        let linear = try LinearRouteMatcher(table: table)
        XCTAssertEqual(router.statistics.unanchoredFallbackEntries, 1) // "^x[0-9]+$"
        let names = ["cdn12.media.net", "cdn.media.net", "a.cdn1.media.net", "my-tracker.io", "MY-TRACKER.IO",
                     "a.shop-ab.com", "a.shop-abc.com", "x42", "x42.com", "upper.com", "Upper.com", "media.net"]
        for name in names {
            for port: UInt16 in [443, 80] {
                let request = RouteRequest(domain: name, port: port)
                XCTAssertEqual(router.match(request).ruleIndex, linear.match(request).ruleIndex, "\(request)")
            }
        }
        XCTAssertEqual(router.match(RouteRequest(domain: "cdn12.media.net")).ruleIndex, 0)
        XCTAssertEqual(router.match(RouteRequest(domain: "MY-TRACKER.IO")).ruleIndex, 1)
        XCTAssertEqual(router.match(RouteRequest(domain: "a.shop-ab.com", port: 443)).ruleIndex, 2)
        XCTAssertEqual(router.match(RouteRequest(domain: "Upper.com")).ruleIndex, nil)
    }
}
