import Foundation
import DomainModels

/// Per-scheme share link parsers.
///
/// The grammar of every scheme, with the sources it was checked against, is in
/// `Documentation/Protocols/share-link-formats.md`. In short:
/// - `vless://`, `trojan://`, URL form of `vmess://`, `socks://`: XTLS/Xray-core discussion 716
///   and `libXray/share/parse_share.go` (VERIFIED in source).
/// - `hysteria2://`: the official URI scheme page and `libXray/share/hysteria2.go` (VERIFIED).
/// - `ss://`: SIP002 and SIP022 (VERIFIED against the specification pages).
/// - `vmess://` base64 JSON: the v2rayN wiki page (VERIFIED against the page).
/// - `tuic://`: daeuniverse/dae discussion 182 (an informal proposal, VERIFIED against the page).
/// - `wireguard://`: no specification and no reference implementation in the checked
///   sources (UNVERIFIED). The importer adds a warning.
enum LinkParsers {

    // MARK: - VLESS

    static func vless(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "vless-url"
        let uri = try ParsedURI.parse(link)
        let userID = try LinkSupport.requiredUserInfo(uri, field: "id")
        let server = try LinkSupport.endpoint(uri, defaultPort: nil, report: &report)
        LinkSupport.recordPath(uri, report: &report)

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        var settings = VLESSSettings()
        settings.encryption = bag.takeNonEmpty("encryption") ?? "none"
        settings.flow = bag.takeNonEmpty("flow")
        settings.packetEncoding = bag.takeNonEmpty("packetEncoding")

        var extras = EngineExtras()
        let stream = try StreamParameters.parse(
            &bag, defaultSecurity: "none", extras: &extras, limits: limits, report: &report
        )
        bag.finish(knownElsewhere: StreamParameters.knownNames, report: &report)

        if !LinkSupport.looksLikeUUID(userID) {
            report.warn(.suspiciousValue, "VLESS id is not a UUID; kept as written")
        }
        if let flow = settings.flow {
            if flow != "xtls-rprx-vision" && flow != "xtls-rprx-vision-udp443" {
                report.warn(.suspiciousValue, "Unrecognised VLESS flow '\(flow)'; kept as written")
            }
            if stream.transport.kind != .tcp {
                report.warn(.suspiciousValue, "VLESS flow is set together with a non-TCP transport")
            }
        }
        if stream.security.kind == .none && settings.encryption == "none" {
            report.warn(.plaintextTransport, "VLESS without TLS, REALITY or VLESS Encryption is not encrypted")
        }

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(userID: .inline(userID)),
            settings: .vless(settings), stream: stream, extras: extras
        )
    }

    // MARK: - Trojan

    static func trojan(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "trojan-url"
        let uri = try ParsedURI.parse(link)
        let password = try LinkSupport.requiredUserInfo(uri, field: "password")
        let server = try LinkSupport.endpoint(uri, defaultPort: 443, report: &report)
        LinkSupport.recordPath(uri, report: &report)

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        var extras = EngineExtras()
        let stream = try StreamParameters.parse(
            &bag, defaultSecurity: "tls", extras: &extras, limits: limits, report: &report
        )
        bag.finish(knownElsewhere: StreamParameters.knownNames, report: &report)

        if stream.security.kind == .none {
            report.warn(.plaintextTransport, "Trojan link explicitly disables TLS")
        }

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(password: .inline(password)),
            settings: .trojan, stream: stream, extras: extras
        )
    }

    // MARK: - VMess

    static func vmess(
        _ link: String,
        rest: String,
        limits: ImportLimits,
        report: inout ImportReport
    ) throws -> Outbound {
        if let decoded = LenientBase64.decodeToString(rest) {
            let body = Text.trimmed(decoded)
            if body.hasPrefix("{") {
                report.format = "vmess-base64-json"
                return try vmessJSON(body, limits: limits, report: &report)
            }
            throw ImportError.malformedLink(reason: "unsupported vmess variant: base64 body is not a JSON object")
        }
        if rest.utf8.contains(0x40) {
            report.format = "vmess-url"
            return try vmessURL(link, limits: limits, report: &report)
        }
        throw ImportError.invalidBase64(context: "vmess")
    }

    private static func vmessURL(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        let uri = try ParsedURI.parse(link)
        let userID = try LinkSupport.requiredUserInfo(uri, field: "id")
        let server = try LinkSupport.endpoint(uri, defaultPort: nil, report: &report)
        LinkSupport.recordPath(uri, report: &report)

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        var settings = VMessSettings()
        settings.cipher = bag.takeNonEmpty("encryption") ?? "auto"
        if let alterID = bag.takeFirst(of: ["aid", "alterId"], report: &report) {
            if let value = Text.parseNonNegativeInt(alterID) {
                settings.alterID = value
            } else {
                bag.recordInvalid("aid", value: alterID, detail: "Not a non-negative integer", report: &report)
            }
        }

        var extras = EngineExtras()
        let stream = try StreamParameters.parse(
            &bag, defaultSecurity: "none", extras: &extras, limits: limits, report: &report
        )
        bag.finish(knownElsewhere: StreamParameters.knownNames, report: &report)
        vmessChecks(userID: userID, settings: settings, report: &report)

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(userID: .inline(userID)),
            settings: .vmess(settings), stream: stream, extras: extras
        )
    }

    private static func vmessJSON(_ body: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        let root: JSONValue
        do {
            root = try JSONValue.parse(
                jsonText: body, maximumBytes: limits.maximumLinkBytes, maximumDepth: limits.maximumJSONDepth
            )
        } catch {
            throw ImportError.invalidJSON(context: "vmess")
        }
        guard let members = root.objectValue else {
            throw ImportError.invalidJSON(context: "vmess")
        }
        guard members.count <= limits.maximumParameters else {
            throw ImportError.tooManyParameters(limit: limits.maximumParameters)
        }

        // Scalars are compared as text: real links write numbers both as 443 and as "443".
        var fields: [String: String] = [:]
        for key in members.keys.sorted() {
            guard let value = members[key] else { continue }
            switch value {
            case .null:
                continue
            case .string(let text):
                fields[key] = text
            case .integer(let number):
                fields[key] = String(number)
            case .number(let number):
                fields[key] = String(number)
            case .bool(let flag):
                fields[key] = flag ? "true" : "false"
            case .array, .object:
                report.record(
                    key, value: try? value.jsonText(), location: .jsonBody, reason: .unknown,
                    detail: "Nested value is not part of the format"
                )
            }
        }

        guard var host = LinkSupport.nonEmpty(fields.removeValue(forKey: "add")) else {
            throw ImportError.missingField("add")
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.utf8.contains(0x3A) {
            guard ParsedURI.isValidIPv6Literal(host) else {
                throw ImportError.invalidField(name: "add", reason: "not a host name or an IP literal")
            }
        } else {
            guard ParsedURI.isValidHostName(host) else {
                throw ImportError.invalidField(name: "add", reason: "empty or contains forbidden characters")
            }
        }
        guard let portText = LinkSupport.nonEmpty(fields.removeValue(forKey: "port")) else {
            throw ImportError.missingField("port")
        }
        guard let port = Text.parsePort(portText) else {
            throw ImportError.invalidField(name: "port", reason: "not a number in 1...65535")
        }
        guard let userID = LinkSupport.nonEmpty(fields.removeValue(forKey: "id")) else {
            throw ImportError.missingField("id")
        }
        let server = ServerEndpoint(host: host, port: port)

        var settings = VMessSettings()
        settings.cipher = LinkSupport.nonEmpty(fields.removeValue(forKey: "scy")) ?? "auto"
        if let alterID = LinkSupport.nonEmpty(fields.removeValue(forKey: "aid")) {
            if let value = Text.parseNonNegativeInt(alterID) {
                settings.alterID = value
            } else {
                report.record(
                    "aid", value: alterID, location: .jsonBody, reason: .invalidValue,
                    detail: "Not a non-negative integer"
                )
            }
        }
        if let version = LinkSupport.nonEmpty(fields.removeValue(forKey: "v")), version != "2" {
            report.warn(.suspiciousValue, "VMess link declares format version '\(version)'; parsed as version 2")
        }
        let displayName = fields.removeValue(forKey: "ps")

        let network = (LinkSupport.nonEmpty(fields.removeValue(forKey: "net")) ?? "tcp").lowercased()
        var headerOrMode = LinkSupport.nonEmpty(fields.removeValue(forKey: "type"))
        if let value = headerOrMode, value.lowercased() == "none" {
            headerOrMode = nil
        }
        let hostField = LinkSupport.nonEmpty(fields.removeValue(forKey: "host"))
        let pathField = LinkSupport.nonEmpty(fields.removeValue(forKey: "path"))
        let tlsField = LinkSupport.nonEmpty(fields.removeValue(forKey: "tls"))

        // The JSON reuses `type`, `host` and `path` with a meaning that depends on `net`;
        // translate them into the names of the URL convention and reuse one parser.
        var pairs: [(name: String, value: String)] = []
        pairs.append((name: "type", value: network))
        var typeName = "headerType"
        var hostName = "host"
        var pathName = "path"
        switch network {
        case "kcp", "mkcp":
            pathName = "seed"
        case "quic":
            hostName = "quicSecurity"
            pathName = "key"
        case "grpc", "gun":
            typeName = "mode"
            hostName = "authority"
            pathName = "serviceName"
        case "xhttp", "splithttp":
            typeName = "mode"
        default:
            break
        }
        if let value = headerOrMode { pairs.append((name: typeName, value: value)) }
        if let value = hostField { pairs.append((name: hostName, value: value)) }
        if let value = pathField { pairs.append((name: pathName, value: value)) }
        pairs.append((name: "security", value: tlsField ?? "none"))
        for key in fields.keys.sorted() {
            if let value = fields[key], !value.isEmpty {
                pairs.append((name: key, value: value))
            }
        }

        var bag = ParameterBag(pairs: pairs, location: .jsonBody, report: &report)
        var extras = EngineExtras()
        let stream = try StreamParameters.parse(
            &bag, defaultSecurity: "none", extras: &extras, limits: limits, report: &report
        )
        bag.finish(knownElsewhere: StreamParameters.knownNames, report: &report)
        vmessChecks(userID: userID, settings: settings, report: &report)

        let name = LinkSupport.name(displayName, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(userID: .inline(userID)),
            settings: .vmess(settings), stream: stream, extras: extras
        )
    }

    private static func vmessChecks(userID: String, settings: VMessSettings, report: inout ImportReport) {
        if !LinkSupport.looksLikeUUID(userID) {
            report.warn(.suspiciousValue, "VMess id is not a UUID; kept as written")
        }
        if settings.alterID > 0 {
            report.warn(.legacyFeature, "VMess alterId is non-zero (legacy non-AEAD mode); engines may reject it")
        }
    }

    // MARK: - Shadowsocks

    private static let knownShadowsocksMethods: Set<String> = [
        "none", "plain",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "chacha20-poly1305", "xchacha20-ietf-poly1305", "xchacha20-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "2022-blake3-chacha12-poly1305", "2022-blake3-chacha8-poly1305",
    ]

    /// SIP022: the key is base64 of exactly this many bytes; identity keys (SIP023) are joined with ':'.
    private static let shadowsocks2022KeyLengths: [String: Int] = [
        "2022-blake3-aes-128-gcm": 16, "2022-blake3-aes-256-gcm": 32,
        "2022-blake3-chacha20-poly1305": 32, "2022-blake3-chacha12-poly1305": 32,
        "2022-blake3-chacha8-poly1305": 32,
    ]

    static func shadowsocks(
        _ link: String,
        rest: String,
        limits: ImportLimits,
        report: inout ImportReport
    ) throws -> Outbound {
        let (beforeFragment, fragmentOfRest) = Text.cutFirst(rest, at: 0x23)
        let (mainPart, queryOfRest) = Text.cutFirst(beforeFragment, at: 0x3F)

        let method: String
        let password: String
        let host: String
        let rawPort: String?
        let rawQuery: String?
        let rawFragment: String?

        if !mainPart.utf8.contains(0x40) {
            // Legacy: ss://BASE64(method:password@host:port)#name
            report.format = "ss-legacy-base64"
            guard let decoded = LenientBase64.decodeToString(mainPart) else {
                throw ImportError.invalidBase64(context: "ss")
            }
            let (credentialPart, hostPart) = Text.cutLast(Text.trimmed(decoded), at: 0x40)
            guard let hostPart = hostPart else {
                throw ImportError.malformedLink(reason: "legacy ss body is not method:password@host:port")
            }
            let (methodPart, passwordPart) = Text.cutFirst(credentialPart, at: 0x3A)
            guard let passwordPart = passwordPart else {
                throw ImportError.missingField("password")
            }
            let parsedHost = try ParsedURI.parseHostPort(hostPart)
            method = methodPart
            password = passwordPart
            host = parsedHost.host
            rawPort = parsedHost.rawPort
            rawQuery = queryOfRest
            rawFragment = fragmentOfRest
        } else {
            // SIP002: ss://userinfo@host:port[/][?plugin=...]#name
            report.format = "sip002"
            let uri = try ParsedURI.parse(link)
            guard let rawUserInfo = uri.rawUserInfo, !rawUserInfo.isEmpty else {
                throw ImportError.missingField("method")
            }
            if rawUserInfo.utf8.contains(0x3A) {
                // Plain form, each part percent-encoded (used with the 2022 ciphers).
                let (rawMethod, rawPassword) = Text.cutFirst(rawUserInfo, at: 0x3A)
                guard let decodedMethod = PercentCoding.decode(rawMethod),
                      let decodedPassword = PercentCoding.decode(rawPassword ?? "") else {
                    throw ImportError.invalidField(name: "userinfo", reason: "malformed percent-encoding")
                }
                method = decodedMethod
                password = decodedPassword
            } else {
                guard let unescaped = PercentCoding.decode(rawUserInfo),
                      let decoded = LenientBase64.decodeToString(unescaped) else {
                    throw ImportError.invalidBase64(context: "ss")
                }
                let (methodPart, passwordPart) = Text.cutFirst(decoded, at: 0x3A)
                guard let passwordPart = passwordPart else {
                    throw ImportError.missingField("password")
                }
                method = methodPart
                password = passwordPart
            }
            LinkSupport.recordPath(uri, report: &report)
            host = uri.host
            rawPort = uri.rawPort
            rawQuery = uri.rawQuery
            rawFragment = uri.rawFragment
        }

        guard !method.isEmpty else {
            throw ImportError.missingField("method")
        }
        guard !password.isEmpty else {
            throw ImportError.missingField("password")
        }
        guard let portText = rawPort else {
            throw ImportError.missingField("port")
        }
        guard let port = Text.parsePort(portText) else {
            throw ImportError.invalidField(name: "port", reason: "not a number in 1...65535")
        }
        let server = ServerEndpoint(host: host, port: port)

        var settings = ShadowsocksSettings(method: method)
        var bag = try ParameterBag(rawQuery: rawQuery, limits: limits, report: &report)
        if let plugin = bag.takeNonEmpty("plugin") {
            let (pluginName, pluginOptions) = Text.cutFirst(plugin, at: 0x3B)
            if pluginName.isEmpty {
                bag.recordInvalid("plugin", value: plugin, detail: "Plugin name is empty", report: &report)
            } else {
                settings.plugin = ShadowsocksPlugin(name: pluginName, options: pluginOptions ?? "")
            }
        }
        bag.finish(knownElsewhere: [], report: &report)

        if !knownShadowsocksMethods.contains(method.lowercased()) {
            report.warn(.suspiciousValue, "Shadowsocks method '\(method)' is not an AEAD or 2022 cipher known to the importer")
        }
        if let keyLength = shadowsocks2022KeyLengths[method.lowercased()] {
            let keys = Array(password.utf8).split(separator: 0x3A, omittingEmptySubsequences: false)
            let valid = keys.allSatisfy {
                Data(base64Encoded: String(decoding: $0, as: UTF8.self))?.count == keyLength
            }
            if !valid {
                report.warn(.suspiciousValue, "Shadowsocks 2022 key is not standard base64 of \(keyLength) bytes")
            }
            if report.format == "sip002", !rest.utf8.prefix(while: { $0 != 0x40 }).contains(0x3A) {
                report.warn(.nonStandardFormat, "SIP002 forbids base64 user information with the 2022 methods")
            }
        }

        let name = LinkSupport.name(rawFragment: rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(password: .inline(password)),
            settings: .shadowsocks(settings)
        )
    }

    // MARK: - Hysteria2

    static func hysteria2(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "hysteria2-url"
        let uri = try ParsedURI.parse(link)
        LinkSupport.recordPath(uri, report: &report)

        // The authority may carry a port list: host:443,5000-6000
        let ranges: [PortRange]
        if let rawPort = uri.rawPort {
            guard let parsed = LinkSupport.parsePortList(rawPort) else {
                throw ImportError.invalidField(name: "port", reason: "not a port or a port list")
            }
            ranges = parsed
        } else {
            report.warn(.defaultApplied, "Port is missing; 443 assumed")
            ranges = [PortRange(lower: 443, upper: 443)]
        }
        guard let firstRange = ranges.first else {
            throw ImportError.missingField("port")
        }
        let server = ServerEndpoint(host: uri.host, port: firstRange.lower)

        var settings = Hysteria2Settings()
        if ranges.count > 1 || !firstRange.isSinglePort {
            settings.serverPorts = ranges
        }

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        if let portsText = bag.takeFirst(of: ["mport", "ports"], report: &report) {
            if let parsed = LinkSupport.parsePortList(portsText) {
                if settings.serverPorts.isEmpty {
                    settings.serverPorts = parsed
                } else {
                    report.record(
                        "mport", value: portsText, location: .query, reason: .duplicate,
                        detail: "The authority already carries a port list, which is used"
                    )
                }
            } else {
                bag.recordInvalid("mport", value: portsText, detail: "Not a port list", report: &report)
            }
        }
        if let interval = bag.takeNonEmpty("hop-interval") {
            if let value = Text.parseNonNegativeInt(interval) {
                settings.hopIntervalSeconds = value
            } else {
                bag.recordInvalid("hop-interval", value: interval, detail: "Not a number of seconds", report: &report)
            }
        }
        if let security = bag.takeNonEmpty("security"), security.lowercased() != "tls" {
            bag.recordInvalid("security", value: security, detail: "Hysteria2 always uses TLS", report: &report)
        }

        let obfuscationType = bag.takeNonEmpty("obfs")
        let obfuscationPassword = bag.takeNonEmpty("obfs-password")
        if let type = obfuscationType, type.lowercased() != "none" {
            // The official scheme defines `salamander` and `gecko`.
            let known = type.lowercased()
            guard known == "salamander" || known == "gecko" else {
                // Connecting without the requested obfuscation would change the wire format.
                throw ImportError.unsupportedValue(parameter: "obfs", value: type)
            }
            guard let obfuscationPassword = obfuscationPassword else {
                throw ImportError.missingField("obfs-password")
            }
            settings.obfuscation = Hysteria2Obfuscation(type: known, password: .inline(obfuscationPassword))
        } else if let orphan = obfuscationPassword {
            report.record(
                "obfs-password", value: orphan, location: .query, reason: .notApplicable,
                detail: "Obfuscation password without an obfuscation type"
            )
        }

        // Not part of the official scheme (which says bandwidth must not be shared);
        // libXray and mihomo read `up`/`down`. `upmbps`/`downmbps` belong to Hysteria 1
        // and are left to the unknown-parameter record.
        settings.uploadBandwidth = bag.takeNonEmpty("up")
        settings.downloadBandwidth = bag.takeNonEmpty("down")
        if settings.uploadBandwidth != nil || settings.downloadBandwidth != nil {
            report.warn(.nonStandardFormat, "Bandwidth in a hysteria2:// link is a client extension, not part of the official scheme")
        }
        if settings.hopIntervalSeconds != nil && settings.serverPorts.isEmpty {
            report.warn(.suspiciousValue, "hop-interval without a port list has no effect")
        }

        let tls = StreamParameters.parseTLS(&bag, pinNames: ["pinSHA256", "pcs"], report: &report)
        bag.finish(knownElsewhere: [], report: &report)

        var credentials = Credentials()
        if let rawAuth = uri.rawUserInfo, !rawAuth.isEmpty {
            guard let auth = PercentCoding.decode(rawAuth) else {
                throw ImportError.invalidField(name: "auth", reason: "malformed percent-encoding")
            }
            credentials.password = .inline(auth)
        } else {
            report.warn(.suspiciousValue, "Hysteria2 link carries no authentication string")
        }

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: credentials,
            settings: .hysteria2(settings),
            stream: StreamSettings(transport: .native, security: .tls(tls))
        )
    }

    // MARK: - TUIC

    static func tuic(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "tuic-url"
        report.warn(.nonStandardFormat, "tuic:// links follow a community convention without a specification")
        let uri = try ParsedURI.parse(link)
        LinkSupport.recordPath(uri, report: &report)
        guard let rawUserInfo = uri.rawUserInfo, !rawUserInfo.isEmpty else {
            throw ImportError.missingField("uuid")
        }
        // uuid:password; the separator itself is sometimes percent-encoded.
        let userID: String
        let password: String
        let rawParts = Text.cutFirst(rawUserInfo, at: 0x3A)
        if let rawPassword = rawParts.tail {
            guard let decodedID = PercentCoding.decode(rawParts.head),
                  let decodedPassword = PercentCoding.decode(rawPassword) else {
                throw ImportError.invalidField(name: "userinfo", reason: "malformed percent-encoding")
            }
            userID = decodedID
            password = decodedPassword
        } else {
            guard let decodedWhole = PercentCoding.decode(rawUserInfo) else {
                throw ImportError.invalidField(name: "userinfo", reason: "malformed percent-encoding")
            }
            let parts = Text.cutFirst(decodedWhole, at: 0x3A)
            guard let decodedPassword = parts.tail else {
                throw ImportError.missingField("password")
            }
            userID = parts.head
            password = decodedPassword
        }
        guard !userID.isEmpty else {
            throw ImportError.missingField("uuid")
        }
        guard !password.isEmpty else {
            throw ImportError.missingField("password")
        }
        let server = try LinkSupport.endpoint(uri, defaultPort: nil, report: &report)

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        var settings = TUICSettings()
        settings.congestionControl = bag.takeNonEmpty("congestion_control")
        settings.udpRelayMode = bag.takeNonEmpty("udp_relay_mode")
        if let security = bag.takeNonEmpty("security"), security.lowercased() != "tls" {
            bag.recordInvalid("security", value: security, detail: "TUIC always uses TLS", report: &report)
        }
        var tls = StreamParameters.parseTLS(&bag, report: &report)
        if let disableSNI = bag.takeNonEmpty("disable_sni") {
            if let flag = Text.parseBool(disableSNI) {
                tls.disableSNI = flag
            } else {
                bag.recordInvalid("disable_sni", value: disableSNI, detail: "Not a boolean", report: &report)
            }
        }
        bag.finish(knownElsewhere: [], report: &report)

        if !LinkSupport.looksLikeUUID(userID) {
            report.warn(.suspiciousValue, "TUIC uuid is not a UUID; kept as written")
        }

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: Credentials(userID: .inline(userID), password: .inline(password)),
            settings: .tuic(settings),
            stream: StreamSettings(transport: .native, security: .tls(tls))
        )
    }

    // MARK: - SOCKS

    static func socks(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "socks-url"
        let uri = try ParsedURI.parse(link)
        LinkSupport.recordPath(uri, report: &report)
        let server = try LinkSupport.endpoint(uri, defaultPort: 1080, report: &report)

        let version: SOCKSSettings.Version
        switch uri.scheme {
        case "socks4": version = .v4
        case "socks4a": version = .v4a
        default: version = .v5
        }

        var credentials = Credentials()
        if let rawUserInfo = uri.rawUserInfo, !rawUserInfo.isEmpty {
            if rawUserInfo.utf8.contains(0x3A) {
                let (rawUser, rawPassword) = Text.cutFirst(rawUserInfo, at: 0x3A)
                guard let user = PercentCoding.decode(rawUser),
                      let password = PercentCoding.decode(rawPassword ?? "") else {
                    throw ImportError.invalidField(name: "userinfo", reason: "malformed percent-encoding")
                }
                credentials.username = user
                if !password.isEmpty {
                    credentials.password = .inline(password)
                }
            } else {
                guard let unescaped = PercentCoding.decode(rawUserInfo) else {
                    throw ImportError.invalidField(name: "userinfo", reason: "malformed percent-encoding")
                }
                // socks://BASE64(user:password)@host:port is the common form; a bare user name is the other.
                if let decoded = LenientBase64.decodeToString(unescaped), decoded.utf8.contains(0x3A) {
                    let (user, password) = Text.cutFirst(decoded, at: 0x3A)
                    credentials.username = user
                    if let password = password, !password.isEmpty {
                        credentials.password = .inline(password)
                    }
                } else {
                    credentials.username = unescaped
                }
            }
        }

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        bag.finish(knownElsewhere: [], report: &report)

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: credentials,
            settings: .socks(SOCKSSettings(version: version))
        )
    }

    // MARK: - WireGuard

    static func wireGuard(_ link: String, limits: ImportLimits, report: inout ImportReport) throws -> Outbound {
        report.format = "wireguard-url"
        report.warn(.nonStandardFormat, "wireguard:// links follow a community convention without a specification")
        let uri = try ParsedURI.parse(link)
        LinkSupport.recordPath(uri, report: &report)
        let privateKey = try LinkSupport.requiredUserInfo(uri, field: "private key")
        let server = try LinkSupport.endpoint(uri, defaultPort: nil, report: &report)

        var bag = try ParameterBag(rawQuery: uri.rawQuery, limits: limits, report: &report)
        guard let publicKey = bag.takeFirst(of: ["publickey", "publicKey"], report: &report) else {
            throw ImportError.missingField("publickey")
        }
        var settings = WireGuardSettings(peerPublicKey: publicKey)
        if let addresses = bag.takeFirst(of: ["address", "ip"], report: &report) {
            settings.localAddresses = Text.commaList(addresses)
        }
        if let allowed = bag.takeFirst(of: ["allowedips", "allowedIPs"], report: &report) {
            settings.allowedIPs = Text.commaList(allowed)
        }
        if let reserved = bag.takeNonEmpty("reserved") {
            let parts = Text.commaList(reserved)
            var bytes: [UInt8] = []
            for part in parts {
                if let value = Text.parseNonNegativeInt(part), value <= 255 {
                    bytes.append(UInt8(value))
                }
            }
            if parts.count == 3 && bytes.count == 3 {
                settings.reserved = bytes
            } else {
                bag.recordInvalid("reserved", value: reserved, detail: "Expected three numbers 0...255", report: &report)
            }
        }
        if let mtu = bag.takeNonEmpty("mtu") {
            if let value = Text.parseNonNegativeInt(mtu) {
                settings.mtu = value
            } else {
                bag.recordInvalid("mtu", value: mtu, detail: "Not a non-negative integer", report: &report)
            }
        }
        if let keepalive = bag.takeFirst(of: ["keepalive", "persistentkeepalive"], report: &report) {
            if let value = Text.parseNonNegativeInt(keepalive) {
                settings.persistentKeepaliveSeconds = value
            } else {
                bag.recordInvalid("keepalive", value: keepalive, detail: "Not a number of seconds", report: &report)
            }
        }
        var credentials = Credentials(privateKey: .inline(privateKey))
        if let preSharedKey = bag.takeFirst(of: ["presharedkey", "psk"], report: &report) {
            credentials.preSharedKey = .inline(preSharedKey)
        }
        bag.finish(knownElsewhere: [], report: &report)

        for (label, key) in [("private key", privateKey), ("public key", publicKey)] {
            if let decoded = LenientBase64.decode(key) {
                if decoded.count != 32 {
                    report.warn(.suspiciousValue, "WireGuard \(label) does not decode to 32 bytes")
                }
            } else {
                report.warn(.suspiciousValue, "WireGuard \(label) is not base64")
            }
        }

        let name = LinkSupport.name(rawFragment: uri.rawFragment, server: server, report: &report)
        return Outbound(
            tag: name, name: name, server: server,
            credentials: credentials,
            settings: .wireGuard(settings),
            stream: StreamSettings(transport: .native, security: .none)
        )
    }
}
