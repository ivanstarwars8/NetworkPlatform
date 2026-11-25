import Foundation

/// An exponentially weighted moving average that remembers how many samples
/// it has seen. The first sample initialises the value.
public struct SmoothedValue: Hashable, Sendable, Codable {
    public private(set) var value: Double
    public private(set) var sampleCount: Int

    public init() {
        value = 0
        sampleCount = 0
    }

    public var isEmpty: Bool { sampleCount == 0 }

    /// The smoothed value, or `nil` before the first sample.
    public var current: Double? { sampleCount == 0 ? nil : value }

    /// Folds in one sample. `alpha` is the weight of the new sample, `0 < alpha <= 1`.
    /// Non-finite samples are ignored.
    public mutating func add(_ sample: Double, alpha: Double) {
        guard sample.isFinite else { return }
        let a = min(1, max(0.000_001, alpha))
        if sampleCount == 0 {
            value = sample
        } else {
            value += a * (sample - value)
        }
        sampleCount += 1
    }
}

/// Why a probe or a connection attempt failed. The decision layer treats all
/// kinds the same; the kind is kept for explanations.
public enum FailureKind: String, Hashable, Sendable, Codable, CaseIterable {
    case timeout
    case connectionRefused
    case networkUnreachable
    case tlsFailure
    case authenticationRejected
    case engineError
    case other
}

/// What one successful probe (or one observed connection) measured.
/// Every field is optional: a prober reports what it has.
public struct ProbeMeasurement: Hashable, Sendable, Codable {
    /// Round-trip time through the candidate, milliseconds.
    public var rttMillis: Double?
    /// Time to establish the transport connection, milliseconds.
    public var connectMillis: Double?
    /// Time to complete the TLS (or equivalent) handshake, milliseconds.
    public var tlsMillis: Double?
    /// Fraction of lost probes in the burst, `0...1`.
    public var lossFraction: Double?
    /// Measured throughput, bits per second. Usually absent: measuring it
    /// costs traffic, so it is optional everywhere.
    public var throughputBitsPerSecond: Double?

    public init(
        rttMillis: Double? = nil,
        connectMillis: Double? = nil,
        tlsMillis: Double? = nil,
        lossFraction: Double? = nil,
        throughputBitsPerSecond: Double? = nil
    ) {
        self.rttMillis = rttMillis
        self.connectMillis = connectMillis
        self.tlsMillis = tlsMillis
        self.lossFraction = lossFraction
        self.throughputBitsPerSecond = throughputBitsPerSecond
    }
}

/// One observation about one candidate.
public struct ProbeSample: Hashable, Sendable, Codable {
    public enum Outcome: Hashable, Sendable, Codable {
        case success(ProbeMeasurement)
        case failure(FailureKind)
    }

    public var candidate: Candidate
    public var at: Instant
    public var outcome: Outcome

    public init(candidate: Candidate, at: Instant, outcome: Outcome) {
        self.candidate = candidate
        self.at = at
        self.outcome = outcome
    }

    public static func success(_ candidate: Candidate, at: Instant, _ measurement: ProbeMeasurement) -> ProbeSample {
        ProbeSample(candidate: candidate, at: at, outcome: .success(measurement))
    }

    public static func failure(_ candidate: Candidate, at: Instant, _ kind: FailureKind = .timeout) -> ProbeSample {
        ProbeSample(candidate: candidate, at: at, outcome: .failure(kind))
    }

    public var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }
}

/// Smoothing factors for the per-candidate averages.
public struct SmoothingParameters: Hashable, Sendable, Codable {
    /// Weight of a new RTT / connect / TLS / throughput sample.
    public var alpha: Double
    /// Weight of a new jitter sample (RFC 3550 uses 1/16; a prober sends far
    /// fewer packets than an RTP stream, so the default is larger).
    public var jitterAlpha: Double
    /// Weight of a new outcome in the failure-rate and loss averages.
    public var outcomeAlpha: Double

    public init(alpha: Double = 0.3, jitterAlpha: Double = 0.25, outcomeAlpha: Double = 0.2) {
        self.alpha = alpha
        self.jitterAlpha = jitterAlpha
        self.outcomeAlpha = outcomeAlpha
    }
}

/// Smoothed statistics for one candidate on one network class.
public struct CandidateMetrics: Hashable, Sendable, Codable {
    public private(set) var rtt = SmoothedValue()
    /// Mean absolute difference between consecutive RTT samples.
    public private(set) var jitter = SmoothedValue()
    public private(set) var loss = SmoothedValue()
    public private(set) var connect = SmoothedValue()
    public private(set) var tls = SmoothedValue()
    public private(set) var throughput = SmoothedValue()
    /// Average of outcomes, `1` for a failure and `0` for a success.
    public private(set) var failureRate = SmoothedValue()

    public private(set) var successCount = 0
    public private(set) var failureCount = 0
    public private(set) var lastSampleAt: Instant?
    public private(set) var lastSuccessAt: Instant?
    public private(set) var lastFailure: FailureKind?
    private var previousRTT: Double?

    public init() {}

    /// Number of observations of any outcome.
    public var sampleCount: Int { successCount + failureCount }

    /// Folds in one observation. Values that are negative or not finite are
    /// dropped field by field; the outcome itself is still counted.
    public mutating func add(_ outcome: ProbeSample.Outcome, at: Instant, smoothing: SmoothingParameters) {
        if let last = lastSampleAt {
            lastSampleAt = max(last, at)
        } else {
            lastSampleAt = at
        }
        switch outcome {
        case .failure(let kind):
            failureCount += 1
            lastFailure = kind
            failureRate.add(1, alpha: smoothing.outcomeAlpha)
            // A failed probe breaks the RTT sequence: do not derive jitter
            // from samples that straddle an outage.
            previousRTT = nil
        case .success(let m):
            successCount += 1
            lastSuccessAt = at
            failureRate.add(0, alpha: smoothing.outcomeAlpha)
            if let v = Self.sanitised(m.rttMillis) {
                if let prev = previousRTT {
                    jitter.add(abs(v - prev), alpha: smoothing.jitterAlpha)
                }
                previousRTT = v
                rtt.add(v, alpha: smoothing.alpha)
            }
            if let v = Self.sanitised(m.connectMillis) { connect.add(v, alpha: smoothing.alpha) }
            if let v = Self.sanitised(m.tlsMillis) { tls.add(v, alpha: smoothing.alpha) }
            if let v = Self.sanitised(m.lossFraction) { loss.add(min(1, v), alpha: smoothing.outcomeAlpha) }
            if let v = Self.sanitised(m.throughputBitsPerSecond) { throughput.add(v, alpha: smoothing.alpha) }
        }
    }

    private static func sanitised(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
