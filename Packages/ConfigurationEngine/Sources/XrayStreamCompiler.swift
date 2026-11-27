import Foundation
import DomainModels

/// Collects issues for one outbound while it is compiled.
struct XrayOutboundContext {
    let path: String
    var issues: [ConversionIssue] = []
    /// Set by any `.error`: the outbound is excluded from the output.
    var failed = false

    init(path: String) {
        self.path = path
    }

    mutating func note(
        _ subpath: String,
        _ kind: ConversionIssue.Kind,
        _ severity: ConversionIssue.Severity,
        _ detail: String
    ) {
        let full = subpath.isEmpty ? path : path + "." + subpath
        issues.append(ConversionIssue(path: full, kind: kind, severity: severity, detail: detail))
        if severity == .error {
            failed = true
        }
    }
}

/// `streamSettings` of an Xray outbound.
///
/// Field names and validation rules follow `infra/conf/transport_internet.go`,
/// `transport_method.go`, `transport_security.go` and `transport_finalmask.go`
/// of Xray-core 26.11.9 (read in source; accepted by the real binary through
/// `Tools/validate-fixtures.sh`).
enum XrayStreamCompiler {
    /// uTLS names accepted by `tls.GetFingerprint` (`transport/internet/tls/tls.go`).
    static let fingerprints: Set<String> = [
        "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq",
        "random", "randomized", "randomizednoalpn", "unsafe",
        "hellofirefox_148", "hellochrome_131", "hellochrome_133", "hellochrome_155", "hellosafari_26_3",
        "hellogolang", "hellorandomized", "hellorandomizedalpn", "hellorandomizednoalpn",
        "hellofirefox_auto", "hellofirefox_55", "hellofirefox_56", "hellofirefox_63", "hellofirefox_65",
        "hellofirefox_99", "hellofirefox_102", "hellofirefox_105", "hellofirefox_120",
        "hellochrome_auto", "hellochrome_58", "hellochrome_62", "hellochrome_70", "hellochrome_72",
        "hellochrome_83", "hellochrome_87", "hellochrome_96", "hellochrome_100", "hellochrome_102",
        "hellochrome_106_shuffle", "hellochrome_120",
        "helloios_auto", "helloios_11_1", "helloios_12_1", "helloios_13", "helloios_14",
        "helloandroid_11_okhttp", "helloedge_85", "helloedge_106", "helloedge_auto",
        "hellosafari_16_0", "hellosafari_auto", "hello360_auto", "hello360_7_5", "hello360_11_0",
        "helloqq_auto", "helloqq_11_1",
        "hellochrome_100_psk", "hellochrome_112_psk_shuf", "hellochrome_114_padding_psk_shuf",
        "hellochrome_115_pq", "hellochrome_115_pq_psk",
    ]

    static let xhttpModes: Set<String> = ["auto", "packet-up", "stream-up", "stream-one"]

    /// Result of compiling the transport part: the fields to merge into `streamSettings`
    /// plus UDP masks the transport needs in `finalmask`.
    struct Parts {
        var fields: [String: JSONValue] = [:]
        var udpMasks: [JSONValue] = []
        var quicParams: [String: JSONValue] = [:]
    }

    /// Compiles `stream` for an outbound whose server is `server`.
    /// `sniDefaultFromHost` applies the share-link rule "sni defaults to the remote host".
    static func compile(
        _ stream: StreamSettings,
        server: ServerEndpoint,
        extras: EngineExtras,
        sniDefaultFromHost: Bool,
        subpath: String,
        preset: Parts? = nil,
        resolve: (SecretValue?, String, inout XrayOutboundContext) -> String?,
        context: inout XrayOutboundContext
    ) -> [String: JSONValue] {
        var parts = preset ?? Parts()
        if preset == nil {
            compileTransport(
                stream, extras: extras, subpath: subpath, resolve: resolve, parts: &parts, context: &context
            )
        }
        compileSecurity(
            stream, server: server, sniDefaultFromHost: sniDefaultFromHost,
            subpath: subpath, parts: &parts, context: &context
        )
        applyFinalMask(extras: extras, subpath: subpath, parts: &parts, context: &context)
        return parts.fields
    }

    // MARK: - Transport

    private static func compileTransport(
        _ stream: StreamSettings,
        extras: EngineExtras,
        subpath: String,
        resolve: (SecretValue?, String, inout XrayOutboundContext) -> String?,
        parts: inout Parts,
        context: inout XrayOutboundContext
    ) {
        let at = subpath + ".transport"
        switch stream.transport {
        case .tcp(let settings):
            parts.fields["network"] = .string("raw")
            if let obfuscation = settings.httpObfuscation {
                var request: [String: JSONValue] = [:]
                if !obfuscation.paths.isEmpty {
                    request["path"] = .array(obfuscation.paths.map { .string($0) })
                }
                if !obfuscation.hosts.isEmpty {
                    request["headers"] = .object(["Host": .array(obfuscation.hosts.map { .string($0) })])
                }
                parts.fields["rawSettings"] = .object([
                    "header": .object(["type": .string("http"), "request": .object(request)]),
                ])
            }

        case .webSocket(let settings):
            parts.fields["network"] = .string("ws")
            parts.fields["wsSettings"] = hostPath(host: settings.host, path: settings.path)

        case .httpUpgrade(let settings):
            parts.fields["network"] = .string("httpupgrade")
            parts.fields["httpupgradeSettings"] = hostPath(host: settings.host, path: settings.path)

        case .grpc(let settings):
            parts.fields["network"] = .string("grpc")
            var object: [String: JSONValue] = [:]
            if !settings.serviceName.isEmpty { object["serviceName"] = .string(settings.serviceName) }
            if !settings.authority.isEmpty { object["authority"] = .string(settings.authority) }
            if settings.multiMode { object["multiMode"] = .bool(true) }
            parts.fields["grpcSettings"] = .object(object)

        case .xhttp(let settings):
            parts.fields["network"] = .string("xhttp")
            parts.fields["xhttpSettings"] = xhttp(
                settings, extras: extras, at: at, resolve: resolve, context: &context
            )

        case .kcp(let settings):
            parts.fields["network"] = .string("kcp")
            var object: [String: JSONValue] = [:]
            if let mtu = settings.mtu { object["mtu"] = .integer(Int64(mtu)) }
            if let tti = settings.tti {
                if tti < 10 || tti > 1000 {
                    context.note(at + ".tti", .invalid, .error, "mKCP TTI must be between 10 and 1000")
                }
                object["tti"] = .integer(Int64(tti))
            }
            if let mtu = settings.mtu, mtu < 21 {
                context.note(at + ".mtu", .invalid, .error, "mKCP MTU must be at least 21")
            }
            if !object.isEmpty {
                parts.fields["kcpSettings"] = .object(object)
            }
            kcpMasks(settings, at: at, resolve: resolve, parts: &parts, context: &context)

        case .http2:
            context.note(
                at, .unsupported, .error,
                "The HTTP/2 transport was removed from Xray; the server must be reconfigured to XHTTP"
            )
        case .quic:
            context.note(
                at, .unsupported, .error,
                "The QUIC transport was removed from Xray; the server must be reconfigured to XHTTP"
            )
        case .native:
            context.note(
                at, .invalid, .error,
                "A protocol-native transport is only valid for Hysteria2 and WireGuard"
            )
        }
    }

    private static func hostPath(host: String, path: String) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if !host.isEmpty { object["host"] = .string(host) }
        if !path.isEmpty { object["path"] = .string(path) }
        return .object(object)
    }

    private static func xhttp(
        _ settings: XHTTPSettings,
        extras: EngineExtras,
        at: String,
        resolve: (SecretValue?, String, inout XrayOutboundContext) -> String?,
        context: inout XrayOutboundContext
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if !settings.host.isEmpty { object["host"] = .string(settings.host) }
        if !settings.path.isEmpty { object["path"] = .string(settings.path) }
        if !settings.mode.isEmpty {
            if xhttpModes.contains(settings.mode) {
                object["mode"] = .string(settings.mode)
            } else {
                context.note(at + ".mode", .invalid, .error, "Unknown XHTTP mode '\(settings.mode)'")
            }
        }

        // Xray replaces the whole XHTTP object by `extra` (keeping host, path and mode),
        // so everything beyond those three fields has to live inside `extra`.
        var extra: [String: JSONValue] = [:]
        var hasExtra = false
        if let stored = extras.value(engine: .xray, key: EngineExtras.xrayXHTTPExtraKey) {
            if let members = stored.objectValue {
                extra = members
                hasExtra = true
                context.note(
                    at + ".extra", .engineLocked, .info,
                    "XHTTP 'extra' is passed to Xray verbatim; the model does not interpret it"
                )
            } else {
                context.note(at + ".extra", .invalid, .error, "XHTTP 'extra' is not a JSON object")
            }
        }
        if let download = settings.download {
            if settings.mode == "stream-one" {
                context.note(
                    at + ".download", .invalid, .error,
                    "A separate download leg cannot be used in XHTTP stream-one mode"
                )
            }
            if extra["downloadSettings"] != nil {
                context.note(
                    at + ".download", .dropped, .warning,
                    "'downloadSettings' inside the stored XHTTP 'extra' is replaced by the typed download leg"
                )
            }
            if case .xhttp(let nested) = download.stream.transport, nested.download != nil {
                context.note(
                    at + ".download.transport.download", .unsupported, .error,
                    "A download leg cannot have a download leg of its own"
                )
            }
            if download.stream.transport.kind != .xhttp {
                context.note(
                    at + ".download.transport", .invalid, .error,
                    "The XHTTP download leg must itself use the XHTTP transport"
                )
            }
            var nested = compile(
                download.stream, server: download.server, extras: EngineExtras(),
                sniDefaultFromHost: true, subpath: at + ".download",
                resolve: resolve, context: &context
            )
            nested["address"] = .string(download.server.host)
            nested["port"] = .integer(Int64(download.server.port))
            if download.server.port == 0 {
                context.note(at + ".download.server.port", .invalid, .error, "Port is zero")
            }
            extra["downloadSettings"] = .object(nested)
            hasExtra = true
        } else if extra["downloadSettings"] != nil, settings.mode == "stream-one" {
            context.note(
                at + ".extra.downloadSettings", .invalid, .error,
                "Xray rejects 'downloadSettings' in XHTTP stream-one mode"
            )
        }
        if hasExtra {
            object["extra"] = .object(extra)
        }
        return .object(object)
    }

    /// `kcpSettings.header` and `seed` are no longer read by Xray; their job moved to the
    /// UDP mask `mkcp-legacy` (ADR-0002 §6, the mandatory `.migrated` case).
    private static func kcpMasks(
        _ settings: KCPSettings,
        at: String,
        resolve: (SecretValue?, String, inout XrayOutboundContext) -> String?,
        parts: inout Parts,
        context: inout XrayOutboundContext
    ) {
        var header = settings.headerType.lowercased()
        if header == "none" { header = "" }
        if header == "wechat-video" { header = "wechat" }
        let known: Set<String> = ["dns", "dtls", "srtp", "utp", "wechat", "wireguard"]
        if !header.isEmpty {
            if known.contains(header) {
                parts.udpMasks.append(.object([
                    "type": .string("mkcp-legacy"),
                    "settings": .object(["header": .string(header)]),
                ]))
                context.note(
                    at + ".headerType", .migrated, .warning,
                    "mKCP header '\(header)' is emitted as a 'mkcp-legacy' UDP mask"
                )
            } else {
                context.note(at + ".headerType", .unsupported, .error, "Unknown mKCP header '\(header)'")
            }
        }
        if settings.seed != nil {
            if let seed = resolve(settings.seed, at + ".seed", &context) {
                parts.udpMasks.append(.object([
                    "type": .string("mkcp-legacy"),
                    "settings": .object(["value": .string(seed)]),
                ]))
                context.note(
                    at + ".seed", .migrated, .warning,
                    "mKCP seed is emitted as a 'mkcp-legacy' UDP mask (AES-128-GCM)"
                )
            }
        }
        if !header.isEmpty && settings.seed != nil {
            context.note(
                at, .untested, .warning,
                "mKCP header and seed together produce two masks; their order is not confirmed by an interoperability test"
            )
        }
    }

    // MARK: - Security

    private static func compileSecurity(
        _ stream: StreamSettings,
        server: ServerEndpoint,
        sniDefaultFromHost: Bool,
        subpath: String,
        parts: inout Parts,
        context: inout XrayOutboundContext
    ) {
        let at = subpath + ".security"
        switch stream.security {
        case .none:
            parts.fields["security"] = .string("none")

        case .tls(let settings):
            parts.fields["security"] = .string("tls")
            var object: [String: JSONValue] = [:]
            var serverName = settings.serverName
            if serverName == nil || serverName == "" {
                serverName = defaultServerName(
                    stream, server: server, fromHost: sniDefaultFromHost, at: at, context: &context
                )
            }
            if let serverName = serverName, !serverName.isEmpty {
                object["serverName"] = .string(serverName)
            }
            if !settings.alpn.isEmpty {
                object["alpn"] = .array(settings.alpn.map { .string($0) })
            }
            if let fingerprint = checkedFingerprint(settings.fingerprint, reality: false, at: at, context: &context) {
                object["fingerprint"] = .string(fingerprint)
            }
            if settings.allowInsecure {
                context.note(
                    at + ".allowInsecure", .unsupported, .warning,
                    "Xray removed 'allowInsecure'; the certificate is verified, so the connection fails unless it is valid or pinned"
                )
            }
            if settings.disableSNI {
                context.note(at + ".disableSNI", .unsupported, .warning, "Xray cannot disable SNI; SNI is sent")
            }
            if let ech = settings.echConfigList, !ech.isEmpty {
                object["echConfigList"] = .string(ech)
            }
            if let pins = settings.pinnedPeerCertificateSHA256, !pins.isEmpty {
                if validPins(pins) {
                    object["pinnedPeerCertSha256"] = .string(pins)
                } else {
                    context.note(
                        at + ".pinnedPeerCertificateSHA256", .invalid, .error,
                        "Certificate pin is not a comma-separated list of 32-byte hex SHA-256 digests"
                    )
                }
            }
            if let names = settings.verifyPeerCertificateByName, !names.isEmpty {
                object["verifyPeerCertByName"] = .string(names)
            }
            parts.fields["tlsSettings"] = .object(object)

        case .reality(let settings):
            parts.fields["security"] = .string("reality")
            switch stream.transport.kind {
            case .tcp, .xhttp, .grpc:
                break
            default:
                context.note(at, .unsupported, .error, "REALITY works only with the RAW, XHTTP and gRPC transports")
            }
            var object: [String: JSONValue] = [:]
            var serverName = settings.serverName
            if serverName == nil || serverName == "" {
                serverName = defaultServerName(
                    stream, server: server, fromHost: sniDefaultFromHost, at: at, context: &context
                )
                if serverName == nil {
                    context.note(at + ".serverName", .invalid, .warning, "REALITY without a server name")
                }
            }
            if let serverName = serverName, !serverName.isEmpty {
                object["serverName"] = .string(serverName)
            }
            if let fingerprint = checkedFingerprint(settings.fingerprint, reality: true, at: at, context: &context) {
                object["fingerprint"] = .string(fingerprint)
            }
            // Xray decodes the key with unpadded base64url only; links carry other spellings.
            if let key = LenientBase64.decode(settings.publicKey), key.count == 32 {
                object["password"] = .string(rawURLBase64(key))
            } else {
                context.note(at + ".publicKey", .invalid, .error, "REALITY public key is not 32 bytes of base64")
            }
            if let shortID = settings.shortID, !shortID.isEmpty {
                let bytes = Array(shortID.utf8)
                let isHex = bytes.allSatisfy { PercentCoding.hexValue($0) != nil }
                if isHex && bytes.count <= 16 && bytes.count % 2 == 0 {
                    object["shortId"] = .string(shortID)
                } else {
                    context.note(
                        at + ".shortID", .invalid, .error,
                        "REALITY short id must be an even-length hex string of at most 16 digits"
                    )
                }
            }
            if let spiderX = settings.spiderX, !spiderX.isEmpty {
                if spiderX.hasPrefix("/") {
                    object["spiderX"] = .string(spiderX)
                } else {
                    context.note(at + ".spiderX", .invalid, .error, "REALITY spiderX must start with '/'")
                }
            }
            if let verify = settings.mldsa65Verify, !verify.isEmpty {
                if let key = LenientBase64.decode(verify), key.count == 1952 {
                    object["mldsa65Verify"] = .string(rawURLBase64(key))
                } else {
                    context.note(
                        at + ".mldsa65Verify", .invalid, .error,
                        "REALITY ML-DSA-65 verification key is not 1952 bytes of base64"
                    )
                }
            }
            parts.fields["realitySettings"] = .object(object)
        }
    }

    /// The share-link convention (XTLS/Xray-core discussion 716) says `sni` defaults to the
    /// remote host; libXray additionally falls back to the WebSocket host.
    private static func defaultServerName(
        _ stream: StreamSettings,
        server: ServerEndpoint,
        fromHost: Bool,
        at: String,
        context: inout XrayOutboundContext
    ) -> String? {
        if case .webSocket(let settings) = stream.transport, !settings.host.isEmpty, !fromHost || isIPLiteral(server.host) {
            context.note(
                at + ".serverName", .migrated, .info,
                "Server name is absent; the WebSocket host is used, as libXray does"
            )
            return settings.host
        }
        if fromHost && !isIPLiteral(server.host) {
            return server.host
        }
        return nil
    }

    private static func checkedFingerprint(
        _ fingerprint: String?,
        reality: Bool,
        at: String,
        context: inout XrayOutboundContext
    ) -> String? {
        guard let fingerprint = fingerprint, !fingerprint.isEmpty else { return nil }
        let name = fingerprint.lowercased()
        guard fingerprints.contains(name) else {
            context.note(at + ".fingerprint", .unsupported, .error, "Xray does not know the TLS fingerprint '\(name)'")
            return nil
        }
        if reality && (name == "unsafe" || name == "hellogolang") {
            context.note(at + ".fingerprint", .unsupported, .error, "REALITY cannot use the fingerprint '\(name)'")
            return nil
        }
        return name
    }

    static func validPins(_ text: String) -> Bool {
        var count = 0
        for item in Text.commaList(text) {
            let hex = Array(item.utf8).filter { $0 != 0x3A }
            guard hex.count == 64, hex.allSatisfy({ PercentCoding.hexValue($0) != nil }) else { return false }
            count += 1
        }
        return count > 0
    }

    static func rawURLBase64(_ data: Data) -> String {
        var output: [UInt8] = []
        for byte in data.base64EncodedString().utf8 {
            switch byte {
            case 0x2B: output.append(0x2D)
            case 0x2F: output.append(0x5F)
            case 0x3D: continue
            default: output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.utf8.contains(0x3A) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
            return value >= 0 && value <= 255 && part.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        }
    }

    // MARK: - finalmask

    static func applyFinalMask(
        extras: EngineExtras,
        subpath: String,
        parts: inout Parts,
        context: inout XrayOutboundContext
    ) {
        var mask: [String: JSONValue] = [:]
        if let stored = extras.value(engine: .xray, key: EngineExtras.xrayFinalMaskKey) {
            if let members = stored.objectValue {
                mask = members
                context.note(
                    subpath + ".finalmask", .engineLocked, .info,
                    "finalmask is passed to Xray verbatim; the model does not interpret it"
                )
            } else {
                context.note(subpath + ".finalmask", .invalid, .error, "Stored finalmask is not a JSON object")
            }
        }
        if !parts.udpMasks.isEmpty {
            var udp = mask["udp"]?.arrayValue ?? []
            if !udp.isEmpty {
                context.note(
                    subpath + ".finalmask.udp", .untested, .warning,
                    "Generated UDP masks are appended to the stored ones; the combined order is not tested"
                )
            }
            udp.append(contentsOf: parts.udpMasks)
            mask["udp"] = .array(udp)
        }
        if !parts.quicParams.isEmpty {
            if mask["quicParams"] != nil {
                context.note(
                    subpath + ".finalmask.quicParams", .dropped, .warning,
                    "Stored quicParams are replaced by the ones generated from the model"
                )
            }
            mask["quicParams"] = .object(parts.quicParams)
        }
        if !mask.isEmpty {
            parts.fields["finalmask"] = .object(mask)
        }
    }
}
