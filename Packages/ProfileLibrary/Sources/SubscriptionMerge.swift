import DomainModels
import Foundation

/// The stable key of a server across refreshes: protocol, host and port, plus its occurrence among servers
/// with the same three (a provider may list one address twice with different transports). Used as a
/// dictionary key only; never shown and never logged.
public struct ServerIdentity: Hashable, Sendable {
    public let key: String

    /// Identities of `outbounds` in order.
    public static func identities(of outbounds: [Outbound]) -> [ServerIdentity] {
        var seen: [String: Int] = [:]
        return outbounds.map { outbound in
            let base = "\(outbound.kind.rawValue)|\(outbound.server.host.lowercased())|\(outbound.server.port)"
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return ServerIdentity(key: occurrence == 0 ? base : "\(base)#\(occurrence)")
        }
    }
}

/// Merges a freshly downloaded subscription into the stored profile.
///
/// Kept from the stored profile: its id, its name, its source, the tag of every server that is still there
/// (so the user's server choice survives), and the user's edits (names, hidden servers). Taken from the fresh
/// list: which servers exist, their order and settings. Pure: no I/O.
public enum SubscriptionMerger {
    public static func merge(stored: Profile, fresh: Profile, edits: SubscriptionEdits) -> (profile: Profile, diff: SubscriptionDiff) {
        let storedIdentities = ServerIdentity.identities(of: stored.outbounds)
        var storedByIdentity: [ServerIdentity: Outbound] = [:]
        for (identity, outbound) in zip(storedIdentities, stored.outbounds) {
            storedByIdentity[identity] = outbound
        }

        var diff = SubscriptionDiff()
        var merged: [Outbound] = []
        var used = Set<String>()
        var freshIdentities = Set<ServerIdentity>()
        // Tags of servers that stay are reserved first, so a new server never takes one.
        let freshList = ServerIdentity.identities(of: fresh.outbounds)
        for identity in freshList where !edits.hidden.contains(identity.key) {
            if let old = storedByIdentity[identity] { used.insert(old.tag) }
        }
        for (identity, outbound) in zip(freshList, fresh.outbounds) {
            freshIdentities.insert(identity)
            if edits.hidden.contains(identity.key) { continue }
            var server = outbound
            if let name = edits.names[identity.key] { server.name = name }
            if let old = storedByIdentity[identity] {
                server.tag = old.tag
                if old.name != server.name || !sameSettings(old, outbound) {
                    diff.changed.append(server.name)
                } else {
                    diff.unchanged += 1
                }
            } else {
                server.tag = ProfileImporter.uniqueTag(outbound.tag, index: merged.count, used: &used)
                diff.added.append(server.name)
            }
            merged.append(server)
        }
        for (identity, outbound) in zip(storedIdentities, stored.outbounds) where !freshIdentities.contains(identity) {
            diff.removed.append(outbound.name)
        }

        var profile = stored
        profile.outbounds = merged
        profile.groups = []
        if let selected = stored.selectedTag, merged.contains(where: { $0.tag == selected }) {
            profile.selectedTag = selected
        } else {
            profile.selectedTag = merged.first?.tag
        }
        return (profile, diff)
    }

    /// Settings compared without the tag, the name and the credentials: stored credentials are references
    /// to the secret store and cannot be compared with fresh inline values.
    static func sameSettings(_ stored: Outbound, _ fresh: Outbound) -> Bool {
        stored.kind == fresh.kind && stored.server == fresh.server && stored.settings == fresh.settings
            && stored.stream == fresh.stream && stored.extras == fresh.extras
    }
}
