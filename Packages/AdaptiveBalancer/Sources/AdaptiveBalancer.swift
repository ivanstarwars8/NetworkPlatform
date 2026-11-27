import Foundation

/// The decision layer: given measurements, says which configuration to use
/// and why.
///
/// It is a value type with no side effects: no clock, no timers, no I/O, no
/// randomness. The caller feeds samples with `record(_:)`, asks with
/// `decide(now:)` and carries out the returned `Change`. Equal inputs in equal
/// order give equal decisions.
///
/// Three levels are evaluated in a fixed order and never mixed:
///
/// - (a) `SwitchLevel.server` — another server, same engine and transport;
/// - (b) `SwitchLevel.transport` — another protocol/transport, same engine;
/// - (c) `SwitchLevel.engine` — another engine. Considered only when no
///   candidate of the current engine has a closed circuit breaker, i.e. when
///   (a) and (b) cannot satisfy the profile.
///
/// Guarantees (each covered by tests):
///
/// - A change in measured latency, jitter, loss or throughput alone never
///   produces an engine switch. Only failures open circuit breakers, and only
///   an engine whose breakers are all open can be left.
/// - In any window of `SelectionPolicy.rateLimit.window` seconds there are at
///   most `maximumSwitches + 1` in-engine changes (the `+ 1` is a rollback,
///   which is never blocked). The same bound holds for engine changes with
///   `EngineSwitchPolicy.rateLimit`.
/// - Every decision carries an `Explanation`.
///
/// **An engine switch restarts the tunnel extension. All TCP sessions and all
/// other connections through the tunnel are terminated.** Nothing here keeps
/// them alive, and no API of this module promises session continuity across
/// engines. See `Change.requiresTunnelRestart`.
///
/// `decide(now:)` commits: after it returns a `Change`, the balancer considers
/// the target current and in probation. If the caller cannot apply the change,
/// it must call `reportApplyFailure(now:)`.
public struct AdaptiveBalancer: Sendable {
    public let policies: PolicySet
    public private(set) var network: NetworkClass
    public private(set) var current: Candidate?
    /// When the current candidate was selected.
    public private(set) var currentSince: Instant?

    private var descriptors: [Candidate: CandidateDescriptor] = [:]
    private var order: [Candidate] = []
    private var states: [NetworkClass: NetworkState] = [:]
    private var switchLog: [SwitchRecord] = []
    private var probation: ProbationState?
    private var leftAt: [Candidate: Instant] = [:]
    private var quarantinedUntil: [Candidate: Instant] = [:]

    private struct NetworkState: Sendable {
        var metrics: [Candidate: CandidateMetrics] = [:]
        var breakers: [Candidate: CircuitBreaker] = [:]
        var lastKnownGood: LastKnownGood?
        /// Since when no candidate of the current engine has a closed breaker.
        var engineOutageSince: Instant?
    }

    private struct SwitchRecord: Sendable {
        let at: Instant
        let level: SwitchLevel?
        let kind: ChangeKind
    }

    private struct ProbationState: Sendable {
        let candidate: Candidate
        /// The level of the change that started the probation.
        let level: SwitchLevel?
        var startedAt: Instant
        var successes = 0
        var failures = 0
        var applyFailed = false
    }

    private enum ProbationVerdict {
        case pending
        case passed
        case failed(String)
    }

    // MARK: - Setup

    public init(candidates: [CandidateDescriptor], policies: PolicySet = .standard(), network: NetworkClass) {
        self.policies = policies
        self.network = network
        setCandidates(candidates)
    }

    /// The policy in force for the current network class.
    public var policy: SelectionPolicy { policies.policy(for: network) }

    /// All candidates in deterministic order.
    public var candidates: [Candidate] { order }

    /// Replaces the candidate set (profile or subscription changed). State of
    /// candidates that stay is kept; state of removed candidates is dropped.
    /// If the current candidate was removed, the next `decide` treats it as
    /// unusable.
    public mutating func updateCandidates(_ candidates: [CandidateDescriptor], now: Instant) {
        setCandidates(candidates)
        for key in Array(states.keys) {
            guard var state = states[key] else { continue }
            state.metrics = state.metrics.filter { descriptors[$0.key] != nil }
            state.breakers = state.breakers.filter { descriptors[$0.key] != nil }
            if let lkg = state.lastKnownGood, descriptors[lkg.candidate] == nil { state.lastKnownGood = nil }
            states[key] = state
        }
        leftAt = leftAt.filter { descriptors[$0.key] != nil }
        quarantinedUntil = quarantinedUntil.filter { descriptors[$0.key] != nil }
        if let p = probation, descriptors[p.candidate] == nil { probation = nil }
        refreshOutage(now: now)
    }

    private mutating func setCandidates(_ list: [CandidateDescriptor]) {
        var map: [Candidate: CandidateDescriptor] = [:]
        for descriptor in list { map[descriptor.candidate] = descriptor }
        descriptors = map
        order = map.keys.sorted()
    }

    // MARK: - Inputs

    /// Records one observation on the current network class. Samples about
    /// unknown candidates are ignored.
    ///
    /// Call `networkChanged(to:now:)` before recording samples taken on a new
    /// network.
    public mutating func record(_ sample: ProbeSample) {
        let candidate = sample.candidate
        guard descriptors[candidate] != nil else { return }
        let policy = self.policy
        var state = states[network] ?? NetworkState()
        var metrics = state.metrics[candidate] ?? CandidateMetrics()
        metrics.add(sample.outcome, at: sample.at, smoothing: policy.scoring.smoothing)
        state.metrics[candidate] = metrics
        var breaker = state.breakers[candidate] ?? CircuitBreaker()
        breaker.record(
            success: sample.isSuccess,
            at: sample.at,
            failureRate: metrics.failureRate.current,
            sampleCount: metrics.sampleCount,
            policy: policy.breaker
        )
        state.breakers[candidate] = breaker
        states[network] = state

        if var p = probation, p.candidate == candidate, sample.at >= p.startedAt {
            if sample.isSuccess { p.successes += 1 } else { p.failures += 1 }
            probation = p
        }
        refreshOutage(now: sample.at)
    }

    /// The device moved to another network class. Measurements and breakers
    /// are kept per class, so the new class starts from what was last learned
    /// on it. A running probation window restarts: evidence collected on the
    /// old network proves nothing about the new one.
    public mutating func networkChanged(to newNetwork: NetworkClass, now: Instant) {
        guard newNetwork != network else { return }
        network = newNetwork
        if var p = probation {
            p.startedAt = now
            p.successes = 0
            p.failures = 0
            probation = p
        }
        refreshOutage(now: now)
    }

    /// The caller could not apply the last `Change` (the engine refused the
    /// configuration, the extension did not start). The configuration fails
    /// probation at the next `decide`.
    public mutating func reportApplyFailure(now: Instant) {
        guard var p = probation else { return }
        p.applyFailed = true
        probation = p
    }

    // MARK: - Read-only views

    public var lastKnownGood: LastKnownGood? { states[network]?.lastKnownGood }

    /// `true` while the current configuration is in its probation window.
    public var isInProbation: Bool { probation != nil }

    public func health(of candidate: Candidate, now: Instant) -> BreakerState {
        states[network]?.breakers[candidate]?.state(at: now) ?? .closed
    }

    public func metrics(of candidate: Candidate) -> CandidateMetrics? {
        states[network]?.metrics[candidate]
    }

    public func score(of candidate: Candidate, now: Instant) -> ScoreBreakdown {
        policy.scoring.score(states[network]?.metrics[candidate] ?? CandidateMetrics(), now: now)
    }

    /// The assessment of every candidate, in deterministic order.
    public func assessments(now: Instant) -> [CandidateAssessment] {
        let policy = self.policy
        let maxWeight = descriptors.values.map(\.weight).max() ?? 0
        return order.map { assess($0, now: now, policy: policy, maxWeight: maxWeight) }
    }

    /// Which candidates the caller should probe now, and why. The balancer
    /// does not probe; it only says what it needs to know. Candidates with an
    /// open breaker are deliberately absent.
    public func probePlan(now: Instant) -> [ProbeRequest] {
        let policy = self.policy
        var plan: [ProbeRequest] = []
        for candidate in order {
            let state = health(of: candidate, now: now)
            if case .open = state { continue }
            if case .halfOpen = state {
                plan.append(ProbeRequest(candidate: candidate, reason: .recovery))
                continue
            }
            if let p = probation, p.candidate == candidate {
                plan.append(ProbeRequest(candidate: candidate, reason: .probation))
                continue
            }
            guard let metrics = states[network]?.metrics[candidate], let last = metrics.lastSampleAt else {
                plan.append(ProbeRequest(candidate: candidate, reason: .unmeasured))
                continue
            }
            if now.duration(since: last) >= policy.probeStaleAfter {
                plan.append(ProbeRequest(candidate: candidate, reason: .stale))
            }
        }
        return plan
    }

    // MARK: - Decision

    /// Evaluates the three levels and returns what to do, with an explanation.
    /// Commits the result (see the type documentation).
    public mutating func decide(now: Instant) -> Decision {
        prune(now: now)
        refreshOutage(now: now)
        let policy = self.policy

        guard !order.isEmpty else {
            current = nil
            currentSince = nil
            probation = nil
            return decision(.keep(nil), .noCandidates, "no candidates are configured", chosen: nil, blockers: [], now: now)
        }
        guard let cur = current else {
            return initialSelection(now: now, policy: policy)
        }

        if let p = probation, p.candidate == cur {
            switch probationVerdict(p, now: now, policy: policy) {
            case .pending:
                return decision(
                    .keep(cur), .inProbation,
                    "\(cur) is in probation: \(p.successes) successes, \(p.failures) failures, "
                        + "\(fmt(now.duration(since: p.startedAt)))s of \(fmt(policy.probation.window))s",
                    chosen: nil, blockers: [], now: now
                )
            case .passed:
                probation = nil
                var state = states[network] ?? NetworkState()
                state.lastKnownGood = LastKnownGood(candidate: cur, confirmedAt: now)
                states[network] = state
                return decision(
                    .keep(cur), .probationPassed,
                    "\(cur) passed probation with \(p.successes) successes and is now the last known good configuration",
                    chosen: nil, blockers: [], now: now
                )
            case .failed(let why):
                probation = nil
                quarantinedUntil[cur] = now + policy.probation.quarantine
                if let target = rollbackTarget(from: cur, probationLevel: p.level, now: now) {
                    let level = SwitchLevel.between(cur, target)
                    commit(to: target, level: level, kind: .rollback, now: now)
                    let restart = level == .engine ? "; this restarts the tunnel and drops all connections" : ""
                    return decision(
                        .apply(Change(from: cur, to: target, level: level, kind: .rollback)), .rollback,
                        "\(cur) failed probation (\(why)); rolling back to last known good \(target)\(restart)",
                        chosen: target, blockers: [], now: now
                    )
                }
                // No usable last known good configuration: fall through to a
                // forced selection; the failed candidate is quarantined.
            }
        }

        return steadyState(current: cur, now: now, policy: policy)
    }

    private mutating func initialSelection(now: Instant, policy: SelectionPolicy) -> Decision {
        let all = assessments(now: now).filter(\.isAvailable)
        var pool = all
        if let preferred = policies.preferredEngine {
            let inPreferred = all.filter { $0.candidate.engine == preferred }
            if !inPreferred.isEmpty { pool = inPreferred }
        }
        guard let best = ranked(pool).first else {
            return decision(
                .keep(nil), .noUsableCandidate,
                "none of \(order.count) candidates is usable (circuit open or quarantined)",
                chosen: nil, blockers: [], now: now
            )
        }
        commit(to: best.candidate, level: nil, kind: .initialSelection, now: now)
        return decision(
            .apply(Change(from: nil, to: best.candidate, level: nil, kind: .initialSelection)), .initialSelection,
            "initial selection \(best.candidate): utility \(fmt(best.utility)), tier \(best.tier), "
                + "\(best.score.sampleCount) samples, best of \(pool.count) usable",
            chosen: best.candidate, blockers: [], now: now
        )
    }

    private mutating func steadyState(current cur: Candidate, now: Instant, policy: SelectionPolicy) -> Decision {
        let all = assessments(now: now)
        let currentAssessment = all.first { $0.candidate == cur }
        let forced = !(currentAssessment?.isAvailable ?? false)
        var blockers: [Blocker] = []

        // Levels (a) and (b), strictly in this order.
        for level in [SwitchLevel.server, .transport] {
            let pool = all.filter {
                $0.candidate != cur && $0.candidate.engine == cur.engine
                    && (level == .server ? $0.candidate.transport == cur.transport : $0.candidate.transport != cur.transport)
            }
            switch evaluateInEngine(level: level, pool: pool, current: currentAssessment, forced: forced, now: now, policy: policy) {
            case .change(let target, let kind, let summary):
                commit(to: target.candidate, level: level, kind: kind, now: now)
                return decision(
                    .apply(Change(from: cur, to: target.candidate, level: level, kind: kind)),
                    kind == .failover ? .failover : .improvement,
                    summary, chosen: target.candidate, blockers: blockers, now: now
                )
            case .blocked(let found):
                blockers += found
            }
        }

        // Level (c). Reached only when (a) and (b) made no change.
        if forced {
            switch evaluateEngine(current: cur, all: all, now: now, policy: policy) {
            case .change(let target, let kind, let summary):
                commit(to: target.candidate, level: .engine, kind: kind, now: now)
                return decision(
                    .apply(Change(from: cur, to: target.candidate, level: .engine, kind: kind)), .engineSwitch,
                    summary, chosen: target.candidate, blockers: blockers, now: now
                )
            case .blocked(let found):
                blockers += found
            }
            return decision(
                .keep(cur), .noAlternative,
                "\(cur) is unusable, but no change is possible: " + blockers.map { "\($0.level.rawValue): \($0.code.rawValue)" }.joined(separator: ", "),
                chosen: nil, blockers: blockers, now: now
            )
        }

        blockers.append(Blocker(
            level: .engine, code: .inEngineSatisfiable,
            detail: "the current configuration is usable; an engine switch is not considered"
        ))
        return decision(
            .keep(cur), .currentRetained,
            "keeping \(cur): utility \(fmt(currentAssessment?.utility ?? 0)); "
                + blockers.map { "\($0.level.rawValue): \($0.code.rawValue)" }.joined(separator: ", "),
            chosen: nil, blockers: blockers, now: now
        )
    }

    private enum LevelOutcome {
        case change(CandidateAssessment, ChangeKind, String)
        case blocked([Blocker])
    }

    /// Levels (a) and (b).
    private func evaluateInEngine(
        level: SwitchLevel,
        pool: [CandidateAssessment],
        current: CandidateAssessment?,
        forced: Bool,
        now: Instant,
        policy: SelectionPolicy
    ) -> LevelOutcome {
        let levelPolicy = level == .server ? policy.server : policy.transport
        let available = pool.filter(\.isAvailable)
        guard !available.isEmpty else {
            return .blocked([Blocker(
                level: level, code: .noAvailableCandidate,
                detail: "\(pool.count) candidates at this level, none usable"
            )])
        }
        let recent = inEngineSwitchCount(since: now, window: policy.rateLimit.window)
        let rateLimited = recent >= policy.rateLimit.maximumSwitches
        let rateBlocker = Blocker(
            level: level, code: .rateLimited,
            detail: "\(recent) in-engine switches in the last \(fmt(policy.rateLimit.window))s, limit \(policy.rateLimit.maximumSwitches)"
        )

        if forced {
            // The current candidate is unusable: margins, dwell and cooldown
            // do not apply. The rate limit does — it is the hard bound that
            // keeps a flapping network from turning into a switching storm.
            if rateLimited { return .blocked([rateBlocker]) }
            let best = ranked(available)[0]
            return .change(
                best, .failover,
                "failover (\(level.rawValue)) to \(best.candidate): current is unusable; "
                    + "target utility \(fmt(best.utility)), tier \(best.tier), best of \(available.count) usable"
            )
        }

        guard let current else { return .blocked([]) }
        if policy.strategy == .failover {
            return .blocked([Blocker(
                level: level, code: .stickyStrategy,
                detail: "failover strategy leaves a working candidate only when it fails"
            )])
        }
        let needsEvidence = policy.strategy != .manualPriority
        let proven = available.filter { !needsEvidence || $0.score.sampleCount >= levelPolicy.minimumTargetSamples }
        guard !proven.isEmpty else {
            return .blocked([Blocker(
                level: level, code: .targetNotProven,
                detail: "no usable candidate has \(levelPolicy.minimumTargetSamples) samples yet"
            )])
        }
        let eligible = proven.filter { !$0.isCoolingDown }
        guard !eligible.isEmpty else {
            return .blocked([Blocker(
                level: level, code: .targetCoolingDown,
                detail: "\(proven.count) candidates were left less than \(fmt(policy.returnCooldown))s ago"
            )])
        }
        let best = ranked(eligible)[0]
        let gain = best.utility - current.utility
        let better: Bool
        if best.tier != current.tier {
            better = best.tier < current.tier
        } else {
            better = gain > 0 && gain >= levelPolicy.hysteresisMargin
        }
        guard better else {
            return .blocked([Blocker(
                level: level, code: .insufficientMargin,
                detail: "best alternative \(best.candidate) utility \(fmt(best.utility)) (tier \(best.tier)) vs current "
                    + "\(fmt(current.utility)) (tier \(current.tier)); required margin \(fmt(levelPolicy.hysteresisMargin))"
            )])
        }
        let dwell = currentSince.map { now.duration(since: $0) } ?? 0
        guard dwell >= levelPolicy.minimumDwell else {
            return .blocked([Blocker(
                level: level, code: .dwellNotElapsed,
                detail: "on current for \(fmt(dwell))s, minimum dwell \(fmt(levelPolicy.minimumDwell))s"
            )])
        }
        if rateLimited { return .blocked([rateBlocker]) }
        return .change(
            best, .improvement,
            "switch \(level.rawValue) to \(best.candidate): utility \(fmt(best.utility)) vs \(fmt(current.utility)) "
                + "(tier \(best.tier) vs \(current.tier)), margin \(fmt(levelPolicy.hysteresisMargin)), "
                + "dwell \(fmt(dwell))s, \(best.score.sampleCount) samples"
        )
    }

    /// Level (c). Called only when the current candidate is unusable and
    /// levels (a) and (b) made no change.
    private func evaluateEngine(
        current cur: Candidate,
        all: [CandidateAssessment],
        now: Instant,
        policy: SelectionPolicy
    ) -> LevelOutcome {
        let rules = policy.engineSwitch
        // The gate. Breaker state only: quarantine and cooldown are not
        // failure evidence and must not open the way to a tunnel restart.
        let closedInEngine = all.filter { $0.candidate.engine == cur.engine && $0.health.isClosed }.count
        guard closedInEngine == 0 else {
            return .blocked([Blocker(
                level: .engine, code: .inEngineSatisfiable,
                detail: "\(closedInEngine) candidates of engine \(cur.engine) have a closed breaker; levels (a)/(b) can still satisfy the profile"
            )])
        }
        guard rules.isEnabled else {
            return .blocked([Blocker(level: .engine, code: .engineSwitchDisabled, detail: "engine switching is disabled for \(network.rawValue)")])
        }
        let pool = all.filter { $0.candidate.engine != cur.engine && $0.isAvailable }
        guard !pool.isEmpty else {
            return .blocked([Blocker(level: .engine, code: .noAvailableCandidate, detail: "no usable candidate on another engine")])
        }
        // Structural: the profile has no candidate at all for the current
        // engine. There is nothing to wait for and nothing to compare with.
        let structural = !all.contains { $0.candidate.engine == cur.engine }

        var blockers: [Blocker] = []
        var eligible = pool
        if !structural {
            let outage = states[network]?.engineOutageSince.map { now.duration(since: $0) } ?? 0
            if outage < rules.requiredOutage {
                blockers.append(Blocker(
                    level: .engine, code: .outageTooShort,
                    detail: "engine \(cur.engine) unusable for \(fmt(outage))s, required \(fmt(rules.requiredOutage))s"
                ))
            }
            if rules.requireTargetEvidence {
                eligible = pool.filter { $0.score.sampleCount >= rules.minimumTargetSamples }
                if eligible.isEmpty {
                    blockers.append(Blocker(
                        level: .engine, code: .targetNotProven,
                        detail: "no candidate on another engine has \(rules.minimumTargetSamples) samples"
                    ))
                }
            }
        }
        let best = ranked(eligible).first
        if let best, !structural {
            let net = best.score.value - rules.cost.totalPenalty
            if net < rules.minimumNetBenefit {
                blockers.append(Blocker(
                    level: .engine, code: .costExceedsBenefit,
                    detail: "target score \(fmt(best.score.value)) minus restart cost \(fmt(rules.cost.totalPenalty)) "
                        + "= \(fmt(net)), required \(fmt(rules.minimumNetBenefit))"
                ))
            }
        }
        let engineRecords = switchLog.filter { $0.level == .engine }
        if let last = engineRecords.last, now.duration(since: last.at) < rules.minimumInterval {
            blockers.append(Blocker(
                level: .engine, code: .engineIntervalNotElapsed,
                detail: "last tunnel restart \(fmt(now.duration(since: last.at)))s ago, minimum interval \(fmt(rules.minimumInterval))s"
            ))
        }
        let recent = engineRecords.filter { now.duration(since: $0.at) < rules.rateLimit.window }.count
        if recent >= rules.rateLimit.maximumSwitches {
            blockers.append(Blocker(
                level: .engine, code: .rateLimited,
                detail: "\(recent) tunnel restarts in the last \(fmt(rules.rateLimit.window))s, limit \(rules.rateLimit.maximumSwitches)"
            ))
        }
        guard blockers.isEmpty, let best else { return .blocked(blockers) }
        let why = structural
            ? "the profile has no candidate for engine \(cur.engine)"
            : "every candidate of engine \(cur.engine) has an open breaker"
        return .change(
            best, .failover,
            "engine switch to \(best.candidate): \(why); target score \(fmt(best.score.value)), "
                + "restart cost \(fmt(rules.cost.totalPenalty)) points, expected downtime \(fmt(rules.cost.expectedDowntime))s; "
                + "the tunnel restarts and all connections are dropped"
        )
    }

    // MARK: - Probation and rollback

    private func probationVerdict(_ p: ProbationState, now: Instant, policy: SelectionPolicy) -> ProbationVerdict {
        if p.applyFailed { return .failed("the configuration could not be applied") }
        if p.failures >= policy.probation.failureThreshold {
            return .failed("\(p.failures) failures in probation, threshold \(policy.probation.failureThreshold)")
        }
        if !health(of: p.candidate, now: now).isClosed { return .failed("circuit breaker opened") }
        guard now.duration(since: p.startedAt) >= policy.probation.window else { return .pending }
        if p.successes >= policy.probation.minimumSuccesses { return .passed }
        return .failed("only \(p.successes) successes in the probation window, required \(policy.probation.minimumSuccesses)")
    }

    /// The last known good configuration, if rolling back to it is possible.
    /// A rollback across engines is allowed only to undo an engine switch:
    /// an in-engine probation failure never restarts the tunnel.
    private func rollbackTarget(from cur: Candidate, probationLevel: SwitchLevel?, now: Instant) -> Candidate? {
        guard let lkg = states[network]?.lastKnownGood?.candidate, lkg != cur, descriptors[lkg] != nil else { return nil }
        guard health(of: lkg, now: now).isClosed, !isQuarantined(lkg, now: now) else { return nil }
        if lkg.engine != cur.engine, probationLevel != .engine { return nil }
        return lkg
    }

    // MARK: - Helpers

    private mutating func commit(to target: Candidate, level: SwitchLevel?, kind: ChangeKind, now: Instant) {
        if let old = current { leftAt[old] = now }
        current = target
        currentSince = now
        switchLog.append(SwitchRecord(at: now, level: level, kind: kind))
        probation = kind == .rollback ? nil : ProbationState(candidate: target, level: level, startedAt: now)
        if var state = states[network] {
            state.engineOutageSince = nil
            states[network] = state
        }
        refreshOutage(now: now)
    }

    private func inEngineSwitchCount(since now: Instant, window: Double) -> Int {
        switchLog.filter {
            ($0.level == .server || $0.level == .transport) && now.duration(since: $0.at) < window
        }.count
    }

    private func isQuarantined(_ candidate: Candidate, now: Instant) -> Bool {
        guard let until = quarantinedUntil[candidate] else { return false }
        return now < until
    }

    private func assess(_ candidate: Candidate, now: Instant, policy: SelectionPolicy, maxWeight: Double) -> CandidateAssessment {
        let score = policy.scoring.score(states[network]?.metrics[candidate] ?? CandidateMetrics(), now: now)
        let descriptor = descriptors[candidate]
        let tier: Int
        let utility: Double
        switch policy.strategy {
        case .lowestLatency, .highestThroughput, .maxStability, .balanced:
            tier = 0
            utility = score.value
        case .weighted:
            tier = 0
            utility = maxWeight > 0 ? score.value * ((descriptor?.weight ?? 0) / maxWeight) : 0
        case .failover:
            tier = descriptor?.priority ?? 0
            utility = score.value
        case .manualPriority:
            tier = descriptor?.priority ?? 0
            utility = 0
        }
        let cooling = leftAt[candidate].map { now.duration(since: $0) < policy.returnCooldown } ?? false
        return CandidateAssessment(
            candidate: candidate,
            score: score,
            health: health(of: candidate, now: now),
            tier: tier,
            utility: utility,
            isQuarantined: isQuarantined(candidate, now: now),
            isCoolingDown: cooling
        )
    }

    /// Best first: lower tier, then higher utility, then candidate order.
    private func ranked(_ pool: [CandidateAssessment]) -> [CandidateAssessment] {
        pool.sorted {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.utility != $1.utility { return $0.utility > $1.utility }
            return $0.candidate < $1.candidate
        }
    }

    /// Tracks since when the current engine has no candidate with a closed
    /// breaker. Depends on breaker state only.
    private mutating func refreshOutage(now: Instant) {
        guard let cur = current else { return }
        var state = states[network] ?? NetworkState()
        let satisfiable = order.contains { $0.engine == cur.engine && health(of: $0, now: now).isClosed }
        if satisfiable {
            state.engineOutageSince = nil
        } else if state.engineOutageSince == nil {
            state.engineOutageSince = now
        }
        states[network] = state
    }

    private mutating func prune(now: Instant) {
        let horizon = [
            policies.wifi.rateLimit.window, policies.cellular.rateLimit.window,
            policies.wifi.engineSwitch.rateLimit.window, policies.cellular.engineSwitch.rateLimit.window,
            policies.wifi.engineSwitch.minimumInterval, policies.cellular.engineSwitch.minimumInterval,
        ].max() ?? 0
        switchLog.removeAll { now.duration(since: $0.at) > horizon }
        let cooldown = max(policies.wifi.returnCooldown, policies.cellular.returnCooldown)
        leftAt = leftAt.filter { now.duration(since: $0.value) <= cooldown }
        quarantinedUntil = quarantinedUntil.filter { now < $0.value }
    }

    private func decision(
        _ action: Action,
        _ reason: DecisionReason,
        _ summary: String,
        chosen: Candidate?,
        blockers: [Blocker],
        now: Instant
    ) -> Decision {
        let all = assessments(now: now)
        return Decision(
            action: action,
            explanation: Explanation(
                at: now,
                network: network,
                strategy: policy.strategy,
                reason: reason,
                summary: summary,
                current: current.flatMap { cur in all.first { $0.candidate == cur } },
                chosen: chosen.flatMap { c in all.first { $0.candidate == c } },
                blockers: blockers,
                candidates: all
            )
        )
    }

    private func fmt(_ value: Double) -> String {
        guard value.isFinite else { return "n/a" }
        return String((value * 10).rounded() / 10)
    }
}
