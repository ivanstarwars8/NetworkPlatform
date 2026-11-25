import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

/// Behaviour fixed after checking the formats against their specifications
/// (`Documentation/Protocols/share-link-formats.md`).
final class ShareLinkSpecConformanceTests: XCTestCase {

    private let importer = ShareLinkImporter()
    private let exporter = ShareLinkExporter()

    private func roundTrip(_ link: String, file: StaticString = #filePath, line: UInt = #line) throws -> ExportedLink {
        let first = try importer.importLink(link)
        let exported = try exporter.exportLink(first.outbound)
        let second = try importer.importLink(exported.uri)
        XCTAssertEqual(second.outbound, first.outbound, file: file, line: line)
        XCTAssertEqual(try exporter.exportLink(second.outbound).uri, exported.uri, file: file, line: line)
        return exported
    }

    // MARK: - Hysteria2 (official URI scheme)

    func testHysteria2OfficialExample() throws {
        // The example of the specification page, with placeholders filled in.
        let link = "hysteria2://letmein@example.com:123,5000-6000/?insecure=1&obfs=salamander"
            + "&obfs-password=gawrgura&pinSHA256=deadbeef&sni=real.example.com#cool-server"
        let imported = try importer.importLink(link)
        XCTAssertEqual(imported.report.unsupported, [])
        XCTAssertEqual(imported.outbound.server, ServerEndpoint(host: "example.com", port: 123))
        XCTAssertEqual(imported.outbound.credentials.password, .inline("letmein"))
        guard case .hysteria2(let settings) = imported.outbound.settings else { return XCTFail("kind") }
        XCTAssertEqual(settings.serverPorts, [PortRange(lower: 123, upper: 123), PortRange(lower: 5000, upper: 6000)])
        XCTAssertEqual(settings.obfuscation, Hysteria2Obfuscation(type: "salamander", password: .inline("gawrgura")))
        guard case .tls(let tls) = imported.outbound.stream.security else { return XCTFail("security") }
        XCTAssertEqual(tls.serverName, "real.example.com")
        XCTAssertTrue(tls.allowInsecure)
        XCTAssertEqual(tls.pinnedPeerCertificateSHA256, "deadbeef")
        XCTAssertFalse(imported.report.hasWarning(.nonStandardFormat))
    }

    func testHysteria2GeckoIsAcceptedAndUnknownObfuscationIsNot() throws {
        let gecko = try importer.importLink("hysteria2://a@example.com:443/?obfs=gecko&obfs-password=pw12#n")
        guard case .hysteria2(let settings) = gecko.outbound.settings else { return XCTFail("kind") }
        XCTAssertEqual(settings.obfuscation?.type, "gecko")
        XCTAssertThrowsError(try importer.importLink("hysteria2://a@example.com:443/?obfs=rot13&obfs-password=pw#n")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedValue(parameter: "obfs", value: "rot13"))
        }
    }

    func testHysteria2BandwidthIsAnExtensionAndHysteria1NamesAreNotRead() throws {
        let imported = try importer.importLink("hy2://a@example.com/?up=10mbps&down=50mbps&upmbps=10&downmbps=50#n")
        guard case .hysteria2(let settings) = imported.outbound.settings else { return XCTFail("kind") }
        XCTAssertEqual(settings.uploadBandwidth, "10mbps")
        XCTAssertEqual(settings.downloadBandwidth, "50mbps")
        XCTAssertTrue(imported.report.hasWarning(.nonStandardFormat))
        XCTAssertEqual(imported.report.unsupportedParameter(named: "upmbps")?.reason, .unknown)
        XCTAssertEqual(imported.report.unsupportedParameter(named: "downmbps")?.reason, .unknown)
        XCTAssertEqual(imported.outbound.server.port, 443)
    }

    func testHysteria2RealmSchemeIsNotMistakenForHysteria2() {
        XCTAssertThrowsError(try importer.importLink("hysteria2+realm://token@r.example.com/name?auth=pw")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedScheme("hysteria2+realm"))
        }
    }

    func testHysteria2Export() throws {
        let official = "hysteria2://letmein@example.com:123,5000-6000/?obfs=salamander&obfs-password=gawrgura"
            + "&sni=real.example.com&insecure=1&pinSHA256=deadbeef#cool-server"
        let exported = try roundTrip(official)
        XCTAssertEqual(exported.uri, official)
        XCTAssertEqual(exported.warnings, [])

        let extended = try roundTrip("hysteria2://user:p%40ss@[2001:db8::1]:8443/?sni=h.example.com&alpn=h3&up=10mbps&x-custom=1#n")
        XCTAssertTrue(extended.uri.hasPrefix("hysteria2://user%3Ap%40ss@[2001:db8::1]:8443/?"))
        XCTAssertTrue(extended.uri.contains("x-custom=1"))
        XCTAssertTrue(extended.warnings.contains { $0.code == .nonStandardFormat })

        _ = try roundTrip("hysteria2://example.com:443/#no-auth")
    }

    // MARK: - Shadowsocks (SIP002, SIP022)

    func testShadowsocks2022KeyChecks() throws {
        let key16 = Data(repeating: 9, count: 16).base64EncodedString()
        let key32 = Data(repeating: 9, count: 32).base64EncodedString()
        func link(_ method: String, _ key: String) -> String {
            return "ss://\(method):\(PercentCoding.encode(key, as: .strict))@192.0.2.1:8388#n"
        }
        XCTAssertFalse(try importer.importLink(link("2022-blake3-aes-128-gcm", key16)).report.hasWarning(.suspiciousValue))
        XCTAssertFalse(try importer.importLink(link("2022-blake3-aes-256-gcm", key32 + ":" + key32)).report.hasWarning(.suspiciousValue))
        XCTAssertFalse(try importer.importLink(link("2022-blake3-chacha8-poly1305", key32)).report.hasWarning(.suspiciousValue))
        XCTAssertTrue(try importer.importLink(link("2022-blake3-aes-256-gcm", key16)).report.hasWarning(.suspiciousValue))
        XCTAssertTrue(try importer.importLink(link("2022-blake3-aes-128-gcm", "password")).report.hasWarning(.suspiciousValue))

        // SIP002: "MUST NOT be encoded with Base64URL" for the 2022 methods. Read, but flagged.
        let encoded = LenientBase64.encodeURLSafe("2022-blake3-aes-128-gcm:" + key16)
        let tolerated = try importer.importLink("ss://\(encoded)@192.0.2.1:8388#n")
        XCTAssertEqual(tolerated.outbound.credentials.password, .inline(key16))
        XCTAssertTrue(tolerated.report.hasWarning(.nonStandardFormat))

        // The exporter always writes the plain form for 2022 and base64url otherwise.
        XCTAssertEqual(try exporter.exportLink(tolerated.outbound).uri, link("2022-blake3-aes-128-gcm", key16))
        let aead = try roundTrip("ss://\(LenientBase64.encodeURLSafe("aes-256-gcm:pa:ss/word"))@192.0.2.1:8388#n")
        XCTAssertFalse(aead.uri.contains("="))
        XCTAssertFalse(aead.uri.contains("+"))
    }

    // MARK: - VMess (v2rayN JSON, version 2)

    func testVMessJSONExportFollowsTheWikiTable() throws {
        let source: [String: String] = [
            "v": "2", "ps": "name", "add": "v.example.com", "port": "443", "id": ProfileFixtures.uuidA,
            "aid": "0", "scy": "auto", "net": "grpc", "type": "multi", "host": "au.example.com", "path": "svc",
            "tls": "tls", "sni": "v.example.com", "alpn": "h2", "fp": "chrome",
        ]
        let body = try JSONEncoder().encode(source)
        let exported = try roundTrip("vmess://" + body.base64EncodedString())
        XCTAssertTrue(exported.uri.hasPrefix("vmess://"))
        let decoded = try XCTUnwrap(LenientBase64.decodeToString(String(exported.uri.dropFirst(8))))
        let members = try XCTUnwrap(try JSONValue.parse(jsonText: decoded).objectValue)
        for (key, value) in source {
            XCTAssertEqual(members[key], .string(value), key)
        }
        XCTAssertEqual(exported.warnings, [])
    }

    func testVMessExportCoversTransportsAndRecordedMembers() throws {
        func link(_ members: [String: String]) throws -> String {
            var all = ["v": "2", "ps": "n", "add": "v.example.com", "port": "443", "id": ProfileFixtures.uuidA]
            all.merge(members) { _, new in new }
            return "vmess://" + (try JSONEncoder().encode(all)).base64EncodedString()
        }
        _ = try roundTrip(try link(["net": "tcp", "type": "http", "host": "a.example.com,b.example.com", "path": "/"]))
        _ = try roundTrip(try link(["net": "ws", "host": "w.example.com", "path": "/w?ed=2048", "tls": "tls", "insecure": "1"]))
        _ = try roundTrip(try link(["net": "kcp", "type": "wechat-video", "path": "seed-value"]))
        _ = try roundTrip(try link(["net": "h2", "host": "h.example.com", "path": "/h", "tls": "tls"]))
        _ = try roundTrip(try link(["net": "xhttp", "type": "packet-up", "path": "/x", "tls": "tls"]))
        _ = try roundTrip(try link(["net": "httpupgrade", "path": "/u", "aid": "2", "scy": "none"]))
        let unknown = try roundTrip(try link(["net": "tcp", "future": "value"]))
        let decoded = try XCTUnwrap(LenientBase64.decodeToString(String(unknown.uri.dropFirst(8))))
        XCTAssertEqual(try JSONValue.parse(jsonText: decoded)["future"], .string("value"))
    }

    // MARK: - SOCKS (libXray convention)

    func testSOCKSExport() throws {
        let exported = try roundTrip("socks://dXNlcjpwYXNz@192.0.2.1:1080#n")
        XCTAssertEqual(exported.uri, "socks://dXNlcjpwYXNz@192.0.2.1:1080#n")
        XCTAssertEqual(try roundTrip("socks5://[2001:db8::1]:1080#n").uri, "socks://[2001:db8::1]:1080#n")
        XCTAssertEqual(try roundTrip("socks4a://192.0.2.1:1080#n").uri, "socks4a://192.0.2.1:1080#n")
        var odd = try importer.importLink("socks://192.0.2.1:1080#n").outbound
        odd.credentials.username = "a:b"
        XCTAssertThrowsError(try exporter.exportLink(odd))
        odd.credentials.username = nil
        odd.credentials.password = .inline("pw")
        XCTAssertThrowsError(try exporter.exportLink(odd))
    }

    // MARK: - Schemes without a specification stay refused by the exporter

    func testNoExporterForTUICAndWireGuard() throws {
        let tuic = try importer.importLink("tuic://\(ProfileFixtures.uuidA):pw@t.example.com:443?alpn=h3#n")
        XCTAssertTrue(tuic.report.hasWarning(.nonStandardFormat))
        XCTAssertThrowsError(try exporter.exportLink(tuic.outbound)) {
            XCTAssertEqual($0 as? ExportError, .unsupportedProtocol(.tuic))
        }
        let key = PercentCoding.encode(Data(repeating: 1, count: 32).base64EncodedString(), as: .strict)
        let wireGuard = try importer.importLink("wireguard://\(key)@192.0.2.1:51820?publickey=\(key)#n")
        XCTAssertTrue(wireGuard.report.hasWarning(.nonStandardFormat))
        XCTAssertThrowsError(try exporter.exportLink(wireGuard.outbound)) {
            XCTAssertEqual($0 as? ExportError, .unsupportedProtocol(.wireGuard))
        }
    }
}
