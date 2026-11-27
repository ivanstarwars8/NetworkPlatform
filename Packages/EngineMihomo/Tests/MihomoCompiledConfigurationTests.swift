// Verified on Linux only (Swift 5.10.1, swift test).
import ConfigurationEngine
import CoreAbstraction
import DomainModels
import EngineBridge
import EngineBridgeTestSupport
import Foundation
import XCTest
@testable import EngineMihomo

/// The path model → `MihomoConfigCompiler` → `MihomoCore` → bridge, against a fake bridge. The real bridge
/// runs the same compiled YAML in Cores/MihomoBridge (`TestCompiledFixturesNeedNoOverride`, tunlab
/// `ENGINE=mihomo compiled`).
final class MihomoCompiledConfigurationTests: XCTestCase {
    // Throwaway values (the same as the ConfigurationEngine fixture corpus).
    private let uuid = "1cc9207f-5dda-4274-bb0d-9d105c95c6e8"
    private let realityKey = "VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4"

    private func realityProfile() throws -> Profile {
        let link = "vless://\(uuid)@192.0.2.1:443?type=tcp&security=reality&sni=www.example.org"
            + "&fp=chrome&pbk=\(realityKey)&sid=0a1b&flow=xtls-rprx-vision#lab"
        let node = try ShareLinkImporter().importLink(link).outbound
        return Profile(name: "p", outbounds: [node], selectedTag: node.tag)
    }

    private func bridge() -> FakeBridge {
        let bridge = FakeBridge()
        bridge.set {
            $0.versionReply = #"{"code":0,"data":{"abi":1,"engine":"mihomo","core":"v1.19.34","go":"go1.27.4"}}"#
            $0.validateReply = #"{"code":0,"data":{"mode":"rule","proxies":1,"rules":1,"hasTun":true,"depth":"parse"}}"#
        }
        return bridge
    }

    private func settings() -> MihomoCoreSettings {
        var settings = MihomoCoreSettings.packetTunnel
        settings.bridge.pump.readTimeoutMilliseconds = 20
        settings.bridge.logReadTimeoutMilliseconds = 20
        return settings
    }

    func testCompiledProfileReachesTheBridgeUnchangedWithItsMTU() async throws {
        var addressing = TunnelAddressing.standard
        addressing.mtu = 1380
        let compilation = MihomoConfigCompiler(options: .packetTunnel(addressing: addressing)).compile(try realityProfile())
        XCTAssertNotEqual(compilation.report.verdict, .blocked, "\(compilation.report.issues)")
        let compiled = try MihomoCompiledConfiguration(compilation)

        XCTAssertEqual(compiled.configuration.coreID, MihomoCore.identifier)
        XCTAssertEqual(compiled.configuration.format, "yaml")
        XCTAssertEqual(compiled.configuration.payload, Data(try XCTUnwrap(compilation.yamlText()).utf8))
        XCTAssertEqual(compiled.startOptions.mtu, 1380)
        XCTAssertNil(compiled.startOptions.tunnelFileDescriptor, "the Mihomo bridge has no fd mode")
        XCTAssertEqual(compiled.tunnel?.addressing, addressing)
        XCTAssertFalse(compiled.reportIssues.contains { $0.severity == .error })

        let fake = bridge()
        let core = MihomoCore(bridge: fake, packetIO: FakePacketIO(), settings: settings())
        let check = try await core.validate(compiled.configuration)
        XCTAssertTrue(check.isValid)
        XCTAssertEqual(check.warnings, [], "nothing overridden by the bridge")

        try await core.start(compiled.configuration, options: compiled.startOptions)
        let sent = try XCTUnwrap(fake.read { $0.startCalls.first })
        XCTAssertEqual(sent.config, compiled.configuration.payload, "the compiled YAML goes to the bridge as it is")
        let yaml = String(decoding: sent.config, as: UTF8.self)
        XCTAssertTrue(yaml.contains("stack: mips"))
        XCTAssertTrue(yaml.contains("mtu: 1380"))
        XCTAssertTrue(yaml.contains("support-x25519mlkem768: true"))
        let options = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.options) as? [String: Any])
        let tun = options["tun"] as? [String: Any]
        XCTAssertEqual(tun?["mode"] as? String, "flow")
        XCTAssertEqual(tun?["mtu"] as? Int, 1380, "the flow listener and the YAML's tun section agree")
        XCTAssertEqual(options["memory"] as? [String: String], ["profile": "mobile"])
        try await core.stop()
    }

    func testBlockedCompilationIsRefusedWithoutValues() async throws {
        // An SS-2022 key of the wrong length: the compiler excludes the only outbound and blocks.
        let badKey = "c2hvcnQ="
        let node = Outbound(tag: "ss", name: "ss", server: ServerEndpoint(host: "192.0.2.2", port: 8388),
                            credentials: Credentials(password: .inline(badKey)),
                            settings: .shadowsocks(ShadowsocksSettings(method: "2022-blake3-aes-128-gcm")))
        let compilation = MihomoConfigCompiler(options: .packetTunnel()).compile(Profile(name: "p", outbounds: [node], selectedTag: "ss"))
        XCTAssertEqual(compilation.report.verdict, .blocked)
        do {
            _ = try MihomoCompiledConfiguration(compilation)
            XCTFail("a blocked compilation must not reach the core")
        } catch let error as CoreError {
            guard case let .invalidConfiguration(issues) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(issues.isEmpty)
            XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
            XCTAssertFalse(issues.contains { $0.message.contains(badKey) || $0.message.contains("192.0.2.2") }, "values leaked")
        }
    }

    func testDegradedCompilationCarriesItsWarnings() throws {
        var profile = try realityProfile()
        guard case var .reality(reality) = profile.outbounds[0].stream.security else { return XCTFail("not REALITY") }
        reality.mldsa65Verify = "abc"
        profile.outbounds[0].stream.security = .reality(reality)
        let compilation = MihomoConfigCompiler(options: .packetTunnel()).compile(profile)
        XCTAssertEqual(compilation.report.verdict, .degraded)
        let compiled = try MihomoCompiledConfiguration(compilation)
        XCTAssertTrue(compiled.reportIssues.contains { $0.severity == .warning && ($0.path ?? "").contains("mldsa65Verify") },
                      "\(compiled.reportIssues)")
        XCTAssertFalse(compiled.reportIssues.contains { $0.message.contains("abc") })
    }

    func testXrayReportIsAMismatch() {
        let compilation = MihomoCompilation(document: .string("x"), report: ConversionReport(engine: .xray, engineVersion: "26.11.9"))
        XCTAssertThrowsError(try MihomoCompiledConfiguration(compilation)) { error in
            guard case let .configurationMismatch(expected, actual)? = error as? CoreError else { return XCTFail("\(error)") }
            XCTAssertEqual(expected, MihomoCore.identifier)
            XCTAssertEqual(actual, "xray")
        }
    }
}
