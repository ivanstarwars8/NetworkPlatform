import Foundation

/// Percent-encoding on UTF-8 bytes (RFC 3986). `+` is never treated as a space.
enum PercentCoding {
    /// Returns `nil` for a malformed escape, for bytes that are not valid UTF-8
    /// and for control characters other than tab, LF and CR.
    static func decode(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x25 {
                guard index + 2 < bytes.count,
                      let high = hexValue(bytes[index + 1]),
                      let low = hexValue(bytes[index + 2]) else {
                    return nil
                }
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        for byte in output {
            if byte == 0x7F { return nil }
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { return nil }
        }
        return String(bytes: output, encoding: .utf8)
    }

    enum Component {
        /// User information and fragment: only unreserved characters stay literal.
        case strict
        /// Query value: additionally `/`, `:`, `,` and `@` stay literal.
        case queryValue
    }

    static func encode(_ text: String, as component: Component) -> String {
        var output: [UInt8] = []
        let digits = Array("0123456789ABCDEF".utf8)
        for byte in text.utf8 {
            if isLiteral(byte, in: component) {
                output.append(byte)
            } else {
                output.append(0x25)
                output.append(digits[Int(byte >> 4)])
                output.append(digits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isLiteral(_ byte: UInt8, in component: Component) -> Bool {
        if isUnreserved(byte) { return true }
        switch component {
        case .strict:
            return false
        case .queryValue:
            return byte == 0x2F || byte == 0x3A || byte == 0x2C || byte == 0x40
        }
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:
            return true
        case 0x2D, 0x2E, 0x5F, 0x7E:
            return true
        default:
            return false
        }
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

/// Base64 that accepts the standard and URL-safe alphabets, with or without padding,
/// and ignores ASCII whitespace. Anything else is rejected.
enum LenientBase64 {
    static func decode(_ text: String) -> Data? {
        var symbols: [UInt8] = []
        symbols.reserveCapacity(text.utf8.count + 3)
        var sawPadding = false
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case 0x3D:
                sawPadding = true
            case 0x2D:
                if sawPadding { return nil }
                symbols.append(0x2B)
            case 0x5F:
                if sawPadding { return nil }
                symbols.append(0x2F)
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F:
                if sawPadding { return nil }
                symbols.append(byte)
            default:
                return nil
            }
        }
        if symbols.isEmpty { return nil }
        let remainder = symbols.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 {
            for _ in 0..<(4 - remainder) {
                symbols.append(0x3D)
            }
        }
        return Data(base64Encoded: String(decoding: symbols, as: UTF8.self))
    }

    /// Decodes to text; `nil` unless the result is valid UTF-8.
    static func decodeToString(_ text: String) -> String? {
        guard let data = decode(text) else { return nil }
        return String(bytes: Array(data), encoding: .utf8)
    }

    /// URL-safe alphabet, no padding.
    static func encodeURLSafe(_ text: String) -> String {
        let standard = Data(text.utf8).base64EncodedString()
        var output: [UInt8] = []
        for byte in standard.utf8 {
            switch byte {
            case 0x2B: output.append(0x2D)
            case 0x2F: output.append(0x5F)
            case 0x3D: continue
            default: output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Small string helpers that work on bytes so that ASCII delimiters are never
/// merged with a following combining character.
enum Text {
    static func trimmed(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits at the first occurrence of an ASCII delimiter.
    static func cutFirst(_ text: String, at delimiter: UInt8) -> (head: String, tail: String?) {
        let bytes = Array(text.utf8)
        guard let index = bytes.firstIndex(of: delimiter) else { return (text, nil) }
        return (
            String(decoding: bytes[..<index], as: UTF8.self),
            String(decoding: bytes[(index + 1)...], as: UTF8.self)
        )
    }

    /// Splits at the last occurrence of an ASCII delimiter.
    static func cutLast(_ text: String, at delimiter: UInt8) -> (head: String, tail: String?) {
        let bytes = Array(text.utf8)
        guard let index = bytes.lastIndex(of: delimiter) else { return (text, nil) }
        return (
            String(decoding: bytes[..<index], as: UTF8.self),
            String(decoding: bytes[(index + 1)...], as: UTF8.self)
        )
    }

    /// Comma-separated list with blanks removed.
    static func commaList(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        return bytes.split(separator: 0x2C, omittingEmptySubsequences: true)
            .map { trimmed(String(decoding: $0, as: UTF8.self)) }
            .filter { !$0.isEmpty }
    }

    static func parseBool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    /// Decimal port in 1...65535.
    static func parsePort(_ text: String) -> UInt16? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 5 else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        guard value >= 1, value <= 65_535 else { return nil }
        return UInt16(value)
    }

    /// Non-negative decimal integer of at most nine digits.
    static func parseNonNegativeInt(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 9 else { return nil }
        var value = 0
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }
}
