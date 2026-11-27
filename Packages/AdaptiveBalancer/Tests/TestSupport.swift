import XCTest
@testable import AdaptiveBalancer

/// Deterministic generator for property-style tests (SplitMix64).
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }

    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

func cand(_ engine: String, _ transport: String, _ server: String) -> Candidate {
    Candidate(engine: EngineID(engine), transport: TransportID(transport), server: ServerID(server))
}

func at(_ seconds: Double) -> Instant { Instant(seconds: seconds) }

/// A balancer plus a manual clock.
struct Sim {
    var bal: AdaptiveBalancer
    var t: Double = 0

    init(_ candidates: [CandidateDescriptor], policies: PolicySet = .standard(), network: NetworkClass = .wifi) {
        bal = AdaptiveBalancer(candidates: candidates, policies: policies, network: network)
    }

    init(_ candidates: [Candidate], policies: PolicySet = .standard(), network: NetworkClass = .wifi) {
        self.init(candidates.map { CandidateDescriptor($0) }, policies: policies, network: network)
    }

    var now: Instant { Instant(seconds: t) }

    mutating func advance(_ seconds: Double) { t += seconds }

    mutating func ok(_ c: Candidate, rtt: Double = 50, count: Int = 1, loss: Double? = nil, throughput: Double? = nil) {
        for _ in 0..<count {
            bal.record(.success(c, at: now, ProbeMeasurement(rttMillis: rtt, lossFraction: loss, throughputBitsPerSecond: throughput)))
        }
    }

    mutating func fail(_ c: Candidate, count: Int = 1, kind: FailureKind = .timeout) {
        for _ in 0..<count { bal.record(.failure(c, at: now, kind)) }
    }

    @discardableResult
    mutating func decide() -> Decision { bal.decide(now: now) }

    /// Selects `c` and takes it through probation so that it becomes the last
    /// known good configuration. Requires a score-based strategy or `c` to be
    /// the top priority.
    mutating func settle(on c: Candidate, file: StaticString = #filePath, line: UInt = #line) {
        ok(c, count: 5)
        let first = decide()
        XCTAssertEqual(first.change?.to, c, file: file, line: line)
        XCTAssertEqual(first.change?.kind, .initialSelection, file: file, line: line)
        ok(c, count: 2)
        advance(bal.policy.probation.window + 1)
        ok(c)
        let second = decide()
        XCTAssertEqual(second.explanation.reason, .probationPassed, file: file, line: line)
        XCTAssertEqual(bal.lastKnownGood?.candidate, c, file: file, line: line)
    }
}

extension Decision {
    func blocker(_ level: SwitchLevel) -> Blocker.Code? {
        explanation.blockers.first { $0.level == level }?.code
    }

    func blockers(_ level: SwitchLevel) -> [Blocker.Code] {
        explanation.blockers.filter { $0.level == level }.map(\.code)
    }
}

/// Both networks use the same policy: convenient when a test is about one rule.
func uniform(_ policy: SelectionPolicy, preferredEngine: EngineID? = nil) -> PolicySet {
    PolicySet(wifi: policy, cellular: policy, preferredEngine: preferredEngine)
}
