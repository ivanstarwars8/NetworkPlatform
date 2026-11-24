import Foundation
import DomainModels

public enum ExportError: Error, Hashable, Sendable {
    /// No exporter exists for this protocol.
    case unsupportedProtocol(ProxyProtocolKind)
    case missingCredential(SecretSlot)
    /// The secret is a reference; the caller must resolve it before exporting.
    case secretNotInline(SecretSlot)
    /// The outbound uses something the link format cannot carry at all.
    case notExpressible(reason: String)
}

public struct ExportedLink: Codable, Hashable, Sendable {
    public var uri: String
    /// What the link could not carry. Empty when the link is a full representation.
    public var warnings: [ConversionWarning]

    public init(uri: String, warnings: [ConversionWarning] = []) {
        self.uri = uri
        self.warnings = warnings
    }
}

/// Writes an `Outbound` back as a share link in the same conventions the importer reads.
/// Output is deterministic: parameter order is fixed.
public struct ShareLinkExporter: Sendable {
    public init() {}

    public static let supportedKinds: [ProxyProtocolKind] = [.vless, .trojan, .shadowsocks]

    public func exportLink(_ outbound: Outbound) throws -> ExportedLink {
        var warnings: [ConversionWarning] = []
        let authority = try ShareLinkExporter.authority(of: outbound.server)
        var query = QueryWriter()
        let scheme: String
        let userInfo: String
        var pathBeforeQuery = ""

        switch outbound.settings {
        case .vless(let settings):
            scheme = "vless"
            let userID = try ShareLinkExporter.inline(outbound.credentials.userID, slot: .userID)
            userInfo = PercentCoding.encode(userID, as: .strict)
            query.add("encryption", settings.encryption.isEmpty ? "none" : settings.encryption)
            query.addIfPresent("flow", settings.flow)
            query.addIfPresent("packetEncoding", settings.packetEncoding)
            try ShareLinkExporter.appendStream(outbound, to: &query, warnings: &warnings)

        case .trojan:
            scheme = "trojan"
            let password = try ShareLinkExporter.inline(outbound.credentials.password, slot: .password)
            userInfo = PercentCoding.encode(password, as: .strict)
            try ShareLinkExporter.appendStream(outbound, to: &query, warnings: &warnings)

        case .shadowsocks(let settings):
            scheme = "ss"
            let password = try ShareLinkExporter.inline(outbound.credentials.password, slot: .password)
            guard outbound.stream.transport == .tcp(TCPSettings()), outbound.stream.security == .none else {
                throw ExportError.notExpressible(reason: "ss:// links carry no transport or TLS settings")
            }
            if settings.method.lowercased().hasPrefix("2022-") {
                // SIP002: with the 2022 ciphers the user information is percent-encoded, not base64.
                userInfo = PercentCoding.encode(settings.method, as: .strict)
                    + ":" + PercentCoding.encode(password, as: .strict)
            } else {
                userInfo = LenientBase64.encodeURLSafe(settings.method + ":" + password)
            }
            if let plugin = settings.plugin {
                pathBeforeQuery = "/"
                let text = plugin.options.isEmpty ? plugin.name : plugin.name + ";" + plugin.options
                query.add("plugin", text)
            }
            if !outbound.extras.isEmpty {
                warnings.append(ConversionWarning(
                    code: .notExpressible, message: "Engine extras cannot be carried by an ss:// link"
                ))
            }

        default:
            throw ExportError.unsupportedProtocol(outbound.kind)
        }

        // Parameters the importer could not interpret are written back unchanged,
        // so a link survives import → export without losing them.
        for parameter in outbound.unsupported {
            if parameter.disposition == .preservedInEngineExtras {
                continue
            }
            if parameter.location == .query, parameter.reason != .duplicate,
               let value = parameter.value, !query.contains(parameter.name) {
                query.add(parameter.name, value)
            } else {
                warnings.append(ConversionWarning(
                    code: .notExpressible,
                    message: "Recorded parameter '\(parameter.name)' cannot be written back to the link"
                ))
            }
        }
        if outbound.tag != outbound.name {
            warnings.append(ConversionWarning(
                code: .notExpressible, message: "The link carries the name only; the tag is not exported"
            ))
        }

        var uri = scheme + "://" + userInfo + "@" + authority + pathBeforeQuery
        if !query.isEmpty {
            uri += "?" + query.text
        }
        if !outbound.name.isEmpty {
            uri += "#" + PercentCoding.encode(outbound.name, as: .strict)
        }
        return ExportedLink(uri: uri, warnings: warnings)
    }

    // MARK: - Pieces

    private static func authority(of server: ServerEndpoint) throws -> String {
        if server.isIPv6Literal {
            guard ParsedURI.isValidIPv6Literal(server.host) else {
                throw ExportError.notExpressible(reason: "host is not a valid IPv6 literal")
            }
        } else {
            guard ParsedURI.isValidHostName(server.host) else {
                throw ExportError.notExpressible(reason: "host is empty or contains forbidden characters")
            }
        }
        guard server.port != 0 else {
            throw ExportError.notExpressible(reason: "port is zero")
        }
        return server.authority
    }

    private static func inline(_ value: SecretValue?, slot: SecretSlot) throws -> String {
        guard let value = value else {
            throw ExportError.missingCredential(slot)
        }
        switch value {
        case .inline(let text):
            guard !text.isEmpty else {
                throw ExportError.missingCredential(slot)
            }
            return text
        case .reference:
            throw ExportError.secretNotInline(slot)
        }
    }

    private static func appendStream(
        _ outbound: Outbound,
        to query: inout QueryWriter,
        warnings: inout [ConversionWarning]
    ) throws {
        let stream = outbound.stream
        var usedExtraKeys = Set<String>()

        switch stream.transport {
        case .tcp(let settings):
            query.add("type", "tcp")
            if let obfuscation = settings.httpObfuscation {
                query.add("headerType", "http")
                query.addIfNotEmpty("host", obfuscation.hosts.joined(separator: ","))
                query.addIfNotEmpty("path", obfuscation.paths.joined(separator: ","))
            }
        case .webSocket(let settings):
            query.add("type", "ws")
            query.addIfNotEmpty("host", settings.host)
            query.addIfNotEmpty("path", settings.path)
        case .grpc(let settings):
            query.add("type", "grpc")
            query.addIfNotEmpty("serviceName", settings.serviceName)
            query.addIfNotEmpty("authority", settings.authority)
            if settings.multiMode {
                query.add("mode", "multi")
            }
        case .http2(let settings):
            query.add("type", "http")
            query.addIfNotEmpty("host", settings.hosts.joined(separator: ","))
            query.addIfNotEmpty("path", settings.path)
        case .httpUpgrade(let settings):
            query.add("type", "httpupgrade")
            query.addIfNotEmpty("host", settings.host)
            query.addIfNotEmpty("path", settings.path)
        case .xhttp(let settings):
            query.add("type", "xhttp")
            query.addIfNotEmpty("host", settings.host)
            query.addIfNotEmpty("path", settings.path)
            query.addIfNotEmpty("mode", settings.mode)
            if let extra = outbound.extras.value(engine: .xray, key: EngineExtras.xrayXHTTPExtraKey) {
                let text = try jsonText(extra)
                query.add("extra", text)
                usedExtraKeys.insert(EngineExtras.xrayXHTTPExtraKey)
            }
            if settings.download != nil {
                warnings.append(ConversionWarning(
                    code: .notExpressible,
                    message: "The typed XHTTP download leg is not written to the link"
                ))
            }
        case .kcp(let settings):
            query.add("type", "kcp")
            query.addIfNotEmpty("headerType", settings.headerType)
            if let seed = settings.seed {
                let text = try inline(seed, slot: .transportKey)
                query.add("seed", text)
            }
            if let mtu = settings.mtu { query.add("mtu", String(mtu)) }
            if let tti = settings.tti { query.add("tti", String(tti)) }
        case .quic(let settings):
            query.add("type", "quic")
            query.addIfNotEmpty("quicSecurity", settings.security)
            if let key = settings.key {
                let text = try inline(key, slot: .transportKey)
                query.add("key", text)
            }
            query.addIfNotEmpty("headerType", settings.headerType)
        case .native:
            throw ExportError.notExpressible(reason: "a protocol-native transport has no stream parameters in a link")
        }

        switch stream.security {
        case .none:
            query.add("security", "none")
        case .tls(let settings):
            query.add("security", "tls")
            query.addIfPresent("sni", settings.serverName)
            query.addIfNotEmpty("alpn", settings.alpn.joined(separator: ","))
            query.addIfPresent("fp", settings.fingerprint)
            if settings.allowInsecure {
                query.add("allowInsecure", "1")
            }
            query.addIfPresent("ech", settings.echConfigList)
            query.addIfPresent("pcs", settings.pinnedPeerCertificateSHA256)
            query.addIfPresent("vcn", settings.verifyPeerCertificateByName)
            if settings.disableSNI {
                warnings.append(ConversionWarning(
                    code: .notExpressible, message: "'disable SNI' is not written to the link"
                ))
            }
        case .reality(let settings):
            query.add("security", "reality")
            query.addIfPresent("sni", settings.serverName)
            query.addIfPresent("fp", settings.fingerprint)
            query.add("pbk", settings.publicKey)
            query.addIfPresent("sid", settings.shortID)
            query.addIfPresent("spx", settings.spiderX)
            query.addIfPresent("pqv", settings.mldsa65Verify)
        }

        if let finalMask = outbound.extras.value(engine: .xray, key: EngineExtras.xrayFinalMaskKey) {
            let text = try jsonText(finalMask)
            query.add("fm", text)
            usedExtraKeys.insert(EngineExtras.xrayFinalMaskKey)
        }

        for engine in outbound.extras.storage.keys.sorted() {
            guard let bucket = outbound.extras.storage[engine] else { continue }
            for key in bucket.keys.sorted() {
                if engine == EngineID.xray.rawValue && usedExtraKeys.contains(key) {
                    continue
                }
                warnings.append(ConversionWarning(
                    code: .notExpressible,
                    message: "Engine extra '\(engine)/\(key)' is not written to the link"
                ))
            }
        }
    }

    private static func jsonText(_ value: JSONValue) throws -> String {
        do {
            return try value.jsonText()
        } catch {
            throw ExportError.notExpressible(reason: "engine extra cannot be serialised as JSON")
        }
    }
}

/// Ordered query string builder.
struct QueryWriter {
    private var pairs: [(name: String, value: String)] = []

    init() {}

    var isEmpty: Bool {
        return pairs.isEmpty
    }

    func contains(_ name: String) -> Bool {
        return pairs.contains { $0.name == name }
    }

    mutating func add(_ name: String, _ value: String) {
        pairs.append((name: name, value: value))
    }

    mutating func addIfNotEmpty(_ name: String, _ value: String) {
        if !value.isEmpty {
            add(name, value)
        }
    }

    mutating func addIfPresent(_ name: String, _ value: String?) {
        if let value = value, !value.isEmpty {
            add(name, value)
        }
    }

    var text: String {
        return pairs
            .map { PercentCoding.encode($0.name, as: .strict) + "=" + PercentCoding.encode($0.value, as: .queryValue) }
            .joined(separator: "&")
    }
}
