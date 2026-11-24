import Foundation

/// Server address. `host` is kept exactly as written by the source:
/// a domain (ASCII, punycode or Unicode — never converted), an IPv4 literal
/// or an IPv6 literal without brackets.
public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// IPv6 literals are the only hosts that contain a colon.
    public var isIPv6Literal: Bool {
        return host.utf8.contains(0x3A)
    }

    /// `host:port`, with brackets around an IPv6 literal.
    public var authority: String {
        if isIPv6Literal {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}

/// Inclusive port range.
public struct PortRange: Codable, Hashable, Sendable {
    public var lower: UInt16
    public var upper: UInt16

    public init(lower: UInt16, upper: UInt16) {
        self.lower = lower
        self.upper = upper
    }

    public var isSinglePort: Bool {
        return lower == upper
    }
}

// MARK: - Transport

/// HTTP/1.1 request camouflage of the raw TCP transport (`headerType=http`).
public struct HTTPObfuscation: Codable, Hashable, Sendable {
    public var hosts: [String]
    public var paths: [String]

    public init(hosts: [String] = [], paths: [String] = []) {
        self.hosts = hosts
        self.paths = paths
    }
}

public struct TCPSettings: Codable, Hashable, Sendable {
    public var httpObfuscation: HTTPObfuscation?

    public init(httpObfuscation: HTTPObfuscation? = nil) {
        self.httpObfuscation = httpObfuscation
    }
}

/// In the transport structs below an empty string means "not specified by the source".
public struct WebSocketSettings: Codable, Hashable, Sendable {
    public var path: String
    public var host: String

    public init(path: String = "", host: String = "") {
        self.path = path
        self.host = host
    }
}

public struct GRPCSettings: Codable, Hashable, Sendable {
    public var serviceName: String
    public var authority: String
    public var multiMode: Bool

    public init(serviceName: String = "", authority: String = "", multiMode: Bool = false) {
        self.serviceName = serviceName
        self.authority = authority
        self.multiMode = multiMode
    }
}

public struct HTTP2Settings: Codable, Hashable, Sendable {
    public var hosts: [String]
    public var path: String

    public init(hosts: [String] = [], path: String = "") {
        self.hosts = hosts
        self.path = path
    }
}

public struct HTTPUpgradeSettings: Codable, Hashable, Sendable {
    public var path: String
    public var host: String

    public init(path: String = "", host: String = "") {
        self.path = path
        self.host = host
    }
}

/// Separate download leg of XHTTP: a full nested stream with its own address (ADR-0002 §3).
public struct XHTTPDownload: Codable, Hashable, Sendable {
    public var server: ServerEndpoint
    public var stream: StreamSettings

    public init(server: ServerEndpoint, stream: StreamSettings) {
        self.server = server
        self.stream = stream
    }
}

public struct XHTTPSettings: Codable, Hashable, Sendable {
    public var path: String
    public var host: String
    /// `auto`, `packet-up`, `stream-up`, `stream-one`; empty when not specified.
    public var mode: String
    public var download: XHTTPDownload?

    public init(path: String = "", host: String = "", mode: String = "", download: XHTTPDownload? = nil) {
        self.path = path
        self.host = host
        self.mode = mode
        self.download = download
    }
}

/// QUIC as a V2Ray transport (not the native QUIC of Hysteria2 or TUIC).
public struct QUICSettings: Codable, Hashable, Sendable {
    public var security: String
    public var key: SecretValue?
    public var headerType: String

    public init(security: String = "", key: SecretValue? = nil, headerType: String = "") {
        self.security = security
        self.key = key
        self.headerType = headerType
    }
}

public struct KCPSettings: Codable, Hashable, Sendable {
    public var seed: SecretValue?
    public var headerType: String
    public var mtu: Int?
    public var tti: Int?

    public init(seed: SecretValue? = nil, headerType: String = "", mtu: Int? = nil, tti: Int? = nil) {
        self.seed = seed
        self.headerType = headerType
        self.mtu = mtu
        self.tti = tti
    }
}

public enum Transport: Codable, Hashable, Sendable {
    case tcp(TCPSettings)
    case webSocket(WebSocketSettings)
    case grpc(GRPCSettings)
    case http2(HTTP2Settings)
    case httpUpgrade(HTTPUpgradeSettings)
    indirect case xhttp(XHTTPSettings)
    case quic(QUICSettings)
    case kcp(KCPSettings)
    /// The protocol carries its own transport (Hysteria2, TUIC, WireGuard).
    case native

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case tcp
        case webSocket
        case grpc
        case http2
        case httpUpgrade
        case xhttp
        case quic
        case kcp
        case native
    }

    public var kind: Kind {
        switch self {
        case .tcp: return .tcp
        case .webSocket: return .webSocket
        case .grpc: return .grpc
        case .http2: return .http2
        case .httpUpgrade: return .httpUpgrade
        case .xhttp: return .xhttp
        case .quic: return .quic
        case .kcp: return .kcp
        case .native: return .native
        }
    }
}

// MARK: - Security

public struct TLSSettings: Codable, Hashable, Sendable {
    public var serverName: String?
    public var alpn: [String]
    /// uTLS fingerprint name as written by the source (`chrome`, `safari`, …).
    public var fingerprint: String?
    public var allowInsecure: Bool
    public var disableSNI: Bool
    public var echConfigList: String?
    public var pinnedPeerCertificateSHA256: String?
    public var verifyPeerCertificateByName: String?

    public init(
        serverName: String? = nil,
        alpn: [String] = [],
        fingerprint: String? = nil,
        allowInsecure: Bool = false,
        disableSNI: Bool = false,
        echConfigList: String? = nil,
        pinnedPeerCertificateSHA256: String? = nil,
        verifyPeerCertificateByName: String? = nil
    ) {
        self.serverName = serverName
        self.alpn = alpn
        self.fingerprint = fingerprint
        self.allowInsecure = allowInsecure
        self.disableSNI = disableSNI
        self.echConfigList = echConfigList
        self.pinnedPeerCertificateSHA256 = pinnedPeerCertificateSHA256
        self.verifyPeerCertificateByName = verifyPeerCertificateByName
    }
}

public struct RealitySettings: Codable, Hashable, Sendable {
    public var serverName: String?
    public var fingerprint: String?
    /// Server public key (not a secret).
    public var publicKey: String
    public var shortID: String?
    public var spiderX: String?
    public var mldsa65Verify: String?

    public init(
        serverName: String? = nil,
        fingerprint: String? = nil,
        publicKey: String,
        shortID: String? = nil,
        spiderX: String? = nil,
        mldsa65Verify: String? = nil
    ) {
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.shortID = shortID
        self.spiderX = spiderX
        self.mldsa65Verify = mldsa65Verify
    }
}

public enum Security: Codable, Hashable, Sendable {
    case none
    case tls(TLSSettings)
    case reality(RealitySettings)

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case none
        case tls
        case reality
    }

    public var kind: Kind {
        switch self {
        case .none: return .none
        case .tls: return .tls
        case .reality: return .reality
        }
    }

    public var serverName: String? {
        switch self {
        case .none: return nil
        case .tls(let settings): return settings.serverName
        case .reality(let settings): return settings.serverName
        }
    }
}

// MARK: - Stream

public struct StreamSettings: Codable, Hashable, Sendable {
    public var transport: Transport
    public var security: Security

    public init(transport: Transport = .tcp(TCPSettings()), security: Security = .none) {
        self.transport = transport
        self.security = security
    }
}
