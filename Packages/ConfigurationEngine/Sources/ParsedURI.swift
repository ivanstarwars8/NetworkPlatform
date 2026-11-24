import Foundation
import DomainModels

/// Hand-written splitter for `scheme://[userinfo@]host[:port][/path][?query][#fragment]`.
///
/// Foundation's URL types are deliberately not used: their handling of IDN hosts,
/// base64 user information and non-numeric ports differs between platforms.
/// All components are returned raw (still percent-encoded) except the host.
struct ParsedURI {
    var scheme: String
    var rawUserInfo: String?
    /// Host without brackets, percent-decoded if it was encoded, otherwise untouched.
    var host: String
    var isIPv6Literal: Bool
    /// Text after the host's colon; may be a port list for Hysteria2.
    var rawPort: String?
    var rawPath: String
    var rawQuery: String?
    var rawFragment: String?

    /// Lowercased scheme and the text after `://`, or `nil` if the text has no valid scheme.
    static func splitScheme(_ text: String) -> (scheme: String, rest: String)? {
        let bytes = Array(text.utf8)
        guard let colon = bytes.firstIndex(of: 0x3A), colon > 0, colon <= 32 else { return nil }
        guard bytes.count >= colon + 3, bytes[colon + 1] == 0x2F, bytes[colon + 2] == 0x2F else { return nil }
        for byte in bytes[..<colon] {
            guard isSchemeByte(byte) else { return nil }
        }
        let scheme = String(decoding: bytes[..<colon], as: UTF8.self).lowercased()
        let rest = String(decoding: bytes[(colon + 3)...], as: UTF8.self)
        return (scheme, rest)
    }

    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2D, 0x2E:
            return true
        default:
            return false
        }
    }

    static func parse(_ text: String) throws -> ParsedURI {
        guard let (scheme, rest) = splitScheme(text) else {
            throw ImportError.malformedLink(reason: "missing scheme")
        }
        let (beforeFragment, fragment) = Text.cutFirst(rest, at: 0x23)
        let (beforeQuery, query) = Text.cutFirst(beforeFragment, at: 0x3F)

        // User information ends at the last '@' of the authority. When the authority
        // (text before the first '/') has no '@' but the rest does, the user information
        // itself contains '/', as standard-alphabet base64 may.
        let bytes = Array(beforeQuery.utf8)
        let authorityEnd = bytes.firstIndex(of: 0x2F) ?? bytes.count
        var separator = bytes[..<authorityEnd].lastIndex(of: 0x40)
        if separator == nil {
            separator = bytes.lastIndex(of: 0x40)
        }

        var rawUserInfo: String?
        let hostAndPath: String
        if let at = separator {
            rawUserInfo = String(decoding: bytes[..<at], as: UTF8.self)
            hostAndPath = String(decoding: bytes[(at + 1)...], as: UTF8.self)
        } else {
            hostAndPath = beforeQuery
        }

        let (hostPort, pathTail) = Text.cutFirst(hostAndPath, at: 0x2F)
        let rawPath: String
        if let pathTail = pathTail {
            rawPath = "/" + pathTail
        } else {
            rawPath = ""
        }

        let parsedHost = try parseHostPort(hostPort)
        return ParsedURI(
            scheme: scheme,
            rawUserInfo: rawUserInfo,
            host: parsedHost.host,
            isIPv6Literal: parsedHost.isIPv6Literal,
            rawPort: parsedHost.rawPort,
            rawPath: rawPath,
            rawQuery: query,
            rawFragment: fragment
        )
    }

    /// Splits `host`, `host:port`, `[v6]` or `[v6]:port`.
    static func parseHostPort(_ text: String) throws -> (host: String, isIPv6Literal: Bool, rawPort: String?) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else {
            throw ImportError.missingField("host")
        }
        if bytes[0] == 0x5B {
            guard let close = bytes.firstIndex(of: 0x5D) else {
                throw ImportError.malformedLink(reason: "unterminated IPv6 literal")
            }
            let inner = String(decoding: bytes[1..<close], as: UTF8.self)
            guard isValidIPv6Literal(inner) else {
                throw ImportError.invalidField(name: "host", reason: "not an IPv6 literal")
            }
            let tail = bytes[(close + 1)...]
            if tail.isEmpty {
                return (inner, true, nil)
            }
            guard tail.first == 0x3A else {
                throw ImportError.malformedLink(reason: "unexpected text after IPv6 literal")
            }
            return (inner, true, String(decoding: tail.dropFirst(), as: UTF8.self))
        }

        var hostText = text
        var rawPort: String?
        if let colon = bytes.lastIndex(of: 0x3A) {
            hostText = String(decoding: bytes[..<colon], as: UTF8.self)
            rawPort = String(decoding: bytes[(colon + 1)...], as: UTF8.self)
            if hostText.utf8.contains(0x3A) {
                throw ImportError.invalidField(name: "host", reason: "IPv6 literal must be enclosed in brackets")
            }
        }
        if hostText.utf8.contains(0x25) {
            guard let decoded = PercentCoding.decode(hostText) else {
                throw ImportError.invalidField(name: "host", reason: "malformed percent-encoding")
            }
            hostText = decoded
        }
        guard isValidHostName(hostText) else {
            throw ImportError.invalidField(name: "host", reason: "empty or contains forbidden characters")
        }
        return (hostText, false, rawPort)
    }

    /// Syntactic check only: hexadecimal groups, colons, an optional embedded IPv4 tail
    /// and an optional zone identifier. The address is not normalised.
    static func isValidIPv6Literal(_ text: String) -> Bool {
        let (address, zone) = Text.cutFirst(text, at: 0x25)
        let bytes = Array(address.utf8)
        guard bytes.count >= 2, bytes.count <= 45, bytes.contains(0x3A) else { return false }
        for byte in bytes {
            let isHex = PercentCoding.hexValue(byte) != nil
            guard isHex || byte == 0x3A || byte == 0x2E else { return false }
        }
        if let zone = zone {
            let zoneBytes = Array(zone.utf8)
            guard !zoneBytes.isEmpty, zoneBytes.count <= 32 else { return false }
            for byte in zoneBytes {
                guard PercentCoding.isUnreserved(byte) else { return false }
            }
        }
        return true
    }

    /// Accepts ASCII, punycode and Unicode names as written; rejects only what cannot be a host.
    static func isValidHostName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024 else { return false }
        let forbidden = Array("\"#/<>?@[\\]^`{|}:".utf8)
        for byte in bytes {
            if byte <= 0x20 || byte == 0x7F { return false }
            if forbidden.contains(byte) { return false }
        }
        return true
    }
}

/// Ordered key/value parameters with bookkeeping of what the importer consumed.
/// Whatever is left at the end is recorded, never dropped.
struct ParameterBag {
    struct Item {
        var name: String
        var value: String
        var consumed: Bool
    }

    private(set) var items: [Item] = []
    let location: UnsupportedParameter.Location

    /// Builds the bag from a raw query string (`a=1&b=2`).
    init(rawQuery: String?, limits: ImportLimits, report: inout ImportReport) throws {
        self.location = .query
        guard let rawQuery = rawQuery, !rawQuery.isEmpty else { return }
        let parts = Array(rawQuery.utf8).split(separator: 0x26, omittingEmptySubsequences: true)
        guard parts.count <= limits.maximumParameters else {
            throw ImportError.tooManyParameters(limit: limits.maximumParameters)
        }
        for part in parts {
            let pair = String(decoding: part, as: UTF8.self)
            let (rawName, rawValue) = Text.cutFirst(pair, at: 0x3D)
            let name = ParameterBag.decode(rawName, what: "parameter name", report: &report)
            let value = ParameterBag.decode(rawValue ?? "", what: "value of '\(name)'", report: &report)
            add(name: name, value: value, report: &report)
        }
    }

    /// Builds the bag from already decoded pairs.
    init(pairs: [(name: String, value: String)], location: UnsupportedParameter.Location, report: inout ImportReport) {
        self.location = location
        for pair in pairs {
            add(name: pair.name, value: pair.value, report: &report)
        }
    }

    private static func decode(_ raw: String, what: String, report: inout ImportReport) -> String {
        if let decoded = PercentCoding.decode(raw) {
            return decoded
        }
        report.warn(.malformedEncoding, "Malformed percent-encoding in \(what); raw text kept")
        return raw
    }

    private mutating func add(name: String, value: String, report: inout ImportReport) {
        if items.contains(where: { $0.name == name }) {
            report.record(
                name, value: value, location: location, reason: .duplicate,
                detail: "Repeated parameter; the first occurrence is used"
            )
            return
        }
        items.append(Item(name: name, value: value, consumed: false))
    }

    func contains(_ name: String) -> Bool {
        return items.contains { $0.name == name && !$0.consumed }
    }

    /// Removes the parameter from the leftovers and returns its value.
    mutating func take(_ name: String) -> String? {
        guard let index = items.firstIndex(where: { $0.name == name && !$0.consumed }) else { return nil }
        items[index].consumed = true
        return items[index].value
    }

    /// Like `take`, but an empty value counts as absent (it carries no information).
    mutating func takeNonEmpty(_ name: String) -> String? {
        guard let value = take(name), !value.isEmpty else { return nil }
        return value
    }

    /// Takes the first present alias. Other aliases with a different value are recorded as duplicates.
    mutating func takeFirst(of names: [String], report: inout ImportReport) -> String? {
        var result: String?
        var usedName = ""
        for name in names {
            guard let value = takeNonEmpty(name) else { continue }
            if let existing = result {
                if existing != value {
                    report.record(
                        name, value: value, location: location, reason: .duplicate,
                        detail: "Conflicts with '\(usedName)', which is used"
                    )
                }
            } else {
                result = value
                usedName = name
            }
        }
        return result
    }

    /// Records a consumed parameter whose value could not be used.
    func recordInvalid(_ name: String, value: String, detail: String, report: inout ImportReport) {
        report.record(name, value: value, location: location, reason: .invalidValue, detail: detail)
    }

    /// Records every parameter nobody consumed. `knownElsewhere` are names that are valid
    /// in other contexts (another transport or security) and are therefore "not applicable"
    /// rather than "unknown".
    mutating func finish(knownElsewhere: Set<String>, report: inout ImportReport) {
        for index in items.indices where !items[index].consumed {
            items[index].consumed = true
            let item = items[index]
            if knownElsewhere.contains(item.name) {
                report.record(
                    item.name, value: item.value, location: location, reason: .notApplicable,
                    detail: "Not used with the selected transport or security"
                )
            } else {
                report.record(item.name, value: item.value, location: location, reason: .unknown)
            }
        }
    }
}
