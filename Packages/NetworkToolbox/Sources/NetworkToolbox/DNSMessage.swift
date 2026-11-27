// A minimal DNS message codec (RFC 1035, RFC 3596) for the lookup tool: one question out, answers in. The
// parser assumes hostile input: every read is bounds-checked and compression pointers are followed a
// bounded number of times.

import Foundation

public enum DNSRecordType: Equatable, Hashable, Sendable {
    case a
    case aaaa
    case cname
    case other(UInt16)

    public init(code: UInt16) {
        switch code {
        case 1: self = .a
        case 28: self = .aaaa
        case 5: self = .cname
        default: self = .other(code)
        }
    }

    public var code: UInt16 {
        switch self {
        case .a: return 1
        case .aaaa: return 28
        case .cname: return 5
        case let .other(code): return code
        }
    }

    public var name: String {
        switch self {
        case .a: return "A"
        case .aaaa: return "AAAA"
        case .cname: return "CNAME"
        case let .other(code): return "TYPE\(code)"
        }
    }
}

public enum DNSError: Error, Equatable, Sendable {
    case invalidName(String)
    case malformed(String)

    public var message: String {
        switch self {
        case let .invalidName(reason): return "Имя не подходит для DNS: \(reason)."
        case let .malformed(reason): return "Ответ DNS не разобран: \(reason)."
        }
    }
}

public struct DNSRecord: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case address(String)
        case name(String)
        case other(byteCount: Int)
    }

    public let name: String
    public let type: DNSRecordType
    public let ttl: UInt32
    public let value: Value

    public var valueText: String {
        switch value {
        case let .address(text), let .name(text): return text
        case let .other(count): return "\(count) Б данных"
        }
    }
}

public struct DNSResponse: Equatable, Sendable {
    public let id: UInt16
    public let responseCode: UInt8
    public let truncated: Bool
    public let recursionAvailable: Bool
    public let answers: [DNSRecord]

    /// Name of the response code (RFC 1035 §4.1.1, RFC 6895).
    public var responseCodeName: String {
        switch responseCode {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "RCODE\(responseCode)"
        }
    }

    /// The addresses of the answer section, in order.
    public var addresses: [String] {
        answers.compactMap { record in
            if case let .address(text) = record.value { return text }
            return nil
        }
    }
}

public enum DNSMessage {
    /// Largest message read from the wire. A limit of this project (EDNS is not offered, so a compliant
    /// server answers in at most 512 bytes over UDP).
    public static let maximumMessageBytes = 4096

    /// Encodes a name as DNS labels. Non-ASCII labels are converted to IDNA "xn--" form (Punycode), so
    /// Cyrillic domains work.
    public static func encodeName(_ name: String) throws -> [UInt8] {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { throw DNSError.invalidName("пустое имя") }
        var bytes: [UInt8] = []
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { throw DNSError.invalidName("пустая часть между точками") }
            let ascii: String
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
                ascii = String(label)
            } else {
                guard let encoded = Punycode.encode(String(label).lowercased()) else {
                    throw DNSError.invalidName("часть «\(label)» не переводится в Punycode")
                }
                ascii = "xn--" + encoded
            }
            guard ascii.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
                throw DNSError.invalidName("пробелы и управляющие символы недопустимы")
            }
            let utf8 = Array(ascii.utf8)
            guard utf8.count <= 63 else { throw DNSError.invalidName("часть длиннее 63 символов") }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        guard bytes.count <= 255 else { throw DNSError.invalidName("имя длиннее 253 символов") }
        return bytes
    }

    /// One recursive query for `name` and `type`, class IN, no EDNS.
    public static func query(id: UInt16, name: String, type: DNSRecordType) throws -> [UInt8] {
        var message: [UInt8] = [
            UInt8(id >> 8), UInt8(id & 0xFF),
            0x01, 0x00, // RD
            0x00, 0x01, // QDCOUNT
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        message += try encodeName(name)
        message += [UInt8(type.code >> 8), UInt8(type.code & 0xFF), 0x00, 0x01]
        return message
    }

    /// Parses a response. Throws on anything that is not a well-formed response.
    public static func parse(_ bytes: [UInt8]) throws -> DNSResponse {
        var reader = Reader(bytes: bytes)
        let id = try reader.u16()
        let flags = try reader.u16()
        guard flags & 0x8000 != 0 else { throw DNSError.malformed("это запрос, а не ответ") }
        let questions = try reader.u16()
        let answerCount = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()
        for _ in 0..<questions {
            _ = try reader.name()
            _ = try reader.u16()
            _ = try reader.u16()
        }
        var answers: [DNSRecord] = []
        for _ in 0..<answerCount {
            let name = try reader.name()
            let type = DNSRecordType(code: try reader.u16())
            _ = try reader.u16()
            let ttl = try reader.u32()
            let length = Int(try reader.u16())
            let dataStart = reader.offset
            guard dataStart + length <= bytes.count else { throw DNSError.malformed("запись обрезана") }
            let value: DNSRecord.Value
            switch type {
            case .a:
                guard length == 4 else { throw DNSError.malformed("запись A не из 4 байт") }
                value = .address(bytes[dataStart..<dataStart + 4].map(String.init).joined(separator: "."))
            case .aaaa:
                guard length == 16 else { throw DNSError.malformed("запись AAAA не из 16 байт") }
                value = .address(IPv6Text.format(Array(bytes[dataStart..<dataStart + 16])))
            case .cname:
                var inner = Reader(bytes: bytes, offset: dataStart)
                value = .name(try inner.name())
            case .other:
                value = .other(byteCount: length)
            }
            reader.offset = dataStart + length
            answers.append(DNSRecord(name: name, type: type, ttl: ttl, value: value))
        }
        return DNSResponse(
            id: id,
            responseCode: UInt8(flags & 0x000F),
            truncated: flags & 0x0200 != 0,
            recursionAvailable: flags & 0x0080 != 0,
            answers: answers
        )
    }

    struct Reader {
        let bytes: [UInt8]
        var offset: Int = 0

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw DNSError.malformed("сообщение обрезано") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            UInt16(try u8()) << 8 | UInt16(try u8())
        }

        mutating func u32() throws -> UInt32 {
            UInt32(try u16()) << 16 | UInt32(try u16())
        }

        /// Reads a possibly compressed name; leaves `offset` after the name's bytes at this position.
        mutating func name() throws -> String {
            var labels: [String] = []
            var position = offset
            var jumped = false
            var jumps = 0
            var total = 0
            while true {
                guard position < bytes.count else { throw DNSError.malformed("имя обрезано") }
                let length = Int(bytes[position])
                if length & 0xC0 == 0xC0 {
                    guard position + 1 < bytes.count else { throw DNSError.malformed("указатель обрезан") }
                    let target = (length & 0x3F) << 8 | Int(bytes[position + 1])
                    if !jumped { offset = position + 2 }
                    jumped = true
                    jumps += 1
                    guard jumps <= 32, target < bytes.count else { throw DNSError.malformed("петля указателей") }
                    position = target
                    continue
                }
                guard length & 0xC0 == 0 else { throw DNSError.malformed("неизвестный тип метки") }
                if length == 0 {
                    if !jumped { offset = position + 1 }
                    break
                }
                guard position + 1 + length <= bytes.count else { throw DNSError.malformed("метка обрезана") }
                total += length + 1
                guard total <= 255 else { throw DNSError.malformed("имя длиннее 255 байт") }
                let label = bytes[(position + 1)...(position + length)]
                labels.append(String(decoding: label, as: UTF8.self))
                position += 1 + length
            }
            return labels.isEmpty ? "." : labels.joined(separator: ".")
        }
    }
}

enum IPv6Text {
    /// RFC 5952 text form: lower case, longest run of zero groups (two or more) compressed.
    static func format(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        var groups: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }
        var bestStart = -1, bestLength = 0, runStart = -1
        for index in 0...8 {
            if index < 8, groups[index] == 0 {
                if runStart < 0 { runStart = index }
            } else if runStart >= 0 {
                let length = index - runStart
                if length > bestLength { bestStart = runStart; bestLength = length }
                runStart = -1
            }
        }
        if bestLength < 2 { bestStart = -1 }
        var parts: [String] = []
        var index = 0
        var text = ""
        while index < 8 {
            if index == bestStart {
                text += parts.joined(separator: ":") + "::"
                parts = []
                index += bestLength
                continue
            }
            parts.append(String(groups[index], radix: 16))
            index += 1
        }
        if bestStart >= 0 {
            return text + parts.joined(separator: ":")
        }
        return parts.joined(separator: ":")
    }
}

/// RFC 3492 Punycode encoder (for IDNA labels). Lower-casing is the only normalisation applied; full
/// IDNA 2008 mapping is out of scope.
enum Punycode {
    static func encode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = 0x80, delta = 0, bias = 72

        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / count
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }

        func digit(_ value: Int) -> Character {
            let scalar = value < 26 ? 0x61 + value : 0x30 + value - 26
            return Character(Unicode.Scalar(UInt8(scalar)))
        }

        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }
}
