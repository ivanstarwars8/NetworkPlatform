// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import CoreAbstraction

final class CoreLifecycleTableTests: XCTestCase {
    func testTableIsExactlyTheDocumentedOne() {
        // (state, event) -> next state; everything not listed must be illegal.
        let legal: [String: CoreLifecycleState] = [
            "idle+start": .starting,
            "failed+start": .starting,
            "starting+startSucceeded": .running,
            "starting+startFailed": .failed,
            "running+reload": .reloading,
            "reloading+reloadSucceeded": .running,
            "reloading+reloadFailed": .failed,
            "running+stop": .stopping,
            "failed+stop": .stopping,
            "stopping+stopSucceeded": .idle,
            "stopping+stopFailed": .failed,
            "running+unexpectedExit": .failed,
        ]
        var checked = 0
        for state in CoreLifecycleState.allCases {
            for event in CoreLifecycleEvent.allCases {
                let key = "\(state.rawValue)+\(event.rawValue)"
                XCTAssertEqual(CoreLifecycleTable.nextState(from: state, on: event), legal[key], key)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 6 * 10)
    }

    func testTransientStatesAcceptNoCommands() {
        for state in [CoreLifecycleState.starting, .reloading, .stopping] {
            for command in CoreLifecycleTable.commands {
                XCTAssertNil(CoreLifecycleTable.nextState(from: state, on: command), "\(state)+\(command)")
            }
        }
    }

    func testEveryStateIsReachableAndLeavable() {
        var reachable: Set<CoreLifecycleState> = [.idle]
        var changed = true
        while changed {
            changed = false
            for state in reachable {
                for event in CoreLifecycleEvent.allCases {
                    if let next = CoreLifecycleTable.nextState(from: state, on: event), !reachable.contains(next) {
                        reachable.insert(next)
                        changed = true
                    }
                }
            }
        }
        XCTAssertEqual(reachable, Set(CoreLifecycleState.allCases))
        for state in CoreLifecycleState.allCases {
            let exits = CoreLifecycleEvent.allCases.filter { CoreLifecycleTable.nextState(from: state, on: $0) != nil }
            XCTAssertFalse(exits.isEmpty, "\(state) is a dead end")
        }
    }
}

final class CoreLifecycleTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_000)

    private func makeLifecycle(_ core: MockCore, historyLimit: Int = 64) -> CoreLifecycle {
        let date = fixedDate
        return CoreLifecycle(core: core, historyLimit: historyLimit, clock: { date })
    }

    // MARK: Normal flow

    func testStartReloadStop() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        let initial = await lifecycle.state
        XCTAssertEqual(initial, .idle)
        XCTAssertEqual(lifecycle.descriptor, core.descriptor)

        let options = CoreStartOptions(tunnelFileDescriptor: 7, mtu: 1500, memoryLimitBytes: 30_000_000)
        try await lifecycle.start(MockCore.configuration(payload: "{\"a\":1}"), options: options)
        let afterStart = await lifecycle.state
        XCTAssertEqual(afterStart, .running)
        XCTAssertEqual(core.startedConfiguration, MockCore.configuration(payload: "{\"a\":1}"))
        XCTAssertEqual(core.startedOptions, options)

        try await lifecycle.reload(MockCore.configuration(payload: "{\"a\":2}"))
        let afterReload = await lifecycle.state
        XCTAssertEqual(afterReload, .running)
        XCTAssertEqual(core.reloadedConfiguration, MockCore.configuration(payload: "{\"a\":2}"))

        try await lifecycle.stop()
        let afterStop = await lifecycle.state
        XCTAssertEqual(afterStop, .idle)

        XCTAssertEqual(core.commandCalls, [.start, .reload, .stop])
        let history = await lifecycle.history
        XCTAssertEqual(history.map { $0.event }, [
            .start, .startSucceeded, .reload, .reloadSucceeded, .stop, .stopSucceeded,
        ])
        XCTAssertEqual(history.map { $0.to }, [.starting, .running, .reloading, .running, .stopping, .idle])
        XCTAssertEqual(history.first?.from, .idle)
        XCTAssertEqual(history.first?.at, fixedDate)
        let lastError = await lifecycle.lastError
        XCTAssertNil(lastError)
    }

    func testCanRestartAfterStop() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        for _ in 0..<3 {
            try await lifecycle.start(MockCore.configuration())
            try await lifecycle.stop()
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop, .start, .stop, .start, .stop])
    }

    // MARK: Illegal transitions

    func testIllegalCommandsAreRejectedWithoutTouchingTheCore() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)

        await assertThrows(.illegalTransition(from: .idle, event: .stop)) {
            try await lifecycle.stop()
        }
        await assertThrows(.illegalTransition(from: .idle, event: .reload)) {
            try await lifecycle.reload(MockCore.configuration())
        }
        var state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.calls, [])

        try await lifecycle.start(MockCore.configuration())
        await assertThrows(.illegalTransition(from: .running, event: .start)) {
            try await lifecycle.start(MockCore.configuration())
        }
        state = await lifecycle.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(core.commandCalls, [.start])

        let history = await lifecycle.history
        XCTAssertEqual(history.count, 2, "rejected commands must not appear in the history")
    }

    // MARK: Failures

    func testStartFailureLeadsToFailedAndCanBeRetried() async throws {
        let core = MockCore()
        core.setError(MockCore.Failure("boom"), for: .start)
        let lifecycle = makeLifecycle(core)

        await assertThrows(.operationFailed(operation: .start, message: "boom")) {
            try await lifecycle.start(MockCore.configuration())
        }
        var state = await lifecycle.state
        XCTAssertEqual(state, .failed)
        var lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .operationFailed(operation: .start, message: "boom"))

        let health = await lifecycle.health()
        XCTAssertEqual(health.status, .unhealthy)
        XCTAssertEqual(health.lastError, .operationFailed(operation: .start, message: "boom"))
        XCTAssertEqual(health.checkedAt, fixedDate)

        // Reload is not a way out of `failed`.
        await assertThrows(.illegalTransition(from: .failed, event: .reload)) {
            try await lifecycle.reload(MockCore.configuration())
        }

        core.setError(nil, for: .start)
        try await lifecycle.start(MockCore.configuration())
        state = await lifecycle.state
        XCTAssertEqual(state, .running)
        lastError = await lifecycle.lastError
        XCTAssertNil(lastError)
    }

    func testFailedCoreCanBeStopped() async throws {
        let core = MockCore()
        core.setError(MockCore.Failure("boom"), for: .start)
        let lifecycle = makeLifecycle(core)
        await assertThrows(.operationFailed(operation: .start, message: "boom")) {
            try await lifecycle.start(MockCore.configuration())
        }
        try await lifecycle.stop()
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        // The reason of the failure stays available after the clean-up.
        let lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .operationFailed(operation: .start, message: "boom"))
    }

    func testCoreErrorsPassThroughUnchanged() async throws {
        let core = MockCore()
        let issue = CoreValidationIssue(severity: .error, path: "outbounds[0]", message: "unknown protocol")
        core.setError(CoreError.invalidConfiguration(issues: [issue]), for: .start)
        let lifecycle = makeLifecycle(core)
        await assertThrows(.invalidConfiguration(issues: [issue])) {
            try await lifecycle.start(MockCore.configuration())
        }
    }

    func testCancellationIsNormalised() async throws {
        let core = MockCore()
        core.setError(CancellationError(), for: .start)
        let lifecycle = makeLifecycle(core)
        await assertThrows(.cancelled(operation: .start)) {
            try await lifecycle.start(MockCore.configuration())
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .failed)
    }

    func testStopFailure() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())
        core.setError(MockCore.Failure("stuck"), for: .stop)
        await assertThrows(.operationFailed(operation: .stop, message: "stuck")) {
            try await lifecycle.stop()
        }
        var state = await lifecycle.state
        XCTAssertEqual(state, .failed)

        core.setError(nil, for: .stop)
        try await lifecycle.stop()
        state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testReloadFailure() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())
        core.setError(MockCore.Failure("bad reload"), for: .reload)
        await assertThrows(.operationFailed(operation: .reload, message: "bad reload")) {
            try await lifecycle.reload(MockCore.configuration())
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .failed)
        let lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .operationFailed(operation: .reload, message: "bad reload"))
    }

    func testReloadNeedsTheHotReloadFeature() async throws {
        let core = MockCore(capabilities: CoreCapabilities(protocols: [.vless], transports: [.tcp], features: []))
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())
        await assertThrows(.unsupportedFeature(.hotReload)) {
            try await lifecycle.reload(MockCore.configuration())
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .running, "an unsupported reload must leave the core running")
        XCTAssertEqual(core.commandCalls, [.start])
    }

    // MARK: Configuration checks

    func testStructuralConfigurationChecks() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)

        await assertThrows(.configurationMismatch(expected: "mock", actual: "other")) {
            try await lifecycle.start(MockCore.configuration(for: "other"))
        }

        do {
            try await lifecycle.start(MockCore.configuration(payload: ""))
            XCTFail("an empty payload must be rejected")
        } catch let error as CoreError {
            XCTAssertEqual(error.code, "invalid_configuration")
        }

        let oversized = CoreConfiguration(
            coreID: "mock",
            format: "json",
            payload: Data(count: CoreConfiguration.maximumPayloadBytes + 1)
        )
        do {
            try await lifecycle.start(oversized)
            XCTFail("an oversized payload must be rejected")
        } catch let error as CoreError {
            XCTAssertEqual(error.code, "invalid_configuration")
        }

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle, "a rejected configuration must not change the state")
        XCTAssertEqual(core.calls, [])

        let largest = CoreConfiguration(
            coreID: "mock",
            format: "json",
            payload: Data(count: CoreConfiguration.maximumPayloadBytes)
        )
        try await lifecycle.start(largest)
        await assertThrows(.configurationMismatch(expected: "mock", actual: "other")) {
            try await lifecycle.reload(MockCore.configuration(for: "other"))
        }
        let afterReload = await lifecycle.state
        XCTAssertEqual(afterReload, .running)
    }

    func testValidatePassesThrough() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        let warning = CoreValidationIssue(severity: .warning, message: "deprecated field")
        let problem = CoreValidationIssue(severity: .error, path: "dns", message: "no servers")
        core.setValidationReport(CoreValidationReport(issues: [warning, problem]))

        let report = try await lifecycle.validate(MockCore.configuration())
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.errors, [problem])
        XCTAssertEqual(report.warnings, [warning])
        XCTAssertEqual(core.calls, [.validate])

        await assertThrows(.configurationMismatch(expected: "mock", actual: "other")) {
            _ = try await lifecycle.validate(MockCore.configuration(for: "other"))
        }
        core.setError(MockCore.Failure("cannot check"), for: .validate)
        await assertThrows(.operationFailed(operation: .validate, message: "cannot check")) {
            _ = try await lifecycle.validate(MockCore.configuration())
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: Serialisation

    func testStopIssuedDuringStartWaitsForIt() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 150, for: .start)
        let lifecycle = makeLifecycle(core)

        let starter = Task { try await lifecycle.start(MockCore.configuration()) }
        let reachedStarting = await waitUntil { await lifecycle.state == .starting }
        XCTAssertTrue(reachedStarting)

        // The start is still in flight; stop must queue behind it instead of
        // failing with "illegal in starting" or running concurrently.
        try await lifecycle.stop()
        try await starter.value

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        let history = await lifecycle.history
        XCTAssertEqual(history.map { $0.event }, [.start, .startSucceeded, .stop, .stopSucceeded])
    }

    func testConcurrentStartsRunTheCoreOnce() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 20, for: .start)
        let lifecycle = makeLifecycle(core)
        let attempts = 12

        var succeeded = 0
        var rejected = 0
        await withTaskGroup(of: Result<Void, Error>.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    do {
                        try await lifecycle.start(MockCore.configuration())
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success:
                    succeeded += 1
                case let .failure(error):
                    XCTAssertEqual(error as? CoreError, .illegalTransition(from: .running, event: .start))
                    rejected += 1
                }
            }
        }
        XCTAssertEqual(succeeded, 1)
        XCTAssertEqual(rejected, attempts - 1)
        XCTAssertEqual(core.commandCalls, [.start])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
    }

    func testRandomConcurrentCommandsNeverOverlapAndFormALegalChain() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 3, for: .start)
        core.setDelay(milliseconds: 2, for: .stop)
        let lifecycle = makeLifecycle(core, historyLimit: 1_000)

        await withTaskGroup(of: Void.self) { group in
            for number in 0..<60 {
                group.addTask {
                    // Deterministic mix of commands; errors are expected and
                    // irrelevant here.
                    switch number % 3 {
                    case 0: _ = try? await lifecycle.start(MockCore.configuration())
                    case 1: _ = try? await lifecycle.stop()
                    default: _ = try? await lifecycle.reload(MockCore.configuration())
                    }
                }
            }
        }

        XCTAssertEqual(core.maximumConcurrentCommands, 1, "core operations overlapped")
        let state = await lifecycle.state
        XCTAssertTrue(state == .idle || state == .running, "ended in transient state \(state)")

        let history = await lifecycle.history
        XCTAssertFalse(history.isEmpty)
        var previous = CoreLifecycleState.idle
        for transition in history {
            XCTAssertEqual(transition.from, previous, "history is not a chain")
            XCTAssertEqual(CoreLifecycleTable.nextState(from: transition.from, on: transition.event), transition.to)
            previous = transition.to
        }
        XCTAssertEqual(previous, state)
        // Every command that reached the core is paired with its outcome.
        let commands = history.filter { CoreLifecycleTable.commands.contains($0.event) }.count
        XCTAssertEqual(commands * 2, history.count)
        XCTAssertEqual(commands, core.commandCalls.count)
    }

    // MARK: Unexpected exit

    func testUnexpectedExit() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)

        let ignored = await lifecycle.reportUnexpectedExit("not even started")
        XCTAssertFalse(ignored)
        var state = await lifecycle.state
        XCTAssertEqual(state, .idle)

        try await lifecycle.start(MockCore.configuration())
        let accepted = await lifecycle.reportUnexpectedExit("panic: out of memory")
        XCTAssertTrue(accepted)
        state = await lifecycle.state
        XCTAssertEqual(state, .failed)
        let lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .unexpectedExit(message: "panic: out of memory"))

        // A second report changes nothing.
        let repeated = await lifecycle.reportUnexpectedExit("again")
        XCTAssertFalse(repeated)

        try await lifecycle.stop()
        state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testUnexpectedExitReportedDuringStopIsIgnored() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 150, for: .stop)
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())

        let stopper = Task { try await lifecycle.stop() }
        let reachedStopping = await waitUntil { await lifecycle.state == .stopping }
        XCTAssertTrue(reachedStopping)

        // Queued behind the stop: by the time it is processed the core is
        // idle, so the exit is the expected result of stopping.
        let accepted = await lifecycle.reportUnexpectedExit("exited")
        XCTAssertFalse(accepted)
        try await stopper.value
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testLongExitMessageIsBounded() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())
        _ = await lifecycle.reportUnexpectedExit(String(repeating: "x", count: 10_000))
        let lastError = await lifecycle.lastError
        guard case let .unexpectedExit(message)? = lastError else {
            XCTFail("expected unexpectedExit")
            return
        }
        XCTAssertEqual(message.count, CoreError.maximumMessageLength + 3)
    }

    // MARK: Statistics, health, history, stream

    func testStatisticsAndHealthDependOnState() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)

        await assertThrows(.notRunning(state: .idle)) {
            _ = try await lifecycle.statistics()
        }
        let idleHealth = await lifecycle.health()
        XCTAssertEqual(idleHealth.status, .unknown)
        XCTAssertEqual(core.calls, [], "an idle core must not be asked anything")

        try await lifecycle.start(MockCore.configuration())
        let statistics = try await lifecycle.statistics()
        XCTAssertEqual(statistics.traffic, TrafficCounters(uplinkBytes: 10, downlinkBytes: 20))
        XCTAssertEqual(statistics.outbounds["proxy"]?.totalBytes, 16)
        XCTAssertEqual(statistics.activeConnections, 3)
        let health = await lifecycle.health()
        XCTAssertEqual(health.status, .healthy)

        core.setError(MockCore.Failure("stats unavailable"), for: .statistics)
        await assertThrows(.operationFailed(operation: .statistics, message: "stats unavailable")) {
            _ = try await lifecycle.statistics()
        }
        // A failing query is not a lifecycle failure.
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
    }

    func testHistoryIsBounded() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core, historyLimit: 3)
        try await lifecycle.start(MockCore.configuration())
        try await lifecycle.stop()
        try await lifecycle.start(MockCore.configuration())
        let history = await lifecycle.history
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map { $0.event }, [.stopSucceeded, .start, .startSucceeded])
    }

    func testStateUpdatesStream() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        let stream = await lifecycle.stateUpdates()

        try await lifecycle.start(MockCore.configuration())
        try await lifecycle.stop()

        var received: [CoreLifecycleState] = []
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<5 {
            if let state = await iterator.next() {
                received.append(state)
            }
        }
        XCTAssertEqual(received, [.idle, .starting, .running, .stopping, .idle])
    }

    func testLateSubscriberGetsCurrentStateFirst() async throws {
        let core = MockCore()
        let lifecycle = makeLifecycle(core)
        try await lifecycle.start(MockCore.configuration())
        let stream = await lifecycle.stateUpdates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .running)
    }
}
