// Verified on Linux (Swift 5.10, swift test). Which engine can run a profile, read from the compilers' own
// reports (Documentation/Architecture/engine-choice.md). PROTOCOL_MATRIX.md describes the same facts for people;
// the reports are the source of truth because they are what the compilers actually do.

import ConfigurationEngine
import DomainModels
import Foundation
import ProfileLibrary

/// Something of the profile an engine's configuration would not carry as written.
public struct FeatureLoss: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// The engine cannot express it; the outbound or rule is left out.
        case unsupported
        /// Left out of the configuration.
        case dropped
        /// Expressed with another meaning or precision.
        case approximated
        /// A whole server was excluded from the configuration.
        case excludedServer
    }

    public var kind: Kind
    /// Location in the model (`outbounds[2].stream.transport`) or the server's tag.
    public var path: String
    /// The compiler's detail; never contains configuration values (ConversionIssue contract).
    public var detail: String

    public init(kind: Kind, path: String, detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

/// How completely one engine can run one profile.
public struct EngineSupport: Hashable, Sendable {
    public enum Level: Int, Hashable, Sendable, Comparable {
        /// Nothing can be started with this engine.
        case unsupported = 0
        /// Starts, but leaves something out (`losses`).
        case partial = 1
        /// Carries the whole profile.
        case complete = 2

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var engine: TunnelEngine
    public var level: Level
    public var losses: [FeatureLoss]
    /// Why the engine cannot run the profile (errors of the compiler), when `level == .unsupported`.
    public var blockers: [String]

    public init(engine: TunnelEngine, level: Level, losses: [FeatureLoss] = [], blockers: [String] = []) {
        self.engine = engine
        self.level = level
        self.losses = losses
        self.blockers = blockers
    }

    /// Reads a compiler report. Only real losses count: `untested`, `migrated` and `engineLocked` entries do
    /// not change what reaches the network, and `invalid` describes the profile, not the engine.
    public init(engine: TunnelEngine, report: ConversionReport) {
        var losses: [FeatureLoss] = []
        for issue in report.issues where issue.severity >= .warning {
            let kind: FeatureLoss.Kind
            switch issue.kind {
            case .unsupported: kind = .unsupported
            case .dropped: kind = .dropped
            case .approximated: kind = .approximated
            case .migrated, .engineLocked, .untested, .invalid: continue
            }
            losses.append(FeatureLoss(kind: kind, path: issue.path, detail: issue.detail))
        }
        for tag in report.excludedOutbounds.sorted() {
            losses.append(FeatureLoss(kind: .excludedServer, path: tag, detail: "server excluded from the configuration"))
        }
        let blockers = report.verdict == .blocked
            ? report.issues.filter { $0.severity == .error }.map { "\($0.path): \($0.detail)" }
            : []
        let level: Level
        if report.verdict == .blocked {
            level = .unsupported
        } else if losses.isEmpty {
            level = .complete
        } else {
            level = .partial
        }
        self.init(engine: engine, level: level, losses: losses, blockers: blockers)
    }

    /// Compiles `profile` for `engine` and reads the outcome. A compilation that produced no report (it never
    /// ran) is unsupported with the compiler's message.
    public static func assess(
        _ profile: Profile,
        engine: TunnelEngine,
        compiler: TunnelStartCompiler = TunnelStartCompiler(),
        resolveSecret: @escaping @Sendable (SecretReference) -> String?
    ) -> EngineSupport {
        do {
            let compiled = try compiler.compile(profile, for: engine, resolveSecret: resolveSecret)
            return EngineSupport(engine: engine, report: compiled.report)
        } catch let failure as TunnelCompileFailure {
            if let report = failure.report {
                var support = EngineSupport(engine: engine, report: report)
                // A compiler that returned a report but no text is still a blocked start.
                support.level = .unsupported
                if support.blockers.isEmpty { support.blockers = failure.notices.map(\.text) }
                return support
            }
            return EngineSupport(engine: engine, level: .unsupported, blockers: failure.notices.map(\.text))
        } catch {
            return EngineSupport(engine: engine, level: .unsupported, blockers: ["\(type(of: error))"])
        }
    }
}
