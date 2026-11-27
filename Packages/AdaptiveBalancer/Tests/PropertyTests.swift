import XCTest
@testable import AdaptiveBalancer

/// Property-style tests: a seeded generator drives the balancer through
/// thousands of random steps and the invariants are checked at every step.
final class PropertyTests: XCTestCase {
    struct Step {
        let time: Double
        let decision: Decision
        /// State before the decision.
        let previous: Candidate?
        let previousSince: Instant?
        let wasInProbation: Bool
        let closedInCurrentEngine: Int
        let policy: SelectionPolicy
    }

    static let topology: [Candidate] = {
        var list: [Candidate] = []
        for engine in ["x", "s"] {
            for transport in ["t1", "t2"] {
                for server in ["a", "b", "c"] { list.append(cand(engine, transport, server)) }
            }
        }
        return list
    }()

    enum Mode {
        /// Latency, jitter, loss and throughput vary wildly; nothing ever fails.
        case latencyOnly
        /// Servers and whole engines also fail and recover.
        case failures
    }

    /// Runs a random scenario. Deterministic for a given seed.
    func simulate(
        seed: UInt64,
        steps: Int,
        mode: Mode,
        policies: PolicySet = .standard(),
        network: NetworkClass = .wifi,
        networkChanges: Bool = false
    ) -> [Step] {
        var rng = SeededGenerator(seed: seed)
        let candidates = Self.topology
        var bal = AdaptiveBalancer(candidates: candidates.map { CandidateDescriptor($0, weight: 1, priority: 0) },
                                   policies: policies, network: network)
        var baseRTT: [Candidate: Double] = [:]
        var failProbability: [Candidate: Double] = [:]
        var t = 0.0
        var result: [Step] = []
        result.reserveCapacity(steps)

        for step in 0..<steps {
            if step % 40 == 0 {
                // New regime.
                let deadEngine: String? = (mode == .failures && rng.chance(0.35)) ? (rng.chance(0.5) ? "x" : "s") : nil
                for c in candidates {
                    baseRTT[c] = 15 + rng.unit() * 700
                    switch mode {
                    case .latencyOnly:
                        failProbability[c] = 0
                    case .failures:
                        if c.engine.rawValue == deadEngine {
                            failProbability[c] = 1
                        } else {
                            failProbability[c] = [0, 0, 0, 0.1, 0.5, 1][rng.int(6)]
                        }
                    }
                }
            }
            t += 1 + rng.unit() * 9
            if networkChanges, rng.chance(0.01) {
                bal.networkChanged(to: NetworkClass.allCases[rng.int(NetworkClass.allCases.count)], now: at(t))
            }
            for _ in 0..<4 {
                let c = candidates[rng.int(candidates.count)]
                if rng.chance(failProbability[c] ?? 0) {
                    bal.record(.failure(c, at: at(t), FailureKind.allCases[rng.int(FailureKind.allCases.count)]))
                } else {
                    bal.record(.success(c, at: at(t), ProbeMeasurement(
                        rttMillis: (baseRTT[c] ?? 100) * (0.3 + rng.unit() * 3),
                        connectMillis: rng.chance(0.5) ? rng.unit() * 4000 : nil,
                        tlsMillis: rng.chance(0.5) ? rng.unit() * 4000 : nil,
                        lossFraction: rng.chance(0.5) ? rng.unit() : nil,
                        throughputBitsPerSecond: rng.chance(0.3) ? rng.unit() * 2e8 : nil
                    )))
                }
            }
            let previous = bal.current
            let closed = previous.map { cur in
                candidates.filter { $0.engine == cur.engine && bal.health(of: $0, now: at(t)).isClosed }.count
            } ?? 0
            let since = bal.currentSince
            let probation = bal.isInProbation
            let policy = bal.policy
            let decision = bal.decide(now: at(t))
            result.append(Step(time: t, decision: decision, previous: previous, previousSince: since,
                               wasInProbation: probation, closedInCurrentEngine: closed, policy: policy))
        }
        return result
    }

    private func maxInWindow(_ times: [Double], window: Double) -> Int {
        var best = 0
        var start = 0
        for end in times.indices {
            while times[end] - times[start] >= window { start += 1 }
            best = max(best, end - start + 1)
        }
        return best
    }

    // MARK: Properties

    func testSameSeedGivesSameDecisions() {
        let first = simulate(seed: 7, steps: 1500, mode: .failures, networkChanges: true)
        let second = simulate(seed: 7, steps: 1500, mode: .failures, networkChanges: true)
        XCTAssertEqual(first.map(\.decision), second.map(\.decision))
        let different = simulate(seed: 8, steps: 1500, mode: .failures, networkChanges: true)
        XCTAssertNotEqual(first.map(\.decision), different.map(\.decision))
    }

    func testLatencyOnlyInputNeverRestartsTheTunnel() {
        var inEngineChanges = 0
        for seed in 1...12 {
            for network in [NetworkClass.wifi, .cellular] {
                let steps = simulate(seed: UInt64(seed), steps: 2500, mode: .latencyOnly, network: network, networkChanges: seed % 2 == 0)
                let engines = Set(steps.compactMap { $0.decision.change?.to.engine })
                XCTAssertEqual(engines.count, 1, "seed \(seed): the engine changed without a single failure")
                for step in steps {
                    XCTAssertFalse(step.decision.requiresTunnelRestart, "seed \(seed) at t=\(step.time)")
                    if let change = step.decision.change, change.level != nil { inEngineChanges += 1 }
                }
            }
        }
        XCTAssertGreaterThan(inEngineChanges, 20, "the scenario must exercise in-engine switching, or the property is vacuous")
    }

    func testOscillationIsBoundedByTheRateLimits() {
        var totalInEngine = 0
        var totalEngine = 0
        var rollbacks = 0
        for seed in 100...124 {
            for network in [NetworkClass.wifi, .cellular] {
                let steps = simulate(seed: UInt64(seed), steps: 2500, mode: .failures, network: network)
                let policy = steps[0].policy
                let inEngine = steps.filter { $0.decision.change?.level == .server || $0.decision.change?.level == .transport }.map(\.time)
                let engine = steps.filter { $0.decision.change?.level == .engine }.map(\.time)
                totalInEngine += inEngine.count
                totalEngine += engine.count
                rollbacks += steps.filter { $0.decision.change?.kind == .rollback }.count

                XCTAssertLessThanOrEqual(maxInWindow(inEngine, window: policy.rateLimit.window),
                                         policy.rateLimit.maximumSwitches + 1, "seed \(seed) \(network)")
                XCTAssertLessThanOrEqual(maxInWindow(engine, window: policy.engineSwitch.rateLimit.window),
                                         policy.engineSwitch.rateLimit.maximumSwitches + 1, "seed \(seed) \(network)")
                // Without rollbacks the bound is the limit itself.
                let planned = steps.filter {
                    guard let c = $0.decision.change, c.kind != .rollback else { return false }
                    return c.level == .server || c.level == .transport
                }.map(\.time)
                XCTAssertLessThanOrEqual(maxInWindow(planned, window: policy.rateLimit.window), policy.rateLimit.maximumSwitches)
                // Two non-rollback restarts are never closer than the minimum interval.
                let restarts = steps.filter { $0.decision.change?.level == .engine && $0.decision.change?.kind != .rollback }.map(\.time)
                for (earlier, later) in zip(restarts, restarts.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(later - earlier, policy.engineSwitch.minimumInterval)
                }
            }
        }
        XCTAssertGreaterThan(totalInEngine, 100, "vacuous otherwise")
        XCTAssertGreaterThan(totalEngine, 10, "vacuous otherwise")
        XCTAssertGreaterThan(rollbacks, 5, "vacuous otherwise")
    }

    func testEngineIsLeftOnlyWhenNoInEngineBreakerIsClosed() {
        var restarts = 0
        for seed in 200...219 {
            let steps = simulate(seed: UInt64(seed), steps: 2500, mode: .failures, networkChanges: seed % 2 == 0)
            for step in steps {
                guard let change = step.decision.change, change.level == .engine else { continue }
                restarts += 1
                XCTAssertTrue(step.decision.requiresTunnelRestart)
                if change.kind == .rollback {
                    XCTAssertTrue(step.wasInProbation, "a rollback only undoes a change that was on probation")
                } else {
                    XCTAssertEqual(step.closedInCurrentEngine, 0,
                                   "seed \(seed) t=\(step.time): engine left while \(step.closedInCurrentEngine) in-engine candidates were usable")
                    XCTAssertEqual(change.kind, .failover, "an engine switch is never an 'improvement'")
                }
            }
        }
        XCTAssertGreaterThan(restarts, 5, "vacuous otherwise")
    }

    func testVoluntarySwitchesRespectDwellProbationAndCooldown() {
        var improvements = 0
        for seed in 300...319 {
            let steps = simulate(seed: UInt64(seed), steps: 2500, mode: seed % 2 == 0 ? .failures : .latencyOnly)
            var leftAt: [Candidate: Double] = [:]
            for step in steps {
                guard let change = step.decision.change else { continue }
                if change.kind == .improvement {
                    improvements += 1
                    let level = change.level == .server ? step.policy.server : step.policy.transport
                    XCTAssertNotEqual(change.level, .engine)
                    XCTAssertFalse(step.wasInProbation, "no voluntary switch during probation")
                    XCTAssertGreaterThanOrEqual(step.time - step.previousSince!.seconds, level.minimumDwell)
                    if let left = leftAt[change.to] {
                        XCTAssertGreaterThanOrEqual(step.time - left, step.policy.returnCooldown, "seed \(seed): ping-pong")
                    }
                }
                if let from = change.from { leftAt[from] = step.time }
            }
        }
        XCTAssertGreaterThan(improvements, 30, "vacuous otherwise")
    }

    func testEveryDecisionIsExplained() {
        for seed in 400...405 {
            let steps = simulate(seed: UInt64(seed), steps: 1500, mode: .failures, networkChanges: true)
            for step in steps {
                let e = step.decision.explanation
                XCTAssertFalse(e.summary.isEmpty)
                XCTAssertEqual(e.candidates.count, Self.topology.count)
                XCTAssertEqual(e.at, at(step.time))
                switch step.decision.action {
                case .apply(let change):
                    XCTAssertEqual(e.chosen?.candidate, change.to)
                    XCTAssertEqual(e.current?.candidate, change.to, "the decision is committed")
                    XCTAssertEqual(change.from, step.previous)
                    XCTAssertEqual(change.level, step.previous.flatMap { SwitchLevel.between($0, change.to) })
                    XCTAssertTrue(e.summary.contains(change.to.description))
                case .keep(let kept):
                    XCTAssertEqual(kept, step.previous)
                    if e.reason == .currentRetained || e.reason == .noAlternative {
                        XCTAssertEqual(Set(e.blockers.map(\.level)), [.server, .transport, .engine],
                                       "each level says why it did nothing")
                    }
                }
                for a in e.candidates {
                    XCTAssertTrue(a.score.value >= 0 && a.score.value <= 100)
                }
            }
        }
    }

    func testAllStrategiesKeepTheInvariants() {
        for strategy in SelectionStrategy.allCases {
            let steps = simulate(seed: 500, steps: 2000, mode: .failures, policies: .standard(strategy: strategy))
            let policy = steps[0].policy
            XCTAssertEqual(policy.strategy, strategy)
            let inEngine = steps.filter { $0.decision.change?.level == .server || $0.decision.change?.level == .transport }.map(\.time)
            XCTAssertLessThanOrEqual(maxInWindow(inEngine, window: policy.rateLimit.window), policy.rateLimit.maximumSwitches + 1, "\(strategy)")
            for step in steps {
                guard let change = step.decision.change, change.level == .engine, change.kind != .rollback else { continue }
                XCTAssertEqual(step.closedInCurrentEngine, 0, "\(strategy)")
            }
            if strategy == .failover {
                XCTAssertFalse(steps.contains { $0.decision.change?.kind == .improvement }, "failover never switches voluntarily")
            }
        }
    }

    // MARK: Flapping inputs

    private let a = cand("x", "t1", "a")
    private let b = cand("x", "t1", "b")

    /// Two servers whose latencies swap every `period` seconds.
    private func flap(period: Double, low: Double, high: Double, duration: Double, sampleEvery: Double) -> (switches: [Double], flips: Int) {
        var sim = Sim([a, b])
        var switches: [Double] = []
        var flips = 0
        var lastPhase = -1
        while sim.t < duration {
            let phase = Int(sim.t / period)
            if phase != lastPhase { flips += 1; lastPhase = phase }
            let aIsFast = phase % 2 == 0
            sim.ok(a, rtt: aIsFast ? low : high)
            sim.ok(b, rtt: aIsFast ? high : low)
            if let change = sim.decide().change, change.level != nil { switches.append(sim.t) }
            sim.advance(sampleEvery)
        }
        return (switches, flips)
    }

    func testFastFlappingBelowTheSmoothingHorizonCausesNoSwitches() {
        // The two servers swap on every sample: the averages are equal.
        let result = flap(period: 5, low: 50, high: 300, duration: 3600, sampleEvery: 5)
        XCTAssertEqual(result.flips, 720)
        XCTAssertEqual(result.switches, [])
    }

    func testSmallAmplitudeFlappingCausesNoSwitches() {
        let result = flap(period: 60, low: 50, high: 110, duration: 3600, sampleEvery: 5)
        XCTAssertEqual(result.switches, [], "the difference never reaches the hysteresis margin")
    }

    func testLargeSlowFlappingIsFollowedButBounded() {
        let policy = SelectionPolicy.wifiDefault()
        let result = flap(period: 90, low: 40, high: 700, duration: 7200, sampleEvery: 5)
        XCTAssertEqual(result.flips, 80)
        XCTAssertGreaterThan(result.switches.count, 0, "a real, lasting difference is followed")
        XCTAssertLessThan(result.switches.count, result.flips, "but not every flip")
        XCTAssertLessThanOrEqual(maxInWindow(result.switches, window: policy.rateLimit.window), policy.rateLimit.maximumSwitches)
        for (earlier, later) in zip(result.switches, result.switches.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, policy.server.minimumDwell)
        }
        // Returning to a server needs the cooldown: at most one switch per cooldown period overall here.
        XCTAssertLessThanOrEqual(Double(result.switches.count), 7200 / policy.returnCooldown + 1)
    }

    func testFlappingFailuresDoNotCauseASwitchingStorm() {
        // The current server fails three times, then works, in a loop; the
        // alternative does the same, half a period later.
        var sim = Sim([a, b])
        let policy = sim.bal.policy
        var changes: [Double] = []
        for step in 0..<2000 {
            sim.advance(3)
            let aFails = (step / 3) % 2 == 0
            if aFails { sim.fail(a) } else { sim.ok(a) }
            if aFails { sim.ok(b) } else { sim.fail(b) }
            if let change = sim.decide().change, change.level != nil { changes.append(sim.t) }
        }
        XCTAssertLessThanOrEqual(maxInWindow(changes, window: policy.rateLimit.window), policy.rateLimit.maximumSwitches + 1)
        XCTAssertLessThanOrEqual(changes.count, Int(6000 / policy.rateLimit.window + 1) * (policy.rateLimit.maximumSwitches + 1))
    }
}
