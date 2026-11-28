// Verified on Linux only (Swift 5.10.1, swift test).
import Foundation

/// What the running core knows about one member of an outbound group. Every number is the core's own
/// measurement (Xray observatory, Mihomo health check); nothing here is estimated.
public struct CoreGroupMember: Hashable, Sendable, Codable {
    /// The member's tag in the engine configuration (the compiler's report maps profile tags to it).
    public var tag: String
    /// The core's last health check of this member succeeded.
    public var alive: Bool
    /// The last measured delay, `nil` when the member has not been measured or failed.
    public var delayMilliseconds: Int?
    /// When the core last tried / last succeeded to reach the member, `nil` when it never did.
    public var lastTry: Date?
    public var lastSeen: Date?

    public init(tag: String, alive: Bool, delayMilliseconds: Int? = nil, lastTry: Date? = nil, lastSeen: Date? = nil) {
        self.tag = tag
        self.alive = alive
        self.delayMilliseconds = delayMilliseconds
        self.lastTry = lastTry
        self.lastSeen = lastSeen
    }
}

/// One outbound group (Xray balancer, Mihomo proxy group) of the running configuration.
public struct CoreGroupObservation: Hashable, Sendable, Codable {
    public var tag: String
    /// The engine's name for the strategy or the group type; informational.
    public var kind: String
    /// The member new connections go to, when the core can say.
    public var current: String?
    /// The member pinned with `selectGroupMember`, `nil` when the group chooses by itself.
    public var pinned: String?
    public var members: [CoreGroupMember]

    public init(tag: String, kind: String, current: String?, pinned: String?, members: [CoreGroupMember]) {
        self.tag = tag
        self.kind = kind
        self.current = current
        self.pinned = pinned
        self.members = members
    }
}

/// A core whose outbound groups can be observed and switched while it runs, without a restart
/// (`CoreFeature.selectorGroups`). Both calls follow the rules of `statistics`: not serialised with commands,
/// safe at any time, and answered from in-process state (no probe is sent by the call).
public protocol OutboundGroupControlling: NetworkCore {
    func groupObservations() async throws -> [CoreGroupObservation]
    /// Pins `member` for new connections of `group`; `nil` gives the choice back to the group. Existing
    /// connections keep their outbound.
    func selectGroupMember(group: String, member: String?) async throws
}

extension CoreLifecycle {
    /// The core's groups, while it runs. `unsupportedFeature(.selectorGroups)` for a core without groups.
    public func groupObservations() async throws -> [CoreGroupObservation] {
        guard state == .running || state == .reloading else {
            throw CoreError.notRunning(state: state)
        }
        guard let controlling = core as? any OutboundGroupControlling else {
            throw CoreError.unsupportedFeature(.selectorGroups)
        }
        do {
            return try await controlling.groupObservations()
        } catch {
            throw CoreError.normalise(error, during: .statistics)
        }
    }

    /// Switches a group's member while the core runs.
    public func selectGroupMember(group: String, member: String?) async throws {
        guard state == .running else {
            throw CoreError.notRunning(state: state)
        }
        guard let controlling = core as? any OutboundGroupControlling else {
            throw CoreError.unsupportedFeature(.selectorGroups)
        }
        do {
            try await controlling.selectGroupMember(group: group, member: member)
        } catch {
            throw CoreError.normalise(error, during: .statistics)
        }
    }
}
