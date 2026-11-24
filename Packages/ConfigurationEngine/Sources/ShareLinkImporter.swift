import Foundation
import DomainModels

/// Converts one share link into an `Outbound` plus a report of everything that
/// did not become a typed field. Pure function of its input: no I/O, no global state.
public struct ShareLinkImporter: Sendable {
    public var limits: ImportLimits

    public init(limits: ImportLimits = .standard) {
        self.limits = limits
    }

    /// Schemes `importLink(_:)` accepts.
    public static let supportedSchemes: [String] = [
        "vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic",
        "socks", "socks5", "socks4", "socks4a", "wireguard", "wg",
    ]

    public static func isSupportedScheme(_ scheme: String) -> Bool {
        return supportedSchemes.contains(scheme.lowercased())
    }

    public func importLink(_ text: String) throws -> ImportedOutbound {
        let size = text.utf8.count
        guard size <= limits.maximumLinkBytes else {
            throw ImportError.inputTooLarge(limit: limits.maximumLinkBytes, actual: size)
        }
        let link = Text.trimmed(text)
        guard !link.isEmpty else {
            throw ImportError.emptyInput
        }
        for byte in link.utf8 where byte < 0x20 || byte == 0x7F {
            throw ImportError.malformedLink(reason: "contains control characters")
        }
        guard let (scheme, rest) = ParsedURI.splitScheme(link) else {
            throw ImportError.malformedLink(reason: "missing scheme")
        }
        guard !rest.isEmpty else {
            throw ImportError.malformedLink(reason: "empty body")
        }

        var report = ImportReport(scheme: scheme)
        var outbound: Outbound
        switch scheme {
        case "vless":
            outbound = try LinkParsers.vless(link, limits: limits, report: &report)
        case "vmess":
            outbound = try LinkParsers.vmess(link, rest: rest, limits: limits, report: &report)
        case "trojan":
            outbound = try LinkParsers.trojan(link, limits: limits, report: &report)
        case "ss":
            outbound = try LinkParsers.shadowsocks(link, rest: rest, limits: limits, report: &report)
        case "hysteria2", "hy2":
            outbound = try LinkParsers.hysteria2(link, limits: limits, report: &report)
        case "tuic":
            outbound = try LinkParsers.tuic(link, limits: limits, report: &report)
        case "socks", "socks5", "socks4", "socks4a":
            outbound = try LinkParsers.socks(link, limits: limits, report: &report)
        case "wireguard", "wg":
            outbound = try LinkParsers.wireGuard(link, limits: limits, report: &report)
        default:
            throw ImportError.unsupportedScheme(scheme)
        }
        outbound.unsupported = report.unsupported
        return ImportedOutbound(outbound: outbound, report: report)
    }
}

/// Helpers shared by the per-scheme parsers.
enum LinkSupport {
    static func endpoint(
        _ uri: ParsedURI,
        defaultPort: UInt16?,
        report: inout ImportReport
    ) throws -> ServerEndpoint {
        if let rawPort = uri.rawPort {
            guard let port = Text.parsePort(rawPort) else {
                throw ImportError.invalidField(name: "port", reason: "not a number in 1...65535")
            }
            return ServerEndpoint(host: uri.host, port: port)
        }
        guard let fallback = defaultPort else {
            throw ImportError.missingField("port")
        }
        report.warn(.defaultApplied, "Port is missing; \(fallback) assumed")
        return ServerEndpoint(host: uri.host, port: fallback)
    }

    /// Display name from the fragment; the server address when the link has none.
    static func name(rawFragment: String?, server: ServerEndpoint, report: inout ImportReport) -> String {
        if let raw = rawFragment, !raw.isEmpty {
            guard let decoded = PercentCoding.decode(raw) else {
                report.warn(.malformedEncoding, "Malformed percent-encoding in the name; raw text kept")
                return raw
            }
            let name = Text.trimmed(decoded)
            if !name.isEmpty {
                return name
            }
        }
        report.warn(.defaultApplied, "Link has no name; server address used")
        return server.authority
    }

    static func name(_ candidate: String?, server: ServerEndpoint, report: inout ImportReport) -> String {
        if let candidate = candidate {
            let name = Text.trimmed(candidate)
            if !name.isEmpty {
                return name
            }
        }
        report.warn(.defaultApplied, "Link has no name; server address used")
        return server.authority
    }

    /// A path other than empty or `/` has no meaning in these links; it is recorded.
    static func recordPath(_ uri: ParsedURI, report: inout ImportReport) {
        if !uri.rawPath.isEmpty && uri.rawPath != "/" {
            report.record("path", value: uri.rawPath, location: .path, reason: .unknown)
        }
    }

    /// Percent-decoded user information; throws when absent, empty or malformed.
    static func requiredUserInfo(_ uri: ParsedURI, field: String) throws -> String {
        guard let raw = uri.rawUserInfo, !raw.isEmpty else {
            throw ImportError.missingField(field)
        }
        guard let decoded = PercentCoding.decode(raw), !decoded.isEmpty else {
            throw ImportError.invalidField(name: field, reason: "malformed percent-encoding")
        }
        return decoded
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let value = Text.trimmed(text)
        return value.isEmpty ? nil : value
    }

    static func looksLikeUUID(_ text: String) -> Bool {
        return UUID(uuidString: text) != nil
    }

    /// `443`, `443,5000-6000`, `20000-50000`. At most 64 items.
    static func parsePortList(_ text: String) -> [PortRange]? {
        let items = Array(text.utf8).split(separator: 0x2C, omittingEmptySubsequences: false)
        guard !items.isEmpty, items.count <= 64 else { return nil }
        var ranges: [PortRange] = []
        for item in items {
            let itemText = String(decoding: item, as: UTF8.self)
            let (lowerText, upperText) = Text.cutFirst(itemText, at: 0x2D)
            guard let lower = Text.parsePort(lowerText) else { return nil }
            var upper = lower
            if let upperText = upperText {
                guard let parsed = Text.parsePort(upperText) else { return nil }
                upper = parsed
            }
            guard lower <= upper else { return nil }
            ranges.append(PortRange(lower: lower, upper: upper))
        }
        return ranges
    }
}
