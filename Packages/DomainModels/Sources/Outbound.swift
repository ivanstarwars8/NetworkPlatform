import Foundation

/// Proxy protocols listed in `PROTOCOL_MATRIX.md` §1.
/// Presence in this enum does not mean an importer or a compiler exists for the protocol.
public enum ProxyProtocolKind: String, Codable, Hashable, Sendable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks
    case socks
    case http
    case hysteria
    case hysteria2
    case tuic
    case wireGuard = "wireguard"
    case amneziaWG = "amneziawg"
    case masque
    case shadowTLS = "shadowtls"
    case anyTLS = "anytls"
    case snell
    case naive
    case ssh
    case tor
    case tailscale
    case openVPN = "openvpn"
    case openConnect = "openconnect"
}

// MARK: - Protocol settings

public struct VLESSSettings: Codable, Hashable, Sendable {
    /// For example `xtls-rprx-vision`; `nil` when no flow is used.
    public var flow: String?
    /// `none` or a VLESS Encryption string.
    public var encryption: String
    public var packetEncoding: String?

    public init(flow: String? = nil, encryption: String = "none", packetEncoding: String? = nil) {
        self.flow = flow
        self.encryption = encryption
        self.packetEncoding = packetEncoding
    }
}

public struct VMessSettings: Codable, Hashable, Sendable {
    /// `auto`, `aes-128-gcm`, `chacha20-poly1305`, `none`, `zero`.
    public var cipher: String
    public var alterID: Int

    public init(cipher: String = "auto", alterID: Int = 0) {
        self.cipher = cipher
        self.alterID = alterID
    }
}

/// SIP003 plugin: name and the raw option string after the first `;`.
public struct ShadowsocksPlugin: Codable, Hashable, Sendable {
    public var name: String
    public var options: String

    public init(name: String, options: String = "") {
        self.name = name
        self.options = options
    }
}

public struct ShadowsocksSettings: Codable, Hashable, Sendable {
    public var method: String
    public var plugin: ShadowsocksPlugin?

    public init(method: String, plugin: ShadowsocksPlugin? = nil) {
        self.method = method
        self.plugin = plugin
    }
}

public struct SOCKSSettings: Codable, Hashable, Sendable {
    public enum Version: String, Codable, Hashable, Sendable, CaseIterable {
        case v4 = "4"
        case v4a = "4a"
        case v5 = "5"
    }

    public var version: Version

    public init(version: Version = .v5) {
        self.version = version
    }
}

public struct Hysteria2Obfuscation: Codable, Hashable, Sendable {
    /// Only `salamander` is defined at the time of writing.
    public var type: String
    public var password: SecretValue

    public init(type: String, password: SecretValue) {
        self.type = type
        self.password = password
    }
}

public struct Hysteria2Settings: Codable, Hashable, Sendable {
    public var obfuscation: Hysteria2Obfuscation?
    /// Port hopping set; empty when the server uses the single `Outbound.server.port`.
    public var serverPorts: [PortRange]
    public var hopIntervalSeconds: Int?
    /// Bandwidth hints as written by the source (units are part of the string).
    public var uploadBandwidth: String?
    public var downloadBandwidth: String?

    public init(
        obfuscation: Hysteria2Obfuscation? = nil,
        serverPorts: [PortRange] = [],
        hopIntervalSeconds: Int? = nil,
        uploadBandwidth: String? = nil,
        downloadBandwidth: String? = nil
    ) {
        self.obfuscation = obfuscation
        self.serverPorts = serverPorts
        self.hopIntervalSeconds = hopIntervalSeconds
        self.uploadBandwidth = uploadBandwidth
        self.downloadBandwidth = downloadBandwidth
    }
}

public struct TUICSettings: Codable, Hashable, Sendable {
    public var congestionControl: String?
    public var udpRelayMode: String?

    public init(congestionControl: String? = nil, udpRelayMode: String? = nil) {
        self.congestionControl = congestionControl
        self.udpRelayMode = udpRelayMode
    }
}

public struct WireGuardSettings: Codable, Hashable, Sendable {
    public var peerPublicKey: String
    /// Interface addresses, usually in CIDR form.
    public var localAddresses: [String]
    public var allowedIPs: [String]
    /// Three reserved bytes of the WireGuard header (used by some providers).
    public var reserved: [UInt8]
    public var mtu: Int?
    public var persistentKeepaliveSeconds: Int?

    public init(
        peerPublicKey: String,
        localAddresses: [String] = [],
        allowedIPs: [String] = [],
        reserved: [UInt8] = [],
        mtu: Int? = nil,
        persistentKeepaliveSeconds: Int? = nil
    ) {
        self.peerPublicKey = peerPublicKey
        self.localAddresses = localAddresses
        self.allowedIPs = allowedIPs
        self.reserved = reserved
        self.mtu = mtu
        self.persistentKeepaliveSeconds = persistentKeepaliveSeconds
    }
}

/// Protocol-specific part of an outbound. The protocol kind is derived from this value,
/// so kind and settings cannot disagree.
public enum ProtocolSettings: Codable, Hashable, Sendable {
    case vless(VLESSSettings)
    case vmess(VMessSettings)
    case trojan
    case shadowsocks(ShadowsocksSettings)
    case socks(SOCKSSettings)
    case http
    case hysteria2(Hysteria2Settings)
    case tuic(TUICSettings)
    case wireGuard(WireGuardSettings)
    /// A protocol without typed settings in the model yet.
    case other(ProxyProtocolKind)

    public var kind: ProxyProtocolKind {
        switch self {
        case .vless: return .vless
        case .vmess: return .vmess
        case .trojan: return .trojan
        case .shadowsocks: return .shadowsocks
        case .socks: return .socks
        case .http: return .http
        case .hysteria2: return .hysteria2
        case .tuic: return .tuic
        case .wireGuard: return .wireGuard
        case .other(let kind): return kind
        }
    }
}

// MARK: - Outbound

/// One proxy server, independent of any engine's configuration format.
public struct Outbound: Codable, Hashable, Sendable {
    /// Identifier inside a profile; groups refer to outbounds by tag.
    public var tag: String
    /// Display name.
    public var name: String
    public var server: ServerEndpoint
    public var credentials: Credentials
    public var settings: ProtocolSettings
    public var stream: StreamSettings
    public var extras: EngineExtras
    /// Everything the source contained that did not become a typed field.
    public var unsupported: [UnsupportedParameter]

    public init(
        tag: String,
        name: String,
        server: ServerEndpoint,
        credentials: Credentials = Credentials(),
        settings: ProtocolSettings,
        stream: StreamSettings = StreamSettings(),
        extras: EngineExtras = EngineExtras(),
        unsupported: [UnsupportedParameter] = []
    ) {
        self.tag = tag
        self.name = name
        self.server = server
        self.credentials = credentials
        self.settings = settings
        self.stream = stream
        self.extras = extras
        self.unsupported = unsupported
    }

    public var kind: ProxyProtocolKind {
        return settings.kind
    }
}

// MARK: - Secrets

extension Outbound {
    /// Slots that still hold an inline secret value.
    public var inlineSecretSlots: [SecretSlot] {
        var slots: [SecretSlot] = []
        if let value = credentials.userID, value.isInline { slots.append(.userID) }
        if let value = credentials.password, value.isInline { slots.append(.password) }
        if let value = credentials.privateKey, value.isInline { slots.append(.privateKey) }
        if let value = credentials.preSharedKey, value.isInline { slots.append(.preSharedKey) }
        if case .hysteria2(let settings) = self.settings,
           let obfuscation = settings.obfuscation,
           obfuscation.password.isInline {
            slots.append(.obfuscationPassword)
        }
        switch stream.transport {
        case .quic(let settings):
            if let key = settings.key, key.isInline { slots.append(.transportKey) }
        case .kcp(let settings):
            if let seed = settings.seed, seed.isInline { slots.append(.transportKey) }
        default:
            break
        }
        return slots
    }

    /// Returns a copy in which every inline secret is replaced by the reference
    /// returned by `store`. `store` receives the slot and the inline value and is
    /// expected to persist the value (for example in the Keychain).
    public func replacingInlineSecrets(
        _ store: (SecretSlot, String) throws -> SecretReference
    ) rethrows -> Outbound {
        var copy = self
        copy.credentials.userID = try Outbound.replace(credentials.userID, slot: .userID, store: store)
        copy.credentials.password = try Outbound.replace(credentials.password, slot: .password, store: store)
        copy.credentials.privateKey = try Outbound.replace(credentials.privateKey, slot: .privateKey, store: store)
        copy.credentials.preSharedKey = try Outbound.replace(
            credentials.preSharedKey, slot: .preSharedKey, store: store
        )
        if case .hysteria2(var settings) = self.settings, var obfuscation = settings.obfuscation {
            if let replaced = try Outbound.replace(obfuscation.password, slot: .obfuscationPassword, store: store) {
                obfuscation.password = replaced
            }
            settings.obfuscation = obfuscation
            copy.settings = .hysteria2(settings)
        }
        switch stream.transport {
        case .quic(var settings):
            settings.key = try Outbound.replace(settings.key, slot: .transportKey, store: store)
            copy.stream.transport = .quic(settings)
        case .kcp(var settings):
            settings.seed = try Outbound.replace(settings.seed, slot: .transportKey, store: store)
            copy.stream.transport = .kcp(settings)
        default:
            break
        }
        return copy
    }

    private static func replace(
        _ value: SecretValue?,
        slot: SecretSlot,
        store: (SecretSlot, String) throws -> SecretReference
    ) rethrows -> SecretValue? {
        guard let value = value else { return nil }
        switch value {
        case .inline(let plain):
            return .reference(try store(slot, plain))
        case .reference:
            return value
        }
    }
}
