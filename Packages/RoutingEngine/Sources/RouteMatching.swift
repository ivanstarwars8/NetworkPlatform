// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

// MARK: - Resolved conditions

/// A condition after validation: names normalised to bytes, regexes compiled,
/// rule-set references replaced by their contents.
indirect enum ResolvedCondition: Sendable {
    case domainExact([UInt8])
    case domainSuffix([UInt8], strict: Bool)
    case domainKeyword([UInt8])
    case domainRegex(LinearRegex)
    case ipCIDR(IPCIDR)
    case ipNotIn(ExcludedPrefixes)
    case port(PortRange)
    case network(NetworkKind)
    case sourceCIDR(IPCIDR)
    case sourcePort(PortRange)
    case inboundTag(String)
    case user(String)
    case sniffedProtocol([UInt8])
    case allOf([ResolvedCondition])
    case anyOf([ResolvedCondition])
    case not(ResolvedCondition)
}

/// The prefixes of an `ipNotIn` condition.
struct ExcludedPrefixes: Sendable {
    let prefixes: [IPCIDR]
    let hasIPv4: Bool
    let hasIPv6: Bool

    init(_ prefixes: [IPCIDR]) {
        self.prefixes = prefixes
        self.hasIPv4 = prefixes.contains { $0.network.isIPv4 }
        self.hasIPv6 = prefixes.contains { !$0.network.isIPv4 }
    }

    /// The engine's reversed address-set test for one address: an address
    /// whose family has no prefix in the set never matches.
    func isOutside(_ address: IPAddress) -> Bool {
        if address.isIPv4 ? !hasIPv4 : !hasIPv6 { return false }
        for prefix in prefixes where prefix.contains(address) {
            return false
        }
        return true
    }
}

/// The request in the form the evaluators need, for one evaluation pass.
struct EvaluationInput: Sendable {
    let domain: [UInt8]?
    /// Destination address, or the resolved addresses of the domain when the
    /// pass uses resolution.
    let targetIPs: [IPAddress]
    /// `true` when `targetIPs` came from resolving the domain.
    let usesResolvedIPs: Bool
    /// A missing port is 0, as in the engine.
    let port: UInt16
    let network: NetworkKind?
    let sourceIP: IPAddress?
    let sourcePort: UInt16
    let inboundTag: String?
    let user: String?
    let sniffedProtocol: [UInt8]?

    init(_ request: RouteRequest, resolving: Bool = false) {
        if let domain = request.domain {
            self.domain = Array(domain.utf8)
        } else {
            self.domain = nil
        }
        // A successful lookup replaces the destination address; a failed one
        // (no resolved addresses) leaves it in place.
        if resolving, request.domain != nil, !request.resolvedIPs.isEmpty {
            self.targetIPs = request.resolvedIPs
            self.usesResolvedIPs = true
        } else {
            if let ip = request.ip {
                self.targetIPs = [ip]
            } else {
                self.targetIPs = []
            }
            self.usesResolvedIPs = false
        }
        self.port = request.port ?? 0
        self.network = request.network
        self.sourceIP = request.sourceIP
        self.sourcePort = request.sourcePort ?? 0
        self.inboundTag = request.inboundTag
        self.user = request.user
        if let sniffed = request.sniffedProtocol {
            self.sniffedProtocol = Array(sniffed.utf8)
        } else {
            self.sniffedProtocol = nil
        }
    }

    /// The evaluation passes the engine's router makes for a request: one
    /// pass, or two for `ipIfNonMatch` when resolution can change anything.
    static func passes(for request: RouteRequest, strategy: DomainStrategy) -> (first: EvaluationInput, second: EvaluationInput?) {
        switch strategy {
        case .asIs:
            return (EvaluationInput(request), nil)
        case .ipOnDemand:
            return (EvaluationInput(request, resolving: true), nil)
        case .ipIfNonMatch:
            let first = EvaluationInput(request)
            if request.domain != nil, !request.resolvedIPs.isEmpty {
                return (first, EvaluationInput(request, resolving: true))
            }
            // Without a domain there is no second pass; with a failed lookup
            // the second pass sees the same addresses as the first.
            return (first, nil)
        }
    }
}

enum ByteText {
    /// Label-boundary suffix test. With `strict == false` the name itself
    /// also matches.
    static func hasLabelSuffix(_ name: [UInt8], _ suffix: [UInt8], strict: Bool) -> Bool {
        if name.count == suffix.count {
            return !strict && name == suffix
        }
        guard name.count > suffix.count else { return false }
        let offset = name.count - suffix.count
        guard name[offset - 1] == 0x2E else { return false }
        var position = 0
        while position < suffix.count {
            if name[offset + position] != suffix[position] { return false }
            position += 1
        }
        return true
    }

    /// Plain substring search; both inputs are bounded by the domain limit.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty { return true }
        guard haystack.count >= needle.count else { return false }
        let lastStart = haystack.count - needle.count
        var start = 0
        while start <= lastStart {
            var position = 0
            while position < needle.count && haystack[start + position] == needle[position] {
                position += 1
            }
            if position == needle.count { return true }
            start += 1
        }
        return false
    }

    static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

extension ResolvedCondition {
    /// Direct evaluation, independent of every index. This is the reference
    /// semantics of a condition.
    func matches(_ input: EvaluationInput) -> Bool {
        switch self {
        case let .domainExact(name):
            guard let domain = input.domain else { return false }
            return domain == name
        case let .domainSuffix(name, strict):
            guard let domain = input.domain else { return false }
            return ByteText.hasLabelSuffix(domain, name, strict: strict)
        case let .domainKeyword(keyword):
            guard let domain = input.domain else { return false }
            return ByteText.contains(domain, keyword)
        case let .domainRegex(regex):
            guard let domain = input.domain else { return false }
            return regex.matches(utf8: domain)
        case let .ipCIDR(cidr):
            for ip in input.targetIPs where cidr.contains(ip) {
                return true
            }
            return false
        case let .ipNotIn(excluded):
            for ip in input.targetIPs where excluded.isOutside(ip) {
                return true
            }
            return false
        case let .port(range):
            return range.contains(input.port)
        case let .network(kind):
            guard let network = input.network else { return false }
            return network == kind
        case let .sourceCIDR(cidr):
            guard let ip = input.sourceIP else { return false }
            return cidr.contains(ip)
        case let .sourcePort(range):
            return range.contains(input.sourcePort)
        case let .inboundTag(tag):
            return input.inboundTag == tag
        case let .user(name):
            return input.user == name
        case let .sniffedProtocol(prefix):
            guard let sniffed = input.sniffedProtocol, sniffed.count >= prefix.count else { return false }
            return sniffed.starts(with: prefix)
        case let .allOf(items):
            for item in items {
                if !item.matches(input) { return false }
            }
            return true
        case let .anyOf(items):
            for item in items {
                if item.matches(input) { return true }
            }
            return false
        case let .not(inner):
            return !inner.matches(input)
        }
    }

    /// `true` for leaves that an index can answer.
    var isIndexableAtom: Bool {
        switch self {
        case .domainExact, .domainSuffix, .ipCIDR, .port, .network:
            return true
        case .domainKeyword, .domainRegex, .ipNotIn, .sourceCIDR, .sourcePort, .inboundTag, .user,
             .sniffedProtocol, .allOf, .anyOf, .not:
            return false
        }
    }

    /// Splits the top-level disjunction: indexable leaves go to `atoms`,
    /// everything else to `residual`. The condition is equivalent to
    /// `any(atoms + residual)`.
    func splitTopLevel(atoms: inout [ResolvedCondition], residual: inout [ResolvedCondition]) {
        if isIndexableAtom {
            atoms.append(self)
            return
        }
        if case let .anyOf(items) = self {
            for item in items {
                item.splitTopLevel(atoms: &atoms, residual: &residual)
            }
            return
        }
        residual.append(self)
    }
}

// MARK: - Resolver

/// Validates a table and turns its conditions into `ResolvedCondition`s.
struct TableResolver {
    private let ruleSets: [String: [RuleCondition]]
    private let limits: RoutingLimits
    private var nodeCount = 0

    init(table: RoutingTable, limits: RoutingLimits) throws {
        guard table.rules.count <= limits.maximumRules else {
            throw RoutingCompileError.tooManyRules(count: table.rules.count, limit: limits.maximumRules)
        }
        guard table.ruleSets.count <= limits.maximumRuleSets else {
            throw RoutingCompileError.tooManyRuleSets(count: table.ruleSets.count, limit: limits.maximumRuleSets)
        }
        var sets: [String: [RuleCondition]] = [:]
        for ruleSet in table.ruleSets {
            if sets[ruleSet.tag] != nil {
                throw RoutingCompileError.duplicateRuleSet(tag: ruleSet.tag)
            }
            sets[ruleSet.tag] = ruleSet.conditions
        }
        if let problem = table.finalAction.validationProblem {
            throw RoutingCompileError.invalidAction(ruleIndex: nil, reason: problem)
        }
        self.ruleSets = sets
        self.limits = limits
    }

    /// Resolves every rule. Disabled rules are validated too (so enabling a
    /// rule can never make a table invalid) but yield `nil`.
    mutating func resolveAll(_ rules: [RoutingRule]) throws -> [ResolvedCondition?] {
        var result: [ResolvedCondition?] = []
        result.reserveCapacity(rules.count)
        for (index, rule) in rules.enumerated() {
            if let problem = rule.action.validationProblem {
                throw RoutingCompileError.invalidAction(ruleIndex: index, reason: problem)
            }
            let resolved = try resolve(rule.condition, ruleIndex: index, depth: 0, activeSets: [])
            result.append(rule.isEnabled ? resolved : nil)
        }
        return result
    }

    private mutating func resolve(
        _ condition: RuleCondition,
        ruleIndex: Int,
        depth: Int,
        activeSets: [String]
    ) throws -> ResolvedCondition {
        guard depth <= limits.maximumConditionDepth else {
            throw RoutingCompileError.conditionTooDeep(ruleIndex: ruleIndex, limit: limits.maximumConditionDepth)
        }
        nodeCount += 1
        guard nodeCount <= limits.maximumConditionNodes else {
            throw RoutingCompileError.tableTooLarge(limit: limits.maximumConditionNodes)
        }

        switch condition {
        case let .domain(value):
            guard let name = DomainName.normalise(value) else {
                throw RoutingCompileError.invalidDomain(ruleIndex: ruleIndex, value: value)
            }
            return .domainExact(Array(name.utf8))

        case let .domainSuffix(value):
            let strict = value.hasPrefix(".")
            let body = strict ? String(value.dropFirst()) : value
            guard let name = DomainName.normalise(body), !name.hasPrefix(".") else {
                throw RoutingCompileError.invalidDomain(ruleIndex: ruleIndex, value: value)
            }
            return .domainSuffix(Array(name.utf8), strict: strict)

        case let .domainKeyword(value):
            let keyword = value.lowercased()
            let length = keyword.utf8.count
            guard length > 0, length <= RouteRequest.maximumDomainLength else {
                throw RoutingCompileError.invalidKeyword(ruleIndex: ruleIndex, value: value)
            }
            return .domainKeyword(Array(keyword.utf8))

        case let .domainRegex(pattern):
            do {
                return .domainRegex(try LinearRegex(pattern))
            } catch let error as LinearRegex.CompileError {
                throw RoutingCompileError.invalidRegex(
                    ruleIndex: ruleIndex,
                    pattern: pattern,
                    reason: error.description
                )
            } catch {
                throw RoutingCompileError.invalidRegex(
                    ruleIndex: ruleIndex,
                    pattern: pattern,
                    reason: String(describing: error)
                )
            }

        case let .ipCIDR(cidr):
            return .ipCIDR(cidr)

        case let .ipNotIn(prefixes):
            guard !prefixes.isEmpty else {
                throw RoutingCompileError.invalidValue(ruleIndex: ruleIndex, reason: "ipNotIn has no prefixes")
            }
            nodeCount += prefixes.count
            guard nodeCount <= limits.maximumConditionNodes else {
                throw RoutingCompileError.tableTooLarge(limit: limits.maximumConditionNodes)
            }
            return .ipNotIn(ExcludedPrefixes(prefixes))

        case let .port(range):
            return .port(range)

        case let .network(kind):
            return .network(kind)

        case let .sourceCIDR(cidr):
            return .sourceCIDR(cidr)

        case let .sourcePort(range):
            return .sourcePort(range)

        case let .inboundTag(tag):
            try TableResolver.checkText(tag, what: "inbound tag", ruleIndex: ruleIndex)
            return .inboundTag(tag)

        case let .user(name):
            try TableResolver.checkText(name, what: "user", ruleIndex: ruleIndex)
            return .user(name)

        case let .sniffedProtocol(name):
            try TableResolver.checkText(name, what: "protocol", ruleIndex: ruleIndex)
            return .sniffedProtocol(Array(name.utf8))

        case let .ruleSet(tag):
            if activeSets.contains(tag) {
                throw RoutingCompileError.ruleSetCycle(ruleIndex: ruleIndex, tag: tag)
            }
            guard let conditions = ruleSets[tag] else {
                throw RoutingCompileError.unknownRuleSet(ruleIndex: ruleIndex, tag: tag)
            }
            var nested = activeSets
            nested.append(tag)
            var items: [ResolvedCondition] = []
            items.reserveCapacity(conditions.count)
            for item in conditions {
                items.append(try resolve(item, ruleIndex: ruleIndex, depth: depth + 1, activeSets: nested))
            }
            return .anyOf(items)

        case let .and(children):
            var items: [ResolvedCondition] = []
            items.reserveCapacity(children.count)
            for child in children {
                items.append(try resolve(child, ruleIndex: ruleIndex, depth: depth + 1, activeSets: activeSets))
            }
            return .allOf(items)

        case let .or(children):
            var items: [ResolvedCondition] = []
            items.reserveCapacity(children.count)
            for child in children {
                items.append(try resolve(child, ruleIndex: ruleIndex, depth: depth + 1, activeSets: activeSets))
            }
            return .anyOf(items)

        case let .not(child):
            return .not(try resolve(child, ruleIndex: ruleIndex, depth: depth + 1, activeSets: activeSets))
        }
    }
}

extension TableResolver {
    /// Tags, users and protocol names: non-empty and bounded. The engine
    /// silently drops empty entries, which would turn a rule into something
    /// else, so they are rejected here.
    static func checkText(_ value: String, what: String, ruleIndex: Int) throws {
        if value.isEmpty {
            throw RoutingCompileError.invalidValue(ruleIndex: ruleIndex, reason: "\(what) is empty")
        }
        if value.utf8.count > RouteAction.maximumTagLength {
            throw RoutingCompileError.invalidValue(
                ruleIndex: ruleIndex,
                reason: "\(what) is longer than \(RouteAction.maximumTagLength) bytes"
            )
        }
    }
}

// MARK: - Linear reference matcher

/// The reference implementation of first-match-wins: evaluates rules one by
/// one in priority order. It is O(rules) per request and exists to define
/// the semantics, to cross-check `CompiledRouter` in tests and to produce
/// explanations; production routing uses `CompiledRouter`.
public struct LinearRouteMatcher: Sendable {
    public let rules: [RoutingRule]
    public let finalAction: RouteAction
    public let domainStrategy: DomainStrategy
    let resolved: [ResolvedCondition?]

    public init(table: RoutingTable, limits: RoutingLimits = .standard) throws {
        var resolver = try TableResolver(table: table, limits: limits)
        self.resolved = try resolver.resolveAll(table.rules)
        self.rules = table.rules
        self.finalAction = table.finalAction
        self.domainStrategy = table.domainStrategy
    }

    public func match(_ request: RouteRequest) -> RouteDecision {
        let passes = EvaluationInput.passes(for: request, strategy: domainStrategy)
        if let index = firstMatch(passes.first) {
            return RouteDecision(action: rules[index].action, ruleIndex: index)
        }
        if let second = passes.second, let index = firstMatch(second) {
            return RouteDecision(action: rules[index].action, ruleIndex: index, usedSecondPass: true)
        }
        return RouteDecision(action: finalAction, ruleIndex: nil)
    }

    func firstMatch(_ input: EvaluationInput) -> Int? {
        for (index, condition) in resolved.enumerated() {
            if let condition = condition, condition.matches(input) {
                return index
            }
        }
        return nil
    }
}

// MARK: - Compiled router

/// Lowest matching rule index reported by each index for one request.
struct IndexCandidates: Equatable, Sendable {
    var domain = noRuleIndex
    var cidr = noRuleIndex
    var port = noRuleIndex
    var network = noRuleIndex
    var fallback = noRuleIndex
    /// Most specific CIDR entry containing the address (prefix length and its
    /// rule index); informational, used by explanations.
    var longestPrefixLength = -1
    var longestPrefixIndex = noRuleIndex

    var best: Int {
        min(min(domain, cidr), min(min(port, network), fallback))
    }
}

/// An immutable, thread-safe matcher that does not scan the rule list.
///
/// - Exact and suffix domains live in a reversed-label trie.
/// - CIDR prefixes live in path-compressed binary tries (IPv4 and IPv6).
/// - Port ranges are flattened into disjoint segments with binary search.
/// - Network conditions are two slots.
/// - Only rules that need it (keyword, regex, `and`, `not`, and `or` parts
///   containing those) are kept in an ordered fallback list.
///
/// Every index stores rule priorities, and the winner is the lowest index
/// among all matches, so the result is identical to scanning the rules in
/// order. The fallback list is scanned only up to the best indexed match.
public struct CompiledRouter: Sendable {
    /// Sizes of the compiled structures.
    public struct Statistics: Hashable, Sendable {
        public let ruleCount: Int
        public let enabledRuleCount: Int
        public let domainTrieNodes: Int
        public let cidrEntries: Int
        public let cidrTrieNodes: Int
        public let portSegments: Int
        public let fallbackRules: Int
    }

    struct FallbackEntry: Sendable {
        let ruleIndex: Int
        let condition: ResolvedCondition
    }

    let reference: LinearRouteMatcher
    private let domainTrie: DomainTrie
    private let cidrIndex: CIDRIndex
    private let portIndex: PortIndex
    private let tcpIndex: Int
    private let udpIndex: Int
    private let fallback: [FallbackEntry]

    public let statistics: Statistics

    public var rules: [RoutingRule] { reference.rules }
    public var finalAction: RouteAction { reference.finalAction }
    public var domainStrategy: DomainStrategy { reference.domainStrategy }

    /// Tags of every outbound and group the table refers to (rules and the
    /// final action), for validation against the actual outbound list.
    public var referencedTags: Set<String> {
        var tags = Set<String>(reference.finalAction.referencedTags)
        for rule in reference.rules {
            for tag in rule.action.referencedTags {
                tags.insert(tag)
            }
        }
        return tags
    }

    public init(table: RoutingTable, limits: RoutingLimits = .standard) throws {
        let reference = try LinearRouteMatcher(table: table, limits: limits)

        var domainTrie = DomainTrie()
        var cidrIndex = CIDRIndex()
        var portEntries: [(range: PortRange, ruleIndex: Int)] = []
        var tcpIndex = noRuleIndex
        var udpIndex = noRuleIndex
        var fallback: [FallbackEntry] = []
        var enabled = 0

        for (ruleIndex, resolved) in reference.resolved.enumerated() {
            guard let condition = resolved else { continue }
            enabled += 1
            var atoms: [ResolvedCondition] = []
            var residual: [ResolvedCondition] = []
            condition.splitTopLevel(atoms: &atoms, residual: &residual)

            for atom in atoms {
                switch atom {
                case let .domainExact(name):
                    domainTrie.insertExact(name, ruleIndex: ruleIndex)
                case let .domainSuffix(name, strict):
                    domainTrie.insertSuffix(name, strict: strict, ruleIndex: ruleIndex)
                case let .ipCIDR(cidr):
                    cidrIndex.insert(cidr, ruleIndex: ruleIndex)
                case let .port(range):
                    portEntries.append((range: range, ruleIndex: ruleIndex))
                case let .network(kind):
                    switch kind {
                    case .tcp: tcpIndex = min(tcpIndex, ruleIndex)
                    case .udp: udpIndex = min(udpIndex, ruleIndex)
                    }
                case .domainKeyword, .domainRegex, .ipNotIn, .sourceCIDR, .sourcePort, .inboundTag, .user,
                     .sniffedProtocol, .allOf, .anyOf, .not:
                    // splitTopLevel never puts these into `atoms`; keep the
                    // rule correct even if that ever changes.
                    residual.append(atom)
                }
            }

            if residual.count == 1 {
                fallback.append(FallbackEntry(ruleIndex: ruleIndex, condition: residual[0]))
            } else if residual.count > 1 {
                fallback.append(FallbackEntry(ruleIndex: ruleIndex, condition: .anyOf(residual)))
            }
        }

        let portIndex = PortIndex(entries: portEntries)

        self.reference = reference
        self.domainTrie = domainTrie
        self.cidrIndex = cidrIndex
        self.portIndex = portIndex
        self.tcpIndex = tcpIndex
        self.udpIndex = udpIndex
        self.fallback = fallback
        self.statistics = Statistics(
            ruleCount: table.rules.count,
            enabledRuleCount: enabled,
            domainTrieNodes: domainTrie.nodeCount,
            cidrEntries: cidrIndex.entryCount,
            cidrTrieNodes: cidrIndex.nodeCount,
            portSegments: portIndex.segmentCount,
            fallbackRules: fallback.count
        )
    }

    /// Routes one request. Pure and safe to call from any thread.
    public func match(_ request: RouteRequest) -> RouteDecision {
        let passes = EvaluationInput.passes(for: request, strategy: reference.domainStrategy)
        let best = candidates(for: passes.first).best
        if best != noRuleIndex {
            return RouteDecision(action: reference.rules[best].action, ruleIndex: best)
        }
        if let second = passes.second {
            let later = candidates(for: second).best
            if later != noRuleIndex {
                return RouteDecision(action: reference.rules[later].action, ruleIndex: later, usedSecondPass: true)
            }
        }
        return RouteDecision(action: reference.finalAction, ruleIndex: nil)
    }

    /// The pass that decides a request and what the indexes found in it.
    func evaluate(_ request: RouteRequest) -> (input: EvaluationInput, candidates: IndexCandidates, usedSecondPass: Bool) {
        let passes = EvaluationInput.passes(for: request, strategy: reference.domainStrategy)
        let first = candidates(for: passes.first)
        if first.best == noRuleIndex, let second = passes.second {
            return (second, candidates(for: second), true)
        }
        return (passes.first, first, false)
    }

    /// Routes one request and records the hit.
    public func match(_ request: RouteRequest, counters: HitCounters) -> RouteDecision {
        let decision = match(request)
        counters.record(decision)
        return decision
    }

    func candidates(for input: EvaluationInput) -> IndexCandidates {
        var result = IndexCandidates()
        if let domain = input.domain {
            result.domain = domainTrie.lookup(domain)
        }
        for ip in input.targetIPs {
            let found = cidrIndex.search(ip)
            if found.minimumIndex < result.cidr {
                result.cidr = found.minimumIndex
                result.longestPrefixLength = found.longestPrefixLength
                result.longestPrefixIndex = found.longestPrefixIndex
            }
        }
        result.port = portIndex.lookup(input.port)
        if let network = input.network {
            switch network {
            case .tcp: result.network = tcpIndex
            case .udp: result.network = udpIndex
            }
        }
        // Fallback rules are in priority order; none past the best indexed
        // match can win.
        let indexedBest = result.best
        for entry in fallback {
            if entry.ruleIndex >= indexedBest { break }
            if entry.condition.matches(input) {
                result.fallback = entry.ruleIndex
                break
            }
        }
        return result
    }
}

// MARK: - Hit counters

/// Thread-safe per-rule hit counters.
public final class HitCounters: @unchecked Sendable {
    /// A consistent copy of all counters.
    public struct Snapshot: Hashable, Sendable {
        public let ruleHits: [UInt64]
        public let finalActionHits: UInt64

        public var total: UInt64 {
            var sum = finalActionHits
            for value in ruleHits {
                sum = sum &+ value
            }
            return sum
        }
    }

    private let lock = NSLock()
    private var ruleHits: [UInt64]
    private var finalHits: UInt64 = 0

    public init(ruleCount: Int) {
        ruleHits = [UInt64](repeating: 0, count: max(0, ruleCount))
    }

    /// Counts one decision. A rule index outside the table is ignored.
    public func record(_ decision: RouteDecision) {
        lock.lock()
        defer { lock.unlock() }
        if let index = decision.ruleIndex {
            if index >= 0 && index < ruleHits.count {
                ruleHits[index] = ruleHits[index] &+ 1
            }
        } else {
            finalHits = finalHits &+ 1
        }
    }

    public func hits(forRule index: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < ruleHits.count else { return 0 }
        return ruleHits[index]
    }

    public var finalActionHits: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return finalHits
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(ruleHits: ruleHits, finalActionHits: finalHits)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for index in ruleHits.indices {
            ruleHits[index] = 0
        }
        finalHits = 0
    }
}
