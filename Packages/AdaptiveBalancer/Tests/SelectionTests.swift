import XCTest
@testable import AdaptiveBalancer

/// Levels (a) and (b): selection inside one engine.
final class SelectionTests: XCTestCase {
    private let a = cand("x", "t1", "a")
    private let b = cand("x", "t1", "b")
    private let c = cand("x", "t1", "c")
    private let d = cand("x", "t1", "d")
    private let other = cand("x", "t2", "a")

    // MARK: Initial selection

    func testNoCandidates() {
        var sim = Sim([Candidate]())
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(nil))
        XCTAssertEqual(decision.explanation.reason, .noCandidates)
        XCTAssertFalse(decision.explanation.summary.isEmpty)
    }

    func testInitialSelectionIsDeterministicAndStartsProbation() {
        var sim = Sim([b, a, c])
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: nil, to: a, level: nil, kind: .initialSelection))
        XCTAssertFalse(decision.requiresTunnelRestart)
        XCTAssertTrue(sim.bal.isInProbation)
        XCTAssertNil(sim.bal.lastKnownGood)
        XCTAssertEqual(sim.decide().explanation.reason, .inProbation)
    }

    func testInitialSelectionHonoursPreferredEngineOverScore() {
        let s = cand("s", "t1", "a")
        var sim = Sim([a, s], policies: .standard(preferredEngine: "x"))
        sim.ok(s, rtt: 20, count: 20)
        XCTAssertEqual(sim.decide().change?.to, a, "engine choice is not a latency race")

        var free = Sim([a, s])
        free.ok(s, rtt: 20, count: 20)
        XCTAssertEqual(free.decide().change?.to, s)
    }

    func testInitialSelectionSkipsOpenBreakers() {
        var sim = Sim([a, b])
        sim.fail(a, count: 3)
        XCTAssertEqual(sim.decide().change?.to, b)

        var dead = Sim([a])
        dead.fail(a, count: 3)
        let decision = dead.decide()
        XCTAssertEqual(decision.action, .keep(nil))
        XCTAssertEqual(decision.explanation.reason, .noUsableCandidate)
    }

    // MARK: Hysteresis, dwell, cooldown, rate limit

    func testSmallAdvantageDoesNotSwitch() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        for _ in 0..<40 {
            sim.advance(5)
            sim.ok(a, rtt: 100)
            sim.ok(b, rtt: 60)
            let decision = sim.decide()
            XCTAssertEqual(decision.action, .keep(a))
            XCTAssertEqual(decision.explanation.reason, .currentRetained)
        }
        XCTAssertEqual(sim.decide().blocker(.server), .insufficientMargin)
        XCTAssertGreaterThan(sim.bal.score(of: b, now: sim.now).value, sim.bal.score(of: a, now: sim.now).value)
    }

    func testSinglePingNeverCausesASwitch() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        sim.advance(60)
        sim.ok(a, rtt: 700, count: 10)
        sim.ok(b, rtt: 1)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(a))
        XCTAssertEqual(decision.blocker(.server), .targetNotProven)
        sim.ok(b, rtt: 1)
        XCTAssertEqual(sim.decide().action, .keep(a), "two pings are not enough either")
    }

    func testDwellBlocksThenAllowsAnImprovement() {
        var sim = Sim([a, b])
        sim.settle(on: a)                       // selected at t=0, confirmed at t=21
        sim.ok(a, rtt: 600, count: 10)
        sim.ok(b, rtt: 40, count: 10)
        sim.advance(1)
        let early = sim.decide()
        XCTAssertEqual(early.action, .keep(a))
        XCTAssertEqual(early.blocker(.server), .dwellNotElapsed)

        sim.advance(9)                          // t=31 > dwell 30
        sim.ok(a, rtt: 600)
        sim.ok(b, rtt: 40)
        let late = sim.decide()
        XCTAssertEqual(late.change, Change(from: a, to: b, level: .server, kind: .improvement))
        XCTAssertEqual(late.explanation.reason, .improvement)
        XCTAssertEqual(late.explanation.chosen?.candidate, b)
        XCTAssertFalse(late.requiresTunnelRestart)
        XCTAssertEqual(sim.bal.currentSince, sim.now)
    }

    func testReturnCooldownPreventsPingPong() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        sim.ok(a, rtt: 600, count: 10)
        sim.ok(b, rtt: 40, count: 10)
        sim.advance(10)
        sim.ok(a, rtt: 600); sim.ok(b, rtt: 40)
        XCTAssertEqual(sim.decide().change?.to, b)
        let switchedAt = sim.t

        // b passes probation, then the picture inverts.
        sim.ok(b, rtt: 40, count: 2)
        sim.advance(21)
        sim.ok(b, rtt: 40)
        XCTAssertEqual(sim.decide().explanation.reason, .probationPassed)
        sim.ok(b, rtt: 600, count: 10)
        sim.ok(a, rtt: 40, count: 10)
        sim.advance(30)
        sim.ok(b, rtt: 600); sim.ok(a, rtt: 40)
        let blocked = sim.decide()
        XCTAssertEqual(blocked.action, .keep(b))
        XCTAssertEqual(blocked.blocker(.server), .targetCoolingDown)
        XCTAssertTrue(blocked.explanation.candidates.first { $0.candidate == a }!.isCoolingDown)

        sim.t = switchedAt + 121
        sim.ok(b, rtt: 600); sim.ok(a, rtt: 40)
        XCTAssertEqual(sim.decide().change, Change(from: b, to: a, level: .server, kind: .improvement))
    }

    func testFailoverBypassesDwellAndMargin() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        sim.fail(a, count: 3)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: a, to: b, level: .server, kind: .failover))
        XCTAssertEqual(decision.explanation.reason, .failover)
    }

    func testRateLimitCapsForcedFailovers() {
        var policy = SelectionPolicy.wifiDefault()
        policy.rateLimit = RateLimit(maximumSwitches: 2, window: 600)
        var sim = Sim([a, b, c, d], policies: uniform(policy))
        sim.settle(on: a)
        sim.fail(a, count: 3)
        XCTAssertEqual(sim.decide().change?.to, b)
        sim.advance(1)
        sim.fail(b, count: 3)
        XCTAssertEqual(sim.decide().change?.to, c, "a is still open, so no rollback: next server")
        sim.advance(1)
        sim.fail(c, count: 3)
        let blocked = sim.decide()
        XCTAssertEqual(blocked.action, .keep(c))
        XCTAssertEqual(blocked.explanation.reason, .noAlternative)
        XCTAssertEqual(blocked.blocker(.server), .rateLimited)
        XCTAssertEqual(blocked.blocker(.engine), .inEngineSatisfiable, "d is still usable in this engine")

        sim.advance(600)
        XCTAssertEqual(sim.decide().change?.to, d, "the window has passed")
    }

    // MARK: Levels

    func testServerLevelIsEvaluatedBeforeTransportLevel() {
        var sim = Sim([a, b, other])
        sim.settle(on: a)
        sim.advance(30)
        sim.ok(a, rtt: 700, count: 12)
        sim.ok(b, rtt: 60, count: 12)
        sim.ok(other, rtt: 20, count: 12, throughput: 90_000_000)
        let decision = sim.decide()
        XCTAssertGreaterThan(decision.explanation.candidates.first { $0.candidate == other }!.utility,
                             decision.explanation.candidates.first { $0.candidate == b }!.utility)
        XCTAssertEqual(decision.change, Change(from: a, to: b, level: .server, kind: .improvement))
    }

    /// The same measured advantage is enough to change a server and not
    /// enough to change the transport.
    func testTransportChangeNeedsALargerMargin() {
        let sameTransport = runPair(current: a, other: b, network: .wifi)
        XCTAssertEqual(sameTransport.bal.current, b)

        let otherTransport = runPair(current: a, other: other, network: .wifi)
        XCTAssertEqual(otherTransport.bal.current, a)
        XCTAssertEqual(otherTransport.last.blocker(.transport), .insufficientMargin)
        XCTAssertEqual(otherTransport.last.blocker(.server), .noAvailableCandidate)
    }

    func testTransportFailoverWhenNoServerIsLeft() {
        var sim = Sim([a, other])
        sim.settle(on: a)
        sim.fail(a, count: 3)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: a, to: other, level: .transport, kind: .failover))
        XCTAssertEqual(decision.blocker(.server), .noAvailableCandidate)
        XCTAssertFalse(decision.requiresTunnelRestart)
    }

    // MARK: Wi-Fi and cellular

    func testCellularPolicyIsMoreConservativeThanWiFi() {
        let wifi = runPair(current: a, other: b, network: .wifi)
        let cellular = runPair(current: a, other: b, network: .cellular)
        XCTAssertEqual(wifi.bal.current, b)
        XCTAssertEqual(cellular.bal.current, a)
        XCTAssertEqual(cellular.last.blocker(.server), .insufficientMargin)
        XCTAssertEqual(runPair(current: a, other: b, network: .wired).bal.current, b, "wired uses the Wi-Fi policy")
        XCTAssertEqual(runPair(current: a, other: b, network: .unknown).bal.current, a, "unknown uses the cellular policy")
    }

    func testPoliciesDifferWhereItMatters() {
        let wifi = SelectionPolicy.wifiDefault()
        let cell = SelectionPolicy.cellularDefault()
        XCTAssertGreaterThan(cell.server.hysteresisMargin, wifi.server.hysteresisMargin)
        XCTAssertGreaterThan(cell.server.minimumDwell, wifi.server.minimumDwell)
        XCTAssertGreaterThan(cell.returnCooldown, wifi.returnCooldown)
        XCTAssertGreaterThan(cell.breaker.consecutiveFailures, wifi.breaker.consecutiveFailures)
        XCTAssertGreaterThan(cell.engineSwitch.cost.totalPenalty, wifi.engineSwitch.cost.totalPenalty)
        XCTAssertGreaterThan(cell.engineSwitch.requiredOutage, wifi.engineSwitch.requiredOutage)
        XCTAssertLessThan(cell.engineSwitch.rateLimit.maximumSwitches, wifi.engineSwitch.rateLimit.maximumSwitches)
        for policy in [wifi, cell] {
            XCTAssertGreaterThan(policy.transport.hysteresisMargin, policy.server.hysteresisMargin)
            XCTAssertGreaterThan(policy.transport.minimumDwell, policy.server.minimumDwell)
        }
    }

    func testMeasurementsAndBreakersAreKeptPerNetworkClass() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        sim.ok(b, rtt: 30, count: 10)
        sim.fail(a, count: 3)
        XCTAssertFalse(sim.bal.health(of: a, now: sim.now).isClosed)

        sim.bal.networkChanged(to: .cellular, now: sim.now)
        XCTAssertTrue(sim.bal.health(of: a, now: sim.now).isClosed, "a Wi-Fi failure says nothing about cellular")
        XCTAssertNil(sim.bal.metrics(of: b))
        XCTAssertEqual(sim.bal.score(of: b, now: sim.now).confidence, 0)
        XCTAssertNil(sim.bal.lastKnownGood)
        XCTAssertEqual(sim.decide().action, .keep(a))

        sim.bal.networkChanged(to: .wifi, now: sim.now)
        XCTAssertFalse(sim.bal.health(of: a, now: sim.now).isClosed)
        XCTAssertEqual(sim.bal.metrics(of: b)?.successCount, 10)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, a)
    }

    // MARK: Strategies

    func testLowestLatencyAndHighestThroughputChooseDifferently() {
        func pick(_ strategy: SelectionStrategy) -> Candidate? {
            var sim = Sim([a, b], policies: .standard(strategy: strategy))
            sim.ok(a, rtt: 40, count: 12, loss: 0.15, throughput: 1_000_000)
            sim.ok(b, rtt: 250, count: 12, loss: 0, throughput: 80_000_000)
            return sim.decide().change?.to
        }
        XCTAssertEqual(pick(.lowestLatency), a)
        XCTAssertEqual(pick(.highestThroughput), b)
        XCTAssertEqual(pick(.maxStability), b)
        XCTAssertEqual(pick(.balanced), b)
    }

    func testWeightedStrategyBiasesByWeight() {
        func pick(weightA: Double, weightB: Double) -> Candidate? {
            var sim = Sim([CandidateDescriptor(a, weight: weightA), CandidateDescriptor(b, weight: weightB)],
                          policies: .standard(strategy: .weighted))
            sim.ok(a, rtt: 60, count: 12)
            sim.ok(b, rtt: 120, count: 12)
            return sim.decide().change?.to
        }
        XCTAssertEqual(pick(weightA: 1, weightB: 1), a)
        XCTAssertEqual(pick(weightA: 1, weightB: 3), b)
        XCTAssertEqual(pick(weightA: 1, weightB: -5), a, "a non-positive weight is zero")
    }

    func testFailoverStrategyIsSticky() {
        var sim = Sim([CandidateDescriptor(a, priority: 0), CandidateDescriptor(b, priority: 1)],
                      policies: .standard(strategy: .failover))
        sim.ok(b, rtt: 20, count: 20)
        sim.settle(on: a)                       // priority first, whatever the score
        sim.fail(a, count: 3)
        XCTAssertEqual(sim.decide().change, Change(from: a, to: b, level: .server, kind: .failover))
        recover(&sim, a, keepAlive: b)
        sim.advance(600)
        sim.ok(a, rtt: 20, count: 5); sim.ok(b, rtt: 300)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(b))
        XCTAssertEqual(decision.blocker(.server), .stickyStrategy)
    }

    func testManualPriorityReturnsToTheTopCandidate() {
        var sim = Sim([CandidateDescriptor(a, priority: 0), CandidateDescriptor(b, priority: 1)],
                      policies: .standard(strategy: .manualPriority))
        sim.ok(b, rtt: 20, count: 20)
        sim.settle(on: a)
        sim.fail(a, count: 3)
        let leftAt = sim.t
        XCTAssertEqual(sim.decide().change?.to, b)
        recover(&sim, a, keepAlive: b)
        XCTAssertEqual(sim.decide().blocker(.server), .targetCoolingDown)
        sim.t = leftAt + 121
        sim.ok(b, rtt: 20)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: b, to: a, level: .server, kind: .improvement))
        XCTAssertLessThan(sim.bal.score(of: a, now: sim.now).value, sim.bal.score(of: b, now: sim.now).value,
                          "priority, not score, decided")
    }

    // MARK: Candidate set, probe plan, explanations

    func testRemovingTheCurrentCandidateForcesReselection() {
        var sim = Sim([a, b])
        sim.settle(on: a)
        sim.bal.updateCandidates([CandidateDescriptor(b)], now: sim.now)
        XCTAssertNil(sim.bal.lastKnownGood)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: a, to: b, level: .server, kind: .failover))
        XCTAssertEqual(sim.bal.candidates, [b])
    }

    func testSamplesForUnknownCandidatesAreIgnored() {
        var sim = Sim([a])
        sim.ok(b, count: 5)
        XCTAssertNil(sim.bal.metrics(of: b))
        XCTAssertEqual(sim.bal.assessments(now: sim.now).count, 1)
    }

    func testProbePlan() {
        var sim = Sim([a, b, c])
        XCTAssertEqual(sim.bal.probePlan(now: sim.now).map(\.reason), [.unmeasured, .unmeasured, .unmeasured])
        sim.ok(a, count: 5); sim.ok(b, count: 5)
        sim.decide()
        XCTAssertEqual(sim.bal.probePlan(now: sim.now), [
            ProbeRequest(candidate: a, reason: .probation), ProbeRequest(candidate: c, reason: .unmeasured),
        ])
        sim.fail(b, count: 3)
        sim.advance(29)
        XCTAssertFalse(sim.bal.probePlan(now: sim.now).contains { $0.candidate == b }, "an open breaker is not probed")
        sim.advance(1)
        XCTAssertTrue(sim.bal.probePlan(now: sim.now).contains(ProbeRequest(candidate: b, reason: .recovery)))
        sim.ok(a, count: 2)
        sim.decide()
        sim.advance(200)
        XCTAssertTrue(sim.bal.probePlan(now: sim.now).contains(ProbeRequest(candidate: a, reason: .stale)))
    }

    func testExplanationCarriesNumbersAndSurvivesCoding() throws {
        var sim = Sim([a, b, other])
        sim.settle(on: a)
        sim.ok(b, rtt: 60, count: 6)
        let decision = sim.decide()
        let explanation = decision.explanation
        XCTAssertEqual(explanation.network, .wifi)
        XCTAssertEqual(explanation.strategy, .balanced)
        XCTAssertEqual(explanation.at, sim.now)
        XCTAssertEqual(explanation.current?.candidate, a)
        XCTAssertEqual(explanation.candidates.map(\.candidate), [a, b, other])
        XCTAssertEqual(Set(explanation.blockers.map(\.level)), [.server, .transport, .engine])
        XCTAssertTrue(explanation.blockers.allSatisfy { !$0.detail.isEmpty })
        XCTAssertFalse(explanation.current!.score.components.isEmpty)
        XCTAssertTrue(explanation.summary.contains(a.description))

        let data = try JSONEncoder().encode(decision)
        XCTAssertEqual(try JSONDecoder().decode(Decision.self, from: data).action, decision.action)
        XCTAssertEqual(try JSONDecoder().decode(Decision.self, from: data).explanation.blockers, explanation.blockers)
    }

    // MARK: Helpers

    /// Closes `candidate`'s breaker with half-open probes.
    private func recover(_ sim: inout Sim, _ candidate: Candidate, keepAlive: Candidate) {
        sim.ok(keepAlive, count: 2)
        sim.advance(31)
        sim.ok(keepAlive)
        XCTAssertEqual(sim.decide().explanation.reason, .probationPassed)
        XCTAssertEqual(sim.bal.health(of: candidate, now: sim.now), .halfOpen(successes: 0))
        sim.ok(candidate, rtt: 300, count: 2)
        XCTAssertTrue(sim.bal.health(of: candidate, now: sim.now).isClosed)
    }
}

/// `current` measures 270 ms, `other` 40 ms, both steadily for five minutes.
/// The resulting score gap (about 13 points) lies between the Wi-Fi server
/// margin (10) and both the cellular server margin (15) and the Wi-Fi
/// transport margin (20).
func runPair(current: Candidate, other: Candidate, network: NetworkClass) -> (bal: AdaptiveBalancer, last: Decision) {
    var sim = Sim([current, other], network: network)
    sim.ok(current, rtt: 270, count: 5)
    var last = sim.decide()
    precondition(last.change?.to == current)
    for _ in 0..<60 {
        sim.advance(5)
        sim.ok(current, rtt: 270)
        sim.ok(other, rtt: 40)
        last = sim.decide()
    }
    return (sim.bal, last)
}
