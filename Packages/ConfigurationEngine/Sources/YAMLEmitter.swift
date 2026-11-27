import Foundation

/// A YAML document tree with ordered mappings, for engine configurations written as YAML (Mihomo).
///
/// Only what the compilers need: scalars (null, booleans, integers, strings), sequences and mappings
/// with string keys. No anchors, tags, floats or multi-document streams.
public indirect enum YAMLNode: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case sequence([YAMLNode])
    case mapping([YAMLPair])

    /// Value of `key` in a mapping (first occurrence); `nil` for other nodes.
    public subscript(key: String) -> YAMLNode? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var sequenceValue: [YAMLNode]? {
        if case .sequence(let items) = self { return items }
        return nil
    }
}

public struct YAMLPair: Hashable, Sendable {
    public var key: String
    public var value: YAMLNode

    public init(_ key: String, _ value: YAMLNode) {
        self.key = key
        self.value = value
    }
}

/// Builds an ordered mapping, leaving out `nil` values.
struct YAMLMappingBuilder {
    private(set) var pairs: [YAMLPair] = []

    mutating func set(_ key: String, _ value: YAMLNode?) {
        guard let value = value else { return }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value = value
        } else {
            pairs.append(YAMLPair(key, value))
        }
    }

    mutating func set(_ key: String, _ value: String?) {
        set(key, value.map { YAMLNode.string($0) })
    }

    mutating func set(_ key: String, _ value: Int?) {
        set(key, value.map { YAMLNode.integer(Int64($0)) })
    }

    mutating func set(_ key: String, _ value: Bool?) {
        set(key, value.map { YAMLNode.bool($0) })
    }

    mutating func set(_ key: String, strings: [String]?) {
        set(key, strings.map { YAMLNode.sequence($0.map { .string($0) }) })
    }

    var isEmpty: Bool { pairs.isEmpty }

    var node: YAMLNode { .mapping(pairs) }
}

/// Writes `YAMLNode` trees as YAML 1.2 text that YAML 1.1 parsers (go-yaml, used by Mihomo) read
/// back to the same values.
///
/// Block style with two-space indentation. A string is written plain only when it is made of a
/// conservative set of characters, does not start like a number or an indicator, and is not a word
/// that either YAML version reads as a boolean or null; everything else is double-quoted with escapes.
/// The output is deterministic and ends with a newline.
public enum YAMLEmitter {
    public static func emit(_ node: YAMLNode) -> String {
        var output = ""
        switch node {
        case .mapping(let pairs) where !pairs.isEmpty:
            writeMapping(pairs, indent: 0, into: &output)
        case .sequence(let items) where !items.isEmpty:
            writeSequence(items, indent: 0, into: &output)
        default:
            output = inline(node) + "\n"
        }
        return output
    }

    // MARK: - Block collections

    private static func writeMapping(_ pairs: [YAMLPair], indent: Int, into output: inout String) {
        let pad = String(repeating: " ", count: indent)
        for pair in pairs {
            output += pad + scalar(pair.key) + ":"
            writeValue(pair.value, indent: indent, into: &output)
        }
    }

    private static func writeSequence(_ items: [YAMLNode], indent: Int, into output: inout String) {
        let pad = String(repeating: " ", count: indent)
        for item in items {
            switch item {
            case .mapping(let pairs) where !pairs.isEmpty:
                // "- first: value" and the remaining keys aligned under "first".
                var nested = ""
                writeMapping(pairs, indent: indent + 2, into: &nested)
                output += pad + "- " + nested.dropFirst(indent + 2)
            case .sequence(let inner) where !inner.isEmpty:
                output += pad + "-\n"
                writeSequence(inner, indent: indent + 2, into: &output)
            default:
                output += pad + "- " + inline(item) + "\n"
            }
        }
    }

    /// The part after "key:" — a scalar on the same line, or a nested block on the next lines.
    private static func writeValue(_ value: YAMLNode, indent: Int, into output: inout String) {
        switch value {
        case .mapping(let pairs) where !pairs.isEmpty:
            output += "\n"
            writeMapping(pairs, indent: indent + 2, into: &output)
        case .sequence(let items) where !items.isEmpty:
            output += "\n"
            writeSequence(items, indent: indent + 2, into: &output)
        default:
            output += " " + inline(value) + "\n"
        }
    }

    private static func inline(_ node: YAMLNode) -> String {
        switch node {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .string(let text): return scalar(text)
        case .sequence: return "[]"
        case .mapping: return "{}"
        }
    }

    // MARK: - Scalars

    /// Words that YAML 1.1 or 1.2 resolves to a boolean or null (case-insensitive).
    static let reservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~",
    ]

    /// Characters allowed in a plain scalar. Excludes every YAML indicator (`: # , [ ] { } & * ! | > ' " % @` and
    /// backquote) and whitespace, so no context can give a plain string another meaning.
    private static func isPlainCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".", "/", "+", "=":
            return true
        default:
            return false
        }
    }

    /// `text` as a plain scalar when that is unambiguous, otherwise as a double-quoted scalar.
    public static func scalar(_ text: String) -> String {
        return isSafePlain(text) ? text : doubleQuoted(text)
    }

    static func isSafePlain(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        guard text.unicodeScalars.allSatisfy(isPlainCharacter) else { return false }
        // A leading digit, sign or dot may resolve to an integer, float, ".inf" or ".nan" (or a YAML 1.1
        // sexagesimal or octal number); "-" and "?" start indicators. Such strings are quoted.
        switch first {
        case "0"..."9", "-", "+", ".", "=":
            return false
        default:
            break
        }
        return !reservedWords.contains(text.lowercased())
    }

    static func doubleQuoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{0}": result += "\\0"
            default:
                let value = scalar.value
                // C0 and C1 controls, DEL, the byte-order mark and the YAML line/paragraph separators are escaped;
                // other characters are printable in YAML and written as they are (UTF-8).
                if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                    || value == 0xFEFF || value == 0x2028 || value == 0x2029 {
                    result += value <= 0xFF
                        ? String(format: "\\x%02X", value)
                        : String(format: "\\u%04X", value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
