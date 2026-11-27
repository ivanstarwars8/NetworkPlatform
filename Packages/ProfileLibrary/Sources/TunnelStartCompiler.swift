import ConfigurationEngine
import DomainModels
import Foundation

/// The engines a profile can be compiled for. Raw values are the engines' `CoreDescriptor.id`, which is what
/// `TunnelStartRequest.coreID` and `TunnelEngineCatalog` use.
public enum TunnelEngine: String, CaseIterable, Sendable {
    case xray
    case mihomo

    /// Configuration format the engine's adapter accepts (`XrayCore.configurationFormat`, `MihomoCore`).
    public var configurationFormat: String {
        switch self {
        case .xray: return "json"
        case .mihomo: return "yaml"
        }
    }
}

/// A profile compiled for the Packet Tunnel: everything a `TunnelStartRequest` needs. The configuration holds
/// the secrets inline (the extension does not read the Keychain, ADR-0003 §4): never log it. `description`
/// leaves it out.
public struct CompiledTunnelStart: Sendable, CustomStringConvertible {
    public var engine: TunnelEngine
    public var configuration: Data
    public var tunnel: XrayTunnelPlan
    public var report: ConversionReport
    /// Warnings and errors of the compilation (info entries are left out), safe to show.
    public var notices: [ProfileNotice]
    /// How to switch servers inside the running engine; `nil` for a profile with one server or with groups
    /// of its own.
    public var selectionPlan: ServerSelectionPlan?
    /// The choice the configuration was compiled for.
    public var choice: ServerChoice
    /// The engine selection to apply right after start (`TunnelStartRequest.groupSelection`).
    public var initialSelection: (group: String, member: String?)? {
        selectionPlan?.initialSelection(for: choice)
    }

    public var coreID: String { engine.rawValue }
    public var format: String { engine.configurationFormat }

    public var description: String {
        "CompiledTunnelStart(\(engine.rawValue), \(configuration.count) bytes, verdict \(report.verdict.rawValue))"
    }
}

/// A compilation that produced nothing to start, with the compiler's reasons.
public struct TunnelCompileFailure: Error, Sendable {
    public var notices: [ProfileNotice]

    public init(notices: [ProfileNotice]) {
        self.notices = notices
    }

    public var summary: String {
        notices.first(where: { $0.severity == .error })?.text ?? "the profile could not be compiled"
    }
}

/// Compiles a stored profile with the packet-tunnel options of ConfigurationEngine (tunnel inbound, shared
/// `TunnelAddressing`, mobile memory profile). Secrets are resolved through `resolveSecret`.
public struct TunnelStartCompiler: Sendable {
    public var addressing: TunnelAddressing
    public var dnsServers: [String]

    public init(addressing: TunnelAddressing = .standard, dnsServers: [String] = []) {
        self.addressing = addressing
        self.dnsServers = dnsServers
    }

    /// Compiles `profile` for `engine`. For a profile with several servers and no groups of its own, all
    /// servers are compiled with an automatic group, whatever `choice` is: switching later (to another server
    /// or back to «Авто») then happens inside the running engine. A manual `choice` becomes the initial
    /// selection; a chosen tag that is not in the profile falls back to «Авто» with a notice.
    public func compile(
        _ profile: Profile,
        for engine: TunnelEngine,
        choice: ServerChoice = .automatic,
        resolveSecret: @escaping @Sendable (SecretReference) -> String?
    ) throws -> CompiledTunnelStart {
        var choice = choice
        var extraNotices: [ProfileNotice] = []
        let automatic = AutomaticGroup.applies(to: profile)
        let source: Profile
        if automatic {
            source = profile.withAutomaticGroups(for: engine)
            if case let .server(tag) = choice, profile.outbound(tagged: tag) == nil {
                choice = .automatic
                extraNotices.append(ProfileNotice(.warning, "The chosen server is no longer in the profile; «Авто» is used"))
            }
        } else {
            source = profile
            choice = .automatic
        }
        let text: String?
        let report: ConversionReport
        let plan: XrayTunnelPlan?
        switch engine {
        case .xray:
            let compilation = XrayConfigCompiler(
                options: .packetTunnel(dnsServers: dnsServers, addressing: addressing),
                resolveSecret: resolveSecret
            ).compile(source)
            // `jsonText` fails only for values JSON cannot carry; reported as a blocked compilation.
            text = try? compilation.jsonText()
            report = compilation.report
            plan = compilation.tunnel
        case .mihomo:
            let compilation = MihomoConfigCompiler(
                options: .packetTunnel(dnsServers: dnsServers, addressing: addressing),
                resolveSecret: resolveSecret
            ).compile(source)
            text = compilation.yamlText()
            report = compilation.report
            plan = compilation.tunnel
        }
        let notices = extraNotices + TunnelStartCompiler.notices(of: report)
        guard report.verdict != .blocked, let text = text, !text.isEmpty, let plan = plan else {
            var failure = notices.filter { $0.severity == .error }
            if failure.isEmpty {
                failure = [ProfileNotice(.error, "the \(engine.rawValue) compiler produced no configuration")]
            }
            throw TunnelCompileFailure(notices: failure)
        }
        var selectionPlan: ServerSelectionPlan?
        if automatic {
            selectionPlan = ServerSelectionPlan(engine: engine, profile: profile, engineTags: report.engineTags)
            if selectionPlan == nil {
                throw TunnelCompileFailure(notices: [ProfileNotice(.error, "the automatic group could not be compiled")])
            }
            if case let .server(tag) = choice, selectionPlan?.members[tag] == nil {
                throw TunnelCompileFailure(notices: [ProfileNotice(.error, "the chosen server could not be compiled for \(engine.rawValue)")])
            }
        }
        return CompiledTunnelStart(
            engine: engine, configuration: Data(text.utf8), tunnel: plan, report: report, notices: notices,
            selectionPlan: selectionPlan, choice: choice
        )
    }

    /// The report's warnings and errors. Compiler details are written without configuration values.
    static func notices(of report: ConversionReport) -> [ProfileNotice] {
        report.issues.compactMap { issue in
            let severity: ProfileNotice.Severity
            switch issue.severity {
            case .info: return nil
            case .warning: severity = .warning
            case .error: severity = .error
            }
            return ProfileNotice(severity, "\(issue.path): \(issue.detail)")
        }
    }
}
