// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

/// One line of an explanation.
public struct RouteTraceEntry: Hashable, Sendable {
    public enum Outcome: String, Hashable, Sendable {
        /// The rule is disabled and was skipped.
        case disabled
        /// The rule has higher priority than the winner but did not match.
        case notMatched
        /// The winning rule.
        case matched
        /// The rule matches too, but a rule with a lower index won.
        case lowerPriority
        /// No rule matched; the final action applies.
        case finalAction
    }

    /// Index in `RoutingTable.rules`; `nil` for the final action.
    public let ruleIndex: Int?
    public let ruleID: String?
    public let outcome: Outcome
    /// Human-readable reason.
    public let reason: String
}

/// The full answer of `RouteSimulator.explain`.
public struct RouteExplanation: Sendable {
    public let request: RouteRequest
    public let decision: RouteDecision
    /// The winning rule, or `nil` when the final action applies.
    public let matchedRule: RoutingRule?
    public let matchedRuleIndex: Int?
    /// Earlier rules that did not win (in priority order, at most
    /// `RouteSimulator.traceLimit`), then the winner or the final action,
    /// then lower-priority rules the indexes also found.
    public let trace: [RouteTraceEntry]
    /// Number of earlier non-matching rules left out of `trace`.
    public let omittedEntries: Int

    /// The trace as plain text, one line per entry.
    public var text: String {
        var lines: [String] = ["request: \(request)", "decision: \(decision.action)"]
        for entry in trace {
            var line: String
            if let index = entry.ruleIndex {
                line = "#\(index)"
                if let id = entry.ruleID { line += " [\(id)]" }
            } else {
                line = "final"
            }
            line += " \(entry.outcome.rawValue): \(entry.reason)"
            lines.append(line)
        }
        if omittedEntries > 0 {
            lines.append("(\(omittedEntries) earlier non-matching rules not shown)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Answers "where would this connection go, and why".
///
/// The decision always comes from `CompiledRouter` (the same code path as
/// real routing); the per-rule reasons come from direct evaluation of the
/// rules involved.
public struct RouteSimulator: Sendable {
    public let router: CompiledRouter
    /// Maximum number of earlier (non-matching) rules listed in a trace.
    public let traceLimit: Int

    public init(router: CompiledRouter, traceLimit: Int = 64) {
        self.router = router
        self.traceLimit = max(0, traceLimit)
    }

    public init(table: RoutingTable, limits: RoutingLimits = .standard, traceLimit: Int = 64) throws {
        let router = try CompiledRouter(table: table, limits: limits)
        self.init(router: router, traceLimit: traceLimit)
    }

    public func explain(_ request: RouteRequest) -> RouteExplanation {
        let input = EvaluationInput(request)
        let candidates = router.candidates(for: input)
        let best = candidates.best
        let rules = router.reference.rules
        let resolved = router.reference.resolved
        let winner: Int? = best == noRuleIndex ? nil : best

        var trace: [RouteTraceEntry] = []

        // 1. Rules with higher priority than the winner.
        let earlierCount = winner ?? rules.count
        let shown = min(earlierCount, traceLimit)
        var index = 0
        while index < shown {
            let rule = rules[index]
            if let condition = resolved[index] {
                let verdict = RouteSimulator.describe(condition, input)
                assert(!verdict.matched, "indexed matcher skipped a matching rule")
                trace.append(RouteTraceEntry(
                    ruleIndex: index,
                    ruleID: rule.id,
                    outcome: .notMatched,
                    reason: RouteSimulator.clip(verdict.text)
                ))
            } else {
                trace.append(RouteTraceEntry(
                    ruleIndex: index,
                    ruleID: rule.id,
                    outcome: .disabled,
                    reason: "rule is disabled"
                ))
            }
            index += 1
        }

        // 2. The winner, or the final action.
        if let winner = winner {
            let rule = rules[winner]
            var reason = "matched"
            if let condition = resolved[winner] {
                reason = RouteSimulator.describe(condition, input).text
            }
            let sources = RouteSimulator.sources(of: winner, in: candidates)
            if !sources.isEmpty {
                reason += " (found by " + sources.joined(separator: ", ") + ")"
            }
            if candidates.cidr == winner, candidates.longestPrefixLength >= 0,
               candidates.longestPrefixIndex != winner {
                reason += "; the most specific prefix /\(candidates.longestPrefixLength)"
                    + " belongs to rule #\(candidates.longestPrefixIndex), which has lower priority"
            }
            reason += "; action \(rule.action)"
            trace.append(RouteTraceEntry(
                ruleIndex: winner,
                ruleID: rule.id,
                outcome: .matched,
                reason: RouteSimulator.clip(reason)
            ))

            // 3. Other rules the indexes found: they match but lost on priority.
            var losers: [Int] = []
            for candidate in [candidates.domain, candidates.cidr, candidates.port, candidates.network] {
                if candidate != noRuleIndex && candidate != winner && !losers.contains(candidate) {
                    losers.append(candidate)
                }
            }
            losers.sort()
            for loser in losers {
                let sources = RouteSimulator.sources(of: loser, in: candidates)
                trace.append(RouteTraceEntry(
                    ruleIndex: loser,
                    ruleID: rules[loser].id,
                    outcome: .lowerPriority,
                    reason: "also matches (found by " + sources.joined(separator: ", ")
                        + ") but rule #\(winner) comes first"
                ))
            }
        } else {
            trace.append(RouteTraceEntry(
                ruleIndex: nil,
                ruleID: nil,
                outcome: .finalAction,
                reason: "no rule matched; final action \(router.reference.finalAction)"
            ))
        }

        let decision: RouteDecision
        if let winner = winner {
            decision = RouteDecision(action: rules[winner].action, ruleIndex: winner)
        } else {
            decision = RouteDecision(action: router.reference.finalAction, ruleIndex: nil)
        }
        return RouteExplanation(
            request: request,
            decision: decision,
            matchedRule: winner.map { rules[$0] },
            matchedRuleIndex: winner,
            trace: trace,
            omittedEntries: earlierCount - shown
        )
    }

    // MARK: Helpers

    private static func sources(of ruleIndex: Int, in candidates: IndexCandidates) -> [String] {
        var names: [String] = []
        if candidates.domain == ruleIndex { names.append("domain trie") }
        if candidates.cidr == ruleIndex { names.append("CIDR trie") }
        if candidates.port == ruleIndex { names.append("port index") }
        if candidates.network == ruleIndex { names.append("network index") }
        if candidates.fallback == ruleIndex { names.append("ordered fallback list") }
        return names
    }

    private static func clip(_ text: String) -> String {
        let limit = 400
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func domainText(_ input: EvaluationInput) -> String? {
        guard let domain = input.domain else { return nil }
        return ByteText.string(domain)
    }

    /// Evaluates a condition and says why it did or did not match.
    static func describe(_ condition: ResolvedCondition, _ input: EvaluationInput) -> (matched: Bool, text: String) {
        switch condition {
        case let .domainExact(name):
            let wanted = ByteText.string(name)
            guard let domain = domainText(input) else {
                return (false, "request has no domain (needs domain '\(wanted)')")
            }
            if condition.matches(input) {
                return (true, "domain '\(domain)' equals '\(wanted)'")
            }
            return (false, "domain '\(domain)' is not '\(wanted)'")

        case let .domainSuffix(name, strict):
            let wanted = (strict ? "." : "") + ByteText.string(name)
            guard let domain = domainText(input) else {
                return (false, "request has no domain (needs suffix '\(wanted)')")
            }
            if condition.matches(input) {
                return (true, "domain '\(domain)' is under suffix '\(wanted)'")
            }
            return (false, "domain '\(domain)' is not under suffix '\(wanted)'")

        case let .domainKeyword(keyword):
            let wanted = ByteText.string(keyword)
            guard let domain = domainText(input) else {
                return (false, "request has no domain (needs keyword '\(wanted)')")
            }
            if condition.matches(input) {
                return (true, "domain '\(domain)' contains '\(wanted)'")
            }
            return (false, "domain '\(domain)' does not contain '\(wanted)'")

        case let .domainRegex(regex):
            guard let domain = domainText(input) else {
                return (false, "request has no domain (needs regex '\(regex.pattern)')")
            }
            if condition.matches(input) {
                return (true, "domain '\(domain)' matches regex '\(regex.pattern)'")
            }
            return (false, "domain '\(domain)' does not match regex '\(regex.pattern)'")

        case let .ipCIDR(cidr):
            guard let ip = input.ip else {
                return (false, "request has no IP address (needs \(cidr))")
            }
            if condition.matches(input) {
                return (true, "address \(ip) is inside \(cidr)")
            }
            return (false, "address \(ip) is outside \(cidr)")

        case let .port(range):
            guard let port = input.port else {
                return (false, "request has no port (needs \(range))")
            }
            if condition.matches(input) {
                return (true, "port \(port) is in \(range)")
            }
            return (false, "port \(port) is not in \(range)")

        case let .network(kind):
            guard let network = input.network else {
                return (false, "request has no network (needs \(kind.rawValue))")
            }
            if condition.matches(input) {
                return (true, "network is \(kind.rawValue)")
            }
            return (false, "network is \(network.rawValue), not \(kind.rawValue)")

        case let .allOf(items):
            var texts: [String] = []
            for item in items {
                let verdict = describe(item, input)
                if !verdict.matched {
                    return (false, "AND failed: " + verdict.text)
                }
                if texts.count < 3 { texts.append(verdict.text) }
            }
            if items.isEmpty { return (true, "empty AND is always true") }
            var text = "AND holds: " + texts.joined(separator: "; ")
            if items.count > texts.count { text += "; and \(items.count - texts.count) more" }
            return (true, text)

        case let .anyOf(items):
            var failures: [String] = []
            for item in items {
                let verdict = describe(item, input)
                if verdict.matched {
                    return (true, items.count == 1 ? verdict.text : "OR holds: " + verdict.text)
                }
                if failures.count < 3 { failures.append(verdict.text) }
            }
            if items.isEmpty { return (false, "empty OR never matches") }
            if items.count == 1 { return (false, failures[0]) }
            var text = "none of \(items.count) alternatives matched: " + failures.joined(separator: "; ")
            if items.count > failures.count { text += "; ..." }
            return (false, text)

        case let .not(inner):
            let verdict = describe(inner, input)
            if verdict.matched {
                return (false, "NOT failed because " + verdict.text)
            }
            return (true, "NOT holds because " + verdict.text)
        }
    }
}

// MARK: - Conflict detection

/// A rule that can never win.
public struct RuleConflict: Hashable, Sendable {
    /// The rule that can never match first.
    public let ruleIndex: Int
    public let ruleID: String?
    /// Earlier rules that together cover everything this rule matches,
    /// ascending.
    public let coveredBy: [Int]
    /// `true` when every covering rule has the same action: the rule is
    /// merely redundant. `false` means the rule's own action is silently
    /// overridden, which is usually a mistake.
    public let sameAction: Bool
    public let explanation: String
}

/// Finds shadowed rules for the domain and CIDR cases.
///
/// A rule is reported when its whole condition is a disjunction of exact
/// domains, domain suffixes and CIDR prefixes, and each of them is covered
/// by a single domain-suffix, exact-domain or CIDR entry of an earlier
/// enabled rule. Not detected (by design, to stay exact and cheap): coverage
/// by a union of several entries (two /25 covering a /24), and anything
/// involving ports, networks, keywords, regexes, `and` or `not`.
public enum ConflictDetector {
    public static func shadowedRules(
        in table: RoutingTable,
        limits: RoutingLimits = .standard
    ) throws -> [RuleConflict] {
        let reference = try LinearRouteMatcher(table: table, limits: limits)
        var domains = DomainTrie()
        var prefixes = CIDRIndex()
        var conflicts: [RuleConflict] = []

        for (ruleIndex, resolved) in reference.resolved.enumerated() {
            guard let condition = resolved else { continue }
            var atoms: [ResolvedCondition] = []
            var residual: [ResolvedCondition] = []
            condition.splitTopLevel(atoms: &atoms, residual: &residual)

            // Is every alternative of this rule covered by an earlier entry?
            var fullyCovered = residual.isEmpty && !atoms.isEmpty
            var covering: [Int] = []
            var details: [String] = []
            if fullyCovered {
                for atom in atoms {
                    var by = noRuleIndex
                    var what = ""
                    switch atom {
                    case let .domainExact(name):
                        by = domains.lookup(name)
                        what = "domain '\(ByteText.string(name))'"
                    case let .domainSuffix(name, strict):
                        by = domains.coveringSuffixIndex(name, strict: strict)
                        what = "suffix '\(strict ? "." : "")\(ByteText.string(name))'"
                    case let .ipCIDR(cidr):
                        by = prefixes.coveringIndex(cidr)
                        what = "prefix \(cidr)"
                    case .port, .network, .domainKeyword, .domainRegex, .allOf, .anyOf, .not:
                        by = noRuleIndex
                    }
                    if by == noRuleIndex {
                        fullyCovered = false
                        break
                    }
                    if !covering.contains(by) { covering.append(by) }
                    if details.count < 3 { details.append("\(what) is covered by rule #\(by)") }
                }
            }

            if fullyCovered {
                covering.sort()
                let action = table.rules[ruleIndex].action
                var sameAction = true
                for by in covering where table.rules[by].action != action {
                    sameAction = false
                }
                var explanation = details.joined(separator: "; ")
                if atoms.count > details.count { explanation += "; ..." }
                explanation += sameAction
                    ? " (same action: the rule is redundant)"
                    : " (different action: the rule's own action never applies)"
                conflicts.append(RuleConflict(
                    ruleIndex: ruleIndex,
                    ruleID: table.rules[ruleIndex].id,
                    coveredBy: covering,
                    sameAction: sameAction,
                    explanation: explanation
                ))
            }

            // Top-level alternatives of this rule shadow later rules, even
            // when the rule also has non-indexable alternatives.
            for atom in atoms {
                switch atom {
                case let .domainExact(name):
                    domains.insertExact(name, ruleIndex: ruleIndex)
                case let .domainSuffix(name, strict):
                    domains.insertSuffix(name, strict: strict, ruleIndex: ruleIndex)
                case let .ipCIDR(cidr):
                    prefixes.insert(cidr, ruleIndex: ruleIndex)
                case .port, .network, .domainKeyword, .domainRegex, .allOf, .anyOf, .not:
                    break
                }
            }
        }
        return conflicts
    }
}
