import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

final class ShareLinkExporterTests: XCTestCase {

    private let importer = ShareLinkImporter()
    private let exporter = ShareLinkExporter()

    /// import → export → import must give the same outbound.
    private func assertModelRoundTrip(
        _ link: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ExportedLink {
        let first = try importer.importLink(link)
        let exported = try exporter.exportLink(first.outbound)
        let second = try importer.importLink(exported.uri)
        XCTAssertEqual(second.outbound, first.outbound, file: file, line: line)
        XCTAssertEqual(second.report.unsupported, first.report.unsupported, file: file, line: line)
        // Exporting again is stable.
        XCTAssertEqual(try exporter.exportLink(second.outbound).uri, exported.uri, file: file, line: line)
        return exported
    }

    // MARK: - Exact string round-trips of canonical links

    func testCanonicalLinksRoundTripByteForByte() throws {
        let canonical = [
            Fixtures.vlessRealityVision,
            Fixtures.vlessWebSocketTLS,
            Fixtures.trojanGRPC,
            Fixtures.shadowsocksSIP002,
            Fixtures.shadowsocks2022,
        ]
        for link in canonical {
            let exported = try assertModelRoundTrip(link)
            XCTAssertEqual(exported.uri, link)
            XCTAssertEqual(exported.warnings, [], "unexpected warnings for \(link)")
        }
    }

    // MARK: - Model round-trips

    func testVLESSXHTTPRoundTripKeepsExtra() throws {
        let exported = try assertModelRoundTrip(Fixtures.vlessXHTTP)
        XCTAssertTrue(exported.uri.hasPrefix("vless://\(Fixtures.uuid)@xhttp.example.com:443?encryption=none&type=xhttp"))
        XCTAssertTrue(exported.uri.contains("&extra=%7B"))
        XCTAssertTrue(exported.uri.contains("xPaddingBytes"))
        XCTAssertTrue(exported.uri.hasSuffix("#XHTTP"))
        XCTAssertEqual(exported.warnings, [])
    }

    func testVLESSFinalMaskRoundTrip() throws {
        let link = "vless://\(Fixtures.uuid)@example.com:443?security=tls&sni=example.com"
            + "&fm=%7B%22tcp%22%3A%5B%7B%22type%22%3A%22fragment%22%7D%5D%7D#fm"
        let exported = try assertModelRoundTrip(link)
        XCTAssertTrue(exported.uri.contains("&fm=%7B%22tcp%22:%5B%7B%22type%22:%22fragment%22%7D%5D%7D"))
        XCTAssertEqual(exported.warnings, [])
    }

    func testEveryTransportRoundTrips() throws {
        let base = "vless://\(Fixtures.uuid)@example.com:443?security=tls&sni=example.com&"
        let variants = [
            "type=tcp&headerType=http&host=a.example.com,b.example.com&path=/,/x",
            "type=ws&host=h.example.com&path=%2Fa+b%20c%3Fx%3D1",
            "type=grpc&serviceName=svc&authority=g.example.com&mode=multi",
            "type=grpc&serviceName=svc&mode=gun",
            "type=h2&host=a.example.com&path=/h2",
            "type=httpupgrade&host=u.example.com&path=/up",
            "type=splithttp&path=/s&mode=stream-up",
            "type=kcp&seed=s33d&headerType=wechat-video&mtu=1350&tti=20",
            "type=quic&quicSecurity=aes-128-gcm&key=k3y&headerType=srtp",
        ]
        for variant in variants {
            _ = try assertModelRoundTrip(base + variant + "#n")
        }
    }

    func testEverySecurityRoundTrips() throws {
        let base = "vless://\(Fixtures.uuid)@example.com:443?type=tcp&"
        let variants = [
            "security=none",
            "security=tls&sni=a.example.com&alpn=h2,http/1.1&fp=safari&allowInsecure=1&ech=AEX%2BDQBB&pcs=aabb&vcn=v.example.com",
            "security=reality&sni=a.example.com&fp=chrome&pbk=\(Fixtures.publicKey)&sid=ab&spx=%2Fpath%3Fa%3Db&pqv=verifykey",
        ]
        for variant in variants {
            _ = try assertModelRoundTrip(base + variant + "#n")
        }
    }

    func testTrojanAndShadowsocksVariantsRoundTrip() throws {
        _ = try assertModelRoundTrip("trojan://secret@example.com#min")
        _ = try assertModelRoundTrip("trojan://secret@example.com:80?security=none&type=ws&path=/t#plain")
        _ = try assertModelRoundTrip(
            "trojan://s%C3%A9cret%20%2F%3F%23@xn--e1afmkfd.xn--p1ai:443?security=reality&pbk=\(Fixtures.publicKey)&sid=ab#r"
        )
        _ = try assertModelRoundTrip("trojan://pw@\u{43F}\u{440}\u{438}\u{43C}\u{435}\u{440}.\u{440}\u{444}:443#idn")
        _ = try assertModelRoundTrip(Fixtures.shadowsocksLegacy)
        _ = try assertModelRoundTrip(Fixtures.shadowsocksLegacyIPv6)

        // The legacy form is rewritten as SIP002.
        let legacy = try importer.importLink(Fixtures.shadowsocksLegacy)
        let exported = try exporter.exportLink(legacy.outbound)
        XCTAssertEqual(exported.uri, "ss://YWVzLTI1Ni1nY206c2VjcmV0@198.51.100.20:8388#Legacy%20SS")
    }

    func testIPv6AndUnicodeNameRoundTrip() throws {
        let exported = try assertModelRoundTrip(
            "vless://\(Fixtures.uuid)@[2001:db8::1]:8443?security=tls#\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430} 1"
        )
        XCTAssertTrue(exported.uri.contains("@[2001:db8::1]:8443?"))
        XCTAssertTrue(exported.uri.hasSuffix("#%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0%201"))
    }

    func testUnknownParametersSurviveRoundTrip() throws {
        let link = "vless://\(Fixtures.uuid)@example.com:443"
            + "?encryption=none&type=grpc&serviceName=svc&mode=weird&security=tls&sni=a.example.com"
            + "&foo=bar%20baz&pbk=xyz&allowInsecure=maybe#n"
        let exported = try assertModelRoundTrip(link)
        XCTAssertTrue(exported.uri.contains("&foo=bar%20baz"))
        XCTAssertTrue(exported.uri.contains("&pbk=xyz"))
        XCTAssertTrue(exported.uri.contains("&mode=weird"))
        XCTAssertTrue(exported.uri.contains("&allowInsecure=maybe"))
        XCTAssertEqual(exported.warnings, [])

        let first = try importer.importLink(link)
        XCTAssertEqual(first.report.unsupported.count, 4)
    }

    func testParametersThatCannotBeWrittenBackProduceWarnings() throws {
        // Duplicate and path records have no place in the exported link.
        let link = "vless://\(Fixtures.uuid)@example.com:443/some/path?security=tls&foo=1&foo=2#n"
        let first = try importer.importLink(link)
        XCTAssertEqual(first.report.unsupported.count, 3)
        let exported = try exporter.exportLink(first.outbound)
        XCTAssertEqual(exported.warnings.filter { $0.code == .notExpressible }.count, 2)
        XCTAssertTrue(exported.uri.contains("&foo=1"))
        XCTAssertFalse(exported.uri.contains("foo=2"))
        XCTAssertFalse(exported.uri.contains("/some/path"))
    }

    // MARK: - Export from hand-built models

    func testExportFromModel() throws {
        let outbound = Outbound(
            tag: "n", name: "n",
            server: ServerEndpoint(host: "example.com", port: 8443),
            credentials: Credentials(userID: .inline(Fixtures.uuid)),
            settings: .vless(VLESSSettings()),
            stream: StreamSettings(
                transport: .webSocket(WebSocketSettings(path: "/ws", host: "h.example.com")),
                security: .tls(TLSSettings(serverName: "h.example.com", alpn: ["h2"], fingerprint: "chrome"))
            )
        )
        let exported = try exporter.exportLink(outbound)
        XCTAssertEqual(
            exported.uri,
            "vless://\(Fixtures.uuid)@example.com:8443"
                + "?encryption=none&type=ws&host=h.example.com&path=/ws&security=tls&sni=h.example.com&alpn=h2&fp=chrome#n"
        )
        XCTAssertEqual(exported.warnings, [])
        XCTAssertEqual(try importer.importLink(exported.uri).outbound, outbound)
    }

    func testExportWarnsAboutWhatTheLinkCannotCarry() throws {
        var extras = EngineExtras()
        extras.set(.string("x"), engine: .singBox, key: "multiplex")
        let download = XHTTPDownload(
            server: ServerEndpoint(host: "d.example.com", port: 443),
            stream: StreamSettings(security: .tls(TLSSettings()))
        )
        let outbound = Outbound(
            tag: "tag-differs", name: "n",
            server: ServerEndpoint(host: "example.com", port: 443),
            credentials: Credentials(userID: .inline(Fixtures.uuid)),
            settings: .vless(VLESSSettings()),
            stream: StreamSettings(
                transport: .xhttp(XHTTPSettings(path: "/x", download: download)),
                security: .tls(TLSSettings(disableSNI: true))
            ),
            extras: extras
        )
        let exported = try exporter.exportLink(outbound)
        XCTAssertEqual(exported.warnings.count, 4)
        XCTAssertTrue(exported.warnings.allSatisfy { $0.code == .notExpressible })
    }

    func testExportErrors() {
        func export(_ outbound: Outbound) throws -> ExportedLink {
            return try exporter.exportLink(outbound)
        }
        var outbound = Outbound(
            tag: "n", name: "n",
            server: ServerEndpoint(host: "example.com", port: 443),
            credentials: Credentials(userID: .reference(SecretReference(identifier: "kc-1"))),
            settings: .vless(VLESSSettings())
        )
        XCTAssertThrowsError(try export(outbound)) { error in
            XCTAssertEqual(error as? ExportError, .secretNotInline(.userID))
        }

        outbound.credentials.userID = nil
        XCTAssertThrowsError(try export(outbound)) { error in
            XCTAssertEqual(error as? ExportError, .missingCredential(.userID))
        }

        outbound.credentials.userID = .inline(Fixtures.uuid)
        outbound.server.host = "exa mple.com"
        XCTAssertThrowsError(try export(outbound)) { error in
            XCTAssertEqual(
                error as? ExportError,
                .notExpressible(reason: "host is empty or contains forbidden characters")
            )
        }

        outbound.server.host = "example.com"
        outbound.stream.transport = .native
        XCTAssertThrowsError(try export(outbound)) { error in
            guard case .some(.notExpressible) = error as? ExportError else {
                return XCTFail("expected notExpressible, got \(error)")
            }
        }

        outbound.stream.transport = .tcp(TCPSettings())
        outbound.settings = .trojan
        XCTAssertThrowsError(try export(outbound)) { error in
            XCTAssertEqual(error as? ExportError, .missingCredential(.password))
        }

        outbound.settings = .shadowsocks(ShadowsocksSettings(method: "aes-256-gcm"))
        outbound.credentials.password = .inline("pw")
        outbound.stream.security = .tls(TLSSettings())
        XCTAssertThrowsError(try export(outbound)) { error in
            XCTAssertEqual(
                error as? ExportError,
                .notExpressible(reason: "ss:// links carry no transport or TLS settings")
            )
        }
    }

    func testProtocolsWithoutExporterAreRefusedNotApproximated() throws {
        for link in [Fixtures.hysteria2, Fixtures.tuic, Fixtures.socksBase64, Fixtures.wireGuard, Fixtures.vmessURL] {
            let imported = try importer.importLink(link)
            XCTAssertThrowsError(try exporter.exportLink(imported.outbound)) { error in
                XCTAssertEqual(error as? ExportError, .unsupportedProtocol(imported.outbound.kind))
            }
            XCTAssertFalse(ShareLinkExporter.supportedKinds.contains(imported.outbound.kind))
        }
    }
}
