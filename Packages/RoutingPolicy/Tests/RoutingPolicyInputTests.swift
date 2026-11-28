import Foundation
import RoutingEngine
@testable import RoutingPolicy
import XCTest

final class RoutingPolicyInputTests: XCTestCase {
    // MARK: Host names

    func testPunycodeMatchesRFCAndBrowsers() {
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        XCTAssertEqual(HostName.ascii("Пример.РФ"), "xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(HostName.ascii("москва"), "xn--80adxhks")
        XCTAssertEqual(HostName.ascii("рус"), "xn--p1acf")
        XCTAssertEqual(HostName.ascii("дети"), "xn--d1acj3b")
        XCTAssertEqual(HostName.ascii("Example.COM."), "example.com")
        XCTAssertEqual(HostName.ascii("_dmarc.example.com"), "_dmarc.example.com")
    }

    func testInvalidHostNames() {
        for text in ["", "a b.com", "-a.com", "a-.com", "a..com", "exa$mple.com", String(repeating: "a", count: 64) + ".com", "пример!.рф"] {
            XCTAssertNil(HostName.ascii(text), text)
        }
    }

    // MARK: Own rules

    func testRuleInputIsNormalised() throws {
        XCTAssertEqual(try CustomRule.make(kind: .domainSuffix, text: " *.Example.COM ", target: .direct).get().value, "example.com")
        XCTAssertEqual(try CustomRule.make(kind: .domain, text: "пример.рф", target: .direct).get().value, "xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(try CustomRule.make(kind: .ipCIDR, text: "10.1.2.3/8", target: .block).get().value, "10.0.0.0/8")
        XCTAssertEqual(try CustomRule.make(kind: .ipCIDR, text: "2001:db8::1", target: .block).get().value, "2001:db8::1/128")
        XCTAssertEqual(try CustomRule.make(kind: .port, text: "80:90", target: .tunnel).get().value, "80-90")
        XCTAssertEqual(try CustomRule.make(kind: .network, text: "UDP", target: .tunnel).get().value, "udp")
        XCTAssertEqual(try CustomRule.make(kind: .domainKeyword, text: "Google", target: .tunnel).get().value, "google")
    }

    func testRuleInputErrorsSayWhatIsExpected() {
        let cases: [(RuleMatchKind, String)] = [
            (.domain, "not a domain"), (.ipCIDR, "300.1.1.1"), (.port, "70000"), (.port, "90-80"),
            (.network, "icmp"), (.domainKeyword, "a,b"), (.domain, " "),
        ]
        for (kind, text) in cases {
            guard case .failure(let error) = CustomRule.make(kind: kind, text: text, target: .direct) else {
                return XCTFail("\(kind) \(text) accepted")
            }
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testEveryRuleKindHasACondition() throws {
        let samples: [RuleMatchKind: String] = [
            .domain: "a.example", .domainSuffix: "example", .domainKeyword: "ex", .ipCIDR: "192.0.2.0/24", .port: "443", .network: "tcp",
        ]
        for kind in RuleMatchKind.allCases {
            let rule = try CustomRule.make(kind: kind, text: XCTUnwrap(samples[kind]), target: .direct).get()
            XCTAssertNotNil(rule.condition, "\(kind)")
        }
    }

    // MARK: DNS servers

    func testDNSServerNotations() throws {
        XCTAssertEqual(try DNSServer.parse("1.1.1.1").get(), DNSServer(kind: .udp, text: "1.1.1.1"))
        XCTAssertEqual(try DNSServer.parse("2606:4700:4700::1111").get().kind, .udp)
        XCTAssertEqual(try DNSServer.parse("tcp://8.8.8.8:53").get(), DNSServer(kind: .tcp, text: "tcp://8.8.8.8:53"))
        XCTAssertEqual(try DNSServer.parse("HTTPS://dns.example/dns-query").get(), DNSServer(kind: .https, text: "https://dns.example/dns-query"))
        let dot = try DNSServer.parse("tls://9.9.9.9").get()
        XCTAssertEqual(dot.kind, .tls)
        XCTAssertNotNil(dot.engineNote, "DoT has no Xray form")
        for bad in ["localhost", "https+local://dns.example/q", "udp+local://1.1.1.1", "quic://1.1.1.1", "dns.example", "https://dns.example", "tcp://dns.example", "1.1.1.1#x", "tcp://1.1.1.1:0"] {
            guard case .failure = DNSServer.parse(bad) else { return XCTFail("accepted \(bad)") }
        }
    }

    // MARK: Lists

    func testListShapesAreReadAndCompacted() throws {
        let text = """
        # comment
        example.com
        sub.example.com
        full:www.example.com
        full:exact.example.org
        domain:example.net
        DOMAIN-SUFFIX,example.io,PROXY
        DOMAIN,api.example.dev
        DOMAIN-KEYWORD,tracker
        regexp:^ad\\..*
        IP-CIDR,10.0.0.0/8,no-resolve
        IP-CIDR,10.1.0.0/16
        IP-CIDR6,2001:db8::/32
        192.0.2.7
        0.0.0.0 ads.example.biz
        127.0.0.1 localhost
        payload:
          - '+.example.app'
          - ".example.cc"
          - DOMAIN-SUFFIX,example.com
        PROCESS-NAME,Telegram
        """
        let parsed = try RuleSetParser.parse(text).get()
        XCTAssertEqual(parsed.content.suffixes, ["example.app", "example.cc", "example.com", "example.io", "example.net"])
        XCTAssertEqual(parsed.content.exactDomains, ["ads.example.biz", "api.example.dev", "exact.example.org"])
        XCTAssertEqual(parsed.content.cidrs, ["10.0.0.0/8", "192.0.2.7/32", "2001:db8::/32"])
        XCTAssertEqual(parsed.skipped, 4, "keyword, regexp, localhost, process name")
        XCTAssertEqual(parsed.redundant, 4, "sub.example.com, www.example.com, 10.1.0.0/16, the repeated example.com")
    }

    func testCIDRCompactionKeepsDisjointPrefixes() {
        let input = ["10.0.0.0/8", "10.2.0.0/16", "10.1.0.0/16", "11.0.0.0/8", "11.0.0.0/8", "192.168.0.0/16", "192.168.1.0/24", "0.0.0.0/32"].compactMap(IPCIDR.init)
        XCTAssertEqual(RuleSetParser.compactCIDRList(input).map(\.description), ["0.0.0.0/32", "10.0.0.0/8", "11.0.0.0/8", "192.168.0.0/16"])
    }

    func testListLimits() {
        let big = (0..<50).map { "host\($0).example.com" }.joined(separator: "\n")
        guard case .failure(let error) = RuleSetParser.parse(big, limits: RuleSetLimits(maximumBytes: 1 << 20, maximumEntriesPerSet: 10, maximumTotalEntries: 10)) else {
            return XCTFail("over the entry limit")
        }
        XCTAssertTrue(error.message.contains("10"))
        guard case .failure = RuleSetParser.parse(big, limits: RuleSetLimits(maximumBytes: 100)) else { return XCTFail("over the size limit") }
        guard case .failure = RuleSetParser.parse("# only comments\n\n") else { return XCTFail("empty list") }
    }

    func testListURLValidation() {
        XCTAssertNoThrow(try RemoteRuleSet.validateURL("https://example.com/list.txt").get())
        guard case .failure = RemoteRuleSet.validateURL("ftp://example.com/x") else { return XCTFail() }
        guard case .failure = RemoteRuleSet.validateURL("example.com/list") else { return XCTFail() }
    }

    // MARK: Store

    func testStoreRoundTripAndListCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routing-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RoutingSettingsStore(directory: directory)
        XCTAssertEqual(store.settings, RoutingSettings())

        var settings = RoutingSettings(preset: .russiaDirect)
        settings.customRules = [try CustomRule.make(kind: .domainSuffix, text: "example.com", target: .direct).get()]
        var list = RemoteRuleSet(name: "Список", url: "https://example.com/l.txt", target: .tunnel)
        list.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        list.domainCount = 1
        settings.remoteRuleSets = [list]
        settings.dns = DNSSettings(servers: ["9.9.9.9"], domainServers: [DomainDNSRule(domain: "example.org", server: "1.1.1.1")], ipv6: false, leakProtection: false)
        try store.storeRuleSet(CompiledRuleSet(suffixes: ["example.org"]), for: list.id, updating: settings)

        let reopened = try RoutingSettingsStore(directory: directory)
        XCTAssertEqual(reopened.settings, settings)
        XCTAssertEqual(reopened.ruleSets[list.id], CompiledRuleSet(suffixes: ["example.org"]))

        var without = settings
        without.remoteRuleSets = []
        try reopened.save(without)
        XCTAssertNil(reopened.ruleSets[list.id])
        XCTAssertNil(try RoutingSettingsStore(directory: directory).ruleSets[list.id], "the cache file is removed with the list")
    }

    func testCorruptSettingsAreReportedNotReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routing-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent("routing.json"))
        XCTAssertThrowsError(try RoutingSettingsStore(directory: directory))
    }
}
