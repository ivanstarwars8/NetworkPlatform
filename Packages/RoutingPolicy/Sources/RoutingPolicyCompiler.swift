import ConfigurationEngine
import DomainModels
import Foundation
import RoutingEngine

/// Where a rule of the compiled table came from: what the route simulator names as the reason.
public enum RuleOrigin: Hashable, Sendable {
    case custom(UUID)
    case remote(UUID)
    case preset(RoutingPreset, groupID: String)
}

/// The routing settings compiled for one profile: the table both engine compilers take (and the simulator
/// evaluates), with the origin of each table rule, and the DNS inputs of the compilers.
public struct CompiledPolicy: Sendable {
    /// Always set, also for "everything through the tunnel" (a table with no rules): the simulator uses it.
    public var table: RoutingTable
    /// Origin of `table.rules[i]`.
    public var origins: [RuleOrigin]
    /// The action meaning "through the tunnel" for this profile.
    public var tunnelAction: RouteAction
    /// `true` when the table sends everything to the tunnel and has no rules: the compilers then get no
    /// table at all and write their plain "everything to the selected route" form.
    public var isPassthrough: Bool

    public var dnsServers: [String]
    public var dnsDomainServers: [DNSDomainServer]
    public var dnsIPv6: Bool
    public var dnsFollowsRules: Bool

    /// Things the user should know (a list not downloaded yet, lists over the total limit), in Russian.
    public var notices: [String]

    /// What the engine compilers get as `routing`.
    public var engineTable: RoutingTable? { isPassthrough ? nil : table }

    public func xrayOptions(addressing: TunnelAddressing = .standard) -> XrayCompileOptions {
        var options = XrayCompileOptions.packetTunnel(dnsServers: dnsServers, addressing: addressing, routing: engineTable)
        options.dnsDomainServers = dnsDomainServers
        options.dnsIPv6 = dnsIPv6
        options.dnsFollowsRules = dnsFollowsRules
        return options
    }

    public func mihomoOptions(addressing: TunnelAddressing = .standard) -> MihomoCompileOptions {
        var options = MihomoCompileOptions.packetTunnel(dnsServers: dnsServers, addressing: addressing, routing: engineTable)
        options.dnsDomainServers = dnsDomainServers
        options.dnsIPv6 = dnsIPv6
        options.dnsFollowsRules = dnsFollowsRules
        return options
    }
}

/// A policy that cannot be compiled, with a message for the user.
public struct PolicyCompileError: Error, Hashable, Sendable {
    public var message: String
}

/// Settings → `RoutingTable`. Priority order: own rules, then downloaded lists, then the preset's lists,
/// then the preset's final target. Domain strategy is always `asIs`: the router never resolves names on its
/// own (no extra DNS queries per connection); address rules see the connection's address.
public struct RoutingPolicyCompiler: Sendable {
    public var settings: RoutingSettings
    /// Cached compact entries of the downloaded lists, by list id.
    public var ruleSets: [UUID: CompiledRuleSet]
    public var limits: RuleSetLimits

    public init(settings: RoutingSettings, ruleSets: [UUID: CompiledRuleSet], limits: RuleSetLimits = .standard) {
        self.settings = settings
        self.ruleSets = ruleSets
        self.limits = limits
    }

    /// The tunnel action of a profile: its selected outbound or group, else its first outbound.
    public static func tunnelAction(for profile: Profile) -> RouteAction? {
        guard let tag = profile.selectedTag ?? profile.outbounds.first?.tag else { return nil }
        return profile.group(tagged: tag) != nil ? .group(tag) : .proxy(tag)
    }

    public func compile(for profile: Profile) -> Result<CompiledPolicy, PolicyCompileError> {
        guard let tunnel = RoutingPolicyCompiler.tunnelAction(for: profile) else {
            return .failure(PolicyCompileError(message: "В профиле нет серверов."))
        }
        func action(_ target: RuleTarget) -> RouteAction {
            switch target {
            case .tunnel: return tunnel
            case .direct: return .direct
            case .block: return .reject
            }
        }
        var rules: [RoutingRule] = []
        var origins: [RuleOrigin] = []
        var notices: [String] = []

        for rule in settings.customRules {
            guard let condition = rule.condition else {
                notices.append("Правило «\(rule.value)» не читается и пропущено.")
                continue
            }
            rules.append(RoutingRule(id: "custom.\(rule.id.uuidString)", condition: condition, action: action(rule.target), isEnabled: rule.isEnabled))
            origins.append(.custom(rule.id))
        }

        var total = 0
        for list in settings.remoteRuleSets where list.isEnabled {
            guard let content = ruleSets[list.id], content.entryCount > 0 else {
                notices.append("Список «\(list.name)» ещё не загружен и не применяется.")
                continue
            }
            guard total + content.entryCount <= limits.maximumTotalEntries else {
                notices.append("Список «\(list.name)» не применяется: во всех списках вместе больше \(limits.maximumTotalEntries) записей.")
                continue
            }
            total += content.entryCount
            rules.append(RoutingRule(id: "list.\(list.id.uuidString)", condition: .or(content.conditions), action: action(list.target)))
            origins.append(.remote(list.id))
        }

        for group in PresetLists.groups(of: settings.preset) {
            rules.append(RoutingRule(id: "preset.\(group.id)", condition: .or(group.conditions), action: action(group.target)))
            origins.append(.preset(settings.preset, groupID: group.id))
        }

        let table = RoutingTable(rules: rules, ruleSets: [], finalAction: action(settings.preset.finalTarget), domainStrategy: .asIs)
        do {
            _ = try CompiledRouter(table: table)
            let lowered = try RuleLowering.lower(table)
            if let issue = lowered.issues.first {
                return .failure(PolicyCompileError(message: "Правило №\((issue.ruleIndex ?? 0) + 1) нельзя передать движку: \(issue.detail)."))
            }
        } catch {
            return .failure(PolicyCompileError(message: "Правила не собираются: \(error)."))
        }

        let dns = settings.dns
        return .success(CompiledPolicy(
            table: table,
            origins: origins,
            tunnelAction: tunnel,
            isPassthrough: rules.isEmpty && settings.preset.finalTarget == .tunnel,
            dnsServers: dns.servers,
            dnsDomainServers: dns.domainServers.map { DNSDomainServer(domains: [$0.domain], server: $0.server) },
            dnsIPv6: dns.ipv6,
            dnsFollowsRules: !dns.leakProtection,
            notices: notices
        ))
    }
}
