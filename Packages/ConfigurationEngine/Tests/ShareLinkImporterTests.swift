import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

/// Fixture links shared by the importer, exporter and subscription tests.
/// Hosts are from the documentation ranges (RFC 5737, RFC 3849, example.com); keys are synthetic.
enum Fixtures {
    static let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    /// base64url of bytes 0...31.
    static let publicKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    static let vlessRealityVision =
        "vless://b831381d-6324-4d53-ad4f-8cda48b30811@203.0.113.10:443"
        + "?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality&sni=www.example.com"
        + "&fp=chrome&pbk=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&sid=6ba85179e30d4fc2&spx=/#NL%20Reality"

    static let vlessXHTTP =
        "vless://b831381d-6324-4d53-ad4f-8cda48b30811@xhttp.example.com:443"
        + "?encryption=none&type=xhttp&host=cdn.example.com&path=/api/v3&mode=packet-up"
        + "&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%2C%22noGRPCHeader%22%3Atrue%7D"
        + "&security=tls&sni=cdn.example.com&alpn=h2&fp=chrome#XHTTP"

    static let vlessWebSocketTLS =
        "vless://b831381d-6324-4d53-ad4f-8cda48b30811@ws.example.com:443"
        + "?encryption=none&type=ws&host=ws.example.com&path=/ray%3Fed%3D2048"
        + "&security=tls&sni=ws.example.com&alpn=h2,http/1.1&fp=firefox"
        + "#WS%20TLS%20%F0%9F%87%A9%F0%9F%87%AA"

    static let trojanGRPC =
        "trojan://p%40ss%3Aword@[2001:db8::2]:8443"
        + "?type=grpc&serviceName=grpc-svc&mode=multi&security=tls&sni=trojan.example.com&alpn=h2&allowInsecure=1"
        + "#Trojan%20gRPC"

    /// base64 of a v2rayN-style JSON object: WebSocket + TLS.
    static let vmessWebSocketJSON =
        "vmess://eyJ2IjoiMiIsInBzIjoiREUgRnJhbmtmdXJ0IFdTIiwiYWRkIjoiZGUxLmV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIs"
        + "ImlkIjoiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwiYWlkIjoiMCIsInNjeSI6ImF1dG8iLCJuZXQiOiJ3"
        + "cyIsInR5cGUiOiJub25lIiwiaG9zdCI6ImNkbi5leGFtcGxlLmNvbSIsInBhdGgiOiIvdm1lc3M/ZWQ9MjA0OCIsInRscyI6InRs"
        + "cyIsInNuaSI6ImNkbi5leGFtcGxlLmNvbSIsImFscG4iOiJoMixodHRwLzEuMSIsImZwIjoiY2hyb21lIn0="

    /// base64 of a JSON object with numeric port/aid, gRPC multi mode, an unknown key and a nested value.
    static let vmessGRPCJSON =
        "vmess://eyJ2IjoiMiIsInBzIjoiZ3JwYyBub2RlIiwiYWRkIjoiMjAzLjAuMTEzLjciLCJwb3J0Ijo4NDQzLCJpZCI6ImI4MzEz"
        + "ODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsImFpZCI6MSwibmV0IjoiZ3JwYyIsInR5cGUiOiJtdWx0aSIsInBhdGgi"
        + "OiJzdmMiLCJ0bHMiOiIiLCJ3ZWlyZCI6IngiLCJuZXN0ZWQiOnsiYSI6MX19"

    static let vmessURL =
        "vmess://b831381d-6324-4d53-ad4f-8cda48b30811@vm.example.com:443"
        + "?encryption=aes-128-gcm&type=httpupgrade&host=vm.example.com&path=/up&security=tls&sni=vm.example.com"
        + "#VMess%20AEAD"

    /// SIP002, base64url user information `chacha20-ietf-poly1305:pa:ss/word`, IPv6 host, plugin.
    static let shadowsocksSIP002 =
        "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwYTpzcy93b3Jk@[2001:db8::1]:8388"
        + "/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#SS%20v6"

    /// SIP002 with a 2022 cipher: user information is percent-encoded, not base64.
    static let shadowsocks2022 =
        "ss://2022-blake3-aes-256-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D"
        + "@ss2022.example.com:8388#SS2022"

    /// Legacy: base64 of `aes-256-gcm:secret@198.51.100.20:8388`.
    static let shadowsocksLegacy = "ss://YWVzLTI1Ni1nY206c2VjcmV0QDE5OC41MS4xMDAuMjA6ODM4OA==#Legacy%20SS"

    /// Legacy, unpadded: base64 of `aes-128-gcm:p@ss@[2001:db8::10]:8388`.
    static let shadowsocksLegacyIPv6 = "ss://YWVzLTEyOC1nY206cEBzc0BbMjAwMTpkYjg6OjEwXTo4Mzg4#v6"

    static let hysteria2 =
        "hysteria2://letmein@hy.example.com:443,20000-30000/"
        + "?obfs=salamander&obfs-password=cry_me_a_r1ver&sni=hy.example.com&insecure=1"
        + "&pinSHA256=deadbeef&up=50&down=200&hop-interval=30#HY2"

    static let hy2Short = "hy2://user%3Apass@[2001:db8::3]:8443?mport=5000-6000&foo=bar#hy2%20short"

    static let tuic =
        "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:tu1c-pass@tuic.example.com:8443"
        + "?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=tuic.example.com"
        + "&allow_insecure=0&disable_sni=1#TUIC"

    /// base64 of `alice:s3cret`.
    static let socksBase64 = "socks://YWxpY2U6czNjcmV0@192.0.2.1:1080#Office"
    static let socksPlain = "socks5://bob:p%40ss@proxy.example.com:1081"

    static let wireGuard =
        "wireguard://AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8%3D@wg.example.com:51820"
        + "?publickey=ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8%3D&address=10.0.0.2/32,fd00::2/128"
        + "&reserved=1,2,3&mtu=1280&keepalive=25#WG"
}

final class ShareLinkImporterTests: XCTestCase {

    private let importer = ShareLinkImporter()

    private func assertImportError(
        _ link: String,
        _ expected: ImportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try importer.importLink(link), file: file, line: line) { error in
            XCTAssertEqual(error as? ImportError, expected, file: file, line: line)
        }
    }

    // MARK: - VLESS

    func testVLESSRealityVision() throws {
        let result = try importer.importLink(Fixtures.vlessRealityVision)
        let outbound = result.outbound
        XCTAssertEqual(outbound.kind, .vless)
        XCTAssertEqual(outbound.name, "NL Reality")
        XCTAssertEqual(outbound.tag, "NL Reality")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "203.0.113.10", port: 443))
        XCTAssertEqual(outbound.credentials.userID, .inline(Fixtures.uuid))
        XCTAssertNil(outbound.credentials.password)
        XCTAssertEqual(outbound.settings, .vless(VLESSSettings(flow: "xtls-rprx-vision", encryption: "none")))
        XCTAssertEqual(outbound.stream.transport, .tcp(TCPSettings()))
        XCTAssertEqual(outbound.stream.security, .reality(RealitySettings(
            serverName: "www.example.com",
            fingerprint: "chrome",
            publicKey: Fixtures.publicKey,
            shortID: "6ba85179e30d4fc2",
            spiderX: "/"
        )))
        XCTAssertTrue(outbound.extras.isEmpty)
        XCTAssertEqual(result.report.scheme, "vless")
        XCTAssertEqual(result.report.format, "vless-url")
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings, [])
        XCTAssertTrue(result.report.isLossless)
        XCTAssertEqual(outbound.unsupported, [])
    }

    func testVLESSXHTTPKeepsExtraForXray() throws {
        let result = try importer.importLink(Fixtures.vlessXHTTP)
        let outbound = result.outbound
        XCTAssertEqual(outbound.name, "XHTTP")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "xhttp.example.com", port: 443))
        XCTAssertEqual(outbound.stream.transport, .xhttp(XHTTPSettings(
            path: "/api/v3", host: "cdn.example.com", mode: "packet-up"
        )))
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "cdn.example.com", alpn: ["h2"], fingerprint: "chrome"
        )))
        let extra = outbound.extras.value(engine: .xray, key: EngineExtras.xrayXHTTPExtraKey)
        XCTAssertEqual(extra, .object([
            "xPaddingBytes": .string("100-1000"),
            "noGRPCHeader": .bool(true),
        ]))
        XCTAssertNil(outbound.extras.value(engine: .singBox, key: EngineExtras.xrayXHTTPExtraKey))

        // The Xray-only blob is not lost, but the report says the model did not interpret it.
        XCTAssertEqual(result.report.unsupported.count, 1)
        let record = try XCTUnwrap(result.report.unsupportedParameter(named: "extra"))
        XCTAssertEqual(record.reason, .engineSpecific)
        XCTAssertEqual(record.disposition, .preservedInEngineExtras)
        XCTAssertEqual(record.location, .query)
        XCTAssertFalse(result.report.isLossless)
        XCTAssertEqual(outbound.unsupported, result.report.unsupported)
        XCTAssertEqual(result.report.warnings, [])
    }

    func testVLESSXHTTPDownloadSettingsAndInvalidExtra() throws {
        let withDownload = "vless://\(Fixtures.uuid)@x.example.com:443?type=xhttp&security=tls"
            + "&extra=%7B%22downloadSettings%22%3A%7B%22address%22%3A%22d.example.com%22%2C%22port%22%3A443%7D%7D#d"
        let first = try importer.importLink(withDownload)
        XCTAssertTrue(first.report.hasWarning(.engineSpecific))
        XCTAssertEqual(
            first.outbound.extras.value(engine: .xray, key: EngineExtras.xrayXHTTPExtraKey)?["downloadSettings"]?["port"],
            .integer(443)
        )
        guard case .xhttp(let settings) = first.outbound.stream.transport else {
            return XCTFail("expected xhttp")
        }
        XCTAssertNil(settings.download)

        let broken = "vless://\(Fixtures.uuid)@x.example.com:443?type=xhttp&security=tls&extra=%7Bnot-json#b"
        let second = try importer.importLink(broken)
        XCTAssertTrue(second.outbound.extras.isEmpty)
        let record = try XCTUnwrap(second.report.unsupportedParameter(named: "extra"))
        XCTAssertEqual(record.reason, .invalidValue)
        XCTAssertEqual(record.value, "{not-json")
        XCTAssertEqual(record.disposition, .recorded)
    }

    func testVLESSWebSocketTLS() throws {
        let result = try importer.importLink(Fixtures.vlessWebSocketTLS)
        let outbound = result.outbound
        XCTAssertEqual(outbound.name, "WS TLS \u{1F1E9}\u{1F1EA}")
        XCTAssertEqual(outbound.stream.transport, .webSocket(WebSocketSettings(
            path: "/ray?ed=2048", host: "ws.example.com"
        )))
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "ws.example.com", alpn: ["h2", "http/1.1"], fingerprint: "firefox"
        )))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings, [])
    }

    func testVLESSFinalMaskIsPreservedInExtras() throws {
        let link = "vless://\(Fixtures.uuid)@example.com:443?security=tls"
            + "&fm=%7B%22tcp%22%3A%5B%7B%22type%22%3A%22fragment%22%7D%5D%7D#fm"
        let result = try importer.importLink(link)
        XCTAssertEqual(
            result.outbound.extras.value(engine: .xray, key: EngineExtras.xrayFinalMaskKey),
            .object(["tcp": .array([.object(["type": .string("fragment")])])])
        )
        XCTAssertEqual(result.report.unsupportedParameter(named: "fm")?.disposition, .preservedInEngineExtras)
    }

    func testVLESSOtherTransports() throws {
        let base = "vless://\(Fixtures.uuid)@example.com:443?security=tls&"

        let http = try importer.importLink(base + "type=tcp&headerType=http&host=a.example.com,b.example.com&path=/,/x")
        XCTAssertEqual(http.outbound.stream.transport, .tcp(TCPSettings(httpObfuscation: HTTPObfuscation(
            hosts: ["a.example.com", "b.example.com"], paths: ["/", "/x"]
        ))))

        let raw = try importer.importLink(base + "type=raw")
        XCTAssertEqual(raw.outbound.stream.transport, .tcp(TCPSettings()))

        let grpc = try importer.importLink(base + "type=grpc&serviceName=svc&authority=g.example.com&mode=gun")
        XCTAssertEqual(grpc.outbound.stream.transport, .grpc(GRPCSettings(
            serviceName: "svc", authority: "g.example.com", multiMode: false
        )))

        let grpcBadMode = try importer.importLink(base + "type=grpc&serviceName=svc&mode=weird")
        XCTAssertEqual(grpcBadMode.report.unsupportedParameter(named: "mode")?.reason, .invalidValue)

        let h2 = try importer.importLink(base + "type=h2&host=a.example.com,b.example.com&path=/h2")
        XCTAssertEqual(h2.outbound.stream.transport, .http2(HTTP2Settings(
            hosts: ["a.example.com", "b.example.com"], path: "/h2"
        )))
        let httpAlias = try importer.importLink(base + "type=http&path=/h2")
        XCTAssertEqual(httpAlias.outbound.stream.transport, .http2(HTTP2Settings(hosts: [], path: "/h2")))

        let upgrade = try importer.importLink(base + "type=httpupgrade&host=u.example.com&path=/up")
        XCTAssertEqual(upgrade.outbound.stream.transport, .httpUpgrade(HTTPUpgradeSettings(
            path: "/up", host: "u.example.com"
        )))

        let splitHTTP = try importer.importLink(base + "type=splithttp&path=/s")
        XCTAssertEqual(splitHTTP.outbound.stream.transport, .xhttp(XHTTPSettings(path: "/s")))

        let kcp = try importer.importLink(base + "type=kcp&seed=s33d&headerType=wechat-video&mtu=1350&tti=abc")
        XCTAssertEqual(kcp.outbound.stream.transport, .kcp(KCPSettings(
            seed: .inline("s33d"), headerType: "wechat-video", mtu: 1350, tti: nil
        )))
        XCTAssertEqual(kcp.report.unsupportedParameter(named: "tti")?.reason, .invalidValue)
        XCTAssertEqual(kcp.outbound.inlineSecretSlots, [.userID, .transportKey])

        let quic = try importer.importLink(base + "type=quic&quicSecurity=aes-128-gcm&key=k3y&headerType=srtp")
        XCTAssertEqual(quic.outbound.stream.transport, .quic(QUICSettings(
            security: "aes-128-gcm", key: .inline("k3y"), headerType: "srtp"
        )))
    }

    func testUnknownDuplicateAndNotApplicableParametersAreRecorded() throws {
        let link = "vless://\(Fixtures.uuid)@example.com:443"
            + "?security=tls&sni=a.example.com&foo=bar&pbk=xyz&foo=dup&type=ws&path=%2Fws&serviceName=zzz#n"
        let result = try importer.importLink(link)
        let unsupported = result.report.unsupported
        XCTAssertEqual(unsupported.count, 4)

        let duplicates = unsupported.filter { $0.reason == .duplicate }
        XCTAssertEqual(duplicates.map { $0.name }, ["foo"])
        XCTAssertEqual(duplicates.first?.value, "dup")

        let unknown = unsupported.filter { $0.reason == .unknown }
        XCTAssertEqual(unknown.map { $0.name }, ["foo"])
        XCTAssertEqual(unknown.first?.value, "bar")

        let notApplicable = unsupported.filter { $0.reason == .notApplicable }
        XCTAssertEqual(notApplicable.map { $0.name }, ["pbk", "serviceName"])
        XCTAssertEqual(notApplicable.map { $0.value }, ["xyz", "zzz"])

        XCTAssertTrue(unsupported.allSatisfy { $0.location == .query && $0.disposition == .recorded })
        XCTAssertEqual(result.outbound.unsupported, unsupported)
        XCTAssertEqual(result.outbound.stream.transport, .webSocket(WebSocketSettings(path: "/ws")))
    }

    func testVLESSWarnings() throws {
        let plain = try importer.importLink("vless://\(Fixtures.uuid)@example.com:80#plain")
        XCTAssertTrue(plain.report.hasWarning(.plaintextTransport))
        XCTAssertEqual(plain.outbound.stream, StreamSettings(transport: .tcp(TCPSettings()), security: .none))

        let odd = try importer.importLink(
            "vless://not-a-uuid@example.com:443?security=reality&pbk=short&sid=xyz&flow=xtls-rprx-direct&type=ws#odd"
        )
        XCTAssertEqual(odd.outbound.credentials.userID, .inline("not-a-uuid"))
        XCTAssertEqual(odd.report.warnings.filter { $0.code == .suspiciousValue }.count, 5)

        let insecure = try importer.importLink("vless://\(Fixtures.uuid)@example.com:443?security=tls&insecure=true#i")
        XCTAssertTrue(insecure.report.hasWarning(.insecureTLS))
        guard case .tls(let tls) = insecure.outbound.stream.security else {
            return XCTFail("expected tls")
        }
        XCTAssertTrue(tls.allowInsecure)

        let notBool = try importer.importLink("vless://\(Fixtures.uuid)@example.com:443?security=tls&allowInsecure=maybe#i")
        XCTAssertFalse(notBool.report.hasWarning(.insecureTLS))
        XCTAssertEqual(notBool.report.unsupportedParameter(named: "allowInsecure")?.reason, .invalidValue)
    }

    func testVLESSEncryptionAndTLSExtras() throws {
        let link = "vless://\(Fixtures.uuid)@example.com:443?encryption=mlkem768x25519plus.native.0rtt.abc"
            + "&packetEncoding=xudp&security=tls&peer=p.example.com&ech=AEX%2BDQBB&pcs=aabb&vcn=v.example.com#e"
        let result = try importer.importLink(link)
        XCTAssertEqual(result.outbound.settings, .vless(VLESSSettings(
            flow: nil, encryption: "mlkem768x25519plus.native.0rtt.abc", packetEncoding: "xudp"
        )))
        XCTAssertEqual(result.outbound.stream.security, .tls(TLSSettings(
            serverName: "p.example.com", echConfigList: "AEX+DQBB",
            pinnedPeerCertificateSHA256: "aabb", verifyPeerCertificateByName: "v.example.com"
        )))
        XCTAssertEqual(result.report.unsupported, [])
    }

    // MARK: - Hosts, names, encoding

    func testIPv6LiteralHost() throws {
        let result = try importer.importLink("vless://\(Fixtures.uuid)@[2001:db8::1]:8443?security=tls#v6")
        XCTAssertEqual(result.outbound.server, ServerEndpoint(host: "2001:db8::1", port: 8443))
        XCTAssertTrue(result.outbound.server.isIPv6Literal)
    }

    func testInternationalHostsAreLeftIntact() throws {
        let unicode = try importer.importLink("trojan://pw@\u{43F}\u{440}\u{438}\u{43C}\u{435}\u{440}.\u{440}\u{444}:443#idn")
        XCTAssertEqual(unicode.outbound.server.host, "\u{43F}\u{440}\u{438}\u{43C}\u{435}\u{440}.\u{440}\u{444}")
        let punycode = try importer.importLink("trojan://pw@xn--e1afmkfd.xn--p1ai:443#puny")
        XCTAssertEqual(punycode.outbound.server.host, "xn--e1afmkfd.xn--p1ai")
        let mixedCase = try importer.importLink("trojan://pw@Example.COM:443#case")
        XCTAssertEqual(mixedCase.outbound.server.host, "Example.COM")
    }

    func testFragmentBecomesName() throws {
        let encoded = try importer.importLink("trojan://pw@example.com:443#%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0%20%231")
        XCTAssertEqual(encoded.outbound.name, "\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430} #1")

        let rawUnicodeWithSpace = try importer.importLink("trojan://pw@example.com:443#My Server \u{1F680}")
        XCTAssertEqual(rawUnicodeWithSpace.outbound.name, "My Server \u{1F680}")

        let missing = try importer.importLink("trojan://pw@example.com:443")
        XCTAssertEqual(missing.outbound.name, "example.com:443")
        XCTAssertTrue(missing.report.hasWarning(.defaultApplied))

        let missingIPv6 = try importer.importLink("trojan://pw@[2001:db8::9]:443#")
        XCTAssertEqual(missingIPv6.outbound.name, "[2001:db8::9]:443")

        let malformed = try importer.importLink("trojan://pw@example.com:443#bad%zzname")
        XCTAssertEqual(malformed.outbound.name, "bad%zzname")
        XCTAssertTrue(malformed.report.hasWarning(.malformedEncoding))
    }

    func testPercentDecodingOfQueryAndPlusIsLiteral() throws {
        let result = try importer.importLink(
            "vless://\(Fixtures.uuid)@example.com:443?security=tls&type=ws&path=%2Fa+b%20c%3Fx%3D1&host=h.example.com#p"
        )
        XCTAssertEqual(result.outbound.stream.transport, .webSocket(WebSocketSettings(
            path: "/a+b c?x=1", host: "h.example.com"
        )))

        let malformed = try importer.importLink(
            "vless://\(Fixtures.uuid)@example.com:443?security=tls&type=ws&path=%zz#p"
        )
        XCTAssertEqual(malformed.outbound.stream.transport, .webSocket(WebSocketSettings(path: "%zz")))
        XCTAssertTrue(malformed.report.hasWarning(.malformedEncoding))
    }

    func testSurroundingWhitespaceAndSchemeCase() throws {
        let result = try importer.importLink("  \tVLESS://\(Fixtures.uuid)@example.com:443?security=tls#x \r\n")
        XCTAssertEqual(result.report.scheme, "vless")
        XCTAssertEqual(result.outbound.name, "x")
    }

    // MARK: - Trojan

    func testTrojanGRPC() throws {
        let result = try importer.importLink(Fixtures.trojanGRPC)
        let outbound = result.outbound
        XCTAssertEqual(outbound.kind, .trojan)
        XCTAssertEqual(outbound.name, "Trojan gRPC")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "2001:db8::2", port: 8443))
        XCTAssertEqual(outbound.credentials.password, .inline("p@ss:word"))
        XCTAssertEqual(outbound.stream.transport, .grpc(GRPCSettings(serviceName: "grpc-svc", multiMode: true)))
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "trojan.example.com", alpn: ["h2"], allowInsecure: true
        )))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings.map { $0.code }, [.insecureTLS])
    }

    func testTrojanDefaults() throws {
        let minimal = try importer.importLink("trojan://secret@example.com#min")
        XCTAssertEqual(minimal.outbound.server.port, 443)
        XCTAssertEqual(minimal.outbound.stream.security, .tls(TLSSettings()))
        XCTAssertTrue(minimal.report.hasWarning(.defaultApplied))

        let plain = try importer.importLink("trojan://secret@example.com:80?security=none&type=ws&path=/t#plain")
        XCTAssertEqual(plain.outbound.stream.security, .none)
        XCTAssertTrue(plain.report.hasWarning(.plaintextTransport))

        let reality = try importer.importLink(
            "trojan://secret@example.com:443?security=reality&pbk=\(Fixtures.publicKey)&sid=ab&sni=r.example.com&fp=safari#r"
        )
        XCTAssertEqual(reality.outbound.stream.security, .reality(RealitySettings(
            serverName: "r.example.com", fingerprint: "safari", publicKey: Fixtures.publicKey, shortID: "ab"
        )))
        XCTAssertEqual(reality.report.warnings, [])
    }

    // MARK: - VMess

    func testVMessBase64JSONWebSocket() throws {
        let result = try importer.importLink(Fixtures.vmessWebSocketJSON)
        let outbound = result.outbound
        XCTAssertEqual(result.report.format, "vmess-base64-json")
        XCTAssertEqual(outbound.kind, .vmess)
        XCTAssertEqual(outbound.name, "DE Frankfurt WS")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "de1.example.com", port: 443))
        XCTAssertEqual(outbound.credentials.userID, .inline(Fixtures.uuid))
        XCTAssertEqual(outbound.settings, .vmess(VMessSettings(cipher: "auto", alterID: 0)))
        XCTAssertEqual(outbound.stream.transport, .webSocket(WebSocketSettings(
            path: "/vmess?ed=2048", host: "cdn.example.com"
        )))
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "cdn.example.com", alpn: ["h2", "http/1.1"], fingerprint: "chrome"
        )))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings, [])
    }

    func testVMessBase64JSONWithNumbersUnknownAndNestedMembers() throws {
        let result = try importer.importLink(Fixtures.vmessGRPCJSON)
        let outbound = result.outbound
        XCTAssertEqual(outbound.name, "grpc node")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "203.0.113.7", port: 8443))
        XCTAssertEqual(outbound.settings, .vmess(VMessSettings(cipher: "auto", alterID: 1)))
        XCTAssertEqual(outbound.stream.transport, .grpc(GRPCSettings(serviceName: "svc", multiMode: true)))
        XCTAssertEqual(outbound.stream.security, .none)
        XCTAssertTrue(result.report.hasWarning(.legacyFeature))

        XCTAssertEqual(result.report.unsupported.count, 2)
        let nested = try XCTUnwrap(result.report.unsupportedParameter(named: "nested"))
        XCTAssertEqual(nested.location, .jsonBody)
        XCTAssertEqual(nested.value, "{\"a\":1}")
        let weird = try XCTUnwrap(result.report.unsupportedParameter(named: "weird"))
        XCTAssertEqual(weird.reason, .unknown)
        XCTAssertEqual(weird.value, "x")
        XCTAssertEqual(weird.location, .jsonBody)
    }

    func testVMessBase64JSONBuiltAtRuntime() throws {
        func link(_ json: String) -> String {
            return "vmess://" + Data(json.utf8).base64EncodedString()
        }
        let kcp = try importer.importLink(link(
            "{\"v\":\"2\",\"ps\":\"k\",\"add\":\"[2001:db8::7]\",\"port\":\"8443\",\"id\":\"\(Fixtures.uuid)\","
            + "\"net\":\"kcp\",\"type\":\"wechat-video\",\"path\":\"s33d\",\"scy\":\"chacha20-poly1305\"}"
        ))
        XCTAssertEqual(kcp.outbound.server, ServerEndpoint(host: "2001:db8::7", port: 8443))
        XCTAssertEqual(kcp.outbound.settings, .vmess(VMessSettings(cipher: "chacha20-poly1305", alterID: 0)))
        XCTAssertEqual(kcp.outbound.stream.transport, .kcp(KCPSettings(
            seed: .inline("s33d"), headerType: "wechat-video"
        )))
        XCTAssertEqual(kcp.report.unsupported, [])

        let tcpHTTP = try importer.importLink(link(
            "{\"v\":\"2\",\"add\":\"example.com\",\"port\":80,\"id\":\"\(Fixtures.uuid)\","
            + "\"net\":\"tcp\",\"type\":\"http\",\"host\":\"a.example.com\",\"path\":\"/\"}"
        ))
        XCTAssertEqual(tcpHTTP.outbound.stream.transport, .tcp(TCPSettings(httpObfuscation: HTTPObfuscation(
            hosts: ["a.example.com"], paths: ["/"]
        ))))
        XCTAssertEqual(tcpHTTP.outbound.name, "example.com:80")
        XCTAssertTrue(tcpHTTP.report.hasWarning(.defaultApplied))

        // URL-safe alphabet without padding is accepted as well.
        let unpadded = link("{\"v\":\"2\",\"ps\":\"u\",\"add\":\"example.com\",\"port\":\"443\",\"id\":\"\(Fixtures.uuid)\"}")
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let plain = try importer.importLink(unpadded.replacingOccurrences(of: "vmess:__", with: "vmess://"))
        XCTAssertEqual(plain.outbound.name, "u")
        XCTAssertEqual(plain.outbound.stream, StreamSettings())
    }

    func testVMessURLForm() throws {
        let result = try importer.importLink(Fixtures.vmessURL)
        XCTAssertEqual(result.report.format, "vmess-url")
        XCTAssertEqual(result.outbound.name, "VMess AEAD")
        XCTAssertEqual(result.outbound.settings, .vmess(VMessSettings(cipher: "aes-128-gcm", alterID: 0)))
        XCTAssertEqual(result.outbound.stream.transport, .httpUpgrade(HTTPUpgradeSettings(
            path: "/up", host: "vm.example.com"
        )))
        XCTAssertEqual(result.outbound.stream.security, .tls(TLSSettings(serverName: "vm.example.com")))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings, [])
    }

    // MARK: - Shadowsocks

    func testShadowsocksSIP002WithPluginAndIPv6() throws {
        let result = try importer.importLink(Fixtures.shadowsocksSIP002)
        let outbound = result.outbound
        XCTAssertEqual(result.report.format, "sip002")
        XCTAssertEqual(outbound.kind, .shadowsocks)
        XCTAssertEqual(outbound.name, "SS v6")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "2001:db8::1", port: 8388))
        XCTAssertEqual(outbound.credentials.password, .inline("pa:ss/word"))
        XCTAssertEqual(outbound.settings, .shadowsocks(ShadowsocksSettings(
            method: "chacha20-ietf-poly1305",
            plugin: ShadowsocksPlugin(name: "obfs-local", options: "obfs=http;obfs-host=example.com")
        )))
        XCTAssertEqual(outbound.stream, StreamSettings())
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings, [])
    }

    func testShadowsocks2022PlainUserInfo() throws {
        let result = try importer.importLink(Fixtures.shadowsocks2022)
        XCTAssertEqual(result.report.format, "sip002")
        XCTAssertEqual(result.outbound.credentials.password, .inline("YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI="))
        XCTAssertEqual(result.outbound.settings, .shadowsocks(ShadowsocksSettings(method: "2022-blake3-aes-256-gcm")))
        XCTAssertEqual(result.outbound.server, ServerEndpoint(host: "ss2022.example.com", port: 8388))
        XCTAssertEqual(result.report.warnings, [])
    }

    func testShadowsocksLegacyBase64() throws {
        let result = try importer.importLink(Fixtures.shadowsocksLegacy)
        XCTAssertEqual(result.report.format, "ss-legacy-base64")
        XCTAssertEqual(result.outbound.name, "Legacy SS")
        XCTAssertEqual(result.outbound.server, ServerEndpoint(host: "198.51.100.20", port: 8388))
        XCTAssertEqual(result.outbound.credentials.password, .inline("secret"))
        XCTAssertEqual(result.outbound.settings, .shadowsocks(ShadowsocksSettings(method: "aes-256-gcm")))

        let v6 = try importer.importLink(Fixtures.shadowsocksLegacyIPv6)
        XCTAssertEqual(v6.outbound.server, ServerEndpoint(host: "2001:db8::10", port: 8388))
        XCTAssertEqual(v6.outbound.credentials.password, .inline("p@ss"))
        XCTAssertEqual(v6.outbound.settings, .shadowsocks(ShadowsocksSettings(method: "aes-128-gcm")))
    }

    func testShadowsocksUnknownParametersAndMethods() throws {
        let link = "ss://\(Data("rc4-md5:pw".utf8).base64EncodedString())@example.com:8388?type=ws&plugin=%3Bbroken#x"
        let result = try importer.importLink(link)
        XCTAssertTrue(result.report.hasWarning(.suspiciousValue))
        XCTAssertEqual(result.report.unsupportedParameter(named: "plugin")?.reason, .invalidValue)
        XCTAssertEqual(result.report.unsupportedParameter(named: "type")?.reason, .unknown)
        XCTAssertEqual(result.report.unsupportedParameter(named: "type")?.value, "ws")
        XCTAssertEqual(result.outbound.settings, .shadowsocks(ShadowsocksSettings(method: "rc4-md5")))

        let pluginWithoutOptions = try importer.importLink(
            "ss://\(Data("aes-256-gcm:pw".utf8).base64EncodedString())@example.com:8388/?plugin=v2ray-plugin#y"
        )
        XCTAssertEqual(pluginWithoutOptions.outbound.settings, .shadowsocks(ShadowsocksSettings(
            method: "aes-256-gcm", plugin: ShadowsocksPlugin(name: "v2ray-plugin", options: "")
        )))
    }

    // MARK: - Hysteria2

    func testHysteria2Full() throws {
        let result = try importer.importLink(Fixtures.hysteria2)
        let outbound = result.outbound
        XCTAssertEqual(result.report.scheme, "hysteria2")
        XCTAssertEqual(outbound.kind, .hysteria2)
        XCTAssertEqual(outbound.name, "HY2")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "hy.example.com", port: 443))
        XCTAssertEqual(outbound.credentials.password, .inline("letmein"))
        XCTAssertEqual(outbound.settings, .hysteria2(Hysteria2Settings(
            obfuscation: Hysteria2Obfuscation(type: "salamander", password: .inline("cry_me_a_r1ver")),
            serverPorts: [PortRange(lower: 443, upper: 443), PortRange(lower: 20000, upper: 30000)],
            hopIntervalSeconds: 30,
            uploadBandwidth: "50",
            downloadBandwidth: "200"
        )))
        XCTAssertEqual(outbound.stream.transport, .native)
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "hy.example.com", allowInsecure: true, pinnedPeerCertificateSHA256: "deadbeef"
        )))
        XCTAssertEqual(result.report.unsupported, [])
        // `up`/`down` are outside the official scheme; the importer says so.
        XCTAssertEqual(result.report.warnings.map { $0.code }, [.nonStandardFormat, .insecureTLS])
        XCTAssertEqual(outbound.inlineSecretSlots, [.password, .obfuscationPassword])
    }

    func testHy2AliasWithPortQueryAndUnknownParameter() throws {
        let result = try importer.importLink(Fixtures.hy2Short)
        XCTAssertEqual(result.report.scheme, "hy2")
        XCTAssertEqual(result.outbound.kind, .hysteria2)
        XCTAssertEqual(result.outbound.name, "hy2 short")
        XCTAssertEqual(result.outbound.server, ServerEndpoint(host: "2001:db8::3", port: 8443))
        XCTAssertEqual(result.outbound.credentials.password, .inline("user:pass"))
        XCTAssertEqual(result.outbound.settings, .hysteria2(Hysteria2Settings(
            serverPorts: [PortRange(lower: 5000, upper: 6000)]
        )))
        XCTAssertEqual(result.report.unsupported, [
            UnsupportedParameter(name: "foo", value: "bar", location: .query, reason: .unknown),
        ])
    }

    func testHysteria2EdgeCases() throws {
        let noPort = try importer.importLink("hysteria2://pw@hy.example.com#np")
        XCTAssertEqual(noPort.outbound.server.port, 443)
        XCTAssertTrue(noPort.report.hasWarning(.defaultApplied))

        let noAuth = try importer.importLink("hysteria2://hy.example.com:443?obfs=none#na")
        XCTAssertNil(noAuth.outbound.credentials.password)
        XCTAssertTrue(noAuth.report.hasWarning(.suspiciousValue))
        XCTAssertEqual(noAuth.outbound.settings, .hysteria2(Hysteria2Settings()))

        let orphan = try importer.importLink("hysteria2://pw@hy.example.com:443?obfs-password=zzz&security=reality#o")
        XCTAssertEqual(orphan.report.unsupportedParameter(named: "obfs-password")?.reason, .notApplicable)
        XCTAssertEqual(orphan.report.unsupportedParameter(named: "security")?.reason, .invalidValue)

        assertImportError("hysteria2://pw@hy.example.com:443?obfs=foo", .unsupportedValue(parameter: "obfs", value: "foo"))
        assertImportError("hysteria2://pw@hy.example.com:443?obfs=salamander", .missingField("obfs-password"))
        assertImportError(
            "hysteria2://pw@hy.example.com:443,70000",
            .invalidField(name: "port", reason: "not a port or a port list")
        )
        assertImportError(
            "hysteria2://pw@hy.example.com:6000-5000",
            .invalidField(name: "port", reason: "not a port or a port list")
        )
    }

    // MARK: - TUIC, SOCKS, WireGuard

    func testTUIC() throws {
        let result = try importer.importLink(Fixtures.tuic)
        let outbound = result.outbound
        XCTAssertEqual(outbound.kind, .tuic)
        XCTAssertEqual(outbound.name, "TUIC")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "tuic.example.com", port: 8443))
        XCTAssertEqual(outbound.credentials.userID, .inline(Fixtures.uuid))
        XCTAssertEqual(outbound.credentials.password, .inline("tu1c-pass"))
        XCTAssertEqual(outbound.settings, .tuic(TUICSettings(congestionControl: "bbr", udpRelayMode: "native")))
        XCTAssertEqual(outbound.stream.transport, .native)
        XCTAssertEqual(outbound.stream.security, .tls(TLSSettings(
            serverName: "tuic.example.com", alpn: ["h3"], allowInsecure: false, disableSNI: true
        )))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings.map { $0.code }, [.nonStandardFormat])

        let encodedSeparator = try importer.importLink("tuic://\(Fixtures.uuid)%3Ap%2540ss@tuic.example.com:443#t")
        XCTAssertEqual(encodedSeparator.outbound.credentials.password, .inline("p%40ss"))

        assertImportError("tuic://\(Fixtures.uuid)@tuic.example.com:443", .missingField("password"))
        assertImportError("tuic://tuic.example.com:443", .missingField("uuid"))
    }

    func testSOCKS() throws {
        let base64 = try importer.importLink(Fixtures.socksBase64)
        XCTAssertEqual(base64.outbound.kind, .socks)
        XCTAssertEqual(base64.outbound.name, "Office")
        XCTAssertEqual(base64.outbound.server, ServerEndpoint(host: "192.0.2.1", port: 1080))
        XCTAssertEqual(base64.outbound.credentials.username, "alice")
        XCTAssertEqual(base64.outbound.credentials.password, .inline("s3cret"))
        XCTAssertEqual(base64.outbound.settings, .socks(SOCKSSettings(version: .v5)))
        XCTAssertEqual(base64.outbound.stream, StreamSettings())
        XCTAssertEqual(base64.report.warnings, [])

        let plain = try importer.importLink(Fixtures.socksPlain)
        XCTAssertEqual(plain.report.scheme, "socks5")
        XCTAssertEqual(plain.outbound.credentials.username, "bob")
        XCTAssertEqual(plain.outbound.credentials.password, .inline("p@ss"))
        XCTAssertEqual(plain.outbound.name, "proxy.example.com:1081")

        let anonymous = try importer.importLink("socks4a://192.0.2.9?udp=1#anon")
        XCTAssertNil(anonymous.outbound.credentials.username)
        XCTAssertNil(anonymous.outbound.credentials.password)
        XCTAssertEqual(anonymous.outbound.server.port, 1080)
        XCTAssertEqual(anonymous.outbound.settings, .socks(SOCKSSettings(version: .v4a)))
        XCTAssertEqual(anonymous.report.unsupportedParameter(named: "udp")?.reason, .unknown)

        let userOnly = try importer.importLink("socks://justme@192.0.2.9:1080#u")
        XCTAssertEqual(userOnly.outbound.credentials.username, "justme")
        XCTAssertNil(userOnly.outbound.credentials.password)
    }

    func testWireGuard() throws {
        let result = try importer.importLink(Fixtures.wireGuard)
        let outbound = result.outbound
        XCTAssertEqual(outbound.kind, .wireGuard)
        XCTAssertEqual(outbound.name, "WG")
        XCTAssertEqual(outbound.server, ServerEndpoint(host: "wg.example.com", port: 51820))
        XCTAssertEqual(outbound.credentials.privateKey, .inline("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="))
        XCTAssertNil(outbound.credentials.preSharedKey)
        XCTAssertEqual(outbound.settings, .wireGuard(WireGuardSettings(
            peerPublicKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
            localAddresses: ["10.0.0.2/32", "fd00::2/128"],
            reserved: [1, 2, 3],
            mtu: 1280,
            persistentKeepaliveSeconds: 25
        )))
        XCTAssertEqual(outbound.stream, StreamSettings(transport: .native, security: .none))
        XCTAssertEqual(result.report.unsupported, [])
        XCTAssertEqual(result.report.warnings.map { $0.code }, [.nonStandardFormat])
        XCTAssertEqual(outbound.inlineSecretSlots, [.privateKey])

        let alias = try importer.importLink(
            "wg://c2hvcnQ@wg.example.com:51820?publicKey=c2hvcnQ&reserved=1,2&psk=cHNr&ip=10.0.0.3/32#a"
        )
        XCTAssertEqual(alias.outbound.credentials.preSharedKey, .inline("cHNr"))
        XCTAssertEqual(alias.report.unsupportedParameter(named: "reserved")?.reason, .invalidValue)
        XCTAssertEqual(alias.report.warnings.filter { $0.code == .suspiciousValue }.count, 2)

        assertImportError("wireguard://a2V5@wg.example.com:51820", .missingField("publickey"))
        assertImportError("wireguard://a2V5@wg.example.com?publickey=a2V5", .missingField("port"))
    }

    // MARK: - Malformed and hostile input

    func testEmptyAndSchemeErrors() {
        assertImportError("", .emptyInput)
        assertImportError("   \n", .emptyInput)
        assertImportError("not a link", .malformedLink(reason: "missing scheme"))
        assertImportError("vless:/missing-slash", .malformedLink(reason: "missing scheme"))
        assertImportError("vless://", .malformedLink(reason: "empty body"))
        assertImportError("http://example.com", .unsupportedScheme("http"))
        assertImportError("ssr://c29tZXRoaW5n", .unsupportedScheme("ssr"))
        assertImportError("vless://u@example.com:443\u{01}", .malformedLink(reason: "contains control characters"))
    }

    func testMalformedAuthority() {
        assertImportError("vless://@example.com:443", .missingField("id"))
        assertImportError("vless://example.com:443", .missingField("id"))
        assertImportError("vless://\(Fixtures.uuid)@example.com", .missingField("port"))
        assertImportError("vless://\(Fixtures.uuid)@:443", .invalidField(
            name: "host", reason: "empty or contains forbidden characters"
        ))
        assertImportError("vless://\(Fixtures.uuid)@", .missingField("host"))
        assertImportError("vless://\(Fixtures.uuid)@example.com:99999", .invalidField(
            name: "port", reason: "not a number in 1...65535"
        ))
        assertImportError("vless://\(Fixtures.uuid)@example.com:0", .invalidField(
            name: "port", reason: "not a number in 1...65535"
        ))
        assertImportError("vless://\(Fixtures.uuid)@example.com:44a", .invalidField(
            name: "port", reason: "not a number in 1...65535"
        ))
        assertImportError("vless://\(Fixtures.uuid)@example.com:", .invalidField(
            name: "port", reason: "not a number in 1...65535"
        ))
        assertImportError("vless://\(Fixtures.uuid)@2001:db8::1:443", .invalidField(
            name: "host", reason: "IPv6 literal must be enclosed in brackets"
        ))
        assertImportError("vless://\(Fixtures.uuid)@[2001:db8::1:443", .malformedLink(
            reason: "unterminated IPv6 literal"
        ))
        assertImportError("vless://\(Fixtures.uuid)@[2001:db8::1]443", .malformedLink(
            reason: "unexpected text after IPv6 literal"
        ))
        assertImportError("vless://\(Fixtures.uuid)@[not-v6]:443", .invalidField(
            name: "host", reason: "not an IPv6 literal"
        ))
        assertImportError("trojan://pw@exa mple.com:443", .invalidField(
            name: "host", reason: "empty or contains forbidden characters"
        ))
        assertImportError("trojan://p%zzw@example.com:443", .invalidField(
            name: "password", reason: "malformed percent-encoding"
        ))
    }

    func testUnsupportedValuesAreFatalNotSilentFallbacks() {
        let base = "vless://\(Fixtures.uuid)@example.com:443"
        assertImportError(base + "?type=carrierpigeon", .unsupportedValue(parameter: "type", value: "carrierpigeon"))
        assertImportError(base + "?type=tcp&headerType=srtp", .unsupportedValue(parameter: "headerType", value: "srtp"))
        assertImportError(base + "?security=xtls", .unsupportedValue(parameter: "security", value: "xtls"))
        assertImportError(base + "?security=reality", .missingField("pbk"))
    }

    func testMalformedVMess() {
        assertImportError("vmess://!!!!", .invalidBase64(context: "vmess"))
        // base64 of "auto:uuid@host:443" — a legacy non-JSON variant that is not supported.
        assertImportError(
            "vmess://YXV0bzp1dWlkQGhvc3Q6NDQz",
            .malformedLink(reason: "unsupported vmess variant: base64 body is not a JSON object")
        )
        func link(_ json: String) -> String {
            return "vmess://" + Data(json.utf8).base64EncodedString()
        }
        assertImportError(link("{\"v\":\"2\"}"), .missingField("add"))
        assertImportError(link("{\"add\":\"example.com\"}"), .missingField("port"))
        assertImportError(link("{\"add\":\"example.com\",\"port\":\"443\"}"), .missingField("id"))
        assertImportError(link("{\"add\":\"example.com\",\"port\":\"http\",\"id\":\"x\"}"), .invalidField(
            name: "port", reason: "not a number in 1...65535"
        ))
        assertImportError(link("{\"add\":\"exa mple.com\",\"port\":\"443\",\"id\":\"x\"}"), .invalidField(
            name: "add", reason: "empty or contains forbidden characters"
        ))
        assertImportError(link("{\"add\":\"example.com\",\"port\":\"443\",\"id\":\"x\""), .invalidJSON(context: "vmess"))
        assertImportError(
            link("{\"add\":\"example.com\",\"port\":\"443\",\"id\":\"x\",\"net\":\"smoke\"}"),
            .unsupportedValue(parameter: "type", value: "smoke")
        )
        let deep = "{\"add\":\"example.com\",\"port\":\"443\",\"id\":\"x\",\"z\":"
            + String(repeating: "[", count: 40) + String(repeating: "]", count: 40) + "}"
        assertImportError(link(deep), .invalidJSON(context: "vmess"))
    }

    func testMalformedShadowsocks() {
        assertImportError("ss://%%%@example.com:8388", .invalidBase64(context: "ss"))
        assertImportError("ss://!!!", .invalidBase64(context: "ss"))
        // base64 of "nocolon"
        assertImportError("ss://bm9jb2xvbg@example.com:8388", .missingField("password"))
        // base64 of "aes-256-gcm:pw" without a host
        assertImportError(
            "ss://\(Data("aes-256-gcm:pw".utf8).base64EncodedString())",
            .malformedLink(reason: "legacy ss body is not method:password@host:port")
        )
        assertImportError(
            "ss://\(Data("aes-256-gcm:pw@example.com".utf8).base64EncodedString())",
            .missingField("port")
        )
        assertImportError(
            "ss://\(Data(":pw".utf8).base64EncodedString())@example.com:8388",
            .missingField("method")
        )
        assertImportError("ss://aes-256-gcm:@example.com:8388", .missingField("password"))
    }

    func testOversizedLinkIsRejectedBeforeParsing() {
        let limit = ImportLimits.standard.maximumLinkBytes
        let link = "vless://\(Fixtures.uuid)@example.com:443?security=tls#" + String(repeating: "a", count: limit)
        assertImportError(link, .inputTooLarge(limit: limit, actual: link.utf8.count))

        let small = ShareLinkImporter(limits: ImportLimits(maximumLinkBytes: 32))
        XCTAssertThrowsError(try small.importLink(Fixtures.vlessRealityVision)) { error in
            XCTAssertEqual(
                error as? ImportError,
                .inputTooLarge(limit: 32, actual: Fixtures.vlessRealityVision.utf8.count)
            )
        }
    }

    func testTooManyParameters() {
        var link = "vless://\(Fixtures.uuid)@example.com:443?security=tls"
        for index in 0..<200 {
            link += "&p\(index)=\(index)"
        }
        assertImportError(link, .tooManyParameters(limit: ImportLimits.standard.maximumParameters))
    }

    func testDeeplyNestedExtraIsRecordedNotParsed() throws {
        let deep = String(repeating: "%5B", count: 40) + String(repeating: "%5D", count: 40)
        let result = try importer.importLink(
            "vless://\(Fixtures.uuid)@example.com:443?security=tls&type=xhttp&extra=\(deep)#deep"
        )
        XCTAssertTrue(result.outbound.extras.isEmpty)
        XCTAssertEqual(result.report.unsupportedParameter(named: "extra")?.reason, .invalidValue)
    }

    func testImporterNeverCrashesOnJunk() {
        let junk = [
            "://", "a://", "vless://#", "vless://?", "vless://@", "vless://@@@", "vless://[", "vless://]",
            "vless://[]:1", "vless://a@[::1]:", "vless://a@b:1?&&&=&=", "vless://a@b:1?%=%", "vless://a@b:1#%",
            "vmess://e30", "vmess://W10", "vmess://bnVsbA", "vmess://@", "ss://@", "ss://:@:", "ss://@@@:1",
            "ss://YQ", "trojan://:@:", "hy2://@:,", "hy2://a@b:-", "hysteria2://a@b:1-", "tuic://:@a:1",
            "tuic://%3A@a:1", "socks://%@a:1", "socks://a:1:2", "wireguard://@a:1?publickey=", "wg://a@b:1?reserved=,,,",
            "vless://\u{FEFF}", "trojan://\u{1F600}@\u{1F600}:1#\u{1F600}", "vless://a@b:1?type=%00",
        ]
        for link in junk {
            // Any outcome is acceptable except a crash; errors must be of the declared type.
            do {
                _ = try importer.importLink(link)
            } catch {
                XCTAssertTrue(error is ImportError, "unexpected error type for \(link)")
            }
        }
    }

    func testSupportedSchemes() {
        for scheme in ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic", "socks", "wireguard"] {
            XCTAssertTrue(ShareLinkImporter.isSupportedScheme(scheme))
        }
        XCTAssertTrue(ShareLinkImporter.isSupportedScheme("VLESS"))
        XCTAssertFalse(ShareLinkImporter.isSupportedScheme("https"))
    }

    func testImportIsDeterministic() throws {
        for link in [Fixtures.vlessXHTTP, Fixtures.vmessGRPCJSON, Fixtures.hysteria2, Fixtures.wireGuard] {
            XCTAssertEqual(try importer.importLink(link), try importer.importLink(link))
        }
    }

    func testImportedOutboundIsCodable() throws {
        let imported = try importer.importLink(Fixtures.vlessXHTTP)
        let data = try JSONEncoder().encode(imported)
        XCTAssertEqual(try JSONDecoder().decode(ImportedOutbound.self, from: data), imported)
    }
}
