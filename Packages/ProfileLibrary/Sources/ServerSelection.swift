import ConfigurationEngine
import DomainModels
import Foundation

/// Which server of a profile traffic goes to: chosen by the engine from its own measurements («Авто»), or
/// one server the user picked (by its tag in the profile).
public enum ServerChoice: Hashable, Sendable, Codable {
    case automatic
    case server(tag: String)
}

/// How the engine's health check of the automatic group is set up. Interval: a compromise between failover
/// time (a dead server is noticed at the next round at the latest) and battery (one small request per server
/// per round). Values of this project, not measured on devices.
public enum AutomaticGroup {
    /// The probe address: an empty 204 answer, the same default the Mihomo compiler uses.
    public static let probeURL = MihomoConfigCompiler.defaultHealthCheckURL
    public static let intervalSeconds = 180
    public static let timeoutMilliseconds = 5000
    /// Mihomo keeps the current member while a new one is not faster by more than this.
    public static let toleranceMilliseconds = 50

    /// Profile tags of the two groups added at compile time; never stored in a profile.
    static let automaticTag = "np-automatic"
    static let choiceTag = "np-choice"

    /// A profile qualifies when it has at least two servers and no groups of its own (a subscription or a
    /// pasted list). With one server there is nothing to choose; profiles with their own groups keep them.
    public static func applies(to profile: Profile) -> Bool {
        profile.outbounds.count >= 2 && profile.groups.isEmpty
    }
}

/// What the app needs to switch servers inside the running engine: which engine group to send a selection
/// to, what to send for «Авто» and each server, and which group's measurements to read. Built from the
/// compiler's report (`engineTags`), so it always names what the configuration really contains.
public struct ServerSelectionPlan: Hashable, Sendable, Codable {
    /// The engine group a selection goes to.
    public var group: String
    /// The member that means «Авто» in `group`; `nil` = clear the pin (Xray balancer).
    public var automaticMember: String?
    /// The engine group whose members carry the engine's latency measurements.
    public var measuredGroup: String
    /// Profile server tag → engine tag.
    public var members: [String: String]

    /// The selection that makes `choice` current. `nil` for a server the configuration does not contain.
    public func selection(for choice: ServerChoice) -> (group: String, member: String?)? {
        switch choice {
        case .automatic:
            return (group, automaticMember)
        case let .server(tag):
            guard let member = members[tag] else { return nil }
            return (group, member)
        }
    }

    /// The selection to apply right after the engine starts; `nil` when the configuration already starts
    /// on `choice` (automatic is every compiled group's starting state).
    public func initialSelection(for choice: ServerChoice) -> (group: String, member: String?)? {
        if case .automatic = choice { return nil }
        return selection(for: choice)
    }

    /// Profile tag of an engine member tag, the reverse of `members`.
    public func profileTag(ofEngineTag engineTag: String) -> String? {
        members.first { $0.value == engineTag }?.key
    }
}

extension Profile {
    /// The profile the compilers see for an automatic-capable profile: an automatic group (lowest measured
    /// latency, the engine's own health check) over every server, and — for Mihomo, whose selector can be
    /// switched at run time — a selector over «Авто» and every server. Xray resolves a selector at compile
    /// time, so Xray routes straight to the automatic group (a balancer) and a manual choice pins its member.
    func withAutomaticGroups(for engine: TunnelEngine) -> Profile {
        var compiled = self
        let check = OutboundGroup.HealthCheck(
            url: AutomaticGroup.probeURL,
            intervalSeconds: AutomaticGroup.intervalSeconds,
            timeoutMilliseconds: engine == .mihomo ? AutomaticGroup.timeoutMilliseconds : nil,
            toleranceMilliseconds: engine == .mihomo ? AutomaticGroup.toleranceMilliseconds : nil
        )
        let servers = outbounds.map { OutboundGroup.Member.outbound(tag: $0.tag) }
        compiled.groups = [
            OutboundGroup(tag: AutomaticGroup.automaticTag, name: "Авто", kind: .urlTest, members: servers, healthCheck: check),
        ]
        switch engine {
        case .xray:
            compiled.selectedTag = AutomaticGroup.automaticTag
        case .mihomo:
            compiled.groups.append(OutboundGroup(
                tag: AutomaticGroup.choiceTag, name: "Выбор", kind: .selector,
                members: [.group(tag: AutomaticGroup.automaticTag)] + servers,
                defaultMemberTag: AutomaticGroup.automaticTag
            ))
            compiled.selectedTag = AutomaticGroup.choiceTag
        }
        return compiled
    }
}

extension ServerSelectionPlan {
    /// The plan of a compilation of `withAutomaticGroups(for:)`; `nil` when the report lacks a tag (a server
    /// that could not be compiled is simply absent from `members`).
    init?(engine: TunnelEngine, profile: Profile, engineTags: [String: String]) {
        guard let automatic = engineTags[AutomaticGroup.automaticTag] else { return nil }
        var members: [String: String] = [:]
        for outbound in profile.outbounds {
            if let tag = engineTags[outbound.tag] { members[outbound.tag] = tag }
        }
        guard !members.isEmpty else { return nil }
        switch engine {
        case .xray:
            self.init(group: automatic, automaticMember: nil, measuredGroup: automatic, members: members)
        case .mihomo:
            guard let choice = engineTags[AutomaticGroup.choiceTag] else { return nil }
            self.init(group: choice, automaticMember: automatic, measuredGroup: automatic, members: members)
        }
    }
}
