import Foundation
import XCTest
import DomainModels
import RoutingEngine
@testable import ConfigurationEngine

/// Mihomo half of the golden corpus under `Tests/Fixtures`: the same share links and profiles as the Xray
/// corpus, compiled with the Packet Tunnel options (`MihomoCompileOptions.packetTunnel()`).
///
/// `ShareLinks|Interop/<name>.link` and `Profiles/<name>.profile.json` → `<name>.mihomo.yaml` (absent when
/// the compiler blocks) and `<name>.mihomo-report.json`. `Routing/<name>.routing.json` (a RoutingTable over
/// the profile `routingProfile`) → the same two files.
///
/// The `.mihomo.yaml` files are what `Tools/validate-fixtures.sh` feeds to the real binary (`mihomo -t`).
/// Regenerate with `NP_UPDATE_FIXTURES=1 swift test --filter MihomoFixtureCorpusTests` and review the diff.
final class MihomoFixtureCorpusTests: XCTestCase {
    private static let updating = ProcessInfo.processInfo.environment["NP_UPDATE_FIXTURES"] == "1"
    private static let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let options = MihomoCompileOptions.packetTunnel()

    private static var fixturesRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Tests/Fixtures")
    }

    private func pretty<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }

    private func names(in directory: URL, suffix: String) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return files.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted()
    }

    private func check(_ actual: String?, at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let manager = FileManager.default
        if MihomoFixtureCorpusTests.updating {
            if let actual = actual {
                try actual.write(to: url, atomically: true, encoding: .utf8)
            } else if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            return
        }
        guard let actual = actual else {
            XCTAssertFalse(manager.fileExists(atPath: url.path), "\(url.lastPathComponent) must not exist", file: file, line: line)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("missing fixture file \(url.lastPathComponent)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, "\(url.lastPathComponent) differs", file: file, line: line)
    }

    private func compileAndCheck(_ profile: Profile, options: MihomoCompileOptions, base: URL, name: String) throws -> MihomoCompilation {
        let compiler = MihomoConfigCompiler(options: options)
        let compilation = compiler.compile(profile)
        XCTAssertEqual(compiler.compile(profile).report, compilation.report, "report is not deterministic: \(name)")
        XCTAssertEqual(compiler.compile(profile).yamlText(), compilation.yamlText(), "output is not deterministic: \(name)")
        try check(pretty(compilation.report), at: base.appendingPathComponent(name + ".mihomo-report.json"))
        try check(compilation.yamlText(), at: base.appendingPathComponent(name + ".mihomo.yaml"))
        XCTAssertEqual(compilation.document == nil, compilation.report.verdict == .blocked, name)
        if compilation.report.verdict == .blocked {
            XCTAssertTrue(compilation.report.issues.contains { $0.severity == .error }, "blocked without a reason: \(name)")
        }
        // REALITY entries always carry the flag Xray 26.11.9 servers need.
        for proxy in compilation.document?["proxies"]?.sequenceValue ?? [] where proxy["reality-opts"] != nil {
            XCTAssertEqual(proxy["reality-opts"]?["support-x25519mlkem768"], .bool(true), name)
        }
        return compilation
    }

    private func checkLinks(_ directoryName: String, minimum: Int) throws -> [String: MihomoCompilation] {
        let directory = MihomoFixtureCorpusTests.fixturesRoot.appendingPathComponent(directoryName)
        let fixtures = try names(in: directory, suffix: ".link")
        XCTAssertGreaterThanOrEqual(fixtures.count, minimum)
        var result: [String: MihomoCompilation] = [:]
        for name in fixtures {
            let link = try String(contentsOf: directory.appendingPathComponent(name + ".link"), encoding: .utf8)
            let imported = try ShareLinkImporter().importLink(link)
            let profile = Profile(
                id: MihomoFixtureCorpusTests.profileID, name: name, source: .shareLink,
                outbounds: [imported.outbound], selectedTag: imported.outbound.tag
            )
            result[name] = try compileAndCheck(profile, options: MihomoFixtureCorpusTests.options, base: directory, name: name)
        }
        return result
    }

    func testShareLinkCorpus() throws {
        let compiled = try checkLinks("ShareLinks", minimum: 30)
        // The protocols the end-to-end lab runs must compile.
        for name in ["vless-reality-vision-tcp", "ss-2022-aes128", "trojan-tcp-tls", "hysteria2-basic"] {
            XCTAssertNotNil(compiled[name]?.document, name)
        }
    }

    func testInteropCorpus() throws {
        let compiled = try checkLinks("Interop", minimum: 15)
        XCTAssertGreaterThanOrEqual(compiled.values.filter { $0.document != nil }.count, 12)
    }

    func testProfileCorpus() throws {
        let directory = MihomoFixtureCorpusTests.fixturesRoot.appendingPathComponent("Profiles")
        for name in try names(in: directory, suffix: ".profile.json") {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".profile.json"))
            let profile = try JSONDecoder().decode(Profile.self, from: data)
            _ = try compileAndCheck(profile, options: MihomoFixtureCorpusTests.options, base: directory, name: name)
        }
    }

    // MARK: - Routing

    static var routingProfile: Profile {
        let a = ProfileFixtures.vless("a", host: "192.0.2.80")
        let t = ProfileFixtures.trojan("t", host: "t.example.com")
        let groups = [
            OutboundGroup(tag: "auto", name: "Auto", kind: .urlTest, members: [.outbound(tag: "a"), .outbound(tag: "t")]),
            OutboundGroup(tag: "main", name: "Main", kind: .selector, members: [.group(tag: "auto"), .outbound(tag: "a")]),
        ]
        return Profile(id: profileID, name: "routing", outbounds: [a, t], groups: groups, selectedTag: "main")
    }

    static var routingTables: [(String, RoutingTable)] {
        let lan = [IPCIDR("10.0.0.0/8")!, IPCIDR("192.168.0.0/16")!, IPCIDR("fc00::/7")!]
        let rules = [
            RoutingRule(id: "ads", condition: .or([.domainSuffix("ads.example"), .domainKeyword("tracker"), .domainRegex("^ad[0-9]+\\.example\\.net$")]), action: .reject),
            RoutingRule(id: "lan", condition: .or(lan.map { .ipCIDR($0) }), action: .direct),
            RoutingRule(id: "quic", condition: .and([.network(.udp), .port(RoutingEngine.PortRange(443))]), action: .reject),
            RoutingRule(id: "video", condition: .and([.domainSuffix("video.example"), .or([.port(RoutingEngine.PortRange(443)), .port(RoutingEngine.PortRange(lower: 8000, upper: 8999)!)])]), action: .proxy("t")),
            RoutingRule(id: "chain", condition: .domain("chained.example"), action: .chain(["auto", "t"])),
            RoutingRule(id: "abroad", condition: .ipNotIn([IPCIDR("198.51.100.0/24")!]), action: .group("auto")),
            RoutingRule(id: "src", condition: .and([.sourceCIDR(IPCIDR("198.18.0.0/30")!), .sourcePort(RoutingEngine.PortRange(lower: 1024, upper: 65535)!)]), action: .group("main")),
        ]
        var onDemand = RoutingTable(rules: rules, finalAction: .group("main"), domainStrategy: .ipOnDemand)
        onDemand.rules.removeAll { $0.id == "chain" }
        return [
            ("as-is", RoutingTable(rules: rules, finalAction: .group("main"), domainStrategy: .asIs)),
            ("ip-on-demand", onDemand),
            ("ip-if-non-match", RoutingTable(rules: rules.filter { $0.id != "chain" }, finalAction: .proxy("a"), domainStrategy: .ipIfNonMatch)),
            ("not-lowerable", RoutingTable(rules: [RoutingRule(condition: .not(.domain("x.example")), action: .direct)], finalAction: .group("main"))),
            ("inbound-tag", RoutingTable(rules: [RoutingRule(condition: .inboundTag("tun-in"), action: .direct)], finalAction: .group("main"))),
        ]
    }

    func testRoutingCorpus() throws {
        let directory = MihomoFixtureCorpusTests.fixturesRoot.appendingPathComponent("Routing")
        if MihomoFixtureCorpusTests.updating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let tables = MihomoFixtureCorpusTests.routingTables
        for (name, table) in tables {
            try check(pretty(table), at: directory.appendingPathComponent(name + ".routing.json"))
        }
        XCTAssertEqual(try names(in: directory, suffix: ".routing.json"), tables.map { $0.0 }.sorted())
        var verdicts: [String: ConversionReport.Verdict] = [:]
        for name in try names(in: directory, suffix: ".routing.json") {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".routing.json"))
            var options = MihomoFixtureCorpusTests.options
            options.routing = try JSONDecoder().decode(RoutingTable.self, from: data)
            verdicts[name] = try compileAndCheck(MihomoFixtureCorpusTests.routingProfile, options: options, base: directory, name: name).report.verdict
        }
        XCTAssertNotEqual(verdicts["as-is"], .blocked)
        XCTAssertNotEqual(verdicts["ip-if-non-match"], .blocked)
        XCTAssertEqual(verdicts["not-lowerable"], .blocked)
        XCTAssertEqual(verdicts["inbound-tag"], .blocked)
    }
}
