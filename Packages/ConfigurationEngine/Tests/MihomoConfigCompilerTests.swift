import Foundation
import XCTest
import DomainModels
import RoutingEngine
@testable import ConfigurationEngine

final class MihomoConfigCompilerTests: XCTestCase {
    private let importer = ShareLinkImporter()
    private let realityLink = "vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?type=tcp&security=reality&sni=www.example.org"
        + "&fp=chrome&pbk=\(ProfileFixtures.realityKey)&sid=0a1b&flow=xtls-rprx-vision#lab"

    private func profile(_ outbounds: [Outbound], groups: [OutboundGroup] = [], selected: String? = nil) -> Profile {
        Profile(name: "p", outbounds: outbounds, groups: groups, selectedTag: selected ?? outbounds.first?.tag)
    }

    private func proxies(_ document: YAMLNode?) -> [YAMLNode] { document?["proxies"]?.sequenceValue ?? [] }
    private func rules(_ document: YAMLNode?) -> [String] { document?["rules"]?.sequenceValue?.compactMap(\.stringValue) ?? [] }

    // MARK: - Proxies

    func testRealityVisionCarriesMLKEMFlag() throws {
        let node = try importer.importLink(realityLink).outbound
        let compilation = MihomoConfigCompiler().compile(profile([node]))
        XCTAssertEqual(compilation.report.verdict, .exact, "\(compilation.report.issues)")
        let proxy = try XCTUnwrap(proxies(compilation.document).first)
        XCTAssertEqual(proxy["type"], .string("vless"))
        XCTAssertEqual(proxy["name"], .string("proxy-0000"))
        XCTAssertEqual(proxy["uuid"], .string(ProfileFixtures.uuidA))
        XCTAssertEqual(proxy["flow"], .string("xtls-rprx-vision"))
        XCTAssertEqual(proxy["tls"], .bool(true))
        XCTAssertEqual(proxy["servername"], .string("www.example.org"))
        XCTAssertEqual(proxy["client-fingerprint"], .string("chrome"))
        XCTAssertEqual(proxy["packet-encoding"], .string("xudp"))
        XCTAssertEqual(proxy["reality-opts"]?["public-key"], .string(ProfileFixtures.realityKey))
        XCTAssertEqual(proxy["reality-opts"]?["short-id"], .string("0a1b"))
        XCTAssertEqual(proxy["reality-opts"]?["support-x25519mlkem768"], .bool(true))
        XCTAssertNil(proxy["network"], "raw TCP is the default network")
        XCTAssertEqual(rules(compilation.document), ["MATCH,proxy-0000"])
        XCTAssertEqual(compilation.report.engine, .mihomo)
        XCTAssertEqual(compilation.report.engineTags, ["lab": "proxy-0000"])
        let text = try XCTUnwrap(compilation.yamlText())
        XCTAssertTrue(text.contains("support-x25519mlkem768: true"))
        XCTAssertTrue(text.contains("short-id: \"0a1b\""))
    }

    func testRealityWithoutFingerprintGetsChromeAndMLDSAIsReported() {
        var node = ProfileFixtures.vless("a", host: "192.0.2.1")
        node.stream.security = .reality(RealitySettings(serverName: "s.example", publicKey: ProfileFixtures.realityKey, spiderX: "/x", mldsa65Verify: "abc"))
        let compilation = MihomoConfigCompiler().compile(profile([node]))
        XCTAssertEqual(proxies(compilation.document).first?["client-fingerprint"], .string("chrome"))
        XCTAssertTrue(compilation.report.hasIssue(.unsupported, pathContaining: "mldsa65Verify"))
        XCTAssertTrue(compilation.report.hasIssue(.dropped, pathContaining: "spiderX"))
        XCTAssertEqual(compilation.report.verdict, .degraded)
    }

    func testShadowsocks2022AndKeyCheck() throws {
        let key = Data(repeating: 7, count: 16).base64EncodedString()
        let node = Outbound(tag: "ss", name: "ss", server: ServerEndpoint(host: "192.0.2.2", port: 8388),
                            credentials: Credentials(password: .inline(key)),
                            settings: .shadowsocks(ShadowsocksSettings(method: "2022-blake3-aes-128-gcm")))
        let compilation = MihomoConfigCompiler().compile(profile([node]))
        let proxy = try XCTUnwrap(proxies(compilation.document).first)
        XCTAssertEqual(proxy["type"], .string("ss"))
        XCTAssertEqual(proxy["cipher"], .string("2022-blake3-aes-128-gcm"))
        XCTAssertEqual(proxy["password"], .string(key))
        XCTAssertEqual(proxy["udp"], .bool(true))

        var bad = node
        bad.credentials.password = .inline("c2hvcnQ=")
        let refused = MihomoConfigCompiler().compile(profile([bad]))
        XCTAssertEqual(refused.report.verdict, .blocked)
        XCTAssertEqual(refused.report.excludedOutbounds, ["ss"])
        XCTAssertFalse(refused.report.issues.contains { $0.detail.contains("c2hvcnQ") }, "credential leaked into the report")
    }

    func testTrojanPinAndHysteria2MobileWindows() throws {
        let trojanLink = "trojan://\(ProfileFixtures.password)@192.0.2.3:443?security=tls&sni=t.example&type=ws&path=%2Fws&host=h.example&pcs=aabb" + String(repeating: "cd", count: 30) + "#t"
        let trojan = try importer.importLink(trojanLink).outbound
        let hy2 = try importer.importLink("hysteria2://\(ProfileFixtures.password)@192.0.2.4:8443/?sni=h.example&obfs=salamander&obfs-password=abcdefgh#h").outbound
        let compilation = MihomoConfigCompiler(options: .packetTunnel()).compile(profile([trojan, hy2]))
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let list = proxies(compilation.document)
        guard list.count == 2 else { return XCTFail("expected two proxies") }
        XCTAssertEqual(list[0]["sni"], .string("t.example"))
        XCTAssertNil(list[0]["tls"], "Trojan has no tls key")
        XCTAssertEqual(list[0]["network"], .string("ws"))
        XCTAssertEqual(list[0]["ws-opts"]?["path"], .string("/ws"))
        XCTAssertEqual(list[0]["ws-opts"]?["headers"]?["Host"], .string("h.example"))
        XCTAssertEqual(list[0]["fingerprint"], .string("aabb" + String(repeating: "cd", count: 30)))
        XCTAssertEqual(list[1]["type"], .string("hysteria2"))
        XCTAssertEqual(list[1]["obfs"], .string("salamander"))
        XCTAssertEqual(list[1]["obfs-password"], .string("abcdefgh"))
        XCTAssertEqual(list[1]["max-connection-receive-window"], .integer(4 << 20))
        XCTAssertEqual(list[1]["initial-stream-receive-window"], .integer(512 << 10))
    }

    func testTrojanWithoutTLSAndKCPAreRefused() {
        var trojan = ProfileFixtures.trojan("t", host: "192.0.2.5")
        trojan.stream.security = .none
        var kcp = ProfileFixtures.vless("k", host: "192.0.2.6")
        kcp.stream.transport = .kcp(KCPSettings())
        let compilation = MihomoConfigCompiler().compile(profile([trojan, kcp]))
        XCTAssertEqual(compilation.report.verdict, .blocked)
        XCTAssertEqual(compilation.report.excludedOutbounds, ["t", "k"])
    }

    func testHTTPUpgradeIsWebSocketWithUpgradeFlag() throws {
        var node = ProfileFixtures.vless("u", host: "192.0.2.7")
        node.settings = .vless(VLESSSettings())
        node.stream = StreamSettings(transport: .httpUpgrade(HTTPUpgradeSettings(path: "/hu", host: "x.example")), security: .tls(TLSSettings(serverName: "x.example", alpn: ["http/1.1"])))
        let proxy = try XCTUnwrap(proxies(MihomoConfigCompiler().compile(profile([node])).document).first)
        XCTAssertEqual(proxy["network"], .string("ws"))
        XCTAssertEqual(proxy["ws-opts"]?["v2ray-http-upgrade"], .bool(true))
        XCTAssertEqual(proxy["alpn"]?.sequenceValue, [.string("http/1.1")])
    }

    // MARK: - Tunnel and DNS

    func testTunnelAndDNSShape() throws {
        let node = try importer.importLink(realityLink).outbound
        let compilation = MihomoConfigCompiler(options: .packetTunnel(dnsServers: ["9.9.9.9", "https://dns.example/dns-query"])).compile(profile([node]))
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let document = try XCTUnwrap(compilation.document)
        let tun = try XCTUnwrap(document["tun"])
        XCTAssertEqual(tun["enable"], .bool(true))
        XCTAssertEqual(tun["stack"], .string("mips"))
        XCTAssertEqual(tun["mtu"], .integer(1500))
        XCTAssertEqual(tun["dns-hijack"]?.sequenceValue, [.string("any:53"), .string("tcp://any:53")])
        XCTAssertEqual(tun["inet6-address"]?.sequenceValue, [.string("fd66:6e70::1/126")])
        XCTAssertEqual(tun["auto-route"], .bool(false))
        XCTAssertNil(tun["device"])
        XCTAssertNil(tun["file-descriptor"])
        XCTAssertEqual(document["find-process-mode"], .string("off"))
        XCTAssertEqual(document["profile"]?["store-selected"], .bool(false))
        XCTAssertNil(document["external-controller"])
        XCTAssertNil(document["socks-port"])

        let dns = try XCTUnwrap(document["dns"])
        XCTAssertEqual(dns["enable"], .bool(true))
        XCTAssertEqual(dns["enhanced-mode"], .string("redir-host"))
        XCTAssertEqual(dns["fake-ip-range"], .string("198.18.0.1/30"), "the tun's IPv4 address comes from fake-ip-range")
        XCTAssertEqual(dns["ipv6"], .bool(true))
        XCTAssertEqual(dns["nameserver"]?.sequenceValue, [.string("9.9.9.9#proxy-0000"), .string("https://dns.example/dns-query#proxy-0000")])
        XCTAssertEqual(dns["default-nameserver"]?.sequenceValue, [.string("9.9.9.9#proxy-0000")])
        XCTAssertNil(dns["proxy-server-nameserver"], "no server is named by a domain")
        XCTAssertNil(dns["listen"])

        let plan = try XCTUnwrap(compilation.tunnel)
        let ruleList = rules(compilation.document)
        XCTAssertEqual(ruleList.first, "IP-CIDR,192.0.2.1/32,DIRECT,no-resolve")
        XCTAssertEqual(ruleList.count, plan.excludedRoutes.count + 1)
        XCTAssertTrue(ruleList.contains("IP-CIDR6,fe80::/10,DIRECT,no-resolve"))
        XCTAssertEqual(ruleList.last, "MATCH,proxy-0000")
    }

    func testDomainServerGetsDirectProxyServerResolverAndBypassingDNSIsRefused() throws {
        let node = ProfileFixtures.vless("a", host: "server.example")
        let compilation = MihomoConfigCompiler(options: .packetTunnel()).compile(profile([node]))
        let dns = try XCTUnwrap(compilation.document?["dns"])
        XCTAssertEqual(dns["proxy-server-nameserver"]?.sequenceValue, [.string("1.1.1.1"), .string("8.8.8.8")])
        XCTAssertEqual(dns["nameserver"]?.sequenceValue, [.string("1.1.1.1#proxy-0000"), .string("8.8.8.8#proxy-0000")])

        for server in ["localhost", "https+local://dns.example/dns-query", "fakedns"] {
            let refused = MihomoConfigCompiler(options: .packetTunnel(dnsServers: [server])).compile(profile([node]))
            XCTAssertEqual(refused.report.verdict, .blocked, server)
        }
    }

    func testNoIPv6TunnelAndFakeIP() throws {
        var addressing = TunnelAddressing.standard
        addressing.ipv6Address = nil
        addressing.ipv6PrefixLength = nil
        addressing.dnsIPv6Address = nil
        var options = MihomoCompileOptions.packetTunnel(addressing: addressing)
        options.fakeIP = true
        let compilation = MihomoConfigCompiler(options: options).compile(profile([ProfileFixtures.vless("a", host: "192.0.2.1")]))
        let document = try XCTUnwrap(compilation.document)
        XCTAssertEqual(document["tun"]?["inet6-address"], .sequence([]))
        XCTAssertEqual(document["ipv6"], .bool(false))
        XCTAssertEqual(document["dns"]?["enhanced-mode"], .string("fake-ip"))
        XCTAssertEqual(document["dns"]?["fake-ip-range"], .string("198.18.0.1/16"))
        XCTAssertTrue(compilation.report.hasIssue(.untested, pathContaining: "fakeIP"))
    }

    func testLocalSOCKSPortAndLogLevel() {
        let compilation = MihomoConfigCompiler(options: MihomoCompileOptions(logLevel: "none", localSOCKSPort: 10808))
            .compile(profile([ProfileFixtures.vless("a", host: "192.0.2.1")]))
        XCTAssertEqual(compilation.document?["socks-port"], .integer(10808))
        XCTAssertEqual(compilation.document?["bind-address"], .string("127.0.0.1"))
        XCTAssertEqual(compilation.document?["log-level"], .string("silent"))
        XCTAssertNil(compilation.document?["tun"])
        XCTAssertNil(compilation.document?["dns"])
    }

    // MARK: - Groups

    func testGroupsMapOneToOneIncludingNesting() throws {
        let a = ProfileFixtures.vless("a", host: "192.0.2.1")
        let b = ProfileFixtures.trojan("b", host: "192.0.2.2")
        let check = OutboundGroup.HealthCheck(url: "https://probe.example/204", intervalSeconds: 60, timeoutMilliseconds: 3000, toleranceMilliseconds: 50)
        let groups = [
            OutboundGroup(tag: "auto", name: "Auto", kind: .urlTest, members: [.outbound(tag: "a"), .outbound(tag: "b")], healthCheck: check),
            OutboundGroup(tag: "fb", name: "FB", kind: .fallback, members: [.outbound(tag: "b"), .outbound(tag: "a")]),
            OutboundGroup(tag: "lb", name: "LB", kind: .loadBalance, members: [.outbound(tag: "a"), .outbound(tag: "b")], strategy: .consistentHashing),
            OutboundGroup(tag: "main", name: "Main", kind: .selector, members: [.group(tag: "auto"), .group(tag: "fb"), .outbound(tag: "a")], defaultMemberTag: "fb"),
        ]
        let compilation = MihomoConfigCompiler().compile(profile([a, b], groups: groups, selected: "main"))
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let list = try XCTUnwrap(compilation.document?["proxy-groups"]?.sequenceValue)
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list[0]["type"], .string("url-test"))
        XCTAssertEqual(list[0]["url"], .string("https://probe.example/204"))
        XCTAssertEqual(list[0]["interval"], .integer(60))
        XCTAssertEqual(list[0]["timeout"], .integer(3000))
        XCTAssertEqual(list[0]["tolerance"], .integer(50))
        XCTAssertEqual(list[1]["type"], .string("fallback"))
        XCTAssertEqual(list[1]["proxies"]?.sequenceValue, [.string("proxy-0001"), .string("proxy-0000")])
        XCTAssertEqual(list[2]["strategy"], .string("consistent-hashing"))
        XCTAssertEqual(list[3]["type"], .string("select"))
        XCTAssertEqual(list[3]["proxies"]?.sequenceValue, [.string("group-0001"), .string("group-0000"), .string("proxy-0000")], "default member first")
        XCTAssertEqual(rules(compilation.document).last, "MATCH,group-0003")
        XCTAssertEqual(compilation.report.engineTags["main"], "group-0003")
    }

    func testGroupWithoutCompiledMembersIsLeftOut() {
        var broken = ProfileFixtures.trojan("t", host: "192.0.2.5")
        broken.stream.security = .none
        let a = ProfileFixtures.vless("a", host: "192.0.2.1")
        let groups = [OutboundGroup(tag: "g", name: "g", kind: .urlTest, members: [.outbound(tag: "t")])]
        let ok = MihomoConfigCompiler().compile(profile([a, broken], groups: groups, selected: "a"))
        XCTAssertEqual(ok.report.verdict, .degraded)
        XCTAssertNil(ok.document?["proxy-groups"])
        let selected = MihomoConfigCompiler().compile(profile([a, broken], groups: groups, selected: "g"))
        XCTAssertEqual(selected.report.verdict, .blocked)
    }

    // MARK: - Routing

    private func routed(_ table: RoutingTable, groups: [OutboundGroup] = []) -> MihomoCompilation {
        let a = ProfileFixtures.vless("a", host: "192.0.2.1")
        let b = ProfileFixtures.trojan("b", host: "192.0.2.2")
        let options = MihomoCompileOptions(routing: table)
        return MihomoConfigCompiler(options: options).compile(profile([a, b], groups: groups, selected: "a"))
    }

    func testSingleFieldRulesSplitPerValue() {
        let table = RoutingTable(rules: [
            RoutingRule(condition: .or([.domainSuffix("example.com"), .domain("a.example.org"), .domainKeyword("ads"), .domainRegex("^x(1|2),y$")]), action: .reject),
            RoutingRule(condition: .port(RoutingEngine.PortRange(lower: 1000, upper: 2000)!), action: .proxy("b")),
        ], finalAction: .proxy("a"))
        let compilation = routed(table)
        XCTAssertEqual(compilation.report.verdict, .exact, "\(compilation.report.issues)")
        XCTAssertEqual(rules(compilation.document), [
            "DOMAIN-SUFFIX,example.com,REJECT",
            "DOMAIN,a.example.org,REJECT",
            "DOMAIN-KEYWORD,ads,REJECT",
            "DOMAIN-REGEX,^x(1|2),y$,REJECT",
            "DST-PORT,1000-2000,proxy-0001",
            "MATCH,proxy-0000",
        ])
    }

    func testConjunctionBecomesLogicRuleAndAsIsAddsNoResolve() {
        let cidr = IPCIDR("10.0.0.0/8")!
        let cidr6 = IPCIDR("2001:db8::/32")!
        let table = RoutingTable(rules: [
            RoutingRule(condition: .and([.or([.ipCIDR(cidr), .ipCIDR(cidr6)]), .port(RoutingEngine.PortRange(443)), .network(.udp)]), action: .direct),
        ], finalAction: .proxy("a"))
        XCTAssertEqual(rules(routed(table).document), [
            "AND,((OR,((IP-CIDR,10.0.0.0/8,no-resolve),(IP-CIDR6,2001:db8::/32,no-resolve))),(DST-PORT,443),(NETWORK,udp)),DIRECT",
            "MATCH,proxy-0000",
        ])
        var onDemand = table
        onDemand.domainStrategy = .ipOnDemand
        XCTAssertEqual(rules(routed(onDemand).document).first,
                       "AND,((OR,((IP-CIDR,10.0.0.0/8),(IP-CIDR6,2001:db8::/32))),(DST-PORT,443),(NETWORK,udp)),DIRECT")
    }

    func testIPNotInRequiresAnAddress() {
        let table = RoutingTable(rules: [
            RoutingRule(condition: .ipNotIn([IPCIDR("192.168.0.0/16")!]), action: .proxy("b")),
        ], finalAction: .direct)
        XCTAssertEqual(rules(routed(table).document), [
            "AND,((OR,((IP-CIDR,0.0.0.0/0,no-resolve),(IP-CIDR6,::/0,no-resolve))),(NOT,((IP-CIDR,192.168.0.0/16,no-resolve)))),proxy-0001",
            "MATCH,DIRECT",
        ])
    }

    func testIPIfNonMatchRepeatsAddressRulesWithResolution() {
        let table = RoutingTable(rules: [
            RoutingRule(condition: .domainSuffix("example.com"), action: .proxy("b")),
            RoutingRule(condition: .ipCIDR(IPCIDR("203.0.113.0/24")!), action: .direct),
        ], finalAction: .proxy("a"), domainStrategy: .ipIfNonMatch)
        XCTAssertEqual(rules(routed(table).document), [
            "DOMAIN-SUFFIX,example.com,proxy-0001",
            "IP-CIDR,203.0.113.0/24,DIRECT,no-resolve",
            "IP-CIDR,203.0.113.0/24,DIRECT",
            "MATCH,proxy-0000",
        ])
    }

    func testChainBecomesDialerProxyCopies() throws {
        let groups = [OutboundGroup(tag: "g", name: "g", kind: .selector, members: [.outbound(tag: "a")])]
        let table = RoutingTable(rules: [
            RoutingRule(condition: .domain("x.example"), action: .chain(["g", "b"])),
            RoutingRule(condition: .domain("y.example"), action: .chain(["g", "b"])),
        ], finalAction: .group("g"))
        let compilation = routed(table, groups: groups)
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let list = proxies(compilation.document)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[2]["name"], .string("chain-0000-1"))
        XCTAssertEqual(list[2]["dialer-proxy"], .string("group-0000"))
        XCTAssertEqual(list[2]["type"], .string("trojan"))
        XCTAssertEqual(rules(compilation.document), ["DOMAIN,x.example,chain-0000-1", "DOMAIN,y.example,chain-0000-1", "MATCH,group-0000"])

        let refused = routed(RoutingTable(rules: [RoutingRule(condition: .domain("x.example"), action: .chain(["a", "g"]))], finalAction: .direct), groups: groups)
        XCTAssertEqual(refused.report.verdict, .blocked)
    }

    func testRulesWithoutMihomoFormBlock() {
        for condition in [RuleCondition.not(.domain("x.example")), .inboundTag("tun-in"), .sniffedProtocol("tls"), .and([.domain("a.example"), .domain("b.example")])] {
            let compilation = routed(RoutingTable(rules: [RoutingRule(condition: condition, action: .direct)], finalAction: .proxy("a")))
            XCTAssertEqual(compilation.report.verdict, .blocked, "\(condition)")
            XCTAssertNil(compilation.document)
        }
        let unknown = routed(RoutingTable(rules: [RoutingRule(condition: .domain("x.example"), action: .proxy("missing"))], finalAction: .direct))
        XCTAssertEqual(unknown.report.verdict, .blocked)
    }

    func testManyPortsAreChunked() {
        let ports = (1...30).map { RoutingEngine.PortRange(UInt16($0 * 10)) }
        let table = RoutingTable(rules: [RoutingRule(condition: .or(ports.map { .port($0) }), action: .direct)], finalAction: .proxy("a"))
        let list = rules(routed(table).document)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].split(separator: "/").count, MihomoRuleCompiler.maximumPortRanges)
        XCTAssertEqual(list[1], "DST-PORT,290/300,DIRECT")
    }

    // MARK: - Determinism and redaction

    func testDeterministicAndRedacted() throws {
        let node = try importer.importLink(realityLink).outbound
        var broken = node
        broken.tag = "x"
        broken.stream.security = .reality(RealitySettings(serverName: "secret-sni.example", fingerprint: "hellogolang", publicKey: ProfileFixtures.realityKey))
        let compiler = MihomoConfigCompiler(options: .packetTunnel())
        let first = compiler.compile(profile([node, broken]))
        XCTAssertEqual(first.yamlText(), compiler.compile(profile([node, broken])).yamlText())
        XCTAssertEqual(first.report, compiler.compile(profile([node, broken])).report)
        for issue in first.report.issues {
            XCTAssertFalse(issue.detail.contains(ProfileFixtures.uuidA), issue.detail)
            XCTAssertFalse(issue.detail.contains("192.0.2.1"), issue.detail)
        }
    }

    func testSecretReferencesAreResolved() throws {
        var node = ProfileFixtures.vless("a", host: "192.0.2.1")
        node.credentials.userID = .reference(SecretReference(identifier: "k1"))
        let unresolved = MihomoConfigCompiler().compile(profile([node]))
        XCTAssertEqual(unresolved.report.verdict, .blocked)
        let resolved = MihomoConfigCompiler(resolveSecret: { $0.identifier == "k1" ? ProfileFixtures.uuidB : nil }).compile(profile([node]))
        XCTAssertEqual(proxies(resolved.document).first?["uuid"], .string(ProfileFixtures.uuidB))
    }

    // MARK: - Export for the Linux lab

    /// For `Cores/BuildScripts/bridge-tunlab.sh compiled` with ENGINE=mihomo: set NP_EXPORT_DIR and NP_EXPORT_LINK
    /// (one or more share links separated by whitespace; NP_EXPORT_DNS optional). Each link is compiled with the
    /// packet tunnel options and written to DIR/<link name>/: config.yaml, plan.json, report.json and
    /// bridge-options.json (the options the extension gives the bridge: flow mode, mobile memory profile).
    func testExportCompiledMihomoConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        let links = (environment["NP_EXPORT_LINK"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let dns = (environment["NP_EXPORT_DNS"] ?? "").split(separator: ",").map(String.init)
        for link in links.isEmpty ? [realityLink] : links {
            let imported = try importer.importLink(link)
            let compilation = MihomoConfigCompiler(options: .packetTunnel(dnsServers: dns)).compile(profile([imported.outbound]))
            XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
            let text = try XCTUnwrap(compilation.yamlText())
            let plan = try XCTUnwrap(compilation.tunnel)
            guard let directory = environment["NP_EXPORT_DIR"], !directory.isEmpty else { continue }
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(imported.outbound.tag, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try Data(text.utf8).write(to: url.appendingPathComponent("config.yaml"))
            try encoder.encode(plan).write(to: url.appendingPathComponent("plan.json"))
            try encoder.encode(compilation.report).write(to: url.appendingPathComponent("report.json"))
            try Data(#"{"memory":{"profile":"mobile"},"tun":{"mode":"flow"}}"#.utf8).write(to: url.appendingPathComponent("bridge-options.json"))
        }
    }
}
