import ConfigurationEngine
import DomainModels
import Foundation
import RoutingPolicy

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
    /// The user's routing and DNS settings. `nil`: everything through the selected route, `dnsServers`.
    public var policy: RoutingPolicyCompiler?

    public init(addressing: TunnelAddressing = .standard, dnsServers: [String] = [], policy: RoutingPolicyCompiler? = nil) {
        self.addressing = addressing
        self.dnsServers = dnsServers
        self.policy = policy
    }

    public func compile(
        _ profile: Profile,
        for engine: TunnelEngine,
        resolveSecret: @escaping @Sendable (SecretReference) -> String?
    ) throws -> CompiledTunnelStart {
        var xrayOptions = XrayCompileOptions.packetTunnel(dnsServers: dnsServers, addressing: addressing)
        var mihomoOptions = MihomoCompileOptions.packetTunnel(dnsServers: dnsServers, addressing: addressing)
        var policyNotices: [ProfileNotice] = []
        if let policy = policy {
            switch policy.compile(for: profile) {
            case .success(let compiled):
                xrayOptions = compiled.xrayOptions(addressing: addressing)
                mihomoOptions = compiled.mihomoOptions(addressing: addressing)
                policyNotices = compiled.notices.map { ProfileNotice(.warning, $0) }
            case .failure(let error):
                throw TunnelCompileFailure(notices: [ProfileNotice(.error, error.message)])
            }
        }
        let text: String?
        let report: ConversionReport
        let plan: XrayTunnelPlan?
        switch engine {
        case .xray:
            let compilation = XrayConfigCompiler(
                options: xrayOptions,
                resolveSecret: resolveSecret
            ).compile(profile)
            // `jsonText` fails only for values JSON cannot carry; reported as a blocked compilation.
            text = try? compilation.jsonText()
            report = compilation.report
            plan = compilation.tunnel
        case .mihomo:
            let compilation = MihomoConfigCompiler(
                options: mihomoOptions,
                resolveSecret: resolveSecret
            ).compile(profile)
            text = compilation.yamlText()
            report = compilation.report
            plan = compilation.tunnel
        }
        let notices = policyNotices + TunnelStartCompiler.notices(of: report)
        guard report.verdict != .blocked, let text = text, !text.isEmpty, let plan = plan else {
            var failure = notices.filter { $0.severity == .error }
            if failure.isEmpty {
                failure = [ProfileNotice(.error, "the \(engine.rawValue) compiler produced no configuration")]
            }
            throw TunnelCompileFailure(notices: failure)
        }
        return CompiledTunnelStart(
            engine: engine, configuration: Data(text.utf8), tunnel: plan, report: report, notices: notices
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
