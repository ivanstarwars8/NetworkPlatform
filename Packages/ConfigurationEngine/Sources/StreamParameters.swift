import Foundation
import DomainModels

/// Transport and security parameters shared by the URL-style links
/// (`vless://`, `trojan://`, the URL form of `vmess://`).
///
/// Parameter names follow the de-facto convention documented in
/// XTLS/Xray-core discussion 716 and implemented by `libXray/share/parse_share.go`,
/// `stream.go` and `transport_build.go`.
enum StreamParameters {
    /// Names this parser understands in at least one transport/security combination.
    static let knownNames: Set<String> = [
        "type", "headerType", "host", "path", "mode", "serviceName", "authority",
        "extra", "seed", "mtu", "tti", "quicSecurity", "key", "fm",
        "security", "sni", "peer", "alpn", "fp", "allowInsecure", "insecure", "allow_insecure",
        "ech", "pcs", "vcn", "pbk", "sid", "spx", "pqv",
    ]

    static let insecureAliases = ["allowInsecure", "insecure", "allow_insecure"]

    static func parse(
        _ bag: inout ParameterBag,
        defaultSecurity: String,
        extras: inout EngineExtras,
        limits: ImportLimits,
        report: inout ImportReport
    ) throws -> StreamSettings {
        let transport = try parseTransport(&bag, extras: &extras, limits: limits, report: &report)
        let security = try parseSecurity(&bag, defaultSecurity: defaultSecurity, report: &report)

        if let finalMask = bag.takeNonEmpty("fm") {
            preserveJSON(
                finalMask, name: "fm", key: EngineExtras.xrayFinalMaskKey,
                bag: bag, extras: &extras, limits: limits, report: &report
            )
        }
        return StreamSettings(transport: transport, security: security)
    }

    // MARK: Transport

    private static func parseTransport(
        _ bag: inout ParameterBag,
        extras: inout EngineExtras,
        limits: ImportLimits,
        report: inout ImportReport
    ) throws -> Transport {
        let typeText = bag.takeNonEmpty("type") ?? "tcp"
        switch typeText.lowercased() {
        case "tcp", "raw":
            let headerType = (bag.takeNonEmpty("headerType") ?? "none").lowercased()
            switch headerType {
            case "none":
                return .tcp(TCPSettings())
            case "http":
                let hosts = Text.commaList(bag.takeNonEmpty("host") ?? "")
                let paths = Text.commaList(bag.takeNonEmpty("path") ?? "")
                return .tcp(TCPSettings(httpObfuscation: HTTPObfuscation(hosts: hosts, paths: paths)))
            default:
                throw ImportError.unsupportedValue(parameter: "headerType", value: headerType)
            }

        case "ws", "websocket":
            return .webSocket(WebSocketSettings(
                path: bag.takeNonEmpty("path") ?? "",
                host: bag.takeNonEmpty("host") ?? ""
            ))

        case "grpc", "gun":
            var settings = GRPCSettings(
                serviceName: bag.takeNonEmpty("serviceName") ?? "",
                authority: bag.takeNonEmpty("authority") ?? ""
            )
            if let mode = bag.takeNonEmpty("mode") {
                switch mode.lowercased() {
                case "gun":
                    settings.multiMode = false
                case "multi":
                    settings.multiMode = true
                default:
                    bag.recordInvalid("mode", value: mode, detail: "Unknown gRPC mode", report: &report)
                }
            }
            return .grpc(settings)

        case "http", "h2":
            return .http2(HTTP2Settings(
                hosts: Text.commaList(bag.takeNonEmpty("host") ?? ""),
                path: bag.takeNonEmpty("path") ?? ""
            ))

        case "httpupgrade":
            return .httpUpgrade(HTTPUpgradeSettings(
                path: bag.takeNonEmpty("path") ?? "",
                host: bag.takeNonEmpty("host") ?? ""
            ))

        case "xhttp", "splithttp":
            let settings = XHTTPSettings(
                path: bag.takeNonEmpty("path") ?? "",
                host: bag.takeNonEmpty("host") ?? "",
                mode: bag.takeNonEmpty("mode") ?? ""
            )
            if let extra = bag.takeNonEmpty("extra") {
                let parsed = preserveJSON(
                    extra, name: "extra", key: EngineExtras.xrayXHTTPExtraKey,
                    bag: bag, extras: &extras, limits: limits, report: &report
                )
                if let parsed = parsed, parsed["downloadSettings"] != nil {
                    report.warn(
                        .engineSpecific,
                        "XHTTP 'extra' contains downloadSettings; it is kept for Xray but not interpreted by the model"
                    )
                }
            }
            return .xhttp(settings)

        case "kcp", "mkcp":
            var settings = KCPSettings()
            if let seed = bag.takeNonEmpty("seed") {
                settings.seed = .inline(seed)
            }
            settings.headerType = bag.takeNonEmpty("headerType") ?? ""
            settings.mtu = takeInt("mtu", from: &bag, report: &report)
            settings.tti = takeInt("tti", from: &bag, report: &report)
            return .kcp(settings)

        case "quic":
            var settings = QUICSettings()
            settings.security = bag.takeNonEmpty("quicSecurity") ?? ""
            if let key = bag.takeNonEmpty("key") {
                settings.key = .inline(key)
            }
            settings.headerType = bag.takeNonEmpty("headerType") ?? ""
            return .quic(settings)

        default:
            // Falling back to TCP would silently change the transport, so this is fatal.
            throw ImportError.unsupportedValue(parameter: "type", value: typeText)
        }
    }

    // MARK: Security

    private static func parseSecurity(
        _ bag: inout ParameterBag,
        defaultSecurity: String,
        report: inout ImportReport
    ) throws -> Security {
        let securityText = (bag.takeNonEmpty("security") ?? defaultSecurity).lowercased()
        switch securityText {
        case "none":
            return .none
        case "tls":
            return .tls(parseTLS(&bag, report: &report))
        case "reality":
            guard let publicKey = bag.takeNonEmpty("pbk") else {
                throw ImportError.missingField("pbk")
            }
            var settings = RealitySettings(publicKey: publicKey)
            settings.serverName = bag.takeFirst(of: ["sni", "peer"], report: &report)
            settings.fingerprint = bag.takeNonEmpty("fp")
            settings.shortID = bag.takeNonEmpty("sid")
            settings.spiderX = bag.takeNonEmpty("spx")
            settings.mldsa65Verify = bag.takeNonEmpty("pqv")
            checkReality(settings, report: &report)
            return .reality(settings)
        default:
            throw ImportError.unsupportedValue(parameter: "security", value: securityText)
        }
    }

    /// TLS parameters common to every scheme. `pinNames` lets schemes with their own
    /// spelling of the certificate pin (Hysteria2) reuse the parser.
    static func parseTLS(
        _ bag: inout ParameterBag,
        pinNames: [String] = ["pcs"],
        report: inout ImportReport
    ) -> TLSSettings {
        var settings = TLSSettings()
        settings.serverName = bag.takeFirst(of: ["sni", "peer"], report: &report)
        if let alpn = bag.takeNonEmpty("alpn") {
            settings.alpn = Text.commaList(alpn)
        }
        settings.fingerprint = bag.takeNonEmpty("fp")
        if let insecure = bag.takeFirst(of: insecureAliases, report: &report) {
            if let flag = Text.parseBool(insecure) {
                settings.allowInsecure = flag
                if flag {
                    report.warn(.insecureTLS, "Certificate verification is disabled by the link")
                }
            } else {
                bag.recordInvalid("allowInsecure", value: insecure, detail: "Not a boolean", report: &report)
            }
        }
        settings.echConfigList = bag.takeNonEmpty("ech")
        settings.pinnedPeerCertificateSHA256 = bag.takeFirst(of: pinNames, report: &report)
        settings.verifyPeerCertificateByName = bag.takeNonEmpty("vcn")
        return settings
    }

    private static func checkReality(_ settings: RealitySettings, report: inout ImportReport) {
        // An X25519 public key is 32 bytes; links carry it as unpadded base64url.
        if let key = LenientBase64.decode(settings.publicKey) {
            if key.count != 32 {
                report.warn(.suspiciousValue, "REALITY public key does not decode to 32 bytes")
            }
        } else {
            report.warn(.suspiciousValue, "REALITY public key is not base64")
        }
        if let shortID = settings.shortID {
            let bytes = Array(shortID.utf8)
            let isHex = bytes.allSatisfy { PercentCoding.hexValue($0) != nil }
            if !isHex || bytes.count > 16 || bytes.count % 2 != 0 {
                report.warn(.suspiciousValue, "REALITY short id is not an even-length hex string of at most 16 digits")
            }
        }
    }

    // MARK: Helpers

    private static func takeInt(_ name: String, from bag: inout ParameterBag, report: inout ImportReport) -> Int? {
        guard let text = bag.takeNonEmpty(name) else { return nil }
        guard let value = Text.parseNonNegativeInt(text) else {
            bag.recordInvalid(name, value: text, detail: "Not a non-negative integer", report: &report)
            return nil
        }
        return value
    }

    /// Keeps an Xray-only JSON parameter verbatim in `EngineExtras`. Invalid JSON is recorded with its raw text.
    @discardableResult
    private static func preserveJSON(
        _ text: String,
        name: String,
        key: String,
        bag: ParameterBag,
        extras: inout EngineExtras,
        limits: ImportLimits,
        report: inout ImportReport
    ) -> JSONValue? {
        guard let value = try? JSONValue.parse(
            jsonText: text, maximumBytes: limits.maximumLinkBytes, maximumDepth: limits.maximumJSONDepth
        ) else {
            bag.recordInvalid(name, value: text, detail: "Not valid JSON within the import limits", report: &report)
            return nil
        }
        extras.set(value, engine: .xray, key: key)
        report.record(
            name, value: nil, location: bag.location, reason: .engineSpecific,
            disposition: .preservedInEngineExtras,
            detail: "Kept verbatim for Xray under '\(key)'"
        )
        return value
    }
}
