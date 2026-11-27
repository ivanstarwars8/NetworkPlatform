import XCTest
@testable import AdaptiveBalancer

/// Level (c): switching between engines.
final class EngineSwitchTests: XCTestCase {
    private let x1 = cand("x", "t1", "a")
    private let x2 = cand("x", "t1", "b")
    private let x3 = cand("x", "t2", "a")
    private let s1 = cand("s", "t1", "a")
    private let s2 = cand("s", "t1", "b")

    /// x1 is current and confirmed, s1 is well measured, x1's breaker has just opened.
    private func outage(policy: SelectionPolicy = .wifiDefault(), measureTarget: Bool = true) -> Sim {
        var sim = Sim([x1, s1], policies: uniform(policy, preferredEngine: "x"))
        sim.settle(on: x1)
        if measureTarget { sim.ok(s1, rtt: 40, count: 10) }
        sim.fail(x1, count: 3)
        return sim
    }

    func testLatencyDegradationAloneNeverRestartsTheTunnel() {
        var sim = Sim([x1, s1], policies: .standard(preferredEngine: "x"))
        sim.settle(on: x1)
        for step in 0..<1500 {
            sim.advance(5)
            // The current engine becomes terrible in every measurable way,
            // the other engine is perfect. Nothing fails.
            sim.bal.record(.success(x1, at: sim.now, ProbeMeasurement(
                rttMillis: 4000 + Double(step % 7) * 500, connectMillis: 9000, tlsMillis: 9000,
                lossFraction: 0.9, throughputBitsPerSecond: 10_000
            )))
            sim.bal.record(.success(s1, at: sim.now, ProbeMeasurement(
                rttMillis: 10, connectMillis: 10, tlsMillis: 10, lossFraction: 0, throughputBitsPerSecond: 500_000_000
            )))
            let decision = sim.decide()
            XCTAssertEqual(decision.action, .keep(x1))
            XCTAssertFalse(decision.requiresTunnelRestart)
            XCTAssertEqual(decision.blocker(.engine), .inEngineSatisfiable)
        }
        XCTAssertLessThan(sim.bal.score(of: x1, now: sim.now).value, 25)
        XCTAssertGreaterThan(sim.bal.score(of: s1, now: sim.now).value, 95)
    }

    func testEngineSwitchAfterSustainedOutage() {
        var sim = outage()
        let early = sim.decide()
        XCTAssertEqual(early.action, .keep(x1))
        XCTAssertEqual(early.explanation.reason, .noAlternative)
        XCTAssertEqual(early.blockers(.engine), [.outageTooShort])

        sim.advance(19)
        sim.ok(s1, rtt: 40)
        XCTAssertEqual(sim.decide().blockers(.engine), [.outageTooShort])

        sim.advance(1)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: x1, to: s1, level: .engine, kind: .failover))
        XCTAssertEqual(decision.explanation.reason, .engineSwitch)
        XCTAssertTrue(decision.requiresTunnelRestart)
        XCTAssertTrue(decision.explanation.summary.contains("all connections are dropped"))
        XCTAssertTrue(sim.bal.isInProbation)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, x1, "not replaced until the new engine proves itself")
    }

    func testInEngineAlternativesAreUsedBeforeAnEngineSwitch() {
        var sim = Sim([x1, x2, x3, s1], policies: .standard(preferredEngine: "x"))
        sim.settle(on: x1)
        sim.ok(s1, rtt: 10, count: 20)
        sim.fail(x1, count: 3)
        XCTAssertEqual(sim.decide().change, Change(from: x1, to: x2, level: .server, kind: .failover))
        sim.advance(1)
        sim.fail(x2, count: 3)
        XCTAssertEqual(sim.decide().change, Change(from: x2, to: x3, level: .transport, kind: .failover))
        sim.advance(1)
        sim.fail(x3, count: 3)
        let waiting = sim.decide()
        XCTAssertEqual(waiting.action, .keep(x3))
        XCTAssertEqual(waiting.blocker(.server), .noAvailableCandidate)
        XCTAssertEqual(waiting.blocker(.transport), .noAvailableCandidate)
        XCTAssertEqual(waiting.blockers(.engine), [.outageTooShort])
        sim.advance(20)
        sim.ok(s1, rtt: 10)
        let decision = sim.decide()
        XCTAssertEqual(decision.change?.level, .engine)
        XCTAssertEqual(decision.change?.to, s1)
    }

    func testOutageClockRestartsWhenAnInEngineCandidateRecovers() {
        var sim = Sim([x1, x2, s1], policies: .standard(preferredEngine: "x"))
        sim.settle(on: x1)
        sim.ok(s1, rtt: 40, count: 10)
        sim.fail(x2, count: 3)
        sim.fail(x1, count: 3)                  // both open at t=21, until t=51
        sim.advance(15)
        XCTAssertEqual(sim.decide().blockers(.engine), [.outageTooShort])
        sim.advance(16)                         // t=52: x2 half-open, probes close it
        sim.ok(x2, count: 2)
        sim.ok(s1, rtt: 40)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: x1, to: x2, level: .server, kind: .failover),
                       "31 s of outage would have allowed a restart; a recovered server makes it unnecessary")
    }

    func testCostModelBlocksAnExpensiveRestart() {
        var policy = SelectionPolicy.wifiDefault()
        policy.engineSwitch.cost = EngineSwitchCost(expectedDowntime: 10, downtimePenaltyPerSecond: 5, connectionResetPenalty: 30)
        var sim = outage(policy: policy)
        sim.advance(60)
        sim.ok(s1, rtt: 40)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(x1))
        XCTAssertEqual(decision.blockers(.engine), [.costExceedsBenefit])
        XCTAssertEqual(policy.engineSwitch.cost.totalPenalty, 80)
    }

    func testExpectedDowntimeIsALowerBoundForTheRequiredOutage() {
        var policy = SelectionPolicy.wifiDefault()
        policy.engineSwitch.minimumOutage = 1
        policy.engineSwitch.cost = EngineSwitchCost(expectedDowntime: 8, downtimePenaltyPerSecond: 1, connectionResetPenalty: 0)
        XCTAssertEqual(policy.engineSwitch.requiredOutage, 8)
        var sim = outage(policy: policy)
        sim.advance(7)
        XCTAssertEqual(sim.decide().blockers(.engine), [.outageTooShort])
        sim.advance(1)
        XCTAssertEqual(sim.decide().change?.level, .engine)
    }

    func testUnmeasuredTargetIsNotWorthARestart() {
        var sim = outage(measureTarget: false)
        sim.advance(60)
        XCTAssertEqual(sim.decide().blockers(.engine), [.targetNotProven])
        sim.ok(s1, rtt: 40, count: 2)
        XCTAssertEqual(sim.decide().blockers(.engine), [.targetNotProven])
        sim.ok(s1, rtt: 40, count: 8)
        XCTAssertEqual(sim.decide().change?.level, .engine)
    }

    func testDisabledEngineSwitching() {
        var policy = SelectionPolicy.wifiDefault()
        policy.engineSwitch.isEnabled = false
        var sim = outage(policy: policy)
        sim.advance(3600)
        sim.ok(s1, rtt: 40, count: 5)
        XCTAssertEqual(sim.decide().blockers(.engine), [.engineSwitchDisabled])
    }

    func testDeadTargetEngineIsNotATarget() {
        var sim = outage()
        sim.fail(s1, count: 3)
        sim.advance(25)
        XCTAssertEqual(sim.decide().blockers(.engine), [.noAvailableCandidate])
    }

    func testMinimumIntervalAndRateLimitBetweenRestarts() {
        var sim = outage()                      // x1 opens at t=21
        sim.advance(21)
        sim.ok(s1, rtt: 40)
        XCTAssertEqual(sim.decide().change?.to, s1)             // restart 1 at t=42
        let first = sim.t

        sim.ok(s1, rtt: 40, count: 2)
        sim.advance(21)
        sim.ok(x1, count: 2)                    // half-open probes close x1
        sim.ok(s1, rtt: 40)
        XCTAssertEqual(sim.decide().explanation.reason, .probationPassed)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, s1)

        sim.fail(s1, count: 3)
        XCTAssertEqual(Set(sim.decide().blockers(.engine)), [.outageTooShort, .engineIntervalNotElapsed])
        sim.advance(60)
        sim.ok(x1, count: 3)
        XCTAssertEqual(sim.decide().blockers(.engine), [.engineIntervalNotElapsed])

        sim.t = first + 300
        sim.ok(x1, count: 3)
        XCTAssertEqual(sim.decide().change, Change(from: s1, to: x1, level: .engine, kind: .failover))   // restart 2
        let second = sim.t

        sim.ok(x1, count: 2)
        sim.advance(21)
        sim.ok(x1)
        XCTAssertEqual(sim.decide().explanation.reason, .probationPassed)
        sim.ok(s1, rtt: 40, count: 2)           // s1 was half-open; now closed
        XCTAssertTrue(sim.bal.health(of: s1, now: sim.now).isClosed)
        sim.fail(x1, count: 3)
        sim.t = second + 301
        sim.ok(s1, rtt: 40, count: 5)
        let limited = sim.decide()
        XCTAssertEqual(limited.action, .keep(x1))
        XCTAssertEqual(limited.blockers(.engine), [.rateLimited], "two restarts per hour on Wi-Fi")

        sim.t = first + 3600
        sim.ok(s1, rtt: 40, count: 5)
        XCTAssertEqual(sim.decide().change?.level, .engine)
    }

    func testQuarantineAloneDoesNotOpenTheWayToARestart() {
        // x1 never produces a sample: it fails probation as unproven and is
        // quarantined, but its breaker is closed — there is no failure
        // evidence against the engine.
        var sim = Sim([x1, s1], policies: .standard(preferredEngine: "x"))
        XCTAssertEqual(sim.decide().change?.to, x1)
        sim.ok(s1, rtt: 20, count: 20)
        sim.advance(21)
        sim.ok(s1, rtt: 20)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(x1))
        XCTAssertEqual(decision.explanation.reason, .noAlternative)
        XCTAssertEqual(decision.blockers(.engine), [.inEngineSatisfiable])
        XCTAssertTrue(decision.explanation.current!.isQuarantined)
    }

    func testProfileWithoutCandidatesForTheCurrentEngine() {
        var sim = Sim([x1, s1], policies: .standard(preferredEngine: "x"))
        sim.settle(on: x1)
        // The profile changed: nothing can run on engine x any more.
        sim.bal.updateCandidates([CandidateDescriptor(s1), CandidateDescriptor(s2)], now: sim.now)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: x1, to: s1, level: .engine, kind: .failover))
        XCTAssertTrue(decision.requiresTunnelRestart)
        XCTAssertTrue(decision.explanation.summary.contains("no candidate for engine x"))
    }

    func testCellularRestartIsHarderThanWiFi() {
        func outageSeconds(_ network: NetworkClass) -> Double {
            var sim = Sim([x1, s1], policies: .standard(preferredEngine: "x"), network: network)
            sim.settle(on: x1)
            sim.ok(s1, rtt: 40, count: 10)
            sim.fail(x1, count: 4)
            let start = sim.t
            while sim.t < start + 600 {
                sim.advance(1)
                sim.ok(s1, rtt: 40)
                if sim.decide().requiresTunnelRestart { return sim.t - start }
            }
            return .infinity
        }
        XCTAssertEqual(outageSeconds(.wifi), 20)
        XCTAssertEqual(outageSeconds(.cellular), 45)
    }
}
