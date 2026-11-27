/// How candidates are ranked inside one engine.
public enum SelectionStrategy: String, Hashable, Sendable, Codable, CaseIterable {
    /// Quality score dominated by smoothed RTT.
    case lowestLatency
    /// Quality score dominated by measured throughput (when available).
    case highestThroughput
    /// Quality score dominated by failure rate, loss and jitter.
    case maxStability
    /// Quality score with balanced weights.
    case balanced
    /// Ordered by `CandidateDescriptor.priority`, **sticky**: the current
    /// candidate is left only when it fails; there is no automatic return to
    /// a higher-priority candidate.
    case failover
    /// Balanced quality score multiplied by the candidate's relative weight.
    /// Deterministic: one tunnel uses one outbound, so the weight biases the
    /// choice, it does not distribute traffic randomly.
    case weighted
    /// Ordered by `CandidateDescriptor.priority`, **preemptive**: the highest
    /// priority usable candidate is always preferred, whatever its score.
    case manualPriority

    /// The score weights the strategy implies.
    public var defaultWeights: ScoreWeights {
        switch self {
        case .lowestLatency: return .latencyFirst
        case .highestThroughput: return .throughputFirst
        case .maxStability: return .stabilityFirst
        case .balanced, .failover, .weighted, .manualPriority: return .balanced
        }
    }
}

/// Anti-flapping parameters of one in-engine level (server or transport).
public struct LevelPolicy: Hashable, Sendable, Codable {
    /// Hysteresis: a voluntary switch needs the target's utility to exceed the
    /// current one by at least this many points (`0...100` scale).
    public var hysteresisMargin: Double
    /// Minimum dwell time: seconds the current candidate must have been
    /// selected before a voluntary switch at this level.
    public var minimumDwell: Double
    /// A voluntary target needs at least this many samples: never a single ping.
    public var minimumTargetSamples: Int

    public init(hysteresisMargin: Double, minimumDwell: Double, minimumTargetSamples: Int) {
        self.hysteresisMargin = max(0, hysteresisMargin)
        self.minimumDwell = max(0, minimumDwell)
        self.minimumTargetSamples = max(0, minimumTargetSamples)
    }
}

/// A hard cap on the number of switches inside a sliding window.
public struct RateLimit: Hashable, Sendable, Codable {
    public var maximumSwitches: Int
    public var window: Double

    public init(maximumSwitches: Int, window: Double) {
        self.maximumSwitches = max(0, maximumSwitches)
        self.window = max(0, window)
    }
}

/// How a freshly applied configuration earns the "last known good" title.
public struct ProbationPolicy: Hashable, Sendable, Codable {
    /// Length of the probation window, seconds.
    public var window: Double
    /// Successful samples required inside the window. A configuration that
    /// produced fewer is treated as unproven and fails probation.
    public var minimumSuccesses: Int
    /// Failures inside the window that fail probation at once.
    public var failureThreshold: Int
    /// After a failed probation the configuration is not selectable for this
    /// long, seconds.
    public var quarantine: Double

    public init(window: Double = 20, minimumSuccesses: Int = 2, failureThreshold: Int = 2, quarantine: Double = 300) {
        self.window = max(0, window)
        self.minimumSuccesses = max(0, minimumSuccesses)
        self.failureThreshold = max(1, failureThreshold)
        self.quarantine = max(0, quarantine)
    }
}

/// What an engine switch costs, in the same points as the quality score.
///
/// An engine switch stops the tunnel extension and starts another one. For
/// `expectedDowntime` seconds there is no connectivity, and every connection
/// that existed is gone: applications see resets and must reconnect. Keeping
/// TCP sessions across an engine switch is impossible and is not promised.
public struct EngineSwitchCost: Hashable, Sendable, Codable {
    /// Seconds without connectivity while the extension restarts.
    public var expectedDowntime: Double
    /// Points charged per second of downtime.
    public var downtimePenaltyPerSecond: Double
    /// Points charged for terminating every established connection.
    public var connectionResetPenalty: Double

    public init(expectedDowntime: Double, downtimePenaltyPerSecond: Double, connectionResetPenalty: Double) {
        self.expectedDowntime = max(0, expectedDowntime)
        self.downtimePenaltyPerSecond = max(0, downtimePenaltyPerSecond)
        self.connectionResetPenalty = max(0, connectionResetPenalty)
    }

    /// Total cost in score points.
    public var totalPenalty: Double { expectedDowntime * downtimePenaltyPerSecond + connectionResetPenalty }
}

/// Rules of level (c): switching between engines.
///
/// An engine switch is considered only when levels (a) and (b) cannot satisfy
/// the profile: no candidate of the current engine has a closed circuit
/// breaker. Breakers open on failures only, so a change in measured latency,
/// jitter or throughput can never lead to a tunnel restart.
public struct EngineSwitchPolicy: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    /// The in-engine outage must have lasted at least this long, seconds
    /// (and never less than `cost.expectedDowntime`: restarting to cure an
    /// outage shorter than the restart itself is a net loss).
    public var minimumOutage: Double
    public var cost: EngineSwitchCost
    /// Target score minus `cost.totalPenalty` must reach this value.
    public var minimumNetBenefit: Double
    /// The target must have been measured (out-of-tunnel probes) at least
    /// `minimumTargetSamples` times.
    public var requireTargetEvidence: Bool
    public var minimumTargetSamples: Int
    /// Minimum seconds between two engine switches.
    public var minimumInterval: Double
    public var rateLimit: RateLimit

    public init(
        isEnabled: Bool = true,
        minimumOutage: Double,
        cost: EngineSwitchCost,
        minimumNetBenefit: Double = 10,
        requireTargetEvidence: Bool = true,
        minimumTargetSamples: Int = 3,
        minimumInterval: Double,
        rateLimit: RateLimit
    ) {
        self.isEnabled = isEnabled
        self.minimumOutage = max(0, minimumOutage)
        self.cost = cost
        self.minimumNetBenefit = minimumNetBenefit
        self.requireTargetEvidence = requireTargetEvidence
        self.minimumTargetSamples = max(0, minimumTargetSamples)
        self.minimumInterval = max(0, minimumInterval)
        self.rateLimit = rateLimit
    }

    /// The outage duration actually required.
    public var requiredOutage: Double { max(minimumOutage, cost.expectedDowntime) }
}

/// The complete policy for one network class.
public struct SelectionPolicy: Hashable, Sendable, Codable {
    public var strategy: SelectionStrategy
    public var scoring: ScoreModel
    /// Level (a): server selection inside one engine and transport.
    public var server: LevelPolicy
    /// Level (b): protocol/transport selection inside one engine.
    public var transport: LevelPolicy
    /// Cooldown: seconds during which a candidate that was just left cannot be
    /// chosen again voluntarily (prevents A→B→A ping-pong).
    public var returnCooldown: Double
    /// Hard cap on in-engine switches (levels a and b together, voluntary and
    /// forced). Rollbacks are not blocked by it.
    public var rateLimit: RateLimit
    public var breaker: BreakerPolicy
    public var probation: ProbationPolicy
    /// Level (c).
    public var engineSwitch: EngineSwitchPolicy
    /// A candidate whose newest sample is older than this is listed in the
    /// probe plan, seconds.
    public var probeStaleAfter: Double

    public init(
        strategy: SelectionStrategy,
        scoring: ScoreModel? = nil,
        server: LevelPolicy,
        transport: LevelPolicy,
        returnCooldown: Double,
        rateLimit: RateLimit,
        breaker: BreakerPolicy = BreakerPolicy(),
        probation: ProbationPolicy = ProbationPolicy(),
        engineSwitch: EngineSwitchPolicy,
        probeStaleAfter: Double = 120
    ) {
        self.strategy = strategy
        self.scoring = scoring ?? ScoreModel(weights: strategy.defaultWeights)
        self.server = server
        self.transport = transport
        self.returnCooldown = max(0, returnCooldown)
        self.rateLimit = rateLimit
        self.breaker = breaker
        self.probation = probation
        self.engineSwitch = engineSwitch
        self.probeStaleAfter = max(0, probeStaleAfter)
    }

    /// Defaults for Wi-Fi and wired paths: cheap probes, stable RTT, so
    /// margins are moderate and dwell times short.
    ///
    /// The numbers are project defaults chosen by reasoning, not by
    /// measurement on devices; treat them as a starting point.
    public static func wifiDefault(strategy: SelectionStrategy = .balanced) -> SelectionPolicy {
        SelectionPolicy(
            strategy: strategy,
            server: LevelPolicy(hysteresisMargin: 10, minimumDwell: 30, minimumTargetSamples: 3),
            transport: LevelPolicy(hysteresisMargin: 20, minimumDwell: 120, minimumTargetSamples: 5),
            returnCooldown: 120,
            rateLimit: RateLimit(maximumSwitches: 4, window: 600),
            breaker: BreakerPolicy(),
            probation: ProbationPolicy(),
            engineSwitch: EngineSwitchPolicy(
                minimumOutage: 20,
                cost: EngineSwitchCost(expectedDowntime: 3, downtimePenaltyPerSecond: 5, connectionResetPenalty: 10),
                minimumInterval: 300,
                rateLimit: RateLimit(maximumSwitches: 2, window: 3600)
            )
        )
    }

    /// Defaults for cellular and unknown paths: RTT is noisy, radio blips are
    /// common, every reconnect costs battery and metered traffic. Margins and
    /// dwell times are larger, failure thresholds more tolerant, and an engine
    /// switch is more expensive and rarer.
    public static func cellularDefault(strategy: SelectionStrategy = .balanced) -> SelectionPolicy {
        SelectionPolicy(
            strategy: strategy,
            server: LevelPolicy(hysteresisMargin: 15, minimumDwell: 60, minimumTargetSamples: 4),
            transport: LevelPolicy(hysteresisMargin: 25, minimumDwell: 180, minimumTargetSamples: 6),
            returnCooldown: 300,
            rateLimit: RateLimit(maximumSwitches: 3, window: 900),
            breaker: BreakerPolicy(consecutiveFailures: 4, openDuration: 45),
            probation: ProbationPolicy(window: 30),
            engineSwitch: EngineSwitchPolicy(
                minimumOutage: 45,
                cost: EngineSwitchCost(expectedDowntime: 5, downtimePenaltyPerSecond: 5, connectionResetPenalty: 15),
                minimumInterval: 600,
                rateLimit: RateLimit(maximumSwitches: 1, window: 3600)
            ),
            probeStaleAfter: 300
        )
    }
}

/// Separate policies for Wi-Fi and cellular.
public struct PolicySet: Hashable, Sendable, Codable {
    public var wifi: SelectionPolicy
    public var cellular: SelectionPolicy
    /// The engine to start with when nothing is selected yet. Engine choice is
    /// a profile decision, not a latency race: with a preferred engine set,
    /// the initial selection looks at other engines only if the preferred one
    /// has no usable candidate.
    public var preferredEngine: EngineID?

    public init(wifi: SelectionPolicy, cellular: SelectionPolicy, preferredEngine: EngineID? = nil) {
        self.wifi = wifi
        self.cellular = cellular
        self.preferredEngine = preferredEngine
    }

    public static func standard(strategy: SelectionStrategy = .balanced, preferredEngine: EngineID? = nil) -> PolicySet {
        PolicySet(
            wifi: .wifiDefault(strategy: strategy),
            cellular: .cellularDefault(strategy: strategy),
            preferredEngine: preferredEngine
        )
    }

    /// `wired` uses the Wi-Fi policy, `unknown` the cellular one.
    public func policy(for network: NetworkClass) -> SelectionPolicy {
        switch network {
        case .wifi, .wired: return wifi
        case .cellular, .unknown: return cellular
        }
    }
}
