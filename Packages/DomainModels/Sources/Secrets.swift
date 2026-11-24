import Foundation

/// Opaque reference to a secret kept outside the model (Keychain, see ADR-0003).
/// The model never interprets the identifier.
public struct SecretReference: Codable, Hashable, Sendable {
    public var identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

/// A credential either carried inline (freshly imported, not yet stored)
/// or replaced by a reference to the secret store.
public enum SecretValue: Hashable, Sendable {
    case inline(String)
    case reference(SecretReference)

    public var inlineValue: String? {
        if case .inline(let value) = self { return value }
        return nil
    }

    public var secretReference: SecretReference? {
        if case .reference(let value) = self { return value }
        return nil
    }

    public var isInline: Bool {
        if case .inline = self { return true }
        return false
    }
}

extension SecretValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case inline
        case reference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case .inline:
            self = .inline(value)
        case .reference:
            self = .reference(SecretReference(identifier: value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline(let value):
            try container.encode(Kind.inline, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .reference(let reference):
            try container.encode(Kind.reference, forKey: .kind)
            try container.encode(reference.identifier, forKey: .value)
        }
    }
}

/// Inline secrets must not leak through string interpolation or logging.
extension SecretValue: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .inline:
            return "SecretValue.inline(<redacted>)"
        case .reference(let reference):
            return "SecretValue.reference(\(reference.identifier))"
        }
    }

    public var debugDescription: String {
        return description
    }
}

/// Position of a secret inside an `Outbound`.
public enum SecretSlot: String, Codable, Hashable, Sendable, CaseIterable {
    case userID
    case password
    case privateKey
    case preSharedKey
    case obfuscationPassword
    case transportKey
}

/// Credentials of an outbound. Which fields are used depends on the protocol:
/// VLESS/VMess/TUIC — `userID`; Trojan/Shadowsocks/Hysteria2 — `password`;
/// SOCKS/HTTP — `username` + `password`; WireGuard — `privateKey` (+ `preSharedKey`).
public struct Credentials: Codable, Hashable, Sendable {
    public var userID: SecretValue?
    public var username: String?
    public var password: SecretValue?
    public var privateKey: SecretValue?
    public var preSharedKey: SecretValue?

    public init(
        userID: SecretValue? = nil,
        username: String? = nil,
        password: SecretValue? = nil,
        privateKey: SecretValue? = nil,
        preSharedKey: SecretValue? = nil
    ) {
        self.userID = userID
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.preSharedKey = preSharedKey
    }
}
