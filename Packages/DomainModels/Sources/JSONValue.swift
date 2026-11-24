import Foundation

/// Engine-neutral JSON tree.
///
/// Used for the untranslatable remainder of a configuration (see `EngineExtras`):
/// values the model does not understand but must not lose.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not representable as JSONValue"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// Errors of `JSONValue.parse(jsonText:maximumBytes:maximumDepth:)`.
public enum JSONValueError: Error, Hashable, Sendable {
    case tooLarge(limit: Int, actual: Int)
    case tooDeep(limit: Int)
    case malformed
}

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member of an object; `nil` when `self` is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    /// Parses untrusted JSON text with explicit bounds on size and nesting depth.
    public static func parse(
        jsonText: String,
        maximumBytes: Int = 262_144,
        maximumDepth: Int = 32
    ) throws -> JSONValue {
        let bytes = Array(jsonText.utf8)
        guard bytes.count <= maximumBytes else {
            throw JSONValueError.tooLarge(limit: maximumBytes, actual: bytes.count)
        }
        guard JSONValue.nestingDepth(of: bytes, stopAbove: maximumDepth) <= maximumDepth else {
            throw JSONValueError.tooDeep(limit: maximumDepth)
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
        } catch {
            throw JSONValueError.malformed
        }
    }

    /// Deterministic JSON text: keys sorted, slashes not escaped.
    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Maximum bracket nesting outside string literals. Stops counting once `stopAbove` is exceeded.
    static func nestingDepth(of bytes: [UInt8], stopAbove: Int) -> Int {
        var depth = 0
        var maximum = 0
        var insideString = false
        var escaped = false
        for byte in bytes {
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                continue
            }
            switch byte {
            case 0x22:
                insideString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > maximum { maximum = depth }
                if maximum > stopAbove { return maximum }
            case 0x5D, 0x7D:
                if depth > 0 { depth -= 1 }
            default:
                break
            }
        }
        return maximum
    }
}
