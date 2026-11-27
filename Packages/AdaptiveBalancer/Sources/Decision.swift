/// Why a change is made.
public enum ChangeKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Nothing was selected before.
    case initialSelection
    /// Voluntary: the target is better by more than the hysteresis margin.
    case improvement
    /// Forced: the current candidate is unusable.
    case failover
    /// The new configuration failed probation; back to the last known good one.
    case rollback
}

/// A configuration change the caller is asked to carry out.
public struct Change: Hashable, Sendable, Codable {
    public let from: Candidate?
    public let to: Candidate
    /// The level of the change; `nil` for the initial selection.
    public let level: SwitchLevel?
    public let kind: ChangeKind

    /// `true` when the change replaces the engine and therefore restarts the
    /// tunnel extension.
    ///
    /// When this is `true`, **all connections through the tunnel are lost**.
    /// The decision layer does not, and cannot, preserve TCP sessions across
    /// an engine switch; callers must not present it to users as seamless.
    public var requiresTunnelRestart: Bool { level == .engine }
}

public enum Action: Hashable, Sendable, Codable {
    /// Leave things as they are. The payload is the current candidate, if any.
    case keep(Candidate?)
    case apply(Change)
}

/// The machine-readable headline of a decision.
public enum DecisionReason: String, Hashable, Sendable, Codable, CaseIterable {
    case noCandidates
    case noUsableCandidate
    case initialSelection
    case inProbation
    case probationPassed
    case rollback
    case improvement
    case failover
    case engineSwitch
    /// The current candidate is healthy and nothing justified a change.
    case currentRetained
    /// The current candidate is unusable, but no change is permitted or possible.
    case noAlternative
}

/// One reason a level did not produce a change.
public struct Blocker: Hashable, Sendable, Codable {
    public enum Code: String, Hashable, Sendable, Codable, CaseIterable {
        case noAvailableCandidate
        case stickyStrategy
        case targetNotProven
        case targetCoolingDown
        case insufficientMargin
        case dwellNotElapsed
        case rateLimited
        case inEngineSatisfiable
        case engineSwitchDisabled
        case outageTooShort
        case costExceedsBenefit
        case engineIntervalNotElapsed
    }

    public let level: SwitchLevel
    public let code: Code
    /// Human-readable detail with the numbers that decided it.
    public let detail: String

    public init(level: SwitchLevel, code: Code, detail: String) {
        self.level = level
        self.code = code
        self.detail = detail
    }
}

/// Everything the balancer knows about one candidate at decision time.
public struct CandidateAssessment: Hashable, Sendable, Codable {
    public let candidate: Candidate
    public let score: ScoreBreakdown
    public let health: BreakerState
    /// Priority tier used by the strategy (lower is preferred; `0` for
    /// score-based strategies).
    public let tier: Int
    /// The quantity the strategy compares inside one tier.
    public let utility: Double
    public let isQuarantined: Bool
    public let isCoolingDown: Bool

    /// Selectable for traffic: breaker closed and not quarantined.
    public var isAvailable: Bool { health.isClosed && !isQuarantined }
}

/// Why a decision was made. Returned with every decision, safe to log as long
/// as identifiers are opaque (see `Identifiers.swift`).
public struct Explanation: Hashable, Sendable, Codable {
    public let at: Instant
    public let network: NetworkClass
    public let strategy: SelectionStrategy
    public let reason: DecisionReason
    /// One English sentence with the decisive numbers.
    public let summary: String
    public let current: CandidateAssessment?
    public let chosen: CandidateAssessment?
    /// Per level, why no change (or no cheaper change) was made.
    public let blockers: [Blocker]
    /// All candidates, in deterministic order.
    public let candidates: [CandidateAssessment]
}

/// The result of `AdaptiveBalancer.decide(now:)`.
public struct Decision: Hashable, Sendable, Codable {
    public let action: Action
    public let explanation: Explanation

    /// The change to carry out, if any.
    public var change: Change? {
        if case .apply(let change) = action { return change }
        return nil
    }

    /// See `Change.requiresTunnelRestart`.
    public var requiresTunnelRestart: Bool { change?.requiresTunnelRestart ?? false }
}

/// Why the caller should probe a candidate.
public enum ProbeReason: String, Hashable, Sendable, Codable, CaseIterable {
    /// The breaker is half-open: only probe results can close it.
    case recovery
    /// The current configuration is in its probation window.
    case probation
    /// Never measured on this network class.
    case unmeasured
    /// The newest sample is older than `SelectionPolicy.probeStaleAfter`.
    case stale
}

public struct ProbeRequest: Hashable, Sendable, Codable {
    public let candidate: Candidate
    public let reason: ProbeReason
}

/// The configuration that most recently survived a probation window.
public struct LastKnownGood: Hashable, Sendable, Codable {
    public let candidate: Candidate
    public let confirmedAt: Instant
}
