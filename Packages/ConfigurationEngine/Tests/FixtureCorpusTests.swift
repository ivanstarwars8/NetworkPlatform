import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

/// Golden corpus under `Tests/Fixtures`.
///
/// `ShareLinks/<name>.link` → `<name>.model.json` (expected `Outbound`),
/// `<name>.report.json` (expected import + compile reports) and `<name>.xray.json`
/// (expected Xray configuration; absent when the compiler blocks the outbound).
/// `Profiles/<name>.profile.json` → `<name>.report.json`, `<name>.xray.json`.
///
/// The `.xray.json` files are what `Tools/validate-fixtures.sh` feeds to the real binary.
/// Regenerate with `NP_UPDATE_FIXTURES=1 swift test --filter FixtureCorpusTests`
/// and review the diff: regeneration never happens implicitly.
final class FixtureCorpusTests: XCTestCase {

    private static let updating = ProcessInfo.processInfo.environment["NP_UPDATE_FIXTURES"] == "1"
    private static let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static let options = XrayCompileOptions(localSOCKSPort: 10808)

    private static var fixturesRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Tests/Fixtures")
    }

    private struct Reports: Codable, Equatable {
        var importReport: ImportReport?
        var conversion: ConversionReport
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

    /// Compares `actual` with the stored file, or rewrites the file in update mode.
    /// `nil` means the file must not exist.
    private func check(_ actual: String?, at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let manager = FileManager.default
        if FixtureCorpusTests.updating {
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

    func testShareLinkCorpus() throws {
        let schemes = try checkLinkDirectory("ShareLinks", minimum: 30)
        for scheme in ["vless", "vmess", "trojan", "ss", "socks", "hysteria2", "hy2", "tuic", "wireguard", "wg"] {
            XCTAssertTrue(schemes.contains(scheme), "no fixture for \(scheme)://")
        }
    }

    /// Links that point at the loopback server of `Tests/Fixtures/Interop/server.json`;
    /// `run-interop.sh` passes real traffic through the configurations compiled here.
    func testInteropCorpus() throws {
        _ = try checkLinkDirectory("Interop", minimum: 15)
        let directory = FixtureCorpusTests.fixturesRoot.appendingPathComponent("Interop")
        for name in try names(in: directory, suffix: ".link") {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".xray.json").path),
                "interop fixture must compile: \(name)"
            )
        }
    }

    private func checkLinkDirectory(_ directoryName: String, minimum: Int) throws -> Set<String> {
        let directory = FixtureCorpusTests.fixturesRoot.appendingPathComponent(directoryName)
        let fixtures = try names(in: directory, suffix: ".link")
        XCTAssertGreaterThanOrEqual(fixtures.count, minimum)
        let importer = ShareLinkImporter()
        let compiler = XrayConfigCompiler(options: FixtureCorpusTests.options)
        var schemes = Set<String>()

        for name in fixtures {
            let link = try String(contentsOf: directory.appendingPathComponent(name + ".link"), encoding: .utf8)
            let imported = try importer.importLink(link)
            schemes.insert(imported.report.scheme)
            try check(pretty(imported.outbound), at: directory.appendingPathComponent(name + ".model.json"))

            // The stored model must decode back to the same value.
            if !FixtureCorpusTests.updating {
                let data = try Data(contentsOf: directory.appendingPathComponent(name + ".model.json"))
                XCTAssertEqual(try JSONDecoder().decode(Outbound.self, from: data), imported.outbound, name)
            }

            let profile = Profile(
                id: FixtureCorpusTests.profileID, name: name, source: .shareLink,
                outbounds: [imported.outbound], selectedTag: imported.outbound.tag
            )
            let compilation = compiler.compile(profile)
            XCTAssertEqual(compiler.compile(profile).report, compilation.report, "report is not deterministic: \(name)")
            try check(
                pretty(Reports(importReport: imported.report, conversion: compilation.report)),
                at: directory.appendingPathComponent(name + ".report.json")
            )
            let config = try compilation.config.map { try pretty($0) }
            try check(config, at: directory.appendingPathComponent(name + ".xray.json"))

            XCTAssertEqual(compilation.config == nil, compilation.report.verdict == .blocked, name)
            if compilation.report.verdict == .blocked {
                XCTAssertTrue(compilation.report.issues.contains { $0.severity == .error }, "blocked without a reason: \(name)")
            }
        }
        return schemes
    }

    /// Every fixture whose protocol has an exporter survives import → export → import.
    func testShareLinkCorpusRoundTrips() throws {
        let directory = FixtureCorpusTests.fixturesRoot.appendingPathComponent("ShareLinks")
        let importer = ShareLinkImporter()
        let exporter = ShareLinkExporter()
        var exported = 0
        for name in try names(in: directory, suffix: ".link") {
            let link = try String(contentsOf: directory.appendingPathComponent(name + ".link"), encoding: .utf8)
            let first = try importer.importLink(link)
            guard ShareLinkExporter.supportedKinds.contains(first.outbound.kind) else {
                XCTAssertThrowsError(try exporter.exportLink(first.outbound), name)
                continue
            }
            let written = try exporter.exportLink(first.outbound)
            let second = try importer.importLink(written.uri)
            XCTAssertEqual(second.outbound, first.outbound, "round trip changed the model: \(name)")
            XCTAssertEqual(try exporter.exportLink(second.outbound).uri, written.uri, "export is not stable: \(name)")
            exported += 1
        }
        XCTAssertGreaterThanOrEqual(exported, 25)
    }

    func testProfileCorpus() throws {
        let directory = FixtureCorpusTests.fixturesRoot.appendingPathComponent("Profiles")
        let compiler = XrayConfigCompiler(options: FixtureCorpusTests.options)
        let built = ProfileFixtures.all
        if FixtureCorpusTests.updating {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (name, profile) in built {
            try check(pretty(profile), at: directory.appendingPathComponent(name + ".profile.json"))
        }
        let stored = try names(in: directory, suffix: ".profile.json")
        XCTAssertEqual(stored, built.map { $0.0 }.sorted())
        for name in stored {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".profile.json"))
            let profile = try JSONDecoder().decode(Profile.self, from: data)
            let compilation = compiler.compile(profile)
            try check(
                pretty(Reports(importReport: nil, conversion: compilation.report)),
                at: directory.appendingPathComponent(name + ".report.json")
            )
            try check(
                try compilation.config.map { try pretty($0) },
                at: directory.appendingPathComponent(name + ".xray.json")
            )
        }
    }
}

/// Profiles that no share link can express (HTTP proxy, groups, typed XHTTP download leg).
/// Keys and passwords are throwaway values generated for the corpus.
enum ProfileFixtures {
    static let uuidA = "1cc9207f-5dda-4274-bb0d-9d105c95c6e8"
    static let uuidB = "7d7ea5d0-9ec2-432e-82e7-141bada6fc01"
    static let realityKey = "VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4"
    static let password = "udihPqDumwBiY6PSt26Nqr9G"

    static func vless(_ tag: String, host: String, id: String = uuidA) -> Outbound {
        return Outbound(
            tag: tag, name: tag, server: ServerEndpoint(host: host, port: 443),
            credentials: Credentials(userID: .inline(id)),
            settings: .vless(VLESSSettings(flow: "xtls-rprx-vision")),
            stream: StreamSettings(
                transport: .tcp(TCPSettings()),
                security: .reality(RealitySettings(
                    serverName: "www.example.org", fingerprint: "chrome", publicKey: realityKey, shortID: "65466826"
                ))
            )
        )
    }

    static func trojan(_ tag: String, host: String) -> Outbound {
        return Outbound(
            tag: tag, name: tag, server: ServerEndpoint(host: host, port: 443),
            credentials: Credentials(password: .inline(password)),
            settings: .trojan,
            stream: StreamSettings(security: .tls(TLSSettings(serverName: host)))
        )
    }

    static func profile(_ name: String, _ index: UInt8, outbounds: [Outbound], groups: [OutboundGroup] = [], selected: String?) -> Profile {
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000001%02x", index))!
        return Profile(id: id, name: name, outbounds: outbounds, groups: groups, selectedTag: selected)
    }

    static var all: [(String, Profile)] {
        let http = Outbound(
            tag: "corp", name: "corp", server: ServerEndpoint(host: "proxy.example.com", port: 8443),
            credentials: Credentials(username: "user1", password: .inline(password)),
            settings: .http,
            stream: StreamSettings(security: .tls(TLSSettings(serverName: "proxy.example.com", alpn: ["http/1.1"])))
        )
        let a = vless("a", host: "192.0.2.80")
        let ab = vless("ab", host: "192.0.2.81", id: uuidB)
        let t = trojan("t", host: "t.example.com")
        let tuic = Outbound(
            tag: "tuic", name: "tuic", server: ServerEndpoint(host: "tu.example.com", port: 443),
            credentials: Credentials(userID: .inline(uuidA), password: .inline(password)),
            settings: .tuic(TUICSettings()),
            stream: StreamSettings(transport: .native, security: .tls(TLSSettings()))
        )
        let check = OutboundGroup.HealthCheck(
            url: "https://www.gstatic.com/generate_204", intervalSeconds: 60, timeoutMilliseconds: 3000
        )

        var split = vless("split", host: "192.0.2.82")
        split.settings = .vless(VLESSSettings())
        split.stream.transport = .xhttp(XHTTPSettings(
            path: "/up", mode: "stream-up",
            download: XHTTPDownload(
                server: ServerEndpoint(host: "dl.example.net", port: 8443),
                stream: StreamSettings(
                    transport: .xhttp(XHTTPSettings(path: "/down")),
                    security: .tls(TLSSettings(alpn: ["h2"]))
                )
            )
        ))

        return [
            ("http-proxy-tls", profile("http", 1, outbounds: [http], selected: "corp")),
            ("group-urltest", profile(
                "urltest", 2, outbounds: [a, ab, t, tuic],
                groups: [OutboundGroup(
                    tag: "auto", name: "auto", kind: .urlTest,
                    members: [.outbound(tag: "a"), .outbound(tag: "ab"), .outbound(tag: "t"), .outbound(tag: "tuic")],
                    healthCheck: check
                )],
                selected: "auto"
            )),
            ("group-leastload-nested", profile(
                "leastload", 3, outbounds: [a, ab, t],
                groups: [
                    OutboundGroup(tag: "inner", name: "inner", kind: .fallback, members: [.outbound(tag: "ab"), .outbound(tag: "t")]),
                    OutboundGroup(
                        tag: "outer", name: "outer", kind: .loadBalance,
                        members: [.outbound(tag: "a"), .group(tag: "inner")],
                        healthCheck: check, strategy: .leastLoad
                    ),
                ],
                selected: "outer"
            )),
            ("group-selector", profile(
                "selector", 4, outbounds: [a, t],
                groups: [OutboundGroup(
                    tag: "pick", name: "pick", kind: .selector,
                    members: [.outbound(tag: "a"), .outbound(tag: "t")], defaultMemberTag: "t"
                )],
                selected: "pick"
            )),
            ("xhttp-typed-download", profile("split", 5, outbounds: [split], selected: "split")),
        ]
    }
}
