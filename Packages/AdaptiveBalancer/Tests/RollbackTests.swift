import XCTest
@testable import AdaptiveBalancer

/// Probation, last known good configuration, rollback.
final class RollbackTests: XCTestCase {
    private let a = cand("x", "t1", "a")
    private let b = cand("x", "t1", "b")
    private let c = cand("x", "t1", "c")
    private let x1 = cand("x", "t1", "a")
    private let s1 = cand("s", "t1", "a")
    private let s2 = cand("s", "t1", "b")

    /// a is last known good; the balancer has just switched to b.
    private func switched(policy: SelectionPolicy = .wifiDefault(), extra: [Candidate] = []) -> Sim {
        var sim = Sim([a, b] + extra, policies: uniform(policy))
        sim.settle(on: a)
        sim.ok(a, rtt: 600, count: 10)
        sim.ok(b, rtt: 40, count: 10)
        sim.advance(10)
        sim.ok(a, rtt: 600); sim.ok(b, rtt: 40)
        XCTAssertEqual(sim.decide().change, Change(from: a, to: b, level: .server, kind: .improvement))
        return sim
    }

    func testConfigurationBecomesLastKnownGoodOnlyAfterProbation() {
        var sim = switched()
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, a)
        XCTAssertTrue(sim.bal.isInProbation)
        sim.ok(b, rtt: 40, count: 3)
        sim.advance(19)
        XCTAssertEqual(sim.decide().explanation.reason, .inProbation)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, a)
        sim.advance(1)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(b))
        XCTAssertEqual(decision.explanation.reason, .probationPassed)
        XCTAssertEqual(sim.bal.lastKnownGood, LastKnownGood(candidate: b, confirmedAt: sim.now))
        XCTAssertFalse(sim.bal.isInProbation)
    }

    func testFailuresInProbationRollBack() {
        var sim = switched()
        sim.advance(2)
        sim.ok(b, rtt: 40)
        sim.fail(b, count: 2, kind: .tlsFailure)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: b, to: a, level: .server, kind: .rollback))
        XCTAssertEqual(decision.explanation.reason, .rollback)
        XCTAssertTrue(decision.explanation.summary.contains("failed probation"))
        XCTAssertFalse(decision.requiresTunnelRestart)
        XCTAssertEqual(sim.bal.current, a)
        XCTAssertFalse(sim.bal.isInProbation, "the last known good configuration is not on probation")
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, a)
    }

    func testFailedConfigurationIsQuarantined() {
        var sim = switched()
        sim.fail(b, count: 2)
        XCTAssertEqual(sim.decide().change?.kind, .rollback)
        let rolledBackAt = sim.t
        // b looks excellent again at once; a is still slow.
        for _ in 0..<50 {
            sim.advance(5)
            sim.ok(a, rtt: 600); sim.ok(b, rtt: 40)
            let decision = sim.decide()
            XCTAssertEqual(decision.action, .keep(a))
            XCTAssertTrue(decision.explanation.candidates.first { $0.candidate == b }!.isQuarantined)
        }
        sim.t = rolledBackAt + 300
        sim.ok(a, rtt: 600); sim.ok(b, rtt: 40)
        XCTAssertEqual(sim.decide().change, Change(from: a, to: b, level: .server, kind: .improvement))
    }

    func testUnprovenConfigurationRollsBackAtTheEndOfTheWindow() {
        var sim = switched()
        sim.ok(b, rtt: 40)                      // one success, two are required
        sim.advance(20)
        sim.ok(a, rtt: 600)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: b, to: a, level: .server, kind: .rollback))
        XCTAssertTrue(decision.explanation.summary.contains("only 1 successes"))
    }

    func testApplyFailureRollsBackImmediately() {
        var sim = switched()
        sim.bal.reportApplyFailure(now: sim.now)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: b, to: a, level: .server, kind: .rollback))
        XCTAssertTrue(decision.explanation.summary.contains("could not be applied"))
    }

    func testBreakerOpeningInProbationRollsBack() {
        var policy = SelectionPolicy.wifiDefault()
        policy.probation.failureThreshold = 10
        var sim = switched(policy: policy)
        sim.fail(b, count: 3)
        let decision = sim.decide()
        XCTAssertEqual(decision.change?.kind, .rollback)
        XCTAssertTrue(decision.explanation.summary.contains("circuit breaker opened"))
    }

    func testRollbackIsNotBlockedByTheRateLimit() {
        var policy = SelectionPolicy.wifiDefault()
        policy.rateLimit = RateLimit(maximumSwitches: 1, window: 600)
        var sim = switched(policy: policy, extra: [c])
        sim.fail(b, count: 2)
        XCTAssertEqual(sim.decide().change, Change(from: b, to: a, level: .server, kind: .rollback))
        // But the limiter has counted both changes: nothing further for now.
        sim.fail(a, count: 3)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(a))
        XCTAssertEqual(decision.blocker(.server), .rateLimited)
    }

    func testNoLastKnownGoodMeansForcedSelectionInsteadOfRollback() {
        var sim = Sim([a, b])
        XCTAssertEqual(sim.decide().change?.to, a)
        sim.fail(a, count: 2)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: a, to: b, level: .server, kind: .failover))
        XCTAssertTrue(sim.bal.isInProbation)
    }

    func testRollbackSkippedWhenLastKnownGoodIsDown() {
        var sim = switched(extra: [c])
        sim.fail(a, count: 3)
        sim.fail(b, count: 2)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: b, to: c, level: .server, kind: .failover))
    }

    func testNetworkChangeRestartsTheProbationWindow() {
        var sim = switched()
        sim.ok(b, rtt: 40, count: 3)
        sim.advance(19)
        sim.bal.networkChanged(to: .cellular, now: sim.now)
        sim.advance(2)
        XCTAssertEqual(sim.decide().explanation.reason, .inProbation, "Wi-Fi evidence does not confirm it on cellular")
        sim.ok(b, rtt: 80, count: 2)
        sim.advance(28)                         // the cellular window is 30 s
        XCTAssertEqual(sim.decide().explanation.reason, .probationPassed)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, b)
        sim.bal.networkChanged(to: .wifi, now: sim.now)
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, a, "last known good is tracked per network class")
    }

    // MARK: Across engines

    /// x1 confirmed, x1 down, switched to s1 (in probation), then x1 recovered.
    private func afterEngineSwitch(extra: [Candidate] = []) -> Sim {
        var sim = Sim([x1, s1] + extra, policies: .standard(preferredEngine: "x"))
        sim.settle(on: x1)
        sim.ok(s1, rtt: 40, count: 10)
        sim.fail(x1, count: 3)                  // open until t=51
        sim.advance(21)
        sim.ok(s1, rtt: 40)
        XCTAssertEqual(sim.decide().change, Change(from: x1, to: s1, level: .engine, kind: .failover))
        return sim
    }

    func testFailedEngineSwitchRollsBackToThePreviousEngine() {
        var sim = afterEngineSwitch()
        sim.advance(10)
        sim.ok(x1, count: 2)
        XCTAssertTrue(sim.bal.health(of: x1, now: sim.now).isClosed)
        sim.fail(s1, count: 2, kind: .engineError)
        let decision = sim.decide()
        XCTAssertEqual(decision.change, Change(from: s1, to: x1, level: .engine, kind: .rollback))
        XCTAssertTrue(decision.requiresTunnelRestart, "undoing an engine switch is another restart")
        XCTAssertTrue(decision.explanation.summary.contains("drops all connections"))
    }

    func testFailedEngineSwitchWithoutAUsablePreviousEngineStays() {
        var sim = afterEngineSwitch()
        sim.fail(s1, count: 2)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(s1))
        XCTAssertEqual(decision.explanation.reason, .noAlternative)
        XCTAssertEqual(decision.blockers(.engine), [.inEngineSatisfiable])
    }

    func testInEngineProbationFailureNeverRollsBackAcrossEngines() {
        var sim = afterEngineSwitch(extra: [s2])
        sim.fail(s1, count: 2)                  // x1 still open: no rollback, next server in engine s
        XCTAssertEqual(sim.decide().change, Change(from: s1, to: s2, level: .server, kind: .failover))
        XCTAssertEqual(sim.bal.lastKnownGood?.candidate, x1)
        sim.advance(10)
        sim.ok(x1, count: 2)                    // the old engine's server recovers
        XCTAssertTrue(sim.bal.health(of: x1, now: sim.now).isClosed)
        sim.fail(s2, count: 2)
        let decision = sim.decide()
        XCTAssertEqual(decision.action, .keep(s2))
        XCTAssertFalse(decision.requiresTunnelRestart)
        XCTAssertEqual(decision.blockers(.engine), [.inEngineSatisfiable])
    }
}
