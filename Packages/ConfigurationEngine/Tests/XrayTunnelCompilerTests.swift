import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

/// The tunnel part of the Xray compiler: what the bridge's packet path (`tun.mode = "flow"`) needs.
final class XrayTunnelCompilerTests: XCTestCase {
    private let importer = ShareLinkImporter()
    private let link = "vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?type=tcp&security=reality&sni=www.example.org"
        + "&fp=chrome&pbk=\(ProfileFixtures.realityKey)&sid=0a1b&flow=xtls-rprx-vision#lab"

    private func profile(_ outbounds: [Outbound], groups: [OutboundGroup] = [], selected: String? = nil) -> Profile {
        Profile(name: "p", outbounds: outbounds, groups: groups, selectedTag: selected ?? outbounds.first?.tag)
    }

    private func rules(_ config: JSONValue?) -> [JSONValue] {
        config?["routing"]?["rules"]?.arrayValue ?? []
    }

    func testTunnelInboundDNSHijackAndExclusions() throws {
        let node = try importer.importLink(link).outbound
        let compilation = XrayConfigCompiler(options: .packetTunnel(dnsServers: ["9.9.9.9"])).compile(profile([node]))
        XCTAssertEqual(compilation.report.verdict, .exact, "\(compilation.report.issues)")
        let config = try XCTUnwrap(compilation.config)
        let plan = try XCTUnwrap(compilation.tunnel)
        let addressing = TunnelAddressing.standard
        XCTAssertEqual(plan.addressing, addressing)

        // The inbound the bridge replaces in flow mode: protocol tun, the shared MTU, user level 0.
        let inbounds = try XCTUnwrap(config["inbounds"]?.arrayValue)
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["protocol"], .string("tun"))
        XCTAssertEqual(inbounds[0]["tag"], .string(XrayConfigCompiler.tunInboundTag))
        XCTAssertEqual(inbounds[0]["settings"]?["mtu"], .integer(Int64(addressing.mtu)))
        XCTAssertNil(inbounds[0]["settings"]?["userLevel"], "level 0: the mobile policy applies")
        XCTAssertNil(inbounds[0]["settings"]?["name"])

        // The core's resolver: given servers, own tag; a dns outbound answers hijacked queries.
        XCTAssertEqual(config["dns"]?["servers"], .array([.string("9.9.9.9")]))
        XCTAssertEqual(config["dns"]?["tag"], .string(XrayConfigCompiler.dnsInternalTag))
        let outbounds = try XCTUnwrap(config["outbounds"]?.arrayValue)
        XCTAssertTrue(outbounds.contains { $0["protocol"] == .string("dns") && $0["tag"] == .string(XrayConfigCompiler.dnsOutboundTag) })
        XCTAssertEqual(config["policy"]?["levels"]?["0"]?["connIdle"], .integer(30), "packet tunnel options use the mobile profile")

        let routing = rules(config)
        XCTAssertEqual(routing.count, 4)
        // 1: every UDP/53 from the tunnel, whatever the address, goes to the core's DNS.
        XCTAssertEqual(routing[0]["inboundTag"], .array([.string("tun-in")]))
        XCTAssertEqual(routing[0]["port"], .string("53"))
        XCTAssertEqual(routing[0]["network"], .string("udp"))
        XCTAssertNil(routing[0]["ip"], "hijack is not limited to the tunnel's resolver addresses")
        XCTAssertEqual(routing[0]["outboundTag"], .string("dns-out"))
        // 2: the resolver's own queries go through the proxy, not to a system resolver.
        XCTAssertEqual(routing[1]["inboundTag"], .array([.string("dns-internal")]))
        XCTAssertEqual(routing[1]["outboundTag"], .string("proxy-0000"))
        // 3: server address and local ranges go direct, the same list the system excludes.
        XCTAssertEqual(routing[2]["outboundTag"], .string("direct"))
        let direct = try XCTUnwrap(routing[2]["ip"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(direct, plan.excludedRoutes.map(\.cidr))
        XCTAssertEqual(direct.first, "192.0.2.1/32")
        for route in TunnelAddressing.localRoutes {
            XCTAssertTrue(direct.contains(route.cidr), route.cidr)
        }
        // 4: everything else through the proxy.
        XCTAssertEqual(routing[3]["outboundTag"], .string("proxy-0000"))
        XCTAssertEqual(plan.remoteAddress, "192.0.2.1")
    }

    func testTunnelAddressesStayInsideTheTunnel() {
        // The resolver addresses the system gets must enter the tunnel: no excluded or direct route covers them.
        let addressing = TunnelAddressing.standard
        for address in addressing.dnsServers + [addressing.ipv4Address] + (addressing.ipv6Address.map { [$0] } ?? []) {
            for route in TunnelAddressing.localRoutes where route.isIPv6 == address.contains(":") {
                XCTAssertFalse(TunnelAddressingTests.contains(route, address), "\(address) is inside \(route.cidr)")
            }
        }
        XCTAssertEqual(addressing.ipv4SubnetMask, "255.255.255.252")
    }

    func testBalancerReceivesResolverQueries() throws {
        let a = ProfileFixtures.vless("a", host: "192.0.2.1")
        let b = ProfileFixtures.vless("b", host: "2001:db8::7")
        let group = OutboundGroup(tag: "auto", name: "auto", kind: .urlTest, members: [.outbound(tag: "a"), .outbound(tag: "b")])
        let compilation = XrayConfigCompiler(options: .packetTunnel()).compile(profile([a, b], groups: [group], selected: "auto"))
        let config = try XCTUnwrap(compilation.config)
        let routing = rules(config)
        XCTAssertEqual(routing[1]["balancerTag"], .string("group-0000"))
        XCTAssertEqual(routing[3]["balancerTag"], .string("group-0000"))
        let plan = try XCTUnwrap(compilation.tunnel)
        XCTAssertEqual(Array(plan.excludedRoutes.prefix(2)), [TunnelRoute.host("192.0.2.1"), TunnelRoute.host("2001:db8::7")])
        XCTAssertEqual(plan.excludedRoutes[1].cidr, "2001:db8::7/128")
    }

    func testDefaultResolversAreUsedThroughTheProxy() throws {
        let node = ProfileFixtures.vless("a", host: "192.0.2.1")
        let compilation = XrayConfigCompiler(options: .packetTunnel()).compile(profile([node]))
        XCTAssertEqual(
            compilation.config?["dns"]?["servers"],
            .array(XrayConfigCompiler.defaultTunnelDNSServers.map { .string($0) })
        )
        XCTAssertTrue(compilation.report.hasIssue(.migrated, pathContaining: "options.dnsServers"))
        XCTAssertEqual(compilation.report.verdict, .exact, "a default is an info, not a degradation")
    }

    func testResolversOutsideTheTunnelAreRefused() {
        let node = ProfileFixtures.vless("a", host: "192.0.2.1")
        for server in ["localhost", "https+local://dns.example/dns-query", "TCP+LOCAL://9.9.9.9"] {
            let compilation = XrayConfigCompiler(options: .packetTunnel(dnsServers: ["9.9.9.9", server])).compile(profile([node]))
            XCTAssertEqual(compilation.report.verdict, .blocked, server)
            XCTAssertNil(compilation.config, server)
            XCTAssertNil(compilation.tunnel, server)
            XCTAssertTrue(compilation.report.issues.contains { $0.path == "options.dnsServers[1]" && $0.severity == .error }, server)
        }
        // Without a tunnel the same servers are the caller's business.
        let plain = XrayConfigCompiler(options: XrayCompileOptions(dnsServers: ["localhost"])).compile(profile([node]))
        XCTAssertNotNil(plain.config)
    }

    func testDomainServerIsReportedNotExcluded() throws {
        let node = ProfileFixtures.vless("a", host: "vpn.example.com")
        let compilation = XrayConfigCompiler(options: .packetTunnel()).compile(profile([node]))
        let plan = try XCTUnwrap(compilation.tunnel)
        XCTAssertEqual(plan.excludedRoutes, TunnelAddressing.localRoutes)
        XCTAssertEqual(plan.remoteAddress, TunnelAddressing.standard.ipv4Address)
        let issue = try XCTUnwrap(compilation.report.issues.first { $0.path == "options.tunnel" })
        XCTAssertEqual(issue.kind, .untested)
        XCTAssertFalse(issue.detail.contains("vpn.example.com"), "the report does not name the server")
    }

    func testOutOfRangeMTUIsRefused() {
        var addressing = TunnelAddressing.standard
        addressing.mtu = 100
        let compilation = XrayConfigCompiler(options: .packetTunnel(addressing: addressing))
            .compile(profile([ProfileFixtures.vless("a", host: "192.0.2.1")]))
        XCTAssertEqual(compilation.report.verdict, .blocked)
    }

    func testCompileOptionsWithTunnelRoundTrip() throws {
        let options = XrayCompileOptions.packetTunnel(dnsServers: ["1.1.1.1"])
        let decoded = try JSONDecoder().decode(XrayCompileOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
        let old = Data(#"{"logLevel":"warning","dnsServers":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(XrayCompileOptions.self, from: old).tunnel)
    }

    /// Exports a compilation for the end-to-end run on Linux (`Cores/BuildScripts/bridge-tunlab.sh compiled`):
    /// set NP_EXPORT_DIR (and NP_EXPORT_LINK, NP_EXPORT_DNS) to write config.json, plan.json and report.json.
    /// Without them the same compilation is checked and nothing is written.
    func testExportCompiledTunnelConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        let shareLink = environment["NP_EXPORT_LINK"].flatMap { $0.isEmpty ? nil : $0 } ?? link
        let dns = (environment["NP_EXPORT_DNS"] ?? "").split(separator: ",").map(String.init)
        let imported = try importer.importLink(shareLink)
        let compilation = XrayConfigCompiler(options: .packetTunnel(dnsServers: dns)).compile(profile([imported.outbound]))
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let text = try XCTUnwrap(try compilation.jsonText())
        let plan = try XCTUnwrap(compilation.tunnel)
        guard let directory = environment["NP_EXPORT_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try Data(text.utf8).write(to: url.appendingPathComponent("config.json"))
        try encoder.encode(plan).write(to: url.appendingPathComponent("plan.json"))
        try encoder.encode(compilation.report).write(to: url.appendingPathComponent("report.json"))
    }
}

/// `TunnelAddressing` and `TunnelRoute` of DomainModels, as the compiler uses them.
final class TunnelAddressingTests: XCTestCase {
    func testSubnetMasks() {
        XCTAssertEqual(TunnelRoute.ipv4SubnetMask(prefixLength: 0), "0.0.0.0")
        XCTAssertEqual(TunnelRoute.ipv4SubnetMask(prefixLength: 8), "255.0.0.0")
        XCTAssertEqual(TunnelRoute.ipv4SubnetMask(prefixLength: 12), "255.240.0.0")
        XCTAssertEqual(TunnelRoute.ipv4SubnetMask(prefixLength: 30), "255.255.255.252")
        XCTAssertEqual(TunnelRoute.ipv4SubnetMask(prefixLength: 32), "255.255.255.255")
        XCTAssertNil(TunnelRoute.ipv4SubnetMask(prefixLength: 33))
        XCTAssertNil(TunnelRoute(address: "fe80::", prefixLength: 10).ipv4SubnetMask)
        XCTAssertEqual(TunnelRoute.host("2001:db8::1").prefixLength, 128)
        XCTAssertEqual(TunnelRoute.host("192.0.2.1").cidr, "192.0.2.1/32")
    }

    func testEveryLocalRouteIsANetworkAddress() {
        for route in TunnelAddressing.localIPv4Routes {
            XCTAssertTrue(TunnelAddressingTests.contains(route, route.address), route.cidr)
            XCTAssertFalse(route.isIPv6)
        }
        for route in TunnelAddressing.localIPv6Routes {
            XCTAssertTrue(route.isIPv6)
        }
    }

    /// IPv4 containment, enough for the tests (IPv6 routes are checked by their first group).
    static func contains(_ route: TunnelRoute, _ address: String) -> Bool {
        if route.isIPv6 {
            let group = { (text: String) -> UInt16 in UInt16(text.split(separator: ":").first ?? "0", radix: 16) ?? 0 }
            let bits = min(16, route.prefixLength)
            let mask: UInt16 = bits == 0 ? 0 : UInt16.max << UInt16(16 - bits)
            return group(route.address) & mask == group(address) & mask
        }
        func value(_ text: String) -> UInt32 {
            text.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
        }
        let mask: UInt32 = route.prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - route.prefixLength)
        return value(route.address) & mask == value(address) & mask
    }
}
