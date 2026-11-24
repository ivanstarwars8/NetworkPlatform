import Foundation
import XCTest
@testable import DomainModels

final class DomainModelsTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sampleVLESS(tag: String = "node-1") -> Outbound {
        var extras = EngineExtras()
        extras.set(.object(["tcp": .array([.object(["type": .string("fragment")])])]),
                   engine: .xray, key: EngineExtras.xrayFinalMaskKey)
        return Outbound(
            tag: tag,
            name: "Node 1",
            server: ServerEndpoint(host: "203.0.113.10", port: 443),
            credentials: Credentials(userID: .inline("b831381d-6324-4d53-ad4f-8cda48b30811")),
            settings: .vless(VLESSSettings(flow: "xtls-rprx-vision")),
            stream: StreamSettings(
                transport: .tcp(TCPSettings()),
                security: .reality(RealitySettings(
                    serverName: "www.example.com",
                    fingerprint: "chrome",
                    publicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
                    shortID: "6ba85179e30d4fc2"
                ))
            ),
            extras: extras,
            unsupported: [
                UnsupportedParameter(name: "foo", value: "bar", location: .query, reason: .unknown),
            ]
        )
    }

    private func plainOutbound(_ tag: String) -> Outbound {
        return Outbound(
            tag: tag, name: tag,
            server: ServerEndpoint(host: "example.com", port: 443),
            credentials: Credentials(password: .inline("pw")),
            settings: .trojan,
            stream: StreamSettings(security: .tls(TLSSettings(serverName: "example.com")))
        )
    }

    // MARK: - Codable

    func testOutboundCodableRoundTrip() throws {
        let outbound = sampleVLESS()
        XCTAssertEqual(try roundTrip(outbound), outbound)
        XCTAssertEqual(outbound.kind, .vless)
    }

    func testEveryTransportAndSecurityCodableRoundTrip() throws {
        let download = XHTTPDownload(
            server: ServerEndpoint(host: "2001:db8::5", port: 8443),
            stream: StreamSettings(
                transport: .xhttp(XHTTPSettings(path: "/down", host: "d.example.com", mode: "stream-up")),
                security: .tls(TLSSettings(serverName: "d.example.com", alpn: ["h2"]))
            )
        )
        let transports: [Transport] = [
            .tcp(TCPSettings(httpObfuscation: HTTPObfuscation(hosts: ["a.example.com"], paths: ["/"]))),
            .webSocket(WebSocketSettings(path: "/ws", host: "a.example.com")),
            .grpc(GRPCSettings(serviceName: "svc", authority: "a.example.com", multiMode: true)),
            .http2(HTTP2Settings(hosts: ["a.example.com", "b.example.com"], path: "/h2")),
            .httpUpgrade(HTTPUpgradeSettings(path: "/up", host: "a.example.com")),
            .xhttp(XHTTPSettings(path: "/x", host: "a.example.com", mode: "auto", download: download)),
            .quic(QUICSettings(security: "aes-128-gcm", key: .inline("k"), headerType: "srtp")),
            .kcp(KCPSettings(seed: .reference(SecretReference(identifier: "kc-1")), headerType: "wechat-video", mtu: 1350, tti: 20)),
            .native,
        ]
        let securities: [Security] = [
            .none,
            .tls(TLSSettings(
                serverName: "a.example.com", alpn: ["h2", "http/1.1"], fingerprint: "safari",
                allowInsecure: true, disableSNI: true, echConfigList: "AAA",
                pinnedPeerCertificateSHA256: "abcd", verifyPeerCertificateByName: "b.example.com"
            )),
            .reality(RealitySettings(
                serverName: "a.example.com", fingerprint: "chrome", publicKey: "pk",
                shortID: "ab", spiderX: "/", mldsa65Verify: "v"
            )),
        ]
        XCTAssertEqual(transports.map { $0.kind }, Transport.Kind.allCases)
        XCTAssertEqual(securities.map { $0.kind }, Security.Kind.allCases)
        for transport in transports {
            for security in securities {
                let stream = StreamSettings(transport: transport, security: security)
                XCTAssertEqual(try roundTrip(stream), stream)
            }
        }
    }

    func testEveryProtocolSettingsCodableRoundTrip() throws {
        let all: [ProtocolSettings] = [
            .vless(VLESSSettings(flow: "xtls-rprx-vision", encryption: "none", packetEncoding: "xudp")),
            .vmess(VMessSettings(cipher: "aes-128-gcm", alterID: 0)),
            .trojan,
            .shadowsocks(ShadowsocksSettings(
                method: "2022-blake3-aes-256-gcm",
                plugin: ShadowsocksPlugin(name: "v2ray-plugin", options: "tls;host=example.com")
            )),
            .socks(SOCKSSettings(version: .v4a)),
            .http,
            .hysteria2(Hysteria2Settings(
                obfuscation: Hysteria2Obfuscation(type: "salamander", password: .inline("p")),
                serverPorts: [PortRange(lower: 20000, upper: 30000)],
                hopIntervalSeconds: 30, uploadBandwidth: "50", downloadBandwidth: "200"
            )),
            .tuic(TUICSettings(congestionControl: "bbr", udpRelayMode: "native")),
            .wireGuard(WireGuardSettings(
                peerPublicKey: "pk", localAddresses: ["10.0.0.2/32"], allowedIPs: ["0.0.0.0/0"],
                reserved: [1, 2, 3], mtu: 1280, persistentKeepaliveSeconds: 25
            )),
            .other(.anyTLS),
        ]
        for settings in all {
            XCTAssertEqual(try roundTrip(settings), settings)
        }
        XCTAssertEqual(all.map { $0.kind }, [
            .vless, .vmess, .trojan, .shadowsocks, .socks, .http, .hysteria2, .tuic, .wireGuard, .anyTLS,
        ])
    }

    func testProtocolKindRawValuesAreStable() {
        XCTAssertEqual(ProxyProtocolKind.wireGuard.rawValue, "wireguard")
        XCTAssertEqual(ProxyProtocolKind.hysteria2.rawValue, "hysteria2")
        XCTAssertEqual(ProxyProtocolKind(rawValue: "vless"), .vless)
        XCTAssertNil(ProxyProtocolKind(rawValue: "ssr"))
        XCTAssertEqual(Set(ProxyProtocolKind.allCases.map { $0.rawValue }).count, ProxyProtocolKind.allCases.count)
    }

    // MARK: - Secrets

    func testSecretValueEncodingShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let inline = String(decoding: try encoder.encode(SecretValue.inline("s3cret")), as: UTF8.self)
        XCTAssertEqual(inline, "{\"kind\":\"inline\",\"value\":\"s3cret\"}")
        let reference = String(
            decoding: try encoder.encode(SecretValue.reference(SecretReference(identifier: "kc-7"))),
            as: UTF8.self
        )
        XCTAssertEqual(reference, "{\"kind\":\"reference\",\"value\":\"kc-7\"}")
        XCTAssertEqual(try roundTrip(SecretValue.inline("s3cret")), .inline("s3cret"))
        XCTAssertEqual(
            try roundTrip(SecretValue.reference(SecretReference(identifier: "kc-7"))),
            .reference(SecretReference(identifier: "kc-7"))
        )
    }

    func testSecretValueRejectsUnknownKind() {
        let data = Data("{\"kind\":\"plain\",\"value\":\"x\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SecretValue.self, from: data))
    }

    func testInlineSecretIsRedactedInDescriptions() {
        let secret = SecretValue.inline("hunter2")
        XCTAssertFalse("\(secret)".contains("hunter2"))
        XCTAssertFalse(String(describing: secret).contains("hunter2"))
        XCTAssertFalse(String(reflecting: secret).contains("hunter2"))
        XCTAssertTrue("\(SecretValue.reference(SecretReference(identifier: "kc-1")))".contains("kc-1"))
        XCTAssertEqual(secret.inlineValue, "hunter2")
        XCTAssertNil(secret.secretReference)
        XCTAssertTrue(secret.isInline)
    }

    func testReplacingInlineSecrets() {
        var outbound = Outbound(
            tag: "hy", name: "hy",
            server: ServerEndpoint(host: "hy.example.com", port: 443),
            credentials: Credentials(password: .inline("auth")),
            settings: .hysteria2(Hysteria2Settings(
                obfuscation: Hysteria2Obfuscation(type: "salamander", password: .inline("obfs"))
            )),
            stream: StreamSettings(transport: .native, security: .tls(TLSSettings()))
        )
        XCTAssertEqual(outbound.inlineSecretSlots, [.password, .obfuscationPassword])

        var stored: [SecretSlot: String] = [:]
        let replaced = outbound.replacingInlineSecrets { slot, value in
            stored[slot] = value
            return SecretReference(identifier: "ref-\(slot.rawValue)")
        }
        XCTAssertEqual(stored, [.password: "auth", .obfuscationPassword: "obfs"])
        XCTAssertEqual(replaced.inlineSecretSlots, [])
        XCTAssertEqual(replaced.credentials.password, .reference(SecretReference(identifier: "ref-password")))
        guard case .hysteria2(let settings) = replaced.settings else {
            return XCTFail("settings changed kind")
        }
        XCTAssertEqual(
            settings.obfuscation?.password,
            .reference(SecretReference(identifier: "ref-obfuscationPassword"))
        )

        // Already externalised secrets are left alone.
        var calls = 0
        let again = replaced.replacingInlineSecrets { _, _ in
            calls += 1
            return SecretReference(identifier: "unexpected")
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(again, replaced)

        // Transport secrets are covered too.
        outbound.stream.transport = .kcp(KCPSettings(seed: .inline("seed")))
        XCTAssertTrue(outbound.inlineSecretSlots.contains(.transportKey))
        let kcp = outbound.replacingInlineSecrets { slot, _ in SecretReference(identifier: slot.rawValue) }
        XCTAssertEqual(kcp.inlineSecretSlots, [])
    }

    func testReplacingInlineSecretsPropagatesErrors() {
        struct StoreFailure: Error {}
        XCTAssertThrowsError(try sampleVLESS().replacingInlineSecrets { _, _ in throw StoreFailure() })
    }

    // MARK: - Endpoint, extras, unsupported

    func testServerEndpointAuthority() {
        XCTAssertEqual(ServerEndpoint(host: "example.com", port: 443).authority, "example.com:443")
        XCTAssertEqual(ServerEndpoint(host: "2001:db8::1", port: 8443).authority, "[2001:db8::1]:8443")
        XCTAssertTrue(ServerEndpoint(host: "::1", port: 1).isIPv6Literal)
        XCTAssertFalse(ServerEndpoint(host: "192.0.2.1", port: 1).isIPv6Literal)
        XCTAssertFalse(ServerEndpoint(host: "xn--e1afmkfd.xn--p1ai", port: 1).isIPv6Literal)
    }

    func testEngineExtras() throws {
        var extras = EngineExtras()
        XCTAssertTrue(extras.isEmpty)
        extras.set(.string("v"), engine: .xray, key: "k")
        XCTAssertFalse(extras.isEmpty)
        XCTAssertEqual(extras.value(engine: .xray, key: "k"), .string("v"))
        XCTAssertNil(extras.value(engine: .singBox, key: "k"))
        XCTAssertEqual(try roundTrip(extras), extras)
        extras.set(nil, engine: .xray, key: "k")
        XCTAssertTrue(extras.isEmpty)
        XCTAssertEqual(extras, EngineExtras())
        XCTAssertEqual(EngineID(rawValue: "xray"), .xray)
        XCTAssertEqual(try roundTrip([EngineID.singBox]), [.singBox])
    }

    func testUnsupportedParameterDefaultsAndCodable() throws {
        let parameter = UnsupportedParameter(name: "x", value: nil, location: .jsonBody, reason: .engineSpecific,
                                             disposition: .preservedInEngineExtras, detail: "d")
        XCTAssertEqual(try roundTrip(parameter), parameter)
        let plain = UnsupportedParameter(name: "y", value: "1", location: .query, reason: .unknown)
        XCTAssertEqual(plain.disposition, .recorded)
        XCTAssertNil(plain.detail)
    }

    // MARK: - JSONValue

    func testJSONValueParseAndSerialise() throws {
        let value = try JSONValue.parse(jsonText: "{\"b\":[1,2.5,\"x\",null,true],\"a\":{\"k\":\"v/w\"}}")
        XCTAssertEqual(value["a"]?["k"]?.stringValue, "v/w")
        XCTAssertEqual(value["b"]?.arrayValue?.count, 5)
        XCTAssertEqual(value["b"]?.arrayValue?[0], .integer(1))
        XCTAssertEqual(value["b"]?.arrayValue?[1], .number(2.5))
        XCTAssertEqual(value["b"]?.arrayValue?[3], .null)
        XCTAssertEqual(value["b"]?.arrayValue?[4], .bool(true))
        XCTAssertNil(value["missing"])
        XCTAssertNil(JSONValue.string("x")["a"])
        let text = try value.jsonText()
        XCTAssertEqual(text, "{\"a\":{\"k\":\"v/w\"},\"b\":[1,2.5,\"x\",null,true]}")
        XCTAssertEqual(try JSONValue.parse(jsonText: text), value)
    }

    func testJSONValueBounds() {
        let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try JSONValue.parse(jsonText: deep, maximumDepth: 32)) { error in
            XCTAssertEqual(error as? JSONValueError, .tooDeep(limit: 32))
        }
        XCTAssertNoThrow(try JSONValue.parse(jsonText: deep, maximumDepth: 64))
        XCTAssertThrowsError(try JSONValue.parse(jsonText: "[1,2,3]", maximumBytes: 3)) { error in
            XCTAssertEqual(error as? JSONValueError, .tooLarge(limit: 3, actual: 7))
        }
        XCTAssertThrowsError(try JSONValue.parse(jsonText: "{\"a\":")) { error in
            XCTAssertEqual(error as? JSONValueError, .malformed)
        }
        // Brackets inside strings do not count as nesting.
        XCTAssertEqual(JSONValue.nestingDepth(of: Array("{\"a\":\"[[[[\\\"[[\"}".utf8), stopAbove: 100), 1)
    }

    // MARK: - Groups and profile

    func testGroupCodableRoundTrip() throws {
        let group = OutboundGroup(
            tag: "auto", name: "Auto", kind: .urlTest,
            members: [.outbound(tag: "a"), .group(tag: "fallback")],
            defaultMemberTag: "a",
            healthCheck: OutboundGroup.HealthCheck(
                url: "https://www.gstatic.com/generate_204", intervalSeconds: 300,
                timeoutMilliseconds: 5000, toleranceMilliseconds: 50
            ),
            strategy: .leastPing
        )
        XCTAssertEqual(try roundTrip(group), group)
        XCTAssertEqual(group.members.map { $0.tag }, ["a", "fallback"])
        XCTAssertEqual(OutboundGroup.Kind.allCases.count, 4)
    }

    func testValidProfileWithNestedGroups() throws {
        let profile = Profile(
            name: "P",
            source: .subscription(url: "https://example.com/sub"),
            outbounds: [plainOutbound("a"), plainOutbound("b"), plainOutbound("c")],
            groups: [
                OutboundGroup(tag: "eu", name: "EU", kind: .urlTest, members: [.outbound(tag: "a"), .outbound(tag: "b")]),
                OutboundGroup(tag: "backup", name: "Backup", kind: .fallback,
                              members: [.group(tag: "eu"), .outbound(tag: "c")]),
                OutboundGroup(tag: "proxy", name: "Proxy", kind: .selector,
                              members: [.group(tag: "backup"), .group(tag: "eu"), .outbound(tag: "a")],
                              defaultMemberTag: "backup"),
                OutboundGroup(tag: "lb", name: "LB", kind: .loadBalance,
                              members: [.outbound(tag: "b"), .outbound(tag: "c")], strategy: .roundRobin),
            ],
            selectedTag: "proxy"
        )
        XCTAssertEqual(profile.validate(), [])
        XCTAssertEqual(profile.schemaVersion, Profile.currentSchemaVersion)
        XCTAssertEqual(profile.flattenedOutboundTags(ofGroup: "proxy"), ["a", "b", "c"])
        XCTAssertEqual(profile.flattenedOutboundTags(ofGroup: "lb"), ["b", "c"])
        XCTAssertNil(profile.flattenedOutboundTags(ofGroup: "missing"))
        XCTAssertEqual(profile.outbound(tagged: "b")?.tag, "b")
        XCTAssertEqual(profile.group(tagged: "eu")?.kind, .urlTest)
        XCTAssertNil(profile.outbound(tagged: "eu"))
        XCTAssertEqual(try roundTrip(profile), profile)
    }

    func testProfileValidationFindsStructuralProblems() {
        let profile = Profile(
            name: "Broken",
            outbounds: [plainOutbound("a"), plainOutbound("a"), plainOutbound("")],
            groups: [
                OutboundGroup(tag: "empty", name: "", kind: .selector, members: []),
                OutboundGroup(tag: "dangling", name: "", kind: .selector,
                              members: [.outbound(tag: "nope"), .group(tag: "a"), .outbound(tag: "empty")],
                              defaultMemberTag: "zzz"),
            ],
            selectedTag: "ghost"
        )
        let kinds = profile.validate().map { $0.kind }
        XCTAssertTrue(kinds.contains(.duplicateTag))
        XCTAssertTrue(kinds.contains(.emptyTag))
        XCTAssertTrue(kinds.contains(.emptyGroup))
        XCTAssertTrue(kinds.contains(.danglingMember))
        XCTAssertTrue(kinds.contains(.danglingDefaultMember))
        XCTAssertTrue(kinds.contains(.danglingSelection))
        XCTAssertEqual(kinds.filter { $0 == .memberKindMismatch }.count, 2)
        XCTAssertFalse(kinds.contains(.groupCycle))
        XCTAssertNil(profile.flattenedOutboundTags(ofGroup: "dangling"))
        // Deterministic.
        XCTAssertEqual(profile.validate(), profile.validate())
    }

    func testProfileValidationDetectsCycles() {
        let profile = Profile(
            name: "Cycle",
            outbounds: [plainOutbound("a")],
            groups: [
                OutboundGroup(tag: "g1", name: "", kind: .selector, members: [.group(tag: "g2"), .outbound(tag: "a")]),
                OutboundGroup(tag: "g2", name: "", kind: .selector, members: [.group(tag: "g3")]),
                OutboundGroup(tag: "g3", name: "", kind: .selector, members: [.group(tag: "g1")]),
                OutboundGroup(tag: "self", name: "", kind: .selector, members: [.group(tag: "self")]),
            ]
        )
        let cycles = profile.validate().filter { $0.kind == .groupCycle }.map { $0.tag }
        XCTAssertTrue(cycles.contains("self"))
        XCTAssertTrue(cycles.contains { ["g1", "g2", "g3"].contains($0) })
        XCTAssertNil(profile.flattenedOutboundTags(ofGroup: "g1"))
        XCTAssertNil(profile.flattenedOutboundTags(ofGroup: "self"))
    }

    func testProfileValidationLimitsNestingDepth() {
        func chain(_ length: Int) -> Profile {
            var groups: [OutboundGroup] = []
            for index in 0..<length {
                let member: OutboundGroup.Member = index == length - 1
                    ? .outbound(tag: "a") : .group(tag: "g\(index + 1)")
                groups.append(OutboundGroup(tag: "g\(index)", name: "", kind: .selector, members: [member]))
            }
            return Profile(name: "Chain", outbounds: [plainOutbound("a")], groups: groups)
        }
        let allowed = chain(Profile.maximumGroupNestingDepth)
        XCTAssertEqual(allowed.validate(), [])
        XCTAssertEqual(allowed.flattenedOutboundTags(ofGroup: "g0"), ["a"])

        let tooDeep = chain(Profile.maximumGroupNestingDepth + 2)
        let issues = tooDeep.validate().filter { $0.kind == .nestingTooDeep }.map { $0.tag }
        XCTAssertEqual(issues, ["g0", "g1"])
        XCTAssertNil(tooDeep.flattenedOutboundTags(ofGroup: "g0"))
        XCTAssertEqual(tooDeep.flattenedOutboundTags(ofGroup: "g2"), ["a"])
    }

    func testProfileValidationStaysFastOnDenseGraphs() {
        // Every group contains all later groups: exponential without memoisation.
        let count = 40
        var groups: [OutboundGroup] = []
        for index in 0..<count {
            var members: [OutboundGroup.Member] = [.outbound(tag: "a")]
            for later in (index + 1)..<max(index + 1, count) {
                members.append(.group(tag: "g\(later)"))
            }
            groups.append(OutboundGroup(tag: "g\(index)", name: "", kind: .selector, members: members))
        }
        let profile = Profile(name: "Dense", outbounds: [plainOutbound("a")], groups: groups)
        let issues = profile.validate()
        XCTAssertFalse(issues.contains { $0.kind == .groupCycle })
        XCTAssertTrue(issues.contains { $0.kind == .nestingTooDeep })
        XCTAssertEqual(profile.flattenedOutboundTags(ofGroup: "g\(count - 3)"), ["a"])
    }
}
