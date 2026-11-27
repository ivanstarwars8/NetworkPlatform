import Foundation
import DomainModels

/// Removes configuration values (credentials, keys, server addresses, names) from text that may be shown
/// or logged: report messages of the compiler (ADR-0003 §4: configuration, keys and server addresses are
/// never written to a log).
///
/// Values are collected from an engine document: every string except those under structural keys
/// (protocol names, tags, transport names), and except a few common words. Short values of non-credential
/// keys are kept so that the text stays readable; values of credential and address keys are removed from
/// 4 characters up. Independently of the document, anything shaped like a UUID or an IP literal is removed.
/// The same rules are implemented by the bridge (`Cores/Bridge/engine/redact.go`).
public struct ConfigValueRedactor: Sendable {
    public static let placeholder = "[redacted]"

    /// Keys whose string values describe the shape of the document, not the user's data.
    static let structuralKeys: Set<String> = [
        "protocol", "network", "security", "tag", "outboundTag", "balancerTag", "inboundTag", "loglevel",
        "flow", "fingerprint", "type", "mode", "strategy", "domainStrategy", "queryStrategy", "method",
        "alpn", "congestion", "packetEncoding", "selector", "fallbackTag", "subjectSelector", "cipher",
        "headerType", "header", "auth_mode",
    ]

    /// Keys whose values are credentials or addresses: removed even when short.
    static let sensitiveKeys: Set<String> = [
        "id", "password", "pass", "user", "username", "auth", "address", "endpoint", "serverName", "serverNames",
        "publicKey", "privateKey", "secretKey", "preSharedKey", "shortId", "shortIds", "spiderX", "mldsa65Verify",
        "mldsa65Seed", "seed", "key", "host", "path", "servers", "encryption", "decryption", "certificate",
        "pinnedPeerCertificateSha256", "echConfigList", "serviceName", "dest", "target", "remotePorts",
    ]

    static let commonWords: Set<String> = [
        "none", "auto", "true", "false", "tcp", "udp", "tcp,udp", "raw", "tls", "http", "https", "reality",
        "chrome", "firefox", "safari", "random", "noauth", "freedom", "blackhole",
    ]

    static let minimumSensitiveLength = 4
    static let minimumOtherLength = 6

    private var values: Set<String> = []

    public init() {}

    /// Collects the values of an engine document.
    public init(document: JSONValue?) {
        if let document = document {
            collect(document, key: nil)
        }
    }

    /// Adds one value that must not appear in the output (e.g. a credential that did not make it into
    /// the document because it was refused).
    public mutating func add(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= ConfigValueRedactor.minimumSensitiveLength,
              !ConfigValueRedactor.commonWords.contains(trimmed.lowercased()) else { return }
        values.insert(trimmed)
    }

    private mutating func collect(_ value: JSONValue, key: String?) {
        switch value {
        case .string(let text):
            guard let key = key, !ConfigValueRedactor.structuralKeys.contains(key) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ConfigValueRedactor.commonWords.contains(trimmed.lowercased()) { return }
            let minimum = ConfigValueRedactor.sensitiveKeys.contains(key)
                ? ConfigValueRedactor.minimumSensitiveLength : ConfigValueRedactor.minimumOtherLength
            if trimmed.count >= minimum {
                values.insert(trimmed)
            }
        case .array(let items):
            for item in items {
                collect(item, key: key)
            }
        case .object(let members):
            for (name, member) in members {
                collect(member, key: name)
            }
        default:
            return
        }
    }

    public func redact(_ text: String) -> String {
        var result = text
        // Longest first, so that a value containing another is removed whole.
        // Case-insensitive: some fields are lower-cased before they are quoted.
        for value in values.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: value, with: ConfigValueRedactor.placeholder, options: .caseInsensitive)
        }
        for pattern in ConfigValueRedactor.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: ConfigValueRedactor.placeholder
            )
        }
        return result
    }

    public func redact(_ issues: [ConversionIssue]) -> [ConversionIssue] {
        issues.map { issue in
            var copy = issue
            copy.detail = redact(issue.detail)
            return copy
        }
    }

    /// UUIDs, IPv4 literals, IPv6 literals (at least two groups and a `::` or seven colons).
    // swiftlint:disable:next force_try
    static let patterns: [NSRegularExpression] = [
        "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        "(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(?![0-9.])",
        "(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?(?![0-9A-Fa-f:])",
        "(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])",
        "(?<![0-9A-Fa-f:])::[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}(?![0-9A-Fa-f:])",
    ].map { try! NSRegularExpression(pattern: $0) }
}
