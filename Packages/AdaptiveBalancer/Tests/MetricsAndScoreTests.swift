import XCTest
@testable import AdaptiveBalancer

final class MetricsTests: XCTestCase {
    func testFirstSampleInitialisesThenSmooths() {
        var v = SmoothedValue()
        XCTAssertNil(v.current)
        v.add(100, alpha: 0.5)
        XCTAssertEqual(v.current, 100)
        v.add(200, alpha: 0.5)
        XCTAssertEqual(v.current!, 150, accuracy: 1e-9)
        v.add(.nan, alpha: 0.5)
        v.add(.infinity, alpha: 0.5)
        XCTAssertEqual(v.sampleCount, 2)
        XCTAssertEqual(v.current!, 150, accuracy: 1e-9)
    }

    func testOneOutlierMovesTheAverageOnlyByAlpha() {
        var m = CandidateMetrics()
        let s = SmoothingParameters(alpha: 0.3, jitterAlpha: 0.25, outcomeAlpha: 0.2)
        for i in 0..<20 { m.add(.success(ProbeMeasurement(rttMillis: 100)), at: at(Double(i)), smoothing: s) }
        m.add(.success(ProbeMeasurement(rttMillis: 1100)), at: at(20), smoothing: s)
        XCTAssertEqual(m.rtt.current!, 400, accuracy: 1e-6)
        m.add(.success(ProbeMeasurement(rttMillis: 100)), at: at(21), smoothing: s)
        XCTAssertEqual(m.rtt.current!, 310, accuracy: 1e-6)
    }

    func testJitterIsSmoothedAbsoluteDifferenceAndSkipsOutages() {
        var m = CandidateMetrics()
        let s = SmoothingParameters(alpha: 0.3, jitterAlpha: 0.5, outcomeAlpha: 0.2)
        m.add(.success(ProbeMeasurement(rttMillis: 100)), at: at(0), smoothing: s)
        XCTAssertNil(m.jitter.current, "one sample has no jitter")
        m.add(.success(ProbeMeasurement(rttMillis: 140)), at: at(1), smoothing: s)
        XCTAssertEqual(m.jitter.current!, 40, accuracy: 1e-9)
        m.add(.success(ProbeMeasurement(rttMillis: 120)), at: at(2), smoothing: s)
        XCTAssertEqual(m.jitter.current!, 30, accuracy: 1e-9)
        m.add(.failure(.timeout), at: at(3), smoothing: s)
        m.add(.success(ProbeMeasurement(rttMillis: 900)), at: at(4), smoothing: s)
        XCTAssertEqual(m.jitter.current!, 30, accuracy: 1e-9, "no jitter sample across a failed probe")
        XCTAssertEqual(m.jitter.sampleCount, 2)
    }

    func testInvalidFieldsAreDroppedButOutcomeCounts() {
        var m = CandidateMetrics()
        let s = SmoothingParameters()
        m.add(.success(ProbeMeasurement(rttMillis: -5, connectMillis: .nan, tlsMillis: .infinity, lossFraction: 7, throughputBitsPerSecond: -1)),
              at: at(0), smoothing: s)
        XCTAssertEqual(m.successCount, 1)
        XCTAssertNil(m.rtt.current)
        XCTAssertNil(m.connect.current)
        XCTAssertNil(m.tls.current)
        XCTAssertNil(m.throughput.current)
        XCTAssertEqual(m.loss.current, 1, "loss is clamped to 1")
        XCTAssertEqual(m.failureRate.current, 0)
    }

    func testFailureRateAndCounters() {
        var m = CandidateMetrics()
        let s = SmoothingParameters(outcomeAlpha: 0.5)
        m.add(.success(ProbeMeasurement(rttMillis: 10)), at: at(0), smoothing: s)
        m.add(.failure(.tlsFailure), at: at(1), smoothing: s)
        XCTAssertEqual(m.failureRate.current!, 0.5, accuracy: 1e-9)
        m.add(.failure(.timeout), at: at(2), smoothing: s)
        XCTAssertEqual(m.failureRate.current!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(m.sampleCount, 3)
        XCTAssertEqual(m.failureCount, 2)
        XCTAssertEqual(m.lastFailure, .timeout)
        XCTAssertEqual(m.lastSuccessAt, at(0))
        XCTAssertEqual(m.lastSampleAt, at(2))
    }
}

final class QualityScoreTests: XCTestCase {
    private func metrics(_ samples: [ProbeMeasurement], failures: Int = 0, start: Double = 0) -> CandidateMetrics {
        var m = CandidateMetrics()
        let s = SmoothingParameters()
        var t = start
        for sample in samples {
            m.add(.success(sample), at: at(t), smoothing: s)
            t += 1
        }
        for _ in 0..<failures {
            m.add(.failure(.timeout), at: at(t), smoothing: s)
            t += 1
        }
        return m
    }

    func testUnmeasuredCandidateGetsThePriorWithZeroConfidence() {
        let model = ScoreModel(priorScore: 40)
        let score = model.score(CandidateMetrics(), now: at(0))
        XCTAssertEqual(score.value, 40)
        XCTAssertNil(score.measured)
        XCTAssertEqual(score.confidence, 0)
        XCTAssertTrue(score.components.isEmpty)
    }

    func testSinglePingCannotOutrankAWellMeasuredCandidate() {
        let model = ScoreModel(weights: .latencyFirst)
        let steady = metrics(Array(repeating: ProbeMeasurement(rttMillis: 80), count: 20))
        let lucky = metrics([ProbeMeasurement(rttMillis: 5)], start: 19)
        let a = model.score(steady, now: at(20))
        let b = model.score(lucky, now: at(20))
        XCTAssertGreaterThan(b.measured!, a.measured!, "the raw measurement of the single ping is better")
        XCTAssertGreaterThan(a.value, b.value, "but the decision score is not")
        XCTAssertLessThan(b.confidence, 0.25)
    }

    func testConfidenceGrowsWithSamplesAndDecaysWithAge() {
        let model = ScoreModel(confidenceHalfSamples: 4, freshnessHalfLife: 300)
        var previous = 0.0
        for n in 1...30 {
            let m = metrics(Array(repeating: ProbeMeasurement(rttMillis: 50), count: n))
            let c = model.confidence(of: m, now: m.lastSampleAt!)
            XCTAssertGreaterThan(c, previous)
            XCTAssertLessThan(c, 1)
            previous = c
        }
        let four = metrics(Array(repeating: ProbeMeasurement(rttMillis: 50), count: 4))
        XCTAssertEqual(model.confidence(of: four, now: at(3)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.confidence(of: four, now: at(303)), 0.25, accuracy: 1e-9)
        let stale = model.score(four, now: at(3 + 3000))
        XCTAssertEqual(stale.value, model.priorScore, accuracy: 0.1, "an old measurement fades to the prior")
    }

    func testMissingMetricsDropOutAndWeightsRenormalise() {
        let model = ScoreModel(weights: .balanced)
        let onlyRTT = metrics(Array(repeating: ProbeMeasurement(rttMillis: 20), count: 3))
        let score = model.score(onlyRTT, now: at(2))
        XCTAssertEqual(score.measured!, 100, accuracy: 1e-9)
        XCTAssertEqual(Set(score.components.map(\.metric)), [.latency, .jitter, .reliability])
        XCTAssertFalse(score.components.contains { $0.metric == .throughput }, "throughput is optional")
    }

    func testEveryMetricContributes() {
        let model = ScoreModel(weights: .balanced)
        let good = ProbeMeasurement(rttMillis: 40, connectMillis: 50, tlsMillis: 80, lossFraction: 0, throughputBitsPerSecond: 60_000_000)
        let base = model.score(metrics(Array(repeating: good, count: 10)), now: at(9)).measured!
        XCTAssertEqual(base, 100, accuracy: 1e-9)

        var worse = good; worse.rttMillis = 600
        var lossy = good; lossy.lossFraction = 0.1
        var slowHandshake = good; slowHandshake.tlsMillis = 2500
        var slow = good; slow.throughputBitsPerSecond = 1_000_000
        for variant in [worse, lossy, slowHandshake, slow] {
            let s = model.score(metrics(Array(repeating: variant, count: 10)), now: at(9)).measured!
            XCTAssertLessThan(s, base - 3)
        }
        let failing = model.score(metrics(Array(repeating: good, count: 10), failures: 2), now: at(11)).measured!
        XCTAssertLessThan(failing, base - 3)
        // Jitter: same mean RTT, alternating values.
        let jittery = (0..<10).map { ProbeMeasurement(rttMillis: $0 % 2 == 0 ? 10 : 70, connectMillis: 50, tlsMillis: 80, lossFraction: 0,
                                                 throughputBitsPerSecond: 60_000_000) }
        XCTAssertLessThan(model.score(metrics(jittery), now: at(9)).measured!, base - 3)
    }

    func testStrategyWeightsRankTheSameDataDifferently() {
        let fastButThin = metrics(Array(repeating: ProbeMeasurement(rttMillis: 40, lossFraction: 0.15, throughputBitsPerSecond: 1_000_000), count: 12))
        let slowButFat = metrics(Array(repeating: ProbeMeasurement(rttMillis: 250, lossFraction: 0, throughputBitsPerSecond: 80_000_000), count: 12))
        func value(_ w: ScoreWeights, _ m: CandidateMetrics) -> Double { ScoreModel(weights: w).score(m, now: at(11)).value }
        XCTAssertGreaterThan(value(.latencyFirst, fastButThin), value(.latencyFirst, slowButFat))
        XCTAssertGreaterThan(value(.throughputFirst, slowButFat), value(.throughputFirst, fastButThin))
        XCTAssertGreaterThan(value(.stabilityFirst, slowButFat), value(.stabilityFirst, fastButThin))
    }

    func testScoreStaysInRangeForArbitraryInputs() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        for weights in [ScoreWeights.balanced, .latencyFirst, .throughputFirst, .stabilityFirst] {
            let model = ScoreModel(weights: weights)
            for _ in 0..<300 {
                var m = CandidateMetrics()
                var t = 0.0
                for _ in 0..<(1 + rng.int(30)) {
                    t += rng.unit() * 100
                    if rng.chance(0.3) {
                        m.add(.failure(.timeout), at: at(t), smoothing: model.smoothing)
                    } else {
                        m.add(.success(ProbeMeasurement(
                            rttMillis: rng.chance(0.1) ? nil : rng.unit() * 5000,
                            connectMillis: rng.chance(0.5) ? nil : rng.unit() * 10_000,
                            tlsMillis: rng.chance(0.5) ? nil : rng.unit() * 10_000,
                            lossFraction: rng.chance(0.5) ? nil : rng.unit() * 2,
                            throughputBitsPerSecond: rng.chance(0.5) ? nil : rng.unit() * 1e9
                        )), at: at(t), smoothing: model.smoothing)
                    }
                }
                let score = model.score(m, now: at(t + rng.unit() * 1000))
                XCTAssertTrue(score.value.isFinite)
                XCTAssertGreaterThanOrEqual(score.value, 0)
                XCTAssertLessThanOrEqual(score.value, 100)
                XCTAssertGreaterThanOrEqual(score.confidence, 0)
                XCTAssertLessThanOrEqual(score.confidence, 1)
                for c in score.components {
                    XCTAssertGreaterThanOrEqual(c.quality, 0)
                    XCTAssertLessThanOrEqual(c.quality, 1)
                }
            }
        }
    }
}

final class CircuitBreakerTests: XCTestCase {
    private let policy = BreakerPolicy(
        consecutiveFailures: 3, failureRateThreshold: nil, openDuration: 30, backoffMultiplier: 2,
        maximumOpenDuration: 100, halfOpenSuccesses: 2, tripMemory: 500
    )

    private func feed(_ b: inout CircuitBreaker, _ success: Bool, _ t: Double, policy: BreakerPolicy? = nil,
                      rate: Double? = nil, samples: Int = 0) {
        b.record(success: success, at: at(t), failureRate: rate, sampleCount: samples, policy: policy ?? self.policy)
    }

    func testTripsOnlyOnConsecutiveFailures() {
        var b = CircuitBreaker()
        feed(&b, false, 0); feed(&b, false, 1); feed(&b, true, 2)
        feed(&b, false, 3); feed(&b, false, 4)
        XCTAssertEqual(b.state(at: at(4)), .closed)
        feed(&b, false, 5)
        XCTAssertEqual(b.state(at: at(5)), .open(until: at(35)))
    }

    func testOpenIgnoresResultsThenBecomesHalfOpen() {
        var b = CircuitBreaker()
        for t in 0..<3 { feed(&b, false, Double(t)) }
        feed(&b, true, 10); feed(&b, true, 11); feed(&b, false, 12)
        XCTAssertEqual(b.state(at: at(31.9)), .open(until: at(32)), "successes do not shorten, failures do not extend")
        XCTAssertEqual(b.state(at: at(32)), .halfOpen(successes: 0))
    }

    func testHalfOpenClosesAfterEnoughSuccesses() {
        var b = CircuitBreaker()
        for t in 0..<3 { feed(&b, false, Double(t)) }
        feed(&b, true, 40)
        XCTAssertEqual(b.state(at: at(40)), .halfOpen(successes: 1))
        feed(&b, true, 41)
        XCTAssertEqual(b.state(at: at(41)), .closed)
    }

    func testHalfOpenFailureReopensWithBackoffUpToTheCap() {
        var b = CircuitBreaker()
        for t in 0..<3 { feed(&b, false, Double(t)) }       // open until 32
        feed(&b, false, 40)                                 // half-open probe fails: 60 s
        XCTAssertEqual(b.state(at: at(40)), .open(until: at(100)))
        feed(&b, true, 100); feed(&b, false, 101)           // 120 s, capped at 100
        XCTAssertEqual(b.state(at: at(101)), .open(until: at(201)))
        XCTAssertEqual(b.tripCount, 3)
        feed(&b, false, 300)
        XCTAssertEqual(b.state(at: at(300)), .open(until: at(400)), "stays at the cap")
    }

    func testTripMemoryExpiresAfterAStablePeriod() {
        var b = CircuitBreaker()
        for t in 0..<3 { feed(&b, false, Double(t)) }
        feed(&b, true, 40); feed(&b, true, 41)              // closed at 41
        feed(&b, true, 100)
        XCTAssertEqual(b.tripCount, 1)
        feed(&b, true, 541)
        XCTAssertEqual(b.tripCount, 0)
        for t in 0..<3 { feed(&b, false, 600 + Double(t)) }
        XCTAssertEqual(b.state(at: at(602)), .open(until: at(632)), "back to the base duration")
    }

    func testFailureRateRuleCatchesInterleavedFailures() {
        let p = BreakerPolicy(consecutiveFailures: 5, failureRateThreshold: 0.5, failureRateMinimumSamples: 8)
        var b = CircuitBreaker()
        feed(&b, false, 0, policy: p, rate: 0.9, samples: 7)
        XCTAssertEqual(b.state(at: at(0)), .closed, "not enough samples for the rate rule")
        feed(&b, true, 1, policy: p, rate: 0.7, samples: 8)
        feed(&b, false, 2, policy: p, rate: 0.4, samples: 9)
        XCTAssertEqual(b.state(at: at(2)), .closed, "rate below threshold")
        feed(&b, true, 3, policy: p, rate: 0.6, samples: 10)
        XCTAssertEqual(b.state(at: at(3)), .closed, "a success never trips")
        feed(&b, false, 4, policy: p, rate: 0.6, samples: 11)
        XCTAssertEqual(b.state(at: at(4)), .open(until: at(34)))
    }
}
