import Foundation

/// Identifier of a tunnel engine. Open set: new engines do not require a model change.
public struct EngineID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let xray = EngineID(rawValue: "xray")
    public static let singBox = EngineID(rawValue: "sing-box")
    public static let mihomo = EngineID(rawValue: "mihomo")
}

/// Untranslatable remainder bound to the engine it came from (ADR-0002 §3).
/// Survives import → storage → compilation for the same engine; counts as lost for any other.
public struct EngineExtras: Codable, Hashable, Sendable {
    /// Engine raw identifier → key → value.
    public var storage: [String: [String: JSONValue]]

    public init(storage: [String: [String: JSONValue]] = [:]) {
        self.storage = storage
    }

    public var isEmpty: Bool {
        return storage.values.allSatisfy { $0.isEmpty }
    }

    public func value(engine: EngineID, key: String) -> JSONValue? {
        return storage[engine.rawValue]?[key]
    }

    public mutating func set(_ value: JSONValue?, engine: EngineID, key: String) {
        var bucket = storage[engine.rawValue] ?? [:]
        bucket[key] = value
        if bucket.isEmpty {
            storage[engine.rawValue] = nil
        } else {
            storage[engine.rawValue] = bucket
        }
    }

    /// Well-known keys written by the importers.
    public static let xrayFinalMaskKey = "finalmask"
    public static let xrayXHTTPExtraKey = "xhttp.extra"
}

/// A parameter met in the input that the model could not take as a typed field.
/// Recorded instead of being dropped, so the user and the diagnostics see every loss.
///
/// `value` may contain sensitive data (an unknown parameter can be a credential);
/// treat a list of these records with the same care as the outbound itself.
public struct UnsupportedParameter: Codable, Hashable, Sendable {
    public enum Location: String, Codable, Hashable, Sendable {
        case query
        case userInfo
        case path
        case fragment
        case jsonBody
        case plugin
        case other
    }

    public enum Reason: String, Codable, Hashable, Sendable {
        /// The importer does not know this parameter.
        case unknown
        /// Known parameter whose value the model cannot represent.
        case invalidValue
        /// Known parameter that has no meaning for the chosen transport or security.
        case notApplicable
        /// Repeated parameter; the first occurrence was used.
        case duplicate
        /// Meaningful for one engine only; kept in `EngineExtras`.
        case engineSpecific
    }

    public enum Disposition: String, Codable, Hashable, Sendable {
        /// Not applied to the model; only this record keeps it.
        case recorded
        /// Not interpreted, but kept verbatim in `EngineExtras`.
        case preservedInEngineExtras
    }

    public var name: String
    public var value: String?
    public var location: Location
    public var reason: Reason
    public var disposition: Disposition
    public var detail: String?

    public init(
        name: String,
        value: String?,
        location: Location,
        reason: Reason,
        disposition: Disposition = .recorded,
        detail: String? = nil
    ) {
        self.name = name
        self.value = value
        self.location = location
        self.reason = reason
        self.disposition = disposition
        self.detail = detail
    }
}
