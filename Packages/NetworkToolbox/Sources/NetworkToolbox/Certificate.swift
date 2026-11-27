// A read-only summary of an X.509 certificate (RFC 5280) for the TLS inspection tool: who it names, who
// issued it, when it is valid, which names it covers, the key, and the SHA-256 fingerprint. This is a
// display parser, not a validator: whether the chain is trusted is decided by the system's trust
// evaluation and reported next to the summary.

import Foundation

public struct CertificateSummary: Equatable, Sendable {
    public var subjectCommonName: String?
    public var subjectOrganization: String?
    public var issuerCommonName: String?
    public var issuerOrganization: String?
    public var serialNumberHex: String
    public var notBefore: Date?
    public var notAfter: Date?
    public var dnsNames: [String]
    public var ipAddresses: [String]
    public var publicKey: String
    public var signatureAlgorithm: String
    /// Upper-case hex, colon-separated.
    public var sha256Fingerprint: String

    /// Human name of the subject: common name, organisation, or the first DNS name.
    public var subjectTitle: String {
        subjectCommonName ?? subjectOrganization ?? dnsNames.first ?? "без имени"
    }

    public var issuerTitle: String {
        issuerCommonName ?? issuerOrganization ?? "без имени"
    }

    public enum Validity: Equatable, Sendable {
        case notYetValid
        case valid(daysLeft: Int)
        case expired
        case unknown
    }

    public func validity(at date: Date) -> Validity {
        guard let start = notBefore, let end = notAfter else { return .unknown }
        if date < start { return .notYetValid }
        if date > end { return .expired }
        return .valid(daysLeft: Int(end.timeIntervalSince(date) / 86_400))
    }

    /// Whether the certificate names `host` (RFC 6125: exact match, or a single left-most wildcard label
    /// that matches exactly one label). IP literals are compared with the IP entries.
    public func covers(host: String) -> Bool {
        let target = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if SocketEndpoint(address: target, port: 0) != nil {
            let normalised = SocketEndpoint(address: target, port: 0)?.address ?? target
            return ipAddresses.contains(normalised)
        }
        let names = dnsNames.isEmpty ? [subjectCommonName].compactMap { $0 } : dnsNames
        for pattern in names.map({ $0.lowercased() }) {
            if pattern == target { return true }
            if pattern.hasPrefix("*.") {
                let suffix = pattern.dropFirst(1) // ".example.com"
                if target.hasSuffix(suffix) {
                    let head = target.dropLast(suffix.count)
                    if !head.isEmpty, !head.contains(".") { return true }
                }
            }
        }
        return false
    }
}

public enum CertificateParser {
    /// Parses a DER-encoded certificate. Returns `nil` for anything that is not a certificate.
    public static func summary(der: [UInt8]) -> CertificateSummary? {
        guard der.count <= 64 * 1024, let certificate = try? DER.read(der, at: 0), certificate.tag == 0x30 else { return nil }
        guard let parts = try? DER.children(der, certificate), parts.count >= 3 else { return nil }
        let tbs = parts[0]
        guard tbs.tag == 0x30, let fields = try? DER.children(der, tbs) else { return nil }
        var index = 0
        if fields.first?.tag == 0xA0 { index += 1 } // [0] version
        guard fields.count >= index + 6 else { return nil }
        let serial = fields[index]
        let issuer = fields[index + 2]
        let validity = fields[index + 3]
        let subject = fields[index + 4]
        let keyInfo = fields[index + 5]
        guard serial.tag == 0x02 else { return nil }

        var summary = CertificateSummary(
            serialNumberHex: DER.content(der, serial).map { String(format: "%02X", $0) }.joined(),
            dnsNames: [],
            ipAddresses: [],
            publicKey: "неизвестный",
            signatureAlgorithm: "неизвестный",
            sha256Fingerprint: SHA256.hash(der).map { String(format: "%02X", $0) }.joined(separator: ":")
        )
        let issuerNames = names(der, issuer)
        summary.issuerCommonName = issuerNames["2.5.4.3"]
        summary.issuerOrganization = issuerNames["2.5.4.10"]
        let subjectNames = names(der, subject)
        summary.subjectCommonName = subjectNames["2.5.4.3"]
        summary.subjectOrganization = subjectNames["2.5.4.10"]

        if let times = try? DER.children(der, validity), times.count == 2 {
            summary.notBefore = time(der, times[0])
            summary.notAfter = time(der, times[1])
        }
        summary.publicKey = publicKey(der, keyInfo)
        if let algorithm = try? DER.children(der, parts[1]).first, let oid = DER.oid(der, algorithm) {
            summary.signatureAlgorithm = OIDNames.signature[oid] ?? oid
        }
        for field in fields[(index + 6)...] where field.tag == 0xA3 {
            readExtensions(der, field, into: &summary)
        }
        return summary
    }

    private static func names(_ der: [UInt8], _ name: DER.Node) -> [String: String] {
        var result: [String: String] = [:]
        guard let sets = try? DER.children(der, name) else { return result }
        for set in sets {
            guard let pairs = try? DER.children(der, set) else { continue }
            for pair in pairs {
                guard let items = try? DER.children(der, pair), items.count == 2,
                      let oid = DER.oid(der, items[0]), result[oid] == nil else { continue }
                let bytes = DER.content(der, items[1])
                if items[1].tag == 0x1E { // BMPString (UTF-16BE)
                    var units: [UInt16] = []
                    var i = 0
                    while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
                    result[oid] = String(decoding: units, as: UTF16.self)
                } else {
                    result[oid] = String(decoding: bytes, as: UTF8.self)
                }
            }
        }
        return result
    }

    private static func time(_ der: [UInt8], _ node: DER.Node) -> Date? {
        let text = String(decoding: DER.content(der, node), as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch node.tag {
        case 0x17: // UTCTime: YYMMDDHHMMSSZ, years 50–99 are 19xx (RFC 5280 §4.1.2.5.1)
            guard text.count == 13, let year = Int(text.prefix(2)) else { return nil }
            let century = year >= 50 ? "19" : "20"
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: century + text)
        case 0x18: // GeneralizedTime: YYYYMMDDHHMMSSZ
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: text)
        default:
            return nil
        }
    }

    private static func publicKey(_ der: [UInt8], _ info: DER.Node) -> String {
        guard let parts = try? DER.children(der, info), parts.count == 2,
              let algorithm = try? DER.children(der, parts[0]), let oid = algorithm.first.flatMap({ DER.oid(der, $0) }) else {
            return "неизвестный"
        }
        switch oid {
        case "1.2.840.113549.1.1.1":
            // BIT STRING → RSAPublicKey SEQUENCE { modulus INTEGER, exponent INTEGER }
            let bits = DER.content(der, parts[1])
            guard bits.count > 1, let key = try? DER.read(Array(bits.dropFirst()), at: 0),
                  let fields = try? DER.children(Array(bits.dropFirst()), key), let modulus = fields.first else {
                return "RSA"
            }
            let content = DER.content(Array(bits.dropFirst()), modulus)
            let significant = content.drop(while: { $0 == 0 })
            return "RSA \(significant.count * 8) бит"
        case "1.2.840.10045.2.1":
            if algorithm.count > 1, let curve = DER.oid(der, algorithm[1]) {
                return "ECDSA " + (OIDNames.curve[curve] ?? curve)
            }
            return "ECDSA"
        case "1.3.101.112": return "Ed25519"
        case "1.3.101.113": return "Ed448"
        default: return oid
        }
    }

    private static func readExtensions(_ der: [UInt8], _ wrapper: DER.Node, into summary: inout CertificateSummary) {
        guard let list = try? DER.children(der, wrapper).first, let extensions = try? DER.children(der, list) else { return }
        for item in extensions {
            guard let fields = try? DER.children(der, item), fields.count >= 2,
                  DER.oid(der, fields[0]) == "2.5.29.17", let value = fields.last, value.tag == 0x04 else { continue }
            let inner = DER.content(der, value)
            guard let sequence = try? DER.read(inner, at: 0), let names = try? DER.children(inner, sequence) else { continue }
            for name in names {
                let bytes = DER.content(inner, name)
                switch name.tag {
                case 0x82:
                    summary.dnsNames.append(String(decoding: bytes, as: UTF8.self))
                case 0x87 where bytes.count == 4:
                    summary.ipAddresses.append(bytes.map(String.init).joined(separator: "."))
                case 0x87 where bytes.count == 16:
                    summary.ipAddresses.append(IPv6Text.format(bytes))
                default:
                    break
                }
            }
        }
    }
}

enum OIDNames {
    static let signature: [String: String] = [
        "1.2.840.113549.1.1.5": "RSA с SHA-1",
        "1.2.840.113549.1.1.11": "RSA с SHA-256",
        "1.2.840.113549.1.1.12": "RSA с SHA-384",
        "1.2.840.113549.1.1.13": "RSA с SHA-512",
        "1.2.840.113549.1.1.10": "RSA-PSS",
        "1.2.840.10045.4.3.2": "ECDSA с SHA-256",
        "1.2.840.10045.4.3.3": "ECDSA с SHA-384",
        "1.2.840.10045.4.3.4": "ECDSA с SHA-512",
        "1.3.101.112": "Ed25519",
    ]

    static let curve: [String: String] = [
        "1.2.840.10045.3.1.7": "P-256",
        "1.3.132.0.34": "P-384",
        "1.3.132.0.35": "P-521",
    ]
}

/// Minimal DER reader: definite lengths only (DER forbids indefinite ones), bounds-checked.
enum DER {
    struct Node {
        let tag: UInt8
        let headerStart: Int
        let contentStart: Int
        let contentLength: Int
        var end: Int { contentStart + contentLength }
    }

    struct Malformed: Error {}

    static func read(_ bytes: [UInt8], at offset: Int) throws -> Node {
        guard offset + 2 <= bytes.count else { throw Malformed() }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw Malformed() } // multi-byte tags are not used in certificates
        var position = offset + 1
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, position + count <= bytes.count else { throw Malformed() }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard length >= 0, position + length <= bytes.count else { throw Malformed() }
        return Node(tag: tag, headerStart: offset, contentStart: position, contentLength: length)
    }

    static func children(_ bytes: [UInt8], _ node: Node) throws -> [Node] {
        var result: [Node] = []
        var position = node.contentStart
        while position < node.end {
            let child = try read(bytes, at: position)
            guard child.end <= node.end else { throw Malformed() }
            result.append(child)
            position = child.end
            guard result.count <= 4096 else { throw Malformed() }
        }
        return result
    }

    static func content(_ bytes: [UInt8], _ node: Node) -> [UInt8] {
        Array(bytes[node.contentStart..<node.end])
    }

    static func oid(_ bytes: [UInt8], _ node: Node) -> String? {
        guard node.tag == 0x06, node.contentLength > 0 else { return nil }
        let content = self.content(bytes, node)
        var parts: [UInt64] = []
        var value: UInt64 = 0
        for byte in content {
            guard value < (UInt64(1) << 56) else { return nil }
            value = value << 7 | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        guard let first = parts.first else { return nil }
        let head: [UInt64] = first < 80 ? [first / 40, first % 40] : [2, first - 80]
        return (head + parts.dropFirst()).map(String.init).joined(separator: ".")
    }
}
