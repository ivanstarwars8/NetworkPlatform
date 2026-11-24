import Foundation
import DomainModels

/// Bounds applied to untrusted input. The defaults are this project's own choice,
/// not limits of any external format.
public struct ImportLimits: Codable, Hashable, Sendable {
    /// Longest accepted share link, in UTF-8 bytes.
    public var maximumLinkBytes: Int
    /// Most query parameters (or JSON members) accepted in one link.
    public var maximumParameters: Int
    /// Deepest JSON nesting accepted inside a link (`vmess://` body, `extra`, `fm`).
    public var maximumJSONDepth: Int
    /// Largest accepted subscription body, in bytes, before any decoding.
    public var maximumSubscriptionBytes: Int
    /// Most lines of a subscription that are processed; the rest is reported as truncated.
    public var maximumSubscriptionLines: Int

    public init(
        maximumLinkBytes: Int = 65_536,
        maximumParameters: Int = 128,
        maximumJSONDepth: Int = 16,
        maximumSubscriptionBytes: Int = 4 * 1024 * 1024,
        maximumSubscriptionLines: Int = 5_000
    ) {
        self.maximumLinkBytes = maximumLinkBytes
        self.maximumParameters = maximumParameters
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumSubscriptionBytes = maximumSubscriptionBytes
        self.maximumSubscriptionLines = maximumSubscriptionLines
    }

    public static let standard = ImportLimits()
}

/// Why an input could not be imported at all.
/// Messages never contain credentials taken from the input.
public enum ImportError: Error, Hashable, Sendable {
    case emptyInput
    case inputTooLarge(limit: Int, actual: Int)
    case invalidUTF8
    case unsupportedScheme(String)
    case malformedLink(reason: String)
    case missingField(String)
    case invalidField(name: String, reason: String)
    /// A known parameter carries a value the model cannot represent (for example an unknown transport).
    case unsupportedValue(parameter: String, value: String)
    case invalidBase64(context: String)
    case invalidJSON(context: String)
    case tooManyParameters(limit: Int)
    /// The body is neither a list of share links nor base64 of one.
    case notASubscription
}

/// A non-fatal observation made while converting.
public struct ConversionWarning: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        /// Certificate verification is disabled by the source.
        case insecureTLS
        /// A protocol that expects TLS is configured without it.
        case plaintextTransport
        /// A default was applied because the source omitted a value.
        case defaultApplied
        /// A value looks wrong but was kept as written.
        case suspiciousValue
        /// Percent-encoding was malformed; the raw text was kept.
        case malformedEncoding
        /// The link format is a community convention without a specification.
        case nonStandardFormat
        /// The value is meaningful for one engine only.
        case engineSpecific
        /// A legacy feature engines may no longer accept.
        case legacyFeature
        /// Part of the input was not processed because of a limit.
        case truncated
        /// The model contains something the target format cannot express.
        case notExpressible
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }
}

/// What happened during one import: nothing from the input is dropped without a record here.
public struct ImportReport: Codable, Hashable, Sendable {
    /// Scheme of the link, lowercased (`vless`, `ss`, …).
    public var scheme: String
    /// Recognised variant of the format, for example `sip002` or `vmess-base64-json`.
    public var format: String
    public var unsupported: [UnsupportedParameter]
    public var warnings: [ConversionWarning]

    public init(
        scheme: String,
        format: String = "",
        unsupported: [UnsupportedParameter] = [],
        warnings: [ConversionWarning] = []
    ) {
        self.scheme = scheme
        self.format = format
        self.unsupported = unsupported
        self.warnings = warnings
    }

    /// `true` when everything in the input became a typed field of the model.
    public var isLossless: Bool {
        return unsupported.isEmpty
    }

    public func hasWarning(_ code: ConversionWarning.Code) -> Bool {
        return warnings.contains { $0.code == code }
    }

    public func unsupportedParameter(named name: String) -> UnsupportedParameter? {
        return unsupported.first { $0.name == name }
    }

    mutating func warn(_ code: ConversionWarning.Code, _ message: String) {
        warnings.append(ConversionWarning(code: code, message: message))
    }

    mutating func record(
        _ name: String,
        value: String?,
        location: UnsupportedParameter.Location,
        reason: UnsupportedParameter.Reason,
        disposition: UnsupportedParameter.Disposition = .recorded,
        detail: String? = nil
    ) {
        unsupported.append(UnsupportedParameter(
            name: name, value: value, location: location,
            reason: reason, disposition: disposition, detail: detail
        ))
    }
}

/// Result of importing one share link.
public struct ImportedOutbound: Codable, Hashable, Sendable {
    public var outbound: Outbound
    public var report: ImportReport

    public init(outbound: Outbound, report: ImportReport) {
        self.outbound = outbound
        self.report = report
    }
}
