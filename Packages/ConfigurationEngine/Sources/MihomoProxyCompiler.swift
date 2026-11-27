import Foundation
import DomainModels

/// `proxies[]` entries. Keys follow `adapter/outbound/*.go` of Mihomo 1.19.34 (the `proxy:"…"` struct tags).
extension MihomoConfigCompiler {
    /// uTLS fingerprints the core knows (`component/tls/utls.go`).
    static let clientFingerprints: Set<String> = [
        "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized",
        "chrome120", "firefox120", "safari16",
    ]

    /// Shadowsocks methods of the core (`sing-shadowsocks2`, aead and 2022 families; stream ciphers excluded).
    static let shadowsocksMethods: Set<String> = [
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "none",
    ]

    /// Xray spellings of the same methods.
    static let shadowsocksAliases: [String: String] = [
        "aead_aes_128_gcm": "aes-128-gcm", "aead_aes_256_gcm": "aes-256-gcm",
        "chacha20-poly1305": "chacha20-ietf-poly1305", "aead_chacha20_poly1305": "chacha20-ietf-poly1305",
        "xchacha20-poly1305": "xchacha20-ietf-poly1305", "aead_xchacha20_poly1305": "xchacha20-ietf-poly1305",
        "plain": "none",
    ]

    /// Keys whose values describe the shape of a proxy entry, not the user's data (kept in report messages).
    static let structuralProxyKeys: Set<String> = [
        "name", "type", "network", "cipher", "flow", "client-fingerprint", "packet-encoding", "obfs", "mode",
        "plugin", "congestion-controller", "udp-relay-mode", "strategy", "dialer-proxy",
    ]

    /// Compiles one outbound. `pairs` is `nil` when any issue has severity `.error`.
    public func compileOutbound(
        _ outbound: Outbound,
        name: String,
        path: String = "outbound"
    ) -> (pairs: [YAMLPair]?, issues: [ConversionIssue]) {
        var context = XrayOutboundContext(path: path)
        let pairs = build(outbound, name: name, context: &context)
        // Messages may quote what the profile contains; no credential or address leaves in them.
        var redactor = ConfigValueRedactor()
        redactor.add(outbound.server.host)
        if let pairs = pairs {
            MihomoConfigCompiler.collectValues(.mapping(pairs), key: nil, into: &redactor)
        }
        let credentials = outbound.credentials
        for secret in [credentials.userID, credentials.password, credentials.privateKey, credentials.preSharedKey] {
            if case .inline(let text)? = secret { redactor.add(text) }
        }
        if let username = credentials.username { redactor.add(username) }
        return (context.failed ? nil : pairs, redactor.redact(context.issues))
    }

    static func collectValues(_ node: YAMLNode, key: String?, into redactor: inout ConfigValueRedactor) {
        switch node {
        case .string(let text):
            if let key = key, structuralProxyKeys.contains(key) { return }
            redactor.add(text)
        case .sequence(let items):
            for item in items { collectValues(item, key: key, into: &redactor) }
        case .mapping(let pairs):
            for pair in pairs { collectValues(pair.value, key: pair.key, into: &redactor) }
        default:
            return
        }
    }

    func resolve(_ value: SecretValue?, _ subpath: String, _ context: inout XrayOutboundContext) -> String? {
        guard let value = value else {
            context.note(subpath, .invalid, .error, "Required credential is missing")
            return nil
        }
        let text: String?
        switch value {
        case .inline(let inline):
            text = inline
        case .reference(let reference):
            text = resolver?(reference)
            if text == nil {
                context.note(subpath, .invalid, .error, "Secret reference could not be resolved")
                return nil
            }
        }
        guard let result = text, !result.isEmpty else {
            context.note(subpath, .invalid, .error, "Credential is empty")
            return nil
        }
        return result
    }

    private func build(_ outbound: Outbound, name: String, context: inout XrayOutboundContext) -> [YAMLPair]? {
        let server = outbound.server
        if server.host.isEmpty { context.note("server.host", .invalid, .error, "Server host is empty") }
        if server.port == 0 { context.note("server.port", .invalid, .error, "Server port is zero") }
        for parameter in outbound.unsupported where parameter.disposition == .recorded && parameter.reason != .duplicate {
            context.note(
                "unsupported[\(parameter.name)]", .dropped, .warning,
                "Imported parameter '\(parameter.name)' (\(parameter.reason.rawValue)) is not part of the configuration"
            )
        }
        for engine in outbound.extras.storage.keys.sorted() {
            for key in (outbound.extras.storage[engine] ?? [:]).keys.sorted() {
                if engine == EngineID.mihomo.rawValue {
                    context.note("extras.\(engine).\(key)", .dropped, .warning, "Mihomo extras are not applied by this compiler")
                } else {
                    context.note("extras.\(engine).\(key)", .dropped, engine == EngineID.xray.rawValue ? .warning : .info,
                                 "Extra bound to another engine is not used by Mihomo")
                }
            }
        }

        var b = YAMLMappingBuilder()
        b.set("name", name)
        let stream = outbound.stream

        switch outbound.settings {
        case .vless(let vless):
            b.set("type", "vless")
            addEndpoint(server, &b)
            if let id = resolve(outbound.credentials.userID, "credentials.userID", &context) { b.set("uuid", id) }
            if let flow = vless.flow, !flow.isEmpty {
                switch flow {
                case "xtls-rprx-vision":
                    b.set("flow", flow)
                case "xtls-rprx-vision-udp443":
                    b.set("flow", "xtls-rprx-vision")
                    context.note("settings.flow", .approximated, .warning, "Mihomo has no 'vision-udp443' variant; plain Vision is used")
                default:
                    context.note("settings.flow", .unsupported, .error, "Mihomo does not support the VLESS flow '\(flow)'")
                }
            }
            let encryption = vless.encryption.isEmpty ? "none" : vless.encryption
            if encryption != "none" {
                if encryption.hasPrefix("mlkem768x25519plus.") {
                    b.set("encryption", encryption)
                    context.note("settings.encryption", .untested, .info, "VLESS Encryption with Mihomo against Xray has no interoperability test")
                } else {
                    context.note("settings.encryption", .unsupported, .error, "Mihomo does not support this VLESS encryption value")
                }
            }
            switch vless.packetEncoding?.lowercased() {
            case nil, "", "xudp":
                b.set("packet-encoding", "xudp")
            case "packetaddr", "packet":
                b.set("packet-encoding", "packetaddr")
            case let other?:
                b.set("packet-encoding", "xudp")
                context.note("settings.packetEncoding", .approximated, .warning, "Unknown packet encoding '\(other)'; XUDP is used")
            }
            b.set("udp", true)
            applySecurity(stream.security, sniKey: "servername", allowReality: true, &b, &context)
            applyTransport(outbound, protocolName: "vless", &b, &context)

        case .vmess(let vmess):
            b.set("type", "vmess")
            addEndpoint(server, &b)
            if let id = resolve(outbound.credentials.userID, "credentials.userID", &context) { b.set("uuid", id) }
            b.set("alterId", vmess.alterID)
            let cipher = vmess.cipher.isEmpty ? "auto" : vmess.cipher.lowercased()
            if ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"].contains(cipher) {
                b.set("cipher", cipher)
            } else {
                b.set("cipher", "auto")
                context.note("settings.cipher", .approximated, .warning, "Mihomo has no VMess cipher '\(cipher)'; 'auto' is used")
            }
            b.set("udp", true)
            applySecurity(stream.security, sniKey: "servername", allowReality: true, &b, &context)
            applyTransport(outbound, protocolName: "vmess", &b, &context)

        case .trojan:
            b.set("type", "trojan")
            addEndpoint(server, &b)
            if let password = resolve(outbound.credentials.password, "credentials.password", &context) { b.set("password", password) }
            b.set("udp", true)
            if stream.security.kind == .none {
                context.note("stream.security", .unsupported, .error, "Mihomo's Trojan always uses TLS; the server does not")
            }
            applySecurity(stream.security, sniKey: "sni", allowReality: true, tlsFlag: false, &b, &context)
            applyTransport(outbound, protocolName: "trojan", &b, &context)

        case .shadowsocks(let shadowsocks):
            b.set("type", "ss")
            addEndpoint(server, &b)
            var method = shadowsocks.method.lowercased()
            if let alias = MihomoConfigCompiler.shadowsocksAliases[method] { method = alias }
            if !MihomoConfigCompiler.shadowsocksMethods.contains(method) {
                context.note("settings.method", .unsupported, .error, "This compiler does not emit the Shadowsocks method '\(method)' for Mihomo")
            }
            b.set("cipher", method)
            if method == "none" {
                context.note("settings.method", .untested, .warning, "Shadowsocks without encryption")
            } else if let password = resolve(outbound.credentials.password, "credentials.password", &context) {
                if let keyLength = XrayConfigCompiler.shadowsocks2022KeyLengths[method] {
                    let keys = password.split(separator: ":", omittingEmptySubsequences: false)
                    if !keys.allSatisfy({ Data(base64Encoded: String($0))?.count == keyLength }) {
                        context.note("credentials.password", .invalid, .error, "Shadowsocks 2022 key must be standard base64 of \(keyLength) bytes (identity keys separated by ':')")
                    }
                }
                b.set("password", password)
            }
            b.set("udp", true)
            if let plugin = shadowsocks.plugin {
                applyPlugin(plugin, &b, &context)
            }
            if stream.transport.kind != .tcp || stream.security.kind != .none {
                context.note("stream", .unsupported, .error, "Mihomo's Shadowsocks has no transport or TLS other than through a plugin")
            } else if case .tcp(let tcp) = stream.transport, tcp.httpObfuscation != nil {
                context.note("stream.transport.httpObfuscation", .unsupported, .error, "Mihomo's Shadowsocks has no HTTP header camouflage outside the obfs plugin")
            }

        case .socks(let socks):
            b.set("type", "socks5")
            addEndpoint(server, &b)
            if socks.version != .v5 {
                context.note("settings.version", .unsupported, .error, "The Mihomo SOCKS outbound speaks SOCKS5 only")
            }
            addUserPass(outbound, &b, &context)
            b.set("udp", true)
            applySimpleTLS(outbound, sniKey: nil, &b, &context)

        case .http:
            b.set("type", "http")
            addEndpoint(server, &b)
            addUserPass(outbound, &b, &context)
            applySimpleTLS(outbound, sniKey: "sni", &b, &context)

        case .hysteria2(let hysteria):
            b.set("type", "hysteria2")
            addEndpoint(server, &b)
            if outbound.credentials.password != nil,
               let password = resolve(outbound.credentials.password, "credentials.password", &context) {
                b.set("password", password)
            }
            if !hysteria.serverPorts.isEmpty {
                b.set("ports", hysteria.serverPorts.map { $0.isSinglePort ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }.joined(separator: ","))
                if let interval = hysteria.hopIntervalSeconds {
                    if interval < 5 {
                        context.note("settings.hopIntervalSeconds", .invalid, .error, "Port hopping interval must be at least 5 seconds")
                    }
                    b.set("hop-interval", String(interval))
                }
            } else if hysteria.hopIntervalSeconds != nil {
                context.note("settings.hopIntervalSeconds", .dropped, .warning, "A hop interval without a port list has no effect")
            }
            for (name, key, value) in [("uploadBandwidth", "up", hysteria.uploadBandwidth), ("downloadBandwidth", "down", hysteria.downloadBandwidth)] {
                guard let value = value, !value.isEmpty else { continue }
                b.set(key, value)
                if XrayConfigCompiler.bandwidthBytesPerSecond(value) == nil {
                    context.note("settings.\(name)", .approximated, .warning, "Bandwidth without a unit: Mihomo reads a bare number as Mbps")
                }
            }
            if let obfuscation = hysteria.obfuscation {
                switch obfuscation.type.lowercased() {
                case "salamander":
                    if let password = resolve(obfuscation.password, "settings.obfuscation.password", &context) {
                        b.set("obfs", "salamander")
                        b.set("obfs-password", password)
                    }
                case "gecko":
                    context.note("settings.obfuscation", .unsupported, .error, "Gecko obfuscation needs a packet size range that the model does not carry")
                default:
                    context.note("settings.obfuscation", .unsupported, .error, "Unknown Hysteria2 obfuscation '\(obfuscation.type)'")
                }
            }
            applyQUICTLS(outbound, protocolName: "Hysteria2", &b, &context)
            if options.memoryProfile == .mobile {
                let windows = XrayConfigCompiler.mobileQUICWindows
                b.set("initial-stream-receive-window", windows["initStreamReceiveWindow"].map { Int($0) })
                b.set("max-stream-receive-window", windows["maxStreamReceiveWindow"].map { Int($0) })
                b.set("initial-connection-receive-window", windows["initConnectionReceiveWindow"].map { Int($0) })
                b.set("max-connection-receive-window", windows["maxConnectionReceiveWindow"].map { Int($0) })
            }

        case .tuic(let tuic):
            b.set("type", "tuic")
            addEndpoint(server, &b)
            if let id = resolve(outbound.credentials.userID, "credentials.userID", &context) { b.set("uuid", id) }
            if let password = resolve(outbound.credentials.password, "credentials.password", &context) { b.set("password", password) }
            if let congestion = tuic.congestionControl, !congestion.isEmpty {
                if ["cubic", "new_reno", "bbr"].contains(congestion.lowercased()) {
                    b.set("congestion-controller", congestion.lowercased())
                } else {
                    context.note("settings.congestionControl", .dropped, .warning, "Mihomo's TUIC has no congestion control '\(congestion)'")
                }
            }
            if let mode = tuic.udpRelayMode, !mode.isEmpty {
                if ["native", "quic"].contains(mode.lowercased()) {
                    b.set("udp-relay-mode", mode.lowercased())
                } else {
                    context.note("settings.udpRelayMode", .dropped, .warning, "Unknown TUIC UDP relay mode '\(mode)'")
                }
            }
            b.set("udp", true)
            applyQUICTLS(outbound, protocolName: "TUIC", &b, &context)
            var alpn: [String] = []
            if case .tls(let tls) = stream.security { alpn = tls.alpn }
            if alpn.isEmpty { b.set("alpn", strings: ["h3"]) }
            context.note("settings", .untested, .info, "TUIC with Mihomo has no interoperability test (Xray has no TUIC server)")

        case .wireGuard(let wireGuard):
            b.set("type", "wireguard")
            addEndpoint(server, &b)
            if let key = resolve(outbound.credentials.privateKey, "credentials.privateKey", &context) {
                if !XrayConfigCompiler.isWireGuardKey(key) {
                    context.note("credentials.privateKey", .invalid, .error, "WireGuard private key is not 32 bytes of base64 or hex")
                }
                b.set("private-key", key)
            }
            if XrayConfigCompiler.isWireGuardKey(wireGuard.peerPublicKey) {
                b.set("public-key", wireGuard.peerPublicKey)
            } else {
                context.note("settings.peerPublicKey", .invalid, .error, "WireGuard public key is not 32 bytes of base64 or hex")
            }
            if outbound.credentials.preSharedKey != nil,
               let psk = resolve(outbound.credentials.preSharedKey, "credentials.preSharedKey", &context) {
                b.set("pre-shared-key", psk)
            }
            var v4: [String] = []
            var v6: [String] = []
            for address in wireGuard.localAddresses {
                (address.contains(":") ? { v6.append(address) } : { v4.append(address) })()
            }
            if let first = v4.first { b.set("ip", first) }
            if let first = v6.first { b.set("ipv6", first) }
            if v4.count > 1 || v6.count > 1 {
                context.note("settings.localAddresses", .dropped, .warning, "Mihomo takes one interface address per family; the others are left out")
            }
            if v4.isEmpty && v6.isEmpty {
                context.note("settings.localAddresses", .invalid, .error, "WireGuard needs an interface address")
            }
            if !wireGuard.allowedIPs.isEmpty { b.set("allowed-ips", strings: wireGuard.allowedIPs) }
            if !wireGuard.reserved.isEmpty {
                b.set("reserved", YAMLNode.sequence(wireGuard.reserved.map { .integer(Int64($0)) }))
            }
            b.set("mtu", wireGuard.mtu)
            b.set("persistent-keepalive", wireGuard.persistentKeepaliveSeconds)
            b.set("udp", true)
            if stream.transport.kind != .native || stream.security.kind != .none {
                context.note("stream", .invalid, .error, "WireGuard carries its own transport; stream settings do not apply")
            }

        case .other(let kind):
            context.note("settings", .unsupported, .error, "Mihomo compiler has no support for the protocol '\(kind.rawValue)'")
            return nil
        }
        return b.pairs
    }

    // MARK: - Pieces

    private func addEndpoint(_ server: ServerEndpoint, _ b: inout YAMLMappingBuilder) {
        b.set("server", server.host)
        b.set("port", Int(server.port))
    }

    private func addUserPass(_ outbound: Outbound, _ b: inout YAMLMappingBuilder, _ context: inout XrayOutboundContext) {
        let username = outbound.credentials.username ?? ""
        if !username.isEmpty {
            b.set("username", username)
            if let password = resolve(outbound.credentials.password, "credentials.password", &context) {
                b.set("password", password)
            }
        } else if outbound.credentials.password != nil {
            context.note("credentials.password", .invalid, .error, "A password without a user name")
        }
    }

    /// TLS for SOCKS5 and HTTP proxies (no transports).
    private func applySimpleTLS(_ outbound: Outbound, sniKey: String?, _ b: inout YAMLMappingBuilder, _ context: inout XrayOutboundContext) {
        if outbound.stream.transport.kind != .tcp {
            context.note("stream.transport", .unsupported, .error, "Mihomo's SOCKS5 and HTTP proxies run over TCP only")
        }
        switch outbound.stream.security {
        case .none:
            return
        case .reality:
            context.note("stream.security", .unsupported, .error, "REALITY is not available for this protocol in Mihomo")
        case .tls(let tls):
            if sniKey == nil, tls.serverName != nil {
                context.note("stream.security.serverName", .dropped, .warning, "Mihomo's SOCKS5 proxy sends the server address as SNI; the configured name is not used")
            }
            applySecurity(.tls(tls), sniKey: sniKey, allowReality: false, &b, &context)
        }
    }

    /// TLS of Hysteria2 and TUIC (always TLS, no REALITY, no uTLS).
    private func applyQUICTLS(_ outbound: Outbound, protocolName: String, _ b: inout YAMLMappingBuilder, _ context: inout XrayOutboundContext) {
        if outbound.stream.transport.kind != .native {
            context.note("stream.transport", .invalid, .error, "\(protocolName) carries its own transport")
        }
        switch outbound.stream.security {
        case .none:
            context.note("stream.security", .migrated, .info, "\(protocolName) always uses TLS")
        case .reality:
            context.note("stream.security", .unsupported, .error, "\(protocolName) cannot use REALITY")
        case .tls(let tls):
            var copy = tls
            if copy.fingerprint != nil {
                context.note("stream.security.fingerprint", .dropped, .info, "QUIC has no uTLS fingerprint")
                copy.fingerprint = nil
            }
            if copy.disableSNI && protocolName == "TUIC" {
                b.set("disable-sni", true)
                copy.disableSNI = false
            }
            applySecurity(.tls(copy), sniKey: "sni", allowReality: false, tlsFlag: false, &b, &context)
        }
    }

    /// TLS or REALITY keys shared by the TCP-based protocols.
    private func applySecurity(
        _ security: Security,
        sniKey: String?,
        allowReality: Bool,
        tlsFlag: Bool = true,
        _ b: inout YAMLMappingBuilder,
        _ context: inout XrayOutboundContext
    ) {
        let at = "stream.security"
        switch security {
        case .none:
            return
        case .tls(let tls):
            if tlsFlag { b.set("tls", true) }
            if let sni = tls.serverName, !sni.isEmpty, let key = sniKey { b.set(key, sni) }
            if !tls.alpn.isEmpty { b.set("alpn", strings: tls.alpn) }
            if let fingerprint = tls.fingerprint, !fingerprint.isEmpty {
                let lowered = fingerprint.lowercased()
                if MihomoConfigCompiler.clientFingerprints.contains(lowered) {
                    b.set("client-fingerprint", lowered)
                } else {
                    context.note(at + ".fingerprint", .dropped, .warning, "Mihomo does not know the TLS fingerprint '\(lowered)'; the Go TLS stack is used")
                }
            }
            if tls.allowInsecure {
                b.set("skip-cert-verify", true)
                context.note(at + ".allowInsecure", .migrated, .warning, "The server certificate is not verified")
            }
            if tls.disableSNI {
                context.note(at + ".disableSNI", .unsupported, .warning, "Mihomo cannot disable SNI for this protocol; SNI is sent")
            }
            if let ech = tls.echConfigList, !ech.isEmpty {
                b.set("ech-opts", YAMLNode.mapping([YAMLPair("enable", .bool(true)), YAMLPair("config", .string(ech))]))
                context.note(at + ".echConfigList", .untested, .info, "ECH with Mihomo has no interoperability test")
            }
            if let pins = tls.pinnedPeerCertificateSHA256, !pins.isEmpty {
                let list = pins.split(separator: ",").map { $0.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).lowercased() }
                if let first = list.first, first.count == 64, first.allSatisfy({ $0.isHexDigit }) {
                    b.set("fingerprint", first)
                    if list.count > 1 {
                        context.note(at + ".pinnedPeerCertificateSHA256", .dropped, .warning, "Mihomo pins one certificate; only the first hash is used")
                    }
                } else {
                    context.note(at + ".pinnedPeerCertificateSHA256", .invalid, .error, "Certificate pin is not a SHA-256 hash in hex")
                }
            }
            if let names = tls.verifyPeerCertificateByName, !names.isEmpty {
                let list = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                b.set("name-cert-verify", list.first)
                if list.count > 1 {
                    context.note(at + ".verifyPeerCertificateByName", .dropped, .warning, "Mihomo verifies one name; only the first is used")
                }
            }
        case .reality(let reality):
            guard allowReality else {
                context.note(at, .unsupported, .error, "REALITY is not available for this protocol in Mihomo")
                return
            }
            if tlsFlag { b.set("tls", true) }
            if let sni = reality.serverName, !sni.isEmpty, let key = sniKey {
                b.set(key, sni)
            } else {
                context.note(at + ".serverName", .invalid, .error, "REALITY needs a server name")
            }
            let fingerprint = reality.fingerprint?.lowercased() ?? ""
            if fingerprint.isEmpty {
                b.set("client-fingerprint", "chrome")
                context.note(at + ".fingerprint", .migrated, .info, "REALITY needs a uTLS fingerprint; 'chrome' is used")
            } else if MihomoConfigCompiler.clientFingerprints.contains(fingerprint) && fingerprint != "randomized" {
                b.set("client-fingerprint", fingerprint)
            } else {
                context.note(at + ".fingerprint", .unsupported, .error, "Mihomo's REALITY cannot use the fingerprint '\(fingerprint)'")
            }
            guard !reality.publicKey.isEmpty else {
                context.note(at + ".publicKey", .invalid, .error, "REALITY public key is missing")
                return
            }
            var opts = YAMLMappingBuilder()
            opts.set("public-key", reality.publicKey)
            if let shortID = reality.shortID, !shortID.isEmpty {
                opts.set("short-id", shortID)
            }
            // The core strips the X25519MLKEM768 key share from the Client Hello unless told otherwise, and the
            // REALITY server of Xray 26.11.9 (xtls/reality 4bb46b2afd8b, tls.go) rejects such a Client Hello
            // (Cores/MihomoBridge/engine/protocols_test.go).
            opts.set("support-x25519mlkem768", true)
            b.set("reality-opts", opts.node)
            if let spiderX = reality.spiderX, !spiderX.isEmpty {
                context.note(at + ".spiderX", .dropped, .info, "Mihomo's REALITY client has no spider path")
            }
            if let verify = reality.mldsa65Verify, !verify.isEmpty {
                context.note(at + ".mldsa65Verify", .unsupported, .warning, "Mihomo does not verify the ML-DSA-65 signature of a REALITY server; only the X25519 authentication applies")
            }
        }
    }

    /// Transport keys of VLESS, VMess and Trojan.
    private func applyTransport(_ outbound: Outbound, protocolName: String, _ b: inout YAMLMappingBuilder, _ context: inout XrayOutboundContext) {
        let at = "stream.transport"
        let isVLESS = protocolName == "vless"
        switch outbound.stream.transport {
        case .tcp(let tcp):
            guard let http = tcp.httpObfuscation else { return }
            guard protocolName != "trojan" else {
                context.note(at + ".httpObfuscation", .unsupported, .error, "Mihomo's Trojan has no HTTP header camouflage")
                return
            }
            b.set("network", "http")
            var opts = YAMLMappingBuilder()
            if !http.paths.isEmpty { opts.set("path", strings: http.paths) }
            if !http.hosts.isEmpty {
                opts.set("headers", YAMLNode.mapping([YAMLPair("Host", .sequence(http.hosts.map { .string($0) }))]))
            }
            b.set("http-opts", opts.node)
        case .webSocket(let ws):
            b.set("network", "ws")
            b.set("ws-opts", webSocketOptions(path: ws.path, host: ws.host, upgrade: false))
        case .httpUpgrade(let hu):
            b.set("network", "ws")
            b.set("ws-opts", webSocketOptions(path: hu.path, host: hu.host, upgrade: true))
        case .grpc(let grpc):
            b.set("network", "grpc")
            var opts = YAMLMappingBuilder()
            if !grpc.serviceName.isEmpty { opts.set("grpc-service-name", grpc.serviceName) }
            b.set("grpc-opts", opts.node)
            if !grpc.authority.isEmpty {
                context.note(at + ".authority", .dropped, .warning, "Mihomo's gRPC transport has no authority setting")
            }
            if grpc.multiMode {
                context.note(at + ".multiMode", .approximated, .warning, "Mihomo's gRPC transport has no multi mode; one stream per connection is used")
            }
        case .http2(let h2):
            guard protocolName != "trojan" else {
                context.note(at, .unsupported, .error, "Mihomo's Trojan has no HTTP/2 transport")
                return
            }
            b.set("network", "h2")
            var opts = YAMLMappingBuilder()
            if !h2.hosts.isEmpty { opts.set("host", strings: h2.hosts) }
            if !h2.path.isEmpty { opts.set("path", h2.path) }
            b.set("h2-opts", opts.node)
        case .xhttp(let xhttp):
            guard isVLESS else {
                context.note(at, .unsupported, .error, "Mihomo has XHTTP only for VLESS")
                return
            }
            b.set("network", "xhttp")
            var opts = YAMLMappingBuilder()
            if !xhttp.path.isEmpty { opts.set("path", xhttp.path) }
            if !xhttp.host.isEmpty { opts.set("host", xhttp.host) }
            if !xhttp.mode.isEmpty {
                if ["auto", "packet-up", "stream-up", "stream-one"].contains(xhttp.mode) {
                    opts.set("mode", xhttp.mode)
                } else {
                    context.note(at + ".mode", .invalid, .error, "Unknown XHTTP mode")
                }
            }
            if let download = xhttp.download {
                if xhttp.mode == "stream-one" {
                    context.note(at + ".download", .invalid, .error, "XHTTP mode 'stream-one' cannot have a separate download leg")
                }
                opts.set("download-settings", downloadSettings(download, &context))
            }
            b.set("xhttp-opts", opts.node)
            context.note(at, .untested, .info, "XHTTP with Mihomo against Xray has no interoperability test")
        case .quic:
            context.note(at, .unsupported, .error, "Mihomo has no QUIC transport for \(protocolName)")
        case .kcp:
            context.note(at, .unsupported, .error, "Mihomo has no mKCP transport for \(protocolName) as compiled from the model")
        case .native:
            context.note(at, .invalid, .error, "\(protocolName) needs a stream transport")
        }
    }

    private func webSocketOptions(path: String, host: String, upgrade: Bool) -> YAMLNode {
        var opts = YAMLMappingBuilder()
        opts.set("path", path.isEmpty ? "/" : path)
        if !host.isEmpty {
            opts.set("headers", YAMLNode.mapping([YAMLPair("Host", .string(host))]))
        }
        if upgrade { opts.set("v2ray-http-upgrade", true) }
        return opts.node
    }

    private func downloadSettings(_ download: XHTTPDownload, _ context: inout XrayOutboundContext) -> YAMLNode {
        let at = "stream.transport.download"
        var d = YAMLMappingBuilder()
        guard case .xhttp(let leg) = download.stream.transport else {
            context.note(at + ".stream.transport", .unsupported, .error, "The download leg must be XHTTP in Mihomo")
            return d.node
        }
        if !leg.path.isEmpty { d.set("path", leg.path) }
        if !leg.host.isEmpty { d.set("host", leg.host) }
        if leg.download != nil {
            context.note(at + ".stream.transport.download", .invalid, .error, "A download leg cannot have its own download leg")
        }
        d.set("server", download.server.host)
        d.set("port", Int(download.server.port))
        var nested = context
        nested.issues = []
        var sub = YAMLMappingBuilder()
        applySecurity(download.stream.security, sniKey: "servername", allowReality: true, &sub, &nested)
        for issue in nested.issues {
            let suffix = issue.path.hasPrefix(context.path + ".") ? String(issue.path.dropFirst(context.path.count + 1)) : issue.path
            context.note(at + "." + suffix, issue.kind, issue.severity, issue.detail)
        }
        for pair in sub.pairs { d.set(pair.key, pair.value) }
        return d.node
    }

    /// SIP003 plugins Mihomo runs in-process: simple-obfs and v2ray-plugin (websocket mode).
    private func applyPlugin(_ plugin: ShadowsocksPlugin, _ b: inout YAMLMappingBuilder, _ context: inout XrayOutboundContext) {
        var values: [String: String] = [:]
        var flags = Set<String>()
        for item in plugin.options.split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] } else if let flag = parts.first { flags.insert(flag) }
        }
        var opts = YAMLMappingBuilder()
        switch plugin.name {
        case "obfs-local", "simple-obfs", "obfs":
            b.set("plugin", "obfs")
            let mode = values["obfs"] ?? "http"
            guard mode == "http" || mode == "tls" else {
                context.note("settings.plugin", .invalid, .error, "simple-obfs mode must be 'http' or 'tls'")
                return
            }
            opts.set("mode", mode)
            opts.set("host", values["obfs-host"])
        case "v2ray-plugin":
            b.set("plugin", "v2ray-plugin")
            let mode = values["mode"] ?? "websocket"
            guard mode == "websocket" else {
                context.note("settings.plugin", .unsupported, .error, "Mihomo's v2ray-plugin supports the websocket mode only")
                return
            }
            opts.set("mode", mode)
            opts.set("host", values["host"])
            opts.set("path", values["path"])
            if flags.contains("tls") { opts.set("tls", true) }
            if flags.contains("mux") { opts.set("mux", true) }
        default:
            context.note("settings.plugin", .unsupported, .error, "Mihomo cannot run the SIP003 plugin '\(plugin.name)'")
            return
        }
        b.set("plugin-opts", opts.node)
        context.note("settings.plugin", .untested, .info, "Shadowsocks plugins with Mihomo have no interoperability test")
    }
}
