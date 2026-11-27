// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never run against the real
// bridge or inside a Packet Tunnel extension.
import ConfigurationEngine
import CoreAbstraction
import Foundation

/// The output of `MihomoConfigCompiler` in the form `MihomoCore` takes (ADR-0002: the engine's configuration is
/// the result of compiling the model; the loss report travels with it).
///
/// - `configuration`: the compiler's YAML text, unchanged, labelled `yaml` for the Mihomo core.
/// - `startOptions`: the MTU the YAML's `tun` section was compiled for, so the bridge's flow listener and the
///   core agree (`TunnelAddressing` is the only source of tunnel addresses and MTU).
/// - `tunnel`: the plan for the system interface (`TunnelNetworkPlan(addressing:excludedRoutes:remoteAddress:)`).
/// - `reportIssues`: the compiler's warnings and errors as validation issues, so that a host can show them next
///   to what the bridge's check returns. `info` entries stay in `report` only.
///
/// A blocked compilation (no document) is refused with `CoreError.invalidConfiguration`: nothing is handed to
/// the core that the compiler itself rejected. Report details never contain configuration values (the compiler
/// redacts them), so the thrown issues are safe to log.
public struct MihomoCompiledConfiguration: Sendable {
    public let configuration: CoreConfiguration
    public let report: ConversionReport
    public let tunnel: XrayTunnelPlan?

    public init(_ compilation: MihomoCompilation) throws {
        guard compilation.report.engine == .mihomo else {
            throw CoreError.configurationMismatch(expected: MihomoCore.identifier, actual: CoreIdentifier(compilation.report.engine.rawValue))
        }
        guard compilation.report.verdict != .blocked, let text = compilation.yamlText() else {
            var issues = MihomoCompiledConfiguration.issues(of: compilation.report).filter { $0.severity == .error }
            if issues.isEmpty {
                issues = [CoreValidationIssue(severity: .error, message: "the Mihomo compiler produced no configuration")]
            }
            throw CoreError.invalidConfiguration(issues: issues)
        }
        self.configuration = CoreConfiguration(coreID: MihomoCore.identifier, format: "yaml", payload: Data(text.utf8))
        self.report = compilation.report
        self.tunnel = compilation.tunnel
    }

    /// Start options for the packet flow: the compiled MTU, no file descriptor (the Mihomo bridge has no fd
    /// mode). `memoryLimitBytes` stays with the adapter's settings.
    public var startOptions: CoreStartOptions {
        CoreStartOptions(mtu: tunnel?.addressing.mtu)
    }

    public var reportIssues: [CoreValidationIssue] {
        MihomoCompiledConfiguration.issues(of: report)
    }

    static func issues(of report: ConversionReport) -> [CoreValidationIssue] {
        report.issues.compactMap { issue in
            let severity: CoreValidationIssue.Severity
            switch issue.severity {
            case .info: return nil
            case .warning: severity = .warning
            case .error: severity = .error
            }
            return CoreValidationIssue(severity: severity, path: issue.path, message: "\(issue.kind.rawValue): \(issue.detail)")
        }
    }
}
