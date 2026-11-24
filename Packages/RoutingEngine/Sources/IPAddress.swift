// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

/// An IPv4 or IPv6 address parsed and formatted without any libc dependency.
///
/// The parser is strict on purpose (it is fed with rule text and sniffed
/// destinations): no leading zeros in IPv4 octets, no zone identifiers, no
/// brackets, no whitespace, bounded input length.
public enum IPAddress: Hashable, Sendable {
    case v4(UInt32)
    case v6(high: UInt64, low: UInt64)

    /// Longest accepted textual form:
    /// `ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255` (45 bytes).
    public static let maximumTextLength = 45

    /// Parses dotted-quad IPv4 or RFC 4291 IPv6 text. Returns `nil` on any
    /// malformed input.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= IPAddress.maximumTextLength else { return nil }
        if bytes.contains(IPAddress.colon) {
            guard let pair = IPAddress.parseV6(bytes) else { return nil }
            self = .v6(high: pair.high, low: pair.low)
        } else {
            guard let value = IPAddress.parseV4(bytes[...]) else { return nil }
            self = .v4(value)
        }
    }

    public init(v4Octets a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self = .v4((UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d))
    }

    public var isIPv4: Bool {
        if case .v4 = self { return true }
        return false
    }

    public var isIPv6: Bool { !isIPv4 }

    /// Address width in bits: 32 or 128.
    public var bitWidth: Int { isIPv4 ? 32 : 128 }

    /// `true` for `::ffff:a.b.c.d`.
    public var isIPv4Mapped: Bool {
        if case let .v6(high, low) = self {
            return high == 0 && (low >> 32) == 0xFFFF
        }
        return false
    }

    /// For an IPv4-mapped IPv6 address returns the embedded IPv4 address;
    /// every other address is returned unchanged.
    public var unmapped: IPAddress {
        if case let .v6(high, low) = self, high == 0, (low >> 32) == 0xFFFF {
            return .v4(UInt32(truncatingIfNeeded: low))
        }
        return self
    }

    // MARK: Parsing

    private static let colon: UInt8 = 0x3A
    private static let dot: UInt8 = 0x2E

    private static func parseV4(_ bytes: ArraySlice<UInt8>) -> UInt32? {
        guard bytes.count >= 7, bytes.count <= 15 else { return nil }
        var result: UInt32 = 0
        var parts = 0
        var current: UInt32 = 0
        var digits = 0
        var leadingZero = false
        for byte in bytes {
            if byte == dot {
                guard digits > 0, parts < 3 else { return nil }
                result = (result << 8) | current
                parts += 1
                current = 0
                digits = 0
                leadingZero = false
            } else if byte >= 0x30 && byte <= 0x39 {
                // "0" is fine, "00" and "01" are not.
                guard !leadingZero else { return nil }
                if digits == 0 && byte == 0x30 { leadingZero = true }
                current = current * 10 + UInt32(byte - 0x30)
                digits += 1
                guard digits <= 3, current <= 255 else { return nil }
            } else {
                return nil
            }
        }
        guard digits > 0, parts == 3 else { return nil }
        return (result << 8) | current
    }

    private static func hexValue(_ byte: UInt8) -> UInt16? {
        switch byte {
        case 0x30...0x39: return UInt16(byte - 0x30)
        case 0x61...0x66: return UInt16(byte - 0x61 + 10)
        case 0x41...0x46: return UInt16(byte - 0x41 + 10)
        default: return nil
        }
    }

    private static func parseV6(_ bytes: [UInt8]) -> (high: UInt64, low: UInt64)? {
        let count = bytes.count
        guard count >= 2 else { return nil }
        var head: [UInt16] = []
        var tail: [UInt16] = []
        var seenEllipsis = false
        var index = 0

        if bytes[0] == colon {
            guard bytes[1] == colon else { return nil }
            seenEllipsis = true
            index = 2
        }

        while index < count {
            let tokenStart = index
            var hasDot = false
            while index < count && bytes[index] != colon {
                if bytes[index] == dot { hasDot = true }
                index += 1
            }
            let token = bytes[tokenStart..<index]
            guard !token.isEmpty else { return nil }

            var parsed: [UInt16] = []
            if hasDot {
                // Embedded IPv4 is only legal as the very last token.
                guard index == count, let v4 = parseV4(token) else { return nil }
                parsed.append(UInt16(truncatingIfNeeded: v4 >> 16))
                parsed.append(UInt16(truncatingIfNeeded: v4))
            } else {
                guard token.count <= 4 else { return nil }
                var value: UInt16 = 0
                for byte in token {
                    guard let digit = hexValue(byte) else { return nil }
                    value = (value << 4) | digit
                }
                parsed.append(value)
            }
            if seenEllipsis {
                tail.append(contentsOf: parsed)
            } else {
                head.append(contentsOf: parsed)
            }
            guard head.count + tail.count <= 8 else { return nil }

            if index < count {
                // bytes[index] is a colon.
                index += 1
                guard index < count else { return nil } // trailing single ':'
                if bytes[index] == colon {
                    guard !seenEllipsis else { return nil }
                    seenEllipsis = true
                    index += 1
                }
            }
        }

        let total = head.count + tail.count
        var groups: [UInt16]
        if seenEllipsis {
            // "::" must stand for at least one zero group.
            guard total <= 7 else { return nil }
            groups = head
            groups.append(contentsOf: [UInt16](repeating: 0, count: 8 - total))
            groups.append(contentsOf: tail)
        } else {
            guard total == 8 else { return nil }
            groups = head
        }

        var high: UInt64 = 0
        var low: UInt64 = 0
        for position in 0..<4 {
            high = (high << 16) | UInt64(groups[position])
        }
        for position in 4..<8 {
            low = (low << 16) | UInt64(groups[position])
        }
        return (high, low)
    }
}

// MARK: - Formatting

extension IPAddress: CustomStringConvertible {
    /// Canonical text: dotted quad for IPv4, RFC 5952 for IPv6 (lower case,
    /// the first longest run of two or more zero groups compressed).
    /// IPv4-mapped addresses are printed as `::ffff:a.b.c.d`.
    public var description: String {
        switch self {
        case let .v4(value):
            return IPAddress.formatV4(value)
        case let .v6(high, low):
            if high == 0 && (low >> 32) == 0xFFFF {
                return "::ffff:" + IPAddress.formatV4(UInt32(truncatingIfNeeded: low))
            }
            return IPAddress.formatV6(high: high, low: low)
        }
    }

    private static func formatV4(_ value: UInt32) -> String {
        let a = (value >> 24) & 0xFF
        let b = (value >> 16) & 0xFF
        let c = (value >> 8) & 0xFF
        let d = value & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    private static func formatV6(high: UInt64, low: UInt64) -> String {
        var groups: [UInt16] = []
        groups.reserveCapacity(8)
        for position in 0..<4 {
            groups.append(UInt16(truncatingIfNeeded: high >> UInt64(48 - position * 16)))
        }
        for position in 0..<4 {
            groups.append(UInt16(truncatingIfNeeded: low >> UInt64(48 - position * 16)))
        }

        // Find the first longest run of zero groups (length >= 2).
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        var runLength = 0
        for position in 0..<8 {
            if groups[position] == 0 {
                if runStart < 0 {
                    runStart = position
                    runLength = 0
                }
                runLength += 1
                if runLength > bestLength {
                    bestLength = runLength
                    bestStart = runStart
                }
            } else {
                runStart = -1
                runLength = 0
            }
        }
        if bestLength < 2 {
            bestStart = -1
            bestLength = 0
        }

        var result = ""
        var position = 0
        while position < 8 {
            if position == bestStart {
                result += "::"
                position += bestLength
                continue
            }
            if !result.isEmpty && !result.hasSuffix(":") {
                result += ":"
            }
            result += String(groups[position], radix: 16, uppercase: false)
            position += 1
        }
        return result
    }
}

extension IPAddress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = IPAddress(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IP address")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - CIDR

/// A network prefix. Host bits are always cleared, so two spellings of the
/// same network compare equal. An IPv4-mapped IPv6 prefix of length >= 96 is
/// stored as the equivalent IPv4 prefix, mirroring how requests are unmapped.
public struct IPCIDR: Hashable, Sendable {
    /// Network address with host bits cleared.
    public let network: IPAddress
    /// Prefix length: 0...32 for IPv4, 0...128 for IPv6.
    public let prefixLength: Int

    /// Returns `nil` when `prefixLength` is out of range for the family.
    public init?(address: IPAddress, prefixLength: Int) {
        guard prefixLength >= 0, prefixLength <= address.bitWidth else { return nil }
        var base = address
        var length = prefixLength
        if address.isIPv4Mapped && prefixLength >= 96 {
            base = address.unmapped
            length = prefixLength - 96
        }
        switch base {
        case let .v4(value):
            self.network = .v4(value & IPCIDR.mask32(length))
        case let .v6(high, low):
            let masked = IPBits(high: high, low: low).masked(to: length)
            self.network = .v6(high: masked.high, low: masked.low)
        }
        self.prefixLength = length
    }

    /// Parses `address/length`. A bare address is accepted as a host prefix
    /// (`/32` or `/128`).
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= IPAddress.maximumTextLength + 4 else { return nil }
        guard let slash = bytes.firstIndex(of: 0x2F) else {
            guard let address = IPAddress(text) else { return nil }
            self.init(address: address, prefixLength: address.bitWidth)
            return
        }
        let addressText = String(decoding: bytes[..<slash], as: UTF8.self)
        let lengthBytes = bytes[(slash + 1)...]
        guard let address = IPAddress(addressText) else { return nil }
        guard !lengthBytes.isEmpty, lengthBytes.count <= 3 else { return nil }
        var length = 0
        var first = true
        for byte in lengthBytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            // No leading zeros: "0" is fine, "08" is not.
            if !first && length == 0 { return nil }
            length = length * 10 + Int(byte - 0x30)
            first = false
        }
        self.init(address: address, prefixLength: length)
    }

    /// `true` when the address (after unmapping IPv4-mapped IPv6) is inside
    /// the prefix. Families never match each other.
    public func contains(_ address: IPAddress) -> Bool {
        switch (network, address.unmapped) {
        case let (.v4(net), .v4(value)):
            return (value & IPCIDR.mask32(prefixLength)) == net
        case let (.v6(netHigh, netLow), .v6(high, low)):
            let masked = IPBits(high: high, low: low).masked(to: prefixLength)
            return masked.high == netHigh && masked.low == netLow
        default:
            return false
        }
    }

    /// `true` when every address of `other` is also inside `self`.
    public func covers(_ other: IPCIDR) -> Bool {
        guard network.isIPv4 == other.network.isIPv4 else { return false }
        return prefixLength <= other.prefixLength && contains(other.network)
    }

    static func mask32(_ length: Int) -> UInt32 {
        if length <= 0 { return 0 }
        if length >= 32 { return UInt32.max }
        return UInt32.max << UInt32(32 - length)
    }
}

extension IPCIDR: CustomStringConvertible {
    public var description: String { "\(network)/\(prefixLength)" }
}

extension IPCIDR: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = IPCIDR(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid CIDR")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - 128-bit helper

/// A 128-bit big-endian bit string used as the key of the CIDR trie.
/// IPv4 keys occupy the top 32 bits of `high`.
struct IPBits: Equatable, Sendable {
    var high: UInt64
    var low: UInt64

    /// Bit at `index` (0 = most significant). `index` must be in 0..<128.
    func bit(at index: Int) -> Int {
        if index < 64 {
            return Int((high >> UInt64(63 - index)) & 1)
        }
        return Int((low >> UInt64(127 - index)) & 1)
    }

    /// Keeps the top `length` bits and clears the rest.
    func masked(to length: Int) -> IPBits {
        if length <= 0 { return IPBits(high: 0, low: 0) }
        if length < 64 {
            return IPBits(high: high & (UInt64.max << UInt64(64 - length)), low: 0)
        }
        if length == 64 { return IPBits(high: high, low: 0) }
        if length < 128 {
            return IPBits(high: high, low: low & (UInt64.max << UInt64(128 - length)))
        }
        return self
    }

    /// Number of leading bits shared with `other` (0...128).
    func commonPrefixLength(with other: IPBits) -> Int {
        let highDiff = high ^ other.high
        if highDiff != 0 { return highDiff.leadingZeroBitCount }
        let lowDiff = low ^ other.low
        return 64 + lowDiff.leadingZeroBitCount
    }

    static func key(for address: IPAddress) -> IPBits {
        switch address {
        case let .v4(value):
            return IPBits(high: UInt64(value) << 32, low: 0)
        case let .v6(high, low):
            return IPBits(high: high, low: low)
        }
    }
}
