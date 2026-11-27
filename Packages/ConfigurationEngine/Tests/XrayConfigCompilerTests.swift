import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

final class XrayConfigCompilerTests: XCTestCase {

    private let compiler = XrayConfigCompiler()
    private let importer = ShareLinkImporter()
    private let realityKey = ProfileFixtures.realityKey

    private func outbound(_ link: String) throws -> Outbound {
        return try importer.importLink(link).outbound
    }

    private func compileOne(_ outbound: Outbound) -> (json: JSONValue?, issues: [ConversionIssue]) {
        return compiler.compileOutbound(outbound, engineTag: "proxy-0000")
    }

    private func assertBlocked(
        _ outbound: Outbound,
        at fragment: String,
        _ kind: ConversionIssue.Kind = .unsupported,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = compileOne(outbound)
        XCTAssertNil(result.json, "must not be emitted", file: file, line: line)
        XCTAssertTrue(
            result.issues.contains { $0.severity == .error && $0.kind == kind && $0.path.contains(fragment) },
            "no \(kind) error at \(fragment): \(result.issues)", file: file, line: line
        )
    }

    // MARK: - Shape of the output

    func testVLESSRealityVision() throws {
        let link = "vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?flow=xtls-rprx-vision&security=reality"
            + "&sni=www.example.org&fp=chrome&pbk=\(realityKey)&sid=0a1b#n"
        let result = compileOne(try outbound(link))
        let json = try XCTUnwrap(result.json)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(json["protocol"], .string("vless"))
        XCTAssertEqual(json["tag"], .string("proxy-0000"))
        XCTAssertEqual(json["settings"]?["address"], .string("192.0.2.1"))
        XCTAssertEqual(json["settings"]?["port"], .integer(443))
        XCTAssertEqual(json["settings"]?["flow"], .string("xtls-rprx-vision"))
        XCTAssertEqual(json["settings"]?["encryption"], .string("none"))
        let stream = try XCTUnwrap(json["streamSettings"])
        XCTAssertEqual(stream["network"], .string("raw"))
        XCTAssertEqual(stream["security"], .string("reality"))
        XCTAssertEqual(stream["realitySettings"]?["password"], .string(realityKey))
        XCTAssertEqual(stream["realitySettings"]?["shortId"], .string("0a1b"))
        XCTAssertEqual(stream["realitySettings"]?["serverName"], .string("www.example.org"))
        XCTAssertNil(stream["tlsSettings"])
    }

    func testRealityKeyIsNormalisedToUnpaddedBase64URL() throws {
        let raw = try XCTUnwrap(LenientBase64.decode(realityKey))
        let standard = raw.base64EncodedString()
        XCTAssertNotEqual(standard, realityKey)
        var node = ProfileFixtures.vless("a", host: "192.0.2.1")
        node.stream.security = .reality(RealitySettings(publicKey: standard))
        let json = try XCTUnwrap(compileOne(node).json)
        XCTAssertEqual(json["streamSettings"]?["realitySettings"]?["password"], .string(realityKey))
    }

    func testServerNameDefaultsToHostForVLESSButNotForIPLiterals() throws {
        let domain = try outbound("vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=tls#n")
        XCTAssertEqual(
            compileOne(domain).json?["streamSettings"]?["tlsSettings"]?["serverName"], .string("a.example.com")
        )
        let address = try outbound("vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?security=tls#n")
        XCTAssertNil(compileOne(address).json?["streamSettings"]?["tlsSettings"]?["serverName"])
        // Trojan: libXray falls back to the WebSocket host.
        let trojan = try outbound("trojan://pw@192.0.2.1:443?type=ws&host=ws.example.com#n")
        let result = compileOne(trojan)
        XCTAssertEqual(result.json?["streamSettings"]?["tlsSettings"]?["serverName"], .string("ws.example.com"))
        XCTAssertTrue(result.issues.contains { $0.kind == .migrated && $0.severity == .info })
    }

    func testTransports() throws {
        let base = "vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=tls"
        let ws = try XCTUnwrap(compileOne(try outbound(base + "&type=ws&host=h.example.com&path=%2Fw#n")).json)
        XCTAssertEqual(ws["streamSettings"]?["network"], .string("ws"))
        XCTAssertEqual(ws["streamSettings"]?["wsSettings"], .object(["host": .string("h.example.com"), "path": .string("/w")]))

        let grpc = try XCTUnwrap(compileOne(try outbound(base + "&type=grpc&serviceName=s&authority=au&mode=multi#n")).json)
        XCTAssertEqual(grpc["streamSettings"]?["grpcSettings"], .object([
            "serviceName": .string("s"), "authority": .string("au"), "multiMode": .bool(true),
        ]))

        let upgrade = try XCTUnwrap(compileOne(try outbound(base + "&type=httpupgrade&path=%2Fu#n")).json)
        XCTAssertEqual(upgrade["streamSettings"]?["network"], .string("httpupgrade"))
        XCTAssertEqual(upgrade["streamSettings"]?["httpupgradeSettings"], .object(["path": .string("/u")]))

        let header = try XCTUnwrap(compileOne(try outbound(base + "&type=tcp&headerType=http&host=a.example,b.example&path=%2Fx#n")).json)
        XCTAssertEqual(header["streamSettings"]?["rawSettings"]?["header"]?["type"], .string("http"))
        XCTAssertEqual(
            header["streamSettings"]?["rawSettings"]?["header"]?["request"]?["headers"]?["Host"],
            .array([.string("a.example"), .string("b.example")])
        )
    }

    func testXHTTPExtraIsPassedVerbatimAndReported() throws {
        let extra = #"{"xPaddingBytes":"100-1000","downloadSettings":{"address":"d.example.net","port":443,"network":"xhttp","security":"tls"}}"#
        let encoded = PercentCoding.encode(extra, as: .strict)
        let link = "vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=tls&type=xhttp&path=%2Fp&mode=stream-up&extra=\(encoded)#n"
        let result = compileOne(try outbound(link))
        let settings = try XCTUnwrap(result.json?["streamSettings"]?["xhttpSettings"])
        XCTAssertEqual(settings["mode"], .string("stream-up"))
        XCTAssertEqual(settings["extra"]?["xPaddingBytes"], .string("100-1000"))
        XCTAssertEqual(settings["extra"]?["downloadSettings"]?["address"], .string("d.example.net"))
        XCTAssertTrue(result.issues.contains { $0.kind == .engineLocked && $0.path.hasSuffix("transport.extra") })
    }

    func testTypedXHTTPDownloadLeg() throws {
        let profile = try XCTUnwrap(ProfileFixtures.all.first { $0.0 == "xhttp-typed-download" }?.1)
        let result = compileOne(profile.outbounds[0])
        let download = try XCTUnwrap(result.json?["streamSettings"]?["xhttpSettings"]?["extra"]?["downloadSettings"])
        XCTAssertEqual(download["address"], .string("dl.example.net"))
        XCTAssertEqual(download["port"], .integer(8443))
        XCTAssertEqual(download["network"], .string("xhttp"))
        XCTAssertEqual(download["security"], .string("tls"))
        XCTAssertEqual(download["tlsSettings"]?["serverName"], .string("dl.example.net"))
        XCTAssertEqual(download["xhttpSettings"]?["path"], .string("/down"))

        var streamOne = profile.outbounds[0]
        if case .xhttp(var settings) = streamOne.stream.transport {
            settings.mode = "stream-one"
            streamOne.stream.transport = .xhttp(settings)
        }
        assertBlocked(streamOne, at: "transport.download", .invalid)
    }

    func testKCPHeaderAndSeedAreMigratedToMasks() throws {
        let link = "vless://\(ProfileFixtures.uuidA)@10.0.0.1:4000?type=kcp&headerType=wechat-video&seed=s3cret&mtu=1350#n"
        let result = compileOne(try outbound(link))
        let stream = try XCTUnwrap(result.json?["streamSettings"])
        XCTAssertEqual(stream["kcpSettings"], .object(["mtu": .integer(1350)]))
        XCTAssertEqual(stream["finalmask"]?["udp"], .array([
            .object(["type": .string("mkcp-legacy"), "settings": .object(["header": .string("wechat")])]),
            .object(["type": .string("mkcp-legacy"), "settings": .object(["value": .string("s3cret")])]),
        ]))
        XCTAssertEqual(result.issues.filter { $0.kind == .migrated }.count, 2)
        XCTAssertTrue(result.issues.contains { $0.kind == .untested })
        XCTAssertFalse(result.issues.contains { $0.detail.contains("s3cret") }, "secrets must not leak into the report")
    }

    func testProtocols() throws {
        let vmess = try XCTUnwrap(compileOne(try outbound(
            "vmess://\(ProfileFixtures.uuidA)@a.example.com:443?encryption=aes-128-gcm&security=tls#n"
        )).json)
        XCTAssertEqual(vmess["settings"]?["security"], .string("aes-128-gcm"))
        XCTAssertEqual(vmess["settings"]?["id"], .string(ProfileFixtures.uuidA))

        let trojan = try XCTUnwrap(compileOne(try outbound("trojan://p%40ss@a.example.com:443#n")).json)
        XCTAssertEqual(trojan["settings"]?["password"], .string("p@ss"))
        XCTAssertEqual(trojan["streamSettings"]?["security"], .string("tls"))

        let key = Data(repeating: 7, count: 16).base64EncodedString()
        let shadowsocks = try XCTUnwrap(compileOne(try outbound(
            "ss://2022-blake3-aes-128-gcm:\(PercentCoding.encode(key, as: .strict))@192.0.2.1:8388#n"
        )).json)
        XCTAssertEqual(shadowsocks["settings"]?["method"], .string("2022-blake3-aes-128-gcm"))
        XCTAssertEqual(shadowsocks["settings"]?["password"], .string(key))
        XCTAssertEqual(shadowsocks["streamSettings"]?["network"], .string("raw"))

        let socks = try XCTUnwrap(compileOne(try outbound("socks://dXNlcjpwYXNz@192.0.2.1:1080#n")).json)
        XCTAssertEqual(socks["settings"]?["user"], .string("user"))
        XCTAssertEqual(socks["settings"]?["pass"], .string("pass"))

        let http = try XCTUnwrap(ProfileFixtures.all.first { $0.0 == "http-proxy-tls" }?.1.outbounds[0])
        let compiledHTTP = try XCTUnwrap(compileOne(http).json)
        XCTAssertEqual(compiledHTTP["protocol"], .string("http"))
        XCTAssertEqual(compiledHTTP["settings"]?["user"], .string("user1"))
        XCTAssertEqual(compiledHTTP["streamSettings"]?["tlsSettings"]?["alpn"], .array([.string("http/1.1")]))
    }

    func testWireGuard() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let peer = Data(repeating: 2, count: 32).base64EncodedString()
        let link = "wireguard://\(PercentCoding.encode(key, as: .strict))@[2001:db8::1]:51820"
            + "?publickey=\(PercentCoding.encode(peer, as: .strict))&address=10.0.0.2%2F32&reserved=1,2,3&keepalive=25&mtu=1280#n"
        let result = compileOne(try outbound(link))
        let json = try XCTUnwrap(result.json)
        XCTAssertEqual(json["protocol"], .string("wireguard"))
        XCTAssertNil(json["streamSettings"])
        XCTAssertEqual(json["settings"]?["secretKey"], .string(key))
        XCTAssertEqual(json["settings"]?["reserved"], .array([.integer(1), .integer(2), .integer(3)]))
        XCTAssertEqual(json["settings"]?["mtu"], .integer(1280))
        XCTAssertEqual(json["settings"]?["peers"], .array([.object([
            "endpoint": .string("[2001:db8::1]:51820"), "publicKey": .string(peer), "keepAlive": .integer(25),
        ])]))

        var broken = try outbound(link)
        broken.credentials.privateKey = .inline("not-a-key")
        assertBlocked(broken, at: "credentials.privateKey", .invalid)
    }

    func testHysteria2() throws {
        let link = "hysteria2://auth@hy.example.com:443,5000-6000/?obfs=salamander&obfs-password=gawrgura"
            + "&sni=hy.example.com&hop-interval=45&up=100mbps&down=20#n"
        let result = compileOne(try outbound(link))
        let json = try XCTUnwrap(result.json)
        XCTAssertEqual(json["protocol"], .string("hysteria"))
        XCTAssertEqual(json["settings"], .object([
            "address": .string("hy.example.com"), "port": .integer(443), "version": .integer(2),
        ]))
        let stream = try XCTUnwrap(json["streamSettings"])
        XCTAssertEqual(stream["network"], .string("hysteria"))
        XCTAssertEqual(stream["security"], .string("tls"))
        XCTAssertEqual(stream["hysteriaSettings"], .object(["version": .integer(2), "auth": .string("auth")]))
        XCTAssertEqual(stream["tlsSettings"]?["serverName"], .string("hy.example.com"))
        XCTAssertEqual(stream["finalmask"]?["udp"], .array([
            .object(["type": .string("salamander"), "settings": .object(["password": .string("gawrgura")])]),
            .object(["type": .string("udphop"), "settings": .object([
                "mode": .string("intervalLocal,intervalRemote"),
                "remotePorts": .string("443,5000-6000"),
                "interval": .integer(45),
            ])]),
        ]))
        XCTAssertEqual(stream["finalmask"]?["quicParams"], .object([
            "congestion": .string("brutal"), "brutalUp": .string("100mbps"),
        ]))
        // A bare number means bytes per second to Xray and megabits to other clients: not guessed.
        XCTAssertTrue(result.issues.contains { $0.kind == .dropped && $0.path.hasSuffix("downloadBandwidth") })

        let gecko = try outbound("hysteria2://a@hy.example.com:443/?obfs=gecko&obfs-password=gawrgura#n")
        assertBlocked(gecko, at: "settings.obfuscation")
    }

    func testBandwidthParsingFollowsXray() {
        XCTAssertEqual(XrayConfigCompiler.bandwidthBytesPerSecond("100 mbps"), 12_500_000)
        XCTAssertEqual(XrayConfigCompiler.bandwidthBytesPerSecond("1g"), 125_000_000)
        XCTAssertEqual(XrayConfigCompiler.bandwidthBytesPerSecond("800kbps"), 100_000)
        XCTAssertNil(XrayConfigCompiler.bandwidthBytesPerSecond("100"))
        XCTAssertNil(XrayConfigCompiler.bandwidthBytesPerSecond("100 furlongs"))
        XCTAssertNil(XrayConfigCompiler.bandwidthBytesPerSecond("fast"))
    }

    // MARK: - Lossy and unsupported input is reported, never dropped silently

    func testAllowInsecureIsReportedAndNotEmitted() throws {
        let node = try outbound("trojan://pw@a.example.com:443?allowInsecure=1#n")
        let result = compileOne(node)
        let tls = try XCTUnwrap(result.json?["streamSettings"]?["tlsSettings"])
        XCTAssertNil(tls["allowInsecure"])
        XCTAssertTrue(result.issues.contains {
            $0.kind == .unsupported && $0.severity == .warning && $0.path.hasSuffix("allowInsecure")
        })
    }

    func testUnknownImportParametersAreReported() throws {
        let node = try outbound("vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=tls&foo=bar&serviceName=x#n")
        let result = compileOne(node)
        XCTAssertNotNil(result.json)
        XCTAssertTrue(result.issues.contains { $0.kind == .dropped && $0.path.hasSuffix("unsupported[foo]") })
        XCTAssertTrue(result.issues.contains { $0.kind == .dropped && $0.path.hasSuffix("unsupported[serviceName]") })
        XCTAssertFalse(result.issues.contains { $0.detail.contains("bar") }, "values may be credentials")
    }

    func testUnsupportedProtocolsAndTransports() throws {
        assertBlocked(try outbound("tuic://\(ProfileFixtures.uuidA):pw@a.example.com:443#n"), at: "settings")
        for kind in ProxyProtocolKind.allCases {
            let node = Outbound(tag: "x", name: "x", server: ServerEndpoint(host: "a.example.com", port: 1), settings: .other(kind))
            assertBlocked(node, at: "settings")
        }
        let base = "vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=tls"
        assertBlocked(try outbound(base + "&type=http&path=%2Fh#n"), at: "stream.transport")
        assertBlocked(try outbound(base + "&type=quic#n"), at: "stream.transport")
        assertBlocked(try outbound("socks4://192.0.2.1:1080#n"), at: "settings.version")
        assertBlocked(try outbound("ss://YWVzLTEyOC1nY206cHc@192.0.2.1:1/?plugin=obfs-local%3Bobfs%3Dhttp#n"), at: "settings.plugin")
        assertBlocked(try outbound("ss://bm9uZTpwdw@192.0.2.1:1#n"), at: "settings.method")
        assertBlocked(try outbound("ss://2022-blake3-aes-256-gcm:c2hvcnQ%3D@192.0.2.1:1#n"), at: "credentials.password", .invalid)
        assertBlocked(try outbound(base + "&flow=xtls-rprx-direct#n"), at: "settings.flow")
        assertBlocked(try outbound(base + "&fp=netscape#n"), at: "security.fingerprint")
        assertBlocked(
            try outbound("vless://\(ProfileFixtures.uuidA)@a.example.com:443?type=ws&security=reality&pbk=\(realityKey)#n"),
            at: "stream.security"
        )
    }

    func testInvalidRealityValues() throws {
        let base = "vless://\(ProfileFixtures.uuidA)@a.example.com:443?security=reality"
        assertBlocked(try outbound(base + "&pbk=AAAA#n"), at: "security.publicKey", .invalid)
        assertBlocked(try outbound(base + "&pbk=\(realityKey)&sid=xyz#n"), at: "security.shortID", .invalid)
        assertBlocked(try outbound(base + "&pbk=\(realityKey)&sid=abc#n"), at: "security.shortID", .invalid)
        assertBlocked(try outbound(base + "&pbk=\(realityKey)&spx=nopath#n"), at: "security.spiderX", .invalid)
        assertBlocked(try outbound(base + "&pbk=\(realityKey)&pqv=AAAA#n"), at: "security.mldsa65Verify", .invalid)
        assertBlocked(try outbound(base + "&pbk=\(realityKey)&fp=unsafe#n"), at: "security.fingerprint")
    }

    func testPlaintextToPublicAddressIsRefusedAsXrayDoes() throws {
        assertBlocked(try outbound("vless://\(ProfileFixtures.uuidA)@a.example.com:80#n"), at: "stream.security")
        assertBlocked(try outbound("trojan://pw@192.0.2.1:80?security=none#n"), at: "stream.security")
        XCTAssertNotNil(compileOne(try outbound("vless://\(ProfileFixtures.uuidA)@192.168.1.2:80#n")).json)
        XCTAssertNotNil(compileOne(try outbound("vless://\(ProfileFixtures.uuidA)@router.lan:80#n")).json)
        XCTAssertNotNil(compileOne(try outbound("vmess://\(ProfileFixtures.uuidA)@a.example.com:80#n")).json)
        XCTAssertTrue(XrayConfigCompiler.isPublicAddress("172.32.0.1"))
        XCTAssertFalse(XrayConfigCompiler.isPublicAddress("172.31.0.1"))
        XCTAssertFalse(XrayConfigCompiler.isPublicAddress("fd00::1"))
        XCTAssertFalse(XrayConfigCompiler.isPublicAddress("fe80::1"))
        XCTAssertTrue(XrayConfigCompiler.isPublicAddress("2001:db8::1"))
        XCTAssertFalse(XrayConfigCompiler.isPublicAddress("printer"))
        XCTAssertFalse(XrayConfigCompiler.isPublicAddress("nas.home.arpa"))
    }

    func testVMessLegacyFeaturesAreReported() throws {
        var node = try outbound("vmess://\(ProfileFixtures.uuidA)@a.example.com:443?encryption=zero&security=tls#n")
        node.settings = .vmess(VMessSettings(cipher: "zero", alterID: 4))
        let result = compileOne(node)
        XCTAssertEqual(result.json?["settings"]?["security"], .string("auto"))
        XCTAssertNil(result.json?["settings"]?["alterId"])
        XCTAssertTrue(result.issues.contains { $0.kind == .approximated && $0.path.hasSuffix("settings.cipher") })
        XCTAssertTrue(result.issues.contains { $0.kind == .unsupported && $0.path.hasSuffix("settings.alterID") })
    }

    func testExtrasOfOtherEnginesAndUnusedXrayExtrasAreReported() throws {
        var node = try outbound("trojan://pw@a.example.com:443#n")
        node.extras.set(.string("x"), engine: .singBox, key: "multiplex")
        node.extras.set(.object(["a": .integer(1)]), engine: .xray, key: EngineExtras.xrayXHTTPExtraKey)
        node.extras.set(.object(["tcp": .array([.object(["type": .string("fragment")])])]), engine: .xray, key: EngineExtras.xrayFinalMaskKey)
        let result = compileOne(node)
        XCTAssertEqual(result.json?["streamSettings"]?["finalmask"]?["tcp"], .array([.object(["type": .string("fragment")])]))
        XCTAssertTrue(result.issues.contains { $0.kind == .engineLocked && $0.path.hasSuffix("finalmask") })
        XCTAssertTrue(result.issues.contains { $0.kind == .dropped && $0.severity == .info && $0.path.contains("sing-box") })
        XCTAssertTrue(result.issues.contains { $0.kind == .dropped && $0.severity == .warning && $0.path.contains("xhttp.extra") })
    }

    // MARK: - Secrets

    func testSecretReferencesAreResolvedOrBlock() throws {
        var node = try outbound("trojan://pw@a.example.com:443#n")
        node.credentials.password = .reference(SecretReference(identifier: "kc-1"))
        assertBlocked(node, at: "credentials.password", .invalid)

        let resolving = XrayConfigCompiler(resolveSecret: { $0.identifier == "kc-1" ? "from-keychain" : nil })
        let result = resolving.compileOutbound(node, engineTag: "t")
        XCTAssertEqual(result.json?["settings"]?["password"], .string("from-keychain"))
        XCTAssertFalse(result.issues.contains { $0.detail.contains("from-keychain") })

        node.credentials.password = nil
        assertBlocked(node, at: "credentials.password", .invalid)
    }

    // MARK: - Profile level

    func testMobileMemoryProfile() throws {
        let node = try outbound("trojan://pw@a.example.com:443#my node")
        let profile = Profile(name: "p", outbounds: [node], selectedTag: "my node")
        let mobile = XrayConfigCompiler(options: XrayCompileOptions(memoryProfile: .mobile)).compile(profile)
        // an informational note only: the profile itself is compiled exactly
        XCTAssertEqual(mobile.report.verdict, .exact)
        XCTAssertTrue(mobile.report.issues.contains { $0.path == "options.memoryProfile" && $0.severity == .info })
        XCTAssertEqual(mobile.config?["policy"], .object(["levels": .object(["0": .object([
            "connIdle": .integer(30), "handshake": .integer(10), "uplinkOnly": .integer(1),
            "downlinkOnly": .integer(1), "bufferSize": .integer(4),
        ])])]))
        XCTAssertNil(XrayConfigCompiler().compile(profile).config?["policy"])

        let hysteria = try outbound("hysteria2://auth@hy.example.com:443/?sni=hy.example.com&up=100mbps#h")
        let mobileHy = XrayConfigCompiler(options: XrayCompileOptions(memoryProfile: .mobile))
            .compileOutbound(hysteria, engineTag: "proxy-0000")
        XCTAssertEqual(mobileHy.json?["streamSettings"]?["finalmask"]?["quicParams"], .object([
            "congestion": .string("brutal"), "brutalUp": .string("100mbps"),
            "initStreamReceiveWindow": .integer(524_288), "maxStreamReceiveWindow": .integer(2_097_152),
            "initConnectionReceiveWindow": .integer(1_048_576), "maxConnectionReceiveWindow": .integer(4_194_304),
        ]))
        // windows alone do not switch the congestion control
        let plainHy = try outbound("hysteria2://auth@hy.example.com:443/?sni=hy.example.com#h")
        let windowsOnly = XrayConfigCompiler(options: XrayCompileOptions(memoryProfile: .mobile))
            .compileOutbound(plainHy, engineTag: "proxy-0000")
        XCTAssertNil(windowsOnly.json?["streamSettings"]?["finalmask"]?["quicParams"]?["congestion"])
        XCTAssertNotNil(windowsOnly.json?["streamSettings"]?["finalmask"]?["quicParams"]?["maxStreamReceiveWindow"])
        XCTAssertNil(compiler.compileOutbound(plainHy, engineTag: "proxy-0000").json?["streamSettings"]?["finalmask"])
    }

    func testCompileOptionsDecodeWithoutMemoryProfile() throws {
        let old = #"{"logLevel":"info","dnsServers":[]}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(XrayCompileOptions.self, from: old)
        XCTAssertEqual(options.memoryProfile, .standard)
        let roundTrip = try JSONDecoder().decode(
            XrayCompileOptions.self,
            from: JSONEncoder().encode(XrayCompileOptions(memoryProfile: .mobile))
        )
        XCTAssertEqual(roundTrip.memoryProfile, .mobile)
    }

    func testSingleOutboundProfile() throws {
        let node = try outbound("trojan://pw@a.example.com:443#my node")
        let profile = Profile(name: "p", outbounds: [node], selectedTag: "my node")
        let compilation = XrayConfigCompiler(options: XrayCompileOptions(
            logLevel: "info", localSOCKSPort: 1080, dnsServers: ["1.1.1.1"]
        )).compile(profile)
        XCTAssertEqual(compilation.report.verdict, .exact)
        XCTAssertEqual(compilation.report.engine, .xray)
        XCTAssertEqual(compilation.report.engineVersion, "26.11.9")
        XCTAssertEqual(compilation.report.engineTags, ["my node": "proxy-0000"])
        let config = try XCTUnwrap(compilation.config)
        XCTAssertEqual(config["log"], .object(["loglevel": .string("info")]))
        XCTAssertEqual(config["dns"], .object(["servers": .array([.string("1.1.1.1")])]))
        XCTAssertEqual(config["inbounds"]?.arrayValue?.first?["listen"], .string("127.0.0.1"))
        XCTAssertEqual(config["inbounds"]?.arrayValue?.first?["port"], .integer(1080))
        let tags = config["outbounds"]?.arrayValue?.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags, ["proxy-0000", "direct", "block"])
        XCTAssertEqual(config["routing"]?["rules"], .array([.object([
            "type": .string("field"), "network": .string("tcp,udp"), "outboundTag": .string("proxy-0000"),
        ])]))
        XCTAssertNil(XrayConfigCompiler().compile(profile).config?["inbounds"])
        XCTAssertEqual(try compilation.jsonText(), try compilation.jsonText())
    }

    func testBlockedWhenSelectedOutboundCannotBeCompiled() throws {
        let tuic = try outbound("tuic://\(ProfileFixtures.uuidA):pw@a.example.com:443#tuic")
        let good = try outbound("trojan://pw@a.example.com:443#good")
        let blocked = compiler.compile(Profile(name: "p", outbounds: [good, tuic], selectedTag: "tuic"))
        XCTAssertEqual(blocked.report.verdict, .blocked)
        XCTAssertNil(blocked.config)
        XCTAssertEqual(blocked.report.excludedOutbounds, ["tuic"])

        let degraded = compiler.compile(Profile(name: "p", outbounds: [good, tuic], selectedTag: "good"))
        XCTAssertEqual(degraded.report.verdict, .degraded)
        XCTAssertEqual(degraded.report.excludedOutbounds, ["tuic"])
        XCTAssertEqual(degraded.config?["outbounds"]?.arrayValue?.count, 3)

        XCTAssertEqual(compiler.compile(Profile(name: "empty")).report.verdict, .blocked)
        let dangling = compiler.compile(Profile(name: "p", outbounds: [good], selectedTag: "nope"))
        XCTAssertEqual(dangling.report.verdict, .blocked)
        XCTAssertTrue(dangling.report.issues.contains { $0.kind == .invalid && $0.path == "profile" })
    }

    func testNothingSelectedUsesFirstOutboundAndSaysSo() throws {
        let good = try outbound("trojan://pw@a.example.com:443#good")
        let compilation = compiler.compile(Profile(name: "p", outbounds: [good]))
        XCTAssertEqual(compilation.report.verdict, .exact)
        XCTAssertTrue(compilation.report.hasIssue(.migrated, pathContaining: "selectedTag"))
    }

    func testGroups() throws {
        let fixtures = Dictionary(uniqueKeysWithValues: ProfileFixtures.all)

        // Balancer selectors match by prefix; tags "a" and "ab" must not collide.
        let urlTest = compiler.compile(try XCTUnwrap(fixtures["group-urltest"]))
        XCTAssertEqual(urlTest.report.verdict, .degraded)
        XCTAssertEqual(urlTest.report.excludedOutbounds, ["tuic"])
        let balancer = try XCTUnwrap(urlTest.config?["routing"]?["balancers"]?.arrayValue?.first)
        XCTAssertEqual(balancer["selector"], .array([.string("proxy-0000"), .string("proxy-0001"), .string("proxy-0002")]))
        XCTAssertEqual(balancer["strategy"], .object(["type": .string("leastPing")]))
        XCTAssertEqual(urlTest.config?["observatory"]?["probeInterval"], .string("60s"))
        XCTAssertEqual(urlTest.config?["routing"]?["rules"]?.arrayValue?.first?["balancerTag"], balancer["tag"])
        XCTAssertTrue(urlTest.report.hasIssue(.dropped, pathContaining: "groups[auto]"))

        let leastLoad = compiler.compile(try XCTUnwrap(fixtures["group-leastload-nested"]))
        XCTAssertNotNil(leastLoad.config?["burstObservatory"]?["pingConfig"])
        XCTAssertTrue(leastLoad.report.hasIssue(.approximated, pathContaining: "groups[outer]"))

        let selector = compiler.compile(try XCTUnwrap(fixtures["group-selector"]))
        XCTAssertEqual(selector.config?["routing"]?["rules"]?.arrayValue?.first?["outboundTag"], .string("proxy-0001"))
        XCTAssertNil(selector.config?["routing"]?["balancers"])
        XCTAssertTrue(selector.report.hasIssue(.approximated, pathContaining: "groups[pick]"))
    }

    func testCompilationIsDeterministic() throws {
        for (_, profile) in ProfileFixtures.all {
            let first = compiler.compile(profile)
            let second = compiler.compile(profile)
            XCTAssertEqual(first.report, second.report)
            XCTAssertEqual(try first.jsonText(), try second.jsonText())
        }
    }
}
