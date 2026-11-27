import Foundation
import DomainModels

/// One observation made while compiling the model into an engine configuration (ADR-0002 §6).
///
/// `detail` never contains credentials: the compiler names fields, not secret values.
public struct ConversionIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// The engine cannot express this at all.
        case unsupported
        /// Expressed with a different meaning or precision.
        case approximated
        /// Left out of the output.
        case dropped
        /// Moved automatically to the form the engine expects now.
        case migrated
        /// Passed through verbatim from `EngineExtras`; the model does not understand it.
        case engineLocked
        /// Emitted, but this combination has no interoperability test.
        case untested
        /// The model itself is inconsistent or a value is malformed.
        case invalid
    }

    public enum Severity: String, Codable, Hashable, Sendable, Comparable {
        case info
        case warning
        case error

        private var rank: Int {
            switch self {
            case .info: return 0
            case .warning: return 1
            case .error: return 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            return lhs.rank < rhs.rank
        }
    }

    /// Location in the model, for example `outbounds[3].stream.security`.
    public var path: String
    public var kind: Kind
    public var severity: Severity
    public var detail: String

    public init(path: String, kind: Kind, severity: Severity, detail: String) {
        self.path = path
        self.kind = kind
        self.severity = severity
        self.detail = detail
    }
}

/// Everything that was lossy, unsupported or changed during one compilation.
/// Deterministic: the same profile, options and engine version give the same report.
public struct ConversionReport: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Hashable, Sendable {
        /// The output represents the profile completely.
        case exact
        /// The output is usable but differs from the profile; see `issues`.
        case degraded
        /// No usable output: the selected route could not be compiled.
        case blocked
    }

    public var engine: EngineID
    /// Engine version the compiler's rules were written against.
    public var engineVersion: String
    public var issues: [ConversionIssue]
    public var verdict: Verdict
    /// Model tag → tag used in the engine configuration, for every emitted outbound and group.
    public var engineTags: [String: String]
    /// Model tags of outbounds that were excluded because of an error.
    public var excludedOutbounds: [String]

    public init(
        engine: EngineID,
        engineVersion: String,
        issues: [ConversionIssue] = [],
        verdict: Verdict = .exact,
        engineTags: [String: String] = [:],
        excludedOutbounds: [String] = []
    ) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.issues = issues
        self.verdict = verdict
        self.engineTags = engineTags
        self.excludedOutbounds = excludedOutbounds
    }

    public var highestSeverity: ConversionIssue.Severity? {
        return issues.map { $0.severity }.max()
    }

    public func issues(at pathPrefix: String) -> [ConversionIssue] {
        return issues.filter { $0.path.hasPrefix(pathPrefix) }
    }

    public func hasIssue(_ kind: ConversionIssue.Kind, pathContaining fragment: String) -> Bool {
        return issues.contains { $0.kind == kind && $0.path.contains(fragment) }
    }

    mutating func add(
        _ path: String,
        _ kind: ConversionIssue.Kind,
        _ severity: ConversionIssue.Severity,
        _ detail: String
    ) {
        issues.append(ConversionIssue(path: path, kind: kind, severity: severity, detail: detail))
    }
}
