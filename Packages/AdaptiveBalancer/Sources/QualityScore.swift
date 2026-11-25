import Foundation

/// The inputs of the connection quality score.
public enum QualityMetric: String, Hashable, Sendable, Codable, CaseIterable {
    case latency
    case jitter
    case loss
    /// Connection establishment plus TLS handshake time.
    case handshake
    /// One minus the smoothed failure rate.
    case reliability
    case throughput
}

/// Relative importance of each metric. Weights need not sum to one: metrics
/// that have no data drop out and the rest are renormalised.
public struct ScoreWeights: Hashable, Sendable, Codable {
    public var latency: Double
    public var jitter: Double
    public var loss: Double
    public var handshake: Double
    public var reliability: Double
    public var throughput: Double

    public init(latency: Double, jitter: Double, loss: Double, handshake: Double, reliability: Double, throughput: Double) {
        self.latency = latency
        self.jitter = jitter
        self.loss = loss
        self.handshake = handshake
        self.reliability = reliability
        self.throughput = throughput
    }

    public func weight(of metric: QualityMetric) -> Double {
        let raw: Double
        switch metric {
        case .latency: raw = latency
        case .jitter: raw = jitter
        case .loss: raw = loss
        case .handshake: raw = handshake
        case .reliability: raw = reliability
        case .throughput: raw = throughput
        }
        return (raw.isFinite && raw > 0) ? raw : 0
    }

    public static let balanced = ScoreWeights(latency: 0.25, jitter: 0.10, loss: 0.20, handshake: 0.10, reliability: 0.20, throughput: 0.15)
    public static let latencyFirst = ScoreWeights(latency: 0.60, jitter: 0.10, loss: 0.10, handshake: 0.10, reliability: 0.10, throughput: 0)
    public static let throughputFirst = ScoreWeights(latency: 0.10, jitter: 0, loss: 0.15, handshake: 0, reliability: 0.15, throughput: 0.60)
    public static let stabilityFirst = ScoreWeights(latency: 0.10, jitter: 0.20, loss: 0.30, handshake: 0, reliability: 0.40, throughput: 0)
}

/// The "good" and "bad" ends of each metric. A value at or beyond the good end
/// scores 1, at or beyond the bad end scores 0, linear in between (throughput:
/// logarithmic).
public struct ScoreScale: Hashable, Sendable, Codable {
    public var rttGoodMillis: Double
    public var rttBadMillis: Double
    public var jitterGoodMillis: Double
    public var jitterBadMillis: Double
    public var lossBadFraction: Double
    public var handshakeGoodMillis: Double
    public var handshakeBadMillis: Double
    public var failureRateBad: Double
    public var throughputBadBitsPerSecond: Double
    public var throughputGoodBitsPerSecond: Double

    public init(
        rttGoodMillis: Double = 40,
        rttBadMillis: Double = 800,
        jitterGoodMillis: Double = 5,
        jitterBadMillis: Double = 150,
        lossBadFraction: Double = 0.2,
        handshakeGoodMillis: Double = 150,
        handshakeBadMillis: Double = 3000,
        failureRateBad: Double = 0.5,
        throughputBadBitsPerSecond: Double = 500_000,
        throughputGoodBitsPerSecond: Double = 50_000_000
    ) {
        self.rttGoodMillis = rttGoodMillis
        self.rttBadMillis = rttBadMillis
        self.jitterGoodMillis = jitterGoodMillis
        self.jitterBadMillis = jitterBadMillis
        self.lossBadFraction = lossBadFraction
        self.handshakeGoodMillis = handshakeGoodMillis
        self.handshakeBadMillis = handshakeBadMillis
        self.failureRateBad = failureRateBad
        self.throughputBadBitsPerSecond = throughputBadBitsPerSecond
        self.throughputGoodBitsPerSecond = throughputGoodBitsPerSecond
    }
}

/// How smoothed metrics become one number.
public struct ScoreModel: Hashable, Sendable, Codable {
    public var weights: ScoreWeights
    public var scale: ScoreScale
    public var smoothing: SmoothingParameters
    /// The score of a candidate nothing is known about, `0...100`. A measured
    /// score is pulled towards this value in proportion to missing confidence,
    /// so one lucky probe cannot outrank a well-measured candidate.
    public var priorScore: Double
    /// Number of samples at which sample-count confidence reaches one half.
    public var confidenceHalfSamples: Double
    /// Age of the newest sample, seconds, at which confidence halves.
    public var freshnessHalfLife: Double

    public init(
        weights: ScoreWeights = .balanced,
        scale: ScoreScale = ScoreScale(),
        smoothing: SmoothingParameters = SmoothingParameters(),
        priorScore: Double = 40,
        confidenceHalfSamples: Double = 4,
        freshnessHalfLife: Double = 300
    ) {
        self.weights = weights
        self.scale = scale
        self.smoothing = smoothing
        self.priorScore = min(100, max(0, priorScore))
        self.confidenceHalfSamples = max(0, confidenceHalfSamples)
        self.freshnessHalfLife = max(0, freshnessHalfLife)
    }

    /// Confidence in a candidate's statistics, `0...1`: grows with the number
    /// of samples, decays with the age of the newest one.
    public func confidence(of metrics: CandidateMetrics, now: Instant) -> Double {
        let n = Double(metrics.sampleCount)
        guard n > 0, let last = metrics.lastSampleAt else { return 0 }
        let bySamples = confidenceHalfSamples > 0 ? n / (n + confidenceHalfSamples) : 1
        let age = now.duration(since: last)
        let byAge = freshnessHalfLife > 0 ? pow(0.5, age / freshnessHalfLife) : 1
        return min(1, max(0, bySamples * byAge))
    }

    /// Computes the quality score of a candidate from its smoothed metrics.
    public func score(_ metrics: CandidateMetrics, now: Instant) -> ScoreBreakdown {
        var components: [ScoreBreakdown.Component] = []

        func add(_ metric: QualityMetric, _ value: Double?, _ quality: (Double) -> Double) {
            guard let value else { return }
            let w = weights.weight(of: metric)
            guard w > 0 else { return }
            components.append(.init(metric: metric, smoothedValue: value, quality: min(1, max(0, quality(value))), weight: w))
        }

        add(.latency, metrics.rtt.current) { Self.linear($0, good: scale.rttGoodMillis, bad: scale.rttBadMillis) }
        add(.jitter, metrics.jitter.current) { Self.linear($0, good: scale.jitterGoodMillis, bad: scale.jitterBadMillis) }
        add(.loss, metrics.loss.current) { Self.linear($0, good: 0, bad: scale.lossBadFraction) }
        let handshake: Double?
        switch (metrics.connect.current, metrics.tls.current) {
        case let (c?, t?): handshake = c + t
        case let (c?, nil): handshake = c
        case let (nil, t?): handshake = t
        case (nil, nil): handshake = nil
        }
        add(.handshake, handshake) { Self.linear($0, good: scale.handshakeGoodMillis, bad: scale.handshakeBadMillis) }
        add(.reliability, metrics.failureRate.current) { Self.linear($0, good: 0, bad: scale.failureRateBad) }
        add(.throughput, metrics.throughput.current) {
            Self.logarithmic($0, bad: scale.throughputBadBitsPerSecond, good: scale.throughputGoodBitsPerSecond)
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let confidence = self.confidence(of: metrics, now: now)
        guard totalWeight > 0 else {
            return ScoreBreakdown(value: priorScore, measured: nil, confidence: 0, sampleCount: metrics.sampleCount, components: [])
        }
        let measured = 100 * components.reduce(0) { $0 + $1.weight * $1.quality } / totalWeight
        let value = priorScore + confidence * (measured - priorScore)
        return ScoreBreakdown(
            value: min(100, max(0, value)),
            measured: measured,
            confidence: confidence,
            sampleCount: metrics.sampleCount,
            components: components
        )
    }

    static func linear(_ x: Double, good: Double, bad: Double) -> Double {
        guard bad > good else { return x <= good ? 1 : 0 }
        return (bad - x) / (bad - good)
    }

    static func logarithmic(_ x: Double, bad: Double, good: Double) -> Double {
        guard bad > 0, good > bad else { return x >= good ? 1 : 0 }
        guard x > 0 else { return 0 }
        return (log(x) - log(bad)) / (log(good) - log(bad))
    }
}

/// A quality score with everything needed to explain it.
public struct ScoreBreakdown: Hashable, Sendable, Codable {
    public struct Component: Hashable, Sendable, Codable {
        public let metric: QualityMetric
        /// The smoothed input (milliseconds, a fraction, or bits per second).
        public let smoothedValue: Double
        /// The input mapped onto `0...1`, higher is better.
        public let quality: Double
        public let weight: Double
    }

    /// The score used for decisions, `0...100`: the measured score pulled
    /// towards the prior by missing confidence.
    public let value: Double
    /// The score the metrics alone give, `nil` when nothing was measured.
    public let measured: Double?
    public let confidence: Double
    public let sampleCount: Int
    public let components: [Component]
}
