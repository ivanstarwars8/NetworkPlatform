/// Failure thresholds for one candidate.
public struct BreakerPolicy: Hashable, Sendable, Codable {
    /// Consecutive failures that open the breaker.
    public var consecutiveFailures: Int
    /// Smoothed failure rate that opens the breaker even when failures are
    /// interleaved with successes; `nil` disables the rule.
    public var failureRateThreshold: Double?
    /// Samples required before the failure-rate rule applies.
    public var failureRateMinimumSamples: Int
    /// How long the breaker stays open after the first trip, seconds.
    public var openDuration: Double
    /// Each further trip multiplies the open duration by this factor.
    public var backoffMultiplier: Double
    public var maximumOpenDuration: Double
    /// Consecutive successful probes that close a half-open breaker.
    public var halfOpenSuccesses: Int
    /// A breaker that stayed closed this long forgets its earlier trips.
    public var tripMemory: Double

    public init(
        consecutiveFailures: Int = 3,
        failureRateThreshold: Double? = 0.5,
        failureRateMinimumSamples: Int = 8,
        openDuration: Double = 30,
        backoffMultiplier: Double = 2,
        maximumOpenDuration: Double = 600,
        halfOpenSuccesses: Int = 2,
        tripMemory: Double = 600
    ) {
        self.consecutiveFailures = max(1, consecutiveFailures)
        self.failureRateThreshold = failureRateThreshold
        self.failureRateMinimumSamples = max(1, failureRateMinimumSamples)
        self.openDuration = max(0, openDuration)
        self.backoffMultiplier = max(1, backoffMultiplier)
        self.maximumOpenDuration = max(self.openDuration, maximumOpenDuration)
        self.halfOpenSuccesses = max(1, halfOpenSuccesses)
        self.tripMemory = max(0, tripMemory)
    }
}

/// The health of one candidate as the circuit breaker sees it.
public enum BreakerState: Hashable, Sendable, Codable {
    /// Usable.
    case closed
    /// Failed too often. Not selectable and not probed until `until`.
    case open(until: Instant)
    /// The open period is over. Not selectable for traffic yet; the caller
    /// should send probes (see `AdaptiveBalancer.probePlan`). Closes after
    /// enough consecutive successes, re-opens on the first failure.
    case halfOpen(successes: Int)

    public var isClosed: Bool { self == .closed }
}

/// A per-candidate circuit breaker. A pure state machine: time comes from the
/// caller, and the only inputs are outcomes (success or failure). Latency,
/// jitter and throughput never reach it.
public struct CircuitBreaker: Hashable, Sendable, Codable {
    private var stored: BreakerState = .closed
    public private(set) var tripCount = 0
    public private(set) var consecutiveFailures = 0
    private var closedSince: Instant?

    public init() {}

    /// The state at `now`. An open breaker whose time is up reads as half-open.
    public func state(at now: Instant) -> BreakerState {
        if case .open(let until) = stored, now >= until { return .halfOpen(successes: 0) }
        return stored
    }

    public mutating func record(
        success: Bool,
        at now: Instant,
        failureRate: Double?,
        sampleCount: Int,
        policy: BreakerPolicy
    ) {
        stored = state(at: now)
        switch stored {
        case .closed:
            if success {
                consecutiveFailures = 0
                if tripCount > 0, let since = closedSince, now.duration(since: since) >= policy.tripMemory {
                    tripCount = 0
                }
            } else {
                consecutiveFailures += 1
                var trips = consecutiveFailures >= policy.consecutiveFailures
                if !trips, let threshold = policy.failureRateThreshold, let rate = failureRate,
                   sampleCount >= policy.failureRateMinimumSamples, rate >= threshold {
                    trips = true
                }
                if trips { trip(at: now, policy: policy) }
            }
        case .open:
            // A result that raced with the trip. The open period is not
            // extended and cannot be cut short.
            break
        case .halfOpen(let successes):
            if success {
                if successes + 1 >= policy.halfOpenSuccesses {
                    stored = .closed
                    closedSince = now
                    consecutiveFailures = 0
                } else {
                    stored = .halfOpen(successes: successes + 1)
                }
            } else {
                trip(at: now, policy: policy)
            }
        }
    }

    private mutating func trip(at now: Instant, policy: BreakerPolicy) {
        tripCount += 1
        var duration = policy.openDuration
        if tripCount > 1 {
            for _ in 1..<tripCount {
                duration *= policy.backoffMultiplier
                if duration >= policy.maximumOpenDuration { break }
            }
        }
        duration = min(duration, policy.maximumOpenDuration)
        stored = .open(until: now + duration)
        consecutiveFailures = 0
        closedSince = nil
    }
}
