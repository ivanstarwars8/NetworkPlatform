import Foundation

public enum ProfileSource: Codable, Hashable, Sendable {
    case manual
    case shareLink
    case subscription(url: String)
    case file(name: String)
}

public struct ProfileValidationIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case emptyTag
        case duplicateTag
        case emptyGroup
        case danglingMember
        case memberKindMismatch
        case danglingDefaultMember
        case groupCycle
        case nestingTooDeep
        case danglingSelection
    }

    public var kind: Kind
    /// Tag of the outbound or group the issue is about.
    public var tag: String
    public var detail: String

    public init(kind: Kind, tag: String, detail: String) {
        self.kind = kind
        self.tag = tag
        self.detail = detail
    }
}

/// A stored set of outbounds and groups. Source of truth; engine configs are compiled from it (ADR-0002).
public struct Profile: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    /// Deepest allowed chain of groups containing groups.
    public static let maximumGroupNestingDepth = 8

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var source: ProfileSource
    public var outbounds: [Outbound]
    public var groups: [OutboundGroup]
    /// Tag of the outbound or group traffic goes to.
    public var selectedTag: String?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = Profile.currentSchemaVersion,
        name: String,
        source: ProfileSource = .manual,
        outbounds: [Outbound] = [],
        groups: [OutboundGroup] = [],
        selectedTag: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.source = source
        self.outbounds = outbounds
        self.groups = groups
        self.selectedTag = selectedTag
    }

    public func outbound(tagged tag: String) -> Outbound? {
        return outbounds.first { $0.tag == tag }
    }

    public func group(tagged tag: String) -> OutboundGroup? {
        return groups.first { $0.tag == tag }
    }

    /// Structural check. An empty result means the profile is internally consistent.
    /// The result is deterministic for a given profile.
    public func validate() -> [ProfileValidationIssue] {
        var issues: [ProfileValidationIssue] = []
        var outboundTags = Set<String>()
        var groupTags = Set<String>()
        var seenTags = Set<String>()

        for outbound in outbounds {
            if outbound.tag.isEmpty {
                issues.append(ProfileValidationIssue(kind: .emptyTag, tag: "", detail: "Outbound has an empty tag"))
                continue
            }
            if seenTags.contains(outbound.tag) {
                issues.append(ProfileValidationIssue(
                    kind: .duplicateTag, tag: outbound.tag, detail: "Tag is used more than once"
                ))
            }
            seenTags.insert(outbound.tag)
            outboundTags.insert(outbound.tag)
        }
        for group in groups {
            if group.tag.isEmpty {
                issues.append(ProfileValidationIssue(kind: .emptyTag, tag: "", detail: "Group has an empty tag"))
                continue
            }
            if seenTags.contains(group.tag) {
                issues.append(ProfileValidationIssue(
                    kind: .duplicateTag, tag: group.tag, detail: "Tag is used more than once"
                ))
            }
            seenTags.insert(group.tag)
            groupTags.insert(group.tag)
        }

        for group in groups {
            if group.members.isEmpty {
                issues.append(ProfileValidationIssue(kind: .emptyGroup, tag: group.tag, detail: "Group has no members"))
            }
            for member in group.members {
                switch member {
                case .outbound(let tag):
                    if !outboundTags.contains(tag) {
                        let kind: ProfileValidationIssue.Kind = groupTags.contains(tag)
                            ? .memberKindMismatch : .danglingMember
                        issues.append(ProfileValidationIssue(
                            kind: kind, tag: group.tag, detail: "Member outbound '\(tag)' not found"
                        ))
                    }
                case .group(let tag):
                    if !groupTags.contains(tag) {
                        let kind: ProfileValidationIssue.Kind = outboundTags.contains(tag)
                            ? .memberKindMismatch : .danglingMember
                        issues.append(ProfileValidationIssue(
                            kind: kind, tag: group.tag, detail: "Member group '\(tag)' not found"
                        ))
                    }
                }
            }
            if let defaultTag = group.defaultMemberTag,
               !group.members.contains(where: { $0.tag == defaultTag }) {
                issues.append(ProfileValidationIssue(
                    kind: .danglingDefaultMember, tag: group.tag,
                    detail: "Default member '\(defaultTag)' is not a member of the group"
                ))
            }
        }

        var groupsByTag: [String: OutboundGroup] = [:]
        for group in groups where groupsByTag[group.tag] == nil {
            groupsByTag[group.tag] = group
        }
        var heights: [String: Int] = [:]
        var cyclic = Set<String>()
        for group in groups {
            var path: [String] = []
            let height = Profile.height(
                of: group.tag, groupsByTag: groupsByTag, path: &path, heights: &heights, cyclic: &cyclic
            )
            if height > Profile.maximumGroupNestingDepth {
                issues.append(ProfileValidationIssue(
                    kind: .nestingTooDeep, tag: group.tag,
                    detail: "Group nesting exceeds \(Profile.maximumGroupNestingDepth) levels"
                ))
            }
        }
        var reportedCycle = Set<String>()
        for group in groups where cyclic.contains(group.tag) && !reportedCycle.contains(group.tag) {
            reportedCycle.insert(group.tag)
            issues.append(ProfileValidationIssue(
                kind: .groupCycle, tag: group.tag, detail: "Group is reachable from itself"
            ))
        }

        if let selected = selectedTag, !seenTags.contains(selected) {
            issues.append(ProfileValidationIssue(
                kind: .danglingSelection, tag: selected, detail: "Selected tag does not exist"
            ))
        }
        return issues
    }

    /// Tags of all leaf outbounds reachable from a group, in member order, without repeats.
    /// Returns `nil` if the group does not exist, contains a cycle, a dangling member
    /// or is nested deeper than `maximumGroupNestingDepth`.
    public func flattenedOutboundTags(ofGroup tag: String) -> [String]? {
        var groupsByTag: [String: OutboundGroup] = [:]
        for group in groups where groupsByTag[group.tag] == nil {
            groupsByTag[group.tag] = group
        }
        let outboundTags = Set(outbounds.map { $0.tag })
        var result: [String] = []
        var seen = Set<String>()
        var path: [String] = []
        var expanded = Set<String>()
        let succeeded = Profile.collect(
            tag, groupsByTag: groupsByTag, outboundTags: outboundTags,
            path: &path, expanded: &expanded, seen: &seen, result: &result
        )
        return succeeded ? result : nil
    }

    /// Hard bound on recursion while measuring nesting, independent of the profile size.
    private static let recursionLimit = 64

    /// Height of the group tree below `tag` (a group of plain outbounds has height 1).
    /// Every group is expanded once; recursion depth is bounded by `recursionLimit`.
    private static func height(
        of tag: String,
        groupsByTag: [String: OutboundGroup],
        path: inout [String],
        heights: inout [String: Int],
        cyclic: inout Set<String>
    ) -> Int {
        if let known = heights[tag] { return known }
        if path.contains(tag) {
            cyclic.insert(tag)
            return 0
        }
        guard let group = groupsByTag[tag] else { return 0 }
        if path.count >= recursionLimit {
            return maximumGroupNestingDepth + 1
        }
        path.append(tag)
        var tallest = 0
        for member in group.members {
            if case .group(let memberTag) = member {
                let memberHeight = height(
                    of: memberTag, groupsByTag: groupsByTag, path: &path, heights: &heights, cyclic: &cyclic
                )
                if memberHeight > tallest { tallest = memberHeight }
            }
        }
        path.removeLast()
        let result = tallest + 1
        heights[tag] = result
        return result
    }

    private static func collect(
        _ tag: String,
        groupsByTag: [String: OutboundGroup],
        outboundTags: Set<String>,
        path: inout [String],
        expanded: inout Set<String>,
        seen: inout Set<String>,
        result: inout [String]
    ) -> Bool {
        if path.contains(tag) { return false }
        guard let group = groupsByTag[tag] else { return false }
        if path.count >= maximumGroupNestingDepth { return false }
        // A group already expanded successfully contributes nothing new.
        if expanded.contains(tag) { return true }
        path.append(tag)
        defer { path.removeLast() }
        for member in group.members {
            switch member {
            case .outbound(let memberTag):
                guard outboundTags.contains(memberTag) else { return false }
                if !seen.contains(memberTag) {
                    seen.insert(memberTag)
                    result.append(memberTag)
                }
            case .group(let memberTag):
                let succeeded = collect(
                    memberTag, groupsByTag: groupsByTag, outboundTags: outboundTags,
                    path: &path, expanded: &expanded, seen: &seen, result: &result
                )
                if !succeeded { return false }
            }
        }
        expanded.insert(tag)
        return true
    }
}
