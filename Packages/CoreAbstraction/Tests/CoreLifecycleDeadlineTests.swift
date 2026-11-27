// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import CoreAbstraction

/// Deadlines, cancellation, `shutdown`, system events and observer clean-up.
final class CoreLifecycleDeadlineTests: XCTestCase {
    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }

    private func assertLegalChain(
        _ history: [CoreLifecycleTransition],
        endsIn state: CoreLifecycleState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previous = CoreLifecycleState.idle
        for transition in history {
            XCTAssertEqual(transition.from, previous, "history is not a chain", file: file, line: line)
            XCTAssertEqual(
                CoreLifecycleTable.nextState(from: transition.from, on: transition.event),
                transition.to,
                file: file,
                line: line
            )
            previous = transition.to
        }
        XCTAssertEqual(previous, state, file: file, line: line)
    }

    // MARK: Deadlines

    func testStartTimesOutWhenTheCoreHangsAndTheQueueStaysBlocked() async throws {
        let core = MockCore()
        core.setHang(for: .start)
        let lifecycle = CoreLifecycle(core: core)

        let began = Date()
        await assertThrows(.timedOut(operation: .start, seconds: 0.1)) {
            try await lifecycle.start(MockCore.configuration(), timeout: 0.1)
        }
        XCTAssertLessThan(elapsedMilliseconds(since: began), 3_000, "the caller was not released at the deadline")

        // The core is still inside `start`: the lifecycle says so and does
        // not enter the core a second time.
        var state = await lifecycle.state
        XCTAssertEqual(state, .starting)
        await assertThrows(.timedOut(operation: .stop, seconds: 0.1)) {
            try await lifecycle.shutdown(timeout: 0.1)
        }
        XCTAssertEqual(core.commandCalls, [.start])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)

        // Once the stuck call returns, the abandoned start is recorded as a
        // failure and the shutdown that was queued behind it stops the core.
        core.releaseHang(for: .start)
        let reachedIdle = await waitUntil { await lifecycle.state == .idle }
        XCTAssertTrue(reachedIdle)
        state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        let history = await lifecycle.history
        XCTAssertEqual(history.map { $0.event }, [.start, .startFailed, .stop, .stopSucceeded])
    }

    func testAbandonedStartThatFinishesLateNeverEndsInRunning() async throws {
        let core = MockCore()
        // Ignores cancellation and succeeds after the caller gave up.
        core.setDelay(milliseconds: 200, for: .start)
        let lifecycle = CoreLifecycle(core: core)

        await assertThrows(.timedOut(operation: .start, seconds: 0.05)) {
            try await lifecycle.start(MockCore.configuration(), timeout: 0.05)
        }
        let settled = await waitUntil { await lifecycle.state != .starting }
        XCTAssertTrue(settled)
        let state = await lifecycle.state
        XCTAssertEqual(state, .failed)
        let lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .cancelled(operation: .start))
        XCTAssertEqual(core.cancelledCalls, [.start])

        try await lifecycle.shutdown(timeout: 5)
        let final = await lifecycle.state
        XCTAssertEqual(final, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
    }

    func testStartWithinItsDeadlineSucceeds() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 20, for: .start)
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration(), timeout: 10)
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(core.cancelledCalls, [])
        let pending = await waitUntil { await lifecycle.pendingInterruptibleCount == 0 }
        XCTAssertTrue(pending, "finished operations must not stay registered")
    }

    func testStopTimesOutButIsNeverCancelled() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setHang(for: .stop)

        let began = Date()
        await assertThrows(.timedOut(operation: .stop, seconds: 0.1)) {
            try await lifecycle.stop(timeout: 0.1)
        }
        XCTAssertLessThan(elapsedMilliseconds(since: began), 3_000)
        var state = await lifecycle.state
        XCTAssertEqual(state, .stopping)

        core.releaseHang(for: .stop)
        let reachedIdle = await waitUntil { await lifecycle.state == .idle }
        XCTAssertTrue(reachedIdle)
        state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.cancelledCalls, [], "stop is clean-up and must not see cancellation")
        XCTAssertEqual(core.commandCalls, [.start, .stop])
    }

    func testCancellingTheCallerDoesNotInterruptStop() async throws {
        let core = MockCore()
        core.setHonoursCancellation(true)
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setDelay(milliseconds: 150, for: .stop)

        let stopper = Task { try await lifecycle.stop() }
        let reachedStopping = await waitUntil { await lifecycle.state == .stopping }
        XCTAssertTrue(reachedStopping)
        stopper.cancel()
        try await stopper.value

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.cancelledCalls, [])
    }

    func testReloadTimeoutLeavesTheRealOutcome() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setDelay(milliseconds: 150, for: .reload)

        await assertThrows(.timedOut(operation: .reload, seconds: 0.03)) {
            try await lifecycle.reload(MockCore.configuration(payload: "{\"v\":2}"), timeout: 0.03)
        }
        let settled = await waitUntil { await lifecycle.state != .reloading }
        XCTAssertTrue(settled)
        // The mock ignored the cancellation and applied the configuration,
        // so the core really runs the new one.
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(core.reloadedConfiguration, MockCore.configuration(payload: "{\"v\":2}"))
    }

    // MARK: Cancellation

    func testCancellingTheCallerInterruptsStart() async throws {
        let core = MockCore()
        core.setHonoursCancellation(true)
        core.setDelay(milliseconds: 5_000, for: .start)
        let lifecycle = CoreLifecycle(core: core)

        let starter = Task { try await lifecycle.start(MockCore.configuration()) }
        let reachedStarting = await waitUntil { await lifecycle.state == .starting }
        XCTAssertTrue(reachedStarting)

        let began = Date()
        starter.cancel()
        do {
            try await starter.value
            XCTFail("a cancelled start must throw")
        } catch {
            XCTAssertEqual(error as? CoreError, .cancelled(operation: .start))
        }
        XCTAssertLessThan(elapsedMilliseconds(since: began), 3_000)

        let failed = await waitUntil { await lifecycle.state == .failed }
        XCTAssertTrue(failed)
        let lastError = await lifecycle.lastError
        XCTAssertEqual(lastError, .cancelled(operation: .start))

        // A failed core can be cleaned up and started again.
        try await lifecycle.shutdown()
        core.setDelay(milliseconds: 0, for: .start)
        try await lifecycle.start(MockCore.configuration())
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
    }

    func testStartCancelledWhileQueuedNeverReachesTheCore() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setDelay(milliseconds: 200, for: .stop)

        let stopper = Task { try await lifecycle.stop() }
        let reachedStopping = await waitUntil { await lifecycle.state == .stopping }
        XCTAssertTrue(reachedStopping)

        // Queued behind the slow stop, then abandoned.
        let starter = Task { try await lifecycle.start(MockCore.configuration()) }
        let queued = await waitUntil { await lifecycle.pendingInterruptibleCount == 1 }
        XCTAssertTrue(queued)
        starter.cancel()
        do {
            try await starter.value
            XCTFail("a cancelled start must throw")
        } catch {
            XCTAssertEqual(error as? CoreError, .cancelled(operation: .start))
        }

        try await stopper.value
        let drained = await waitUntil { await lifecycle.pendingInterruptibleCount == 0 }
        XCTAssertTrue(drained)
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop], "the abandoned start reached the core")
    }

    func testStartAlreadyCancelledBeforeTheCall() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        let starter = Task { () -> CoreError? in
            // Make sure the cancellation is visible before `start` is called.
            while !Task.isCancelled { await Task.yield() }
            do {
                try await lifecycle.start(MockCore.configuration())
                return nil
            } catch {
                return error as? CoreError
            }
        }
        starter.cancel()
        let error = await starter.value
        XCTAssertEqual(error, .cancelled(operation: .start))
        let settled = await waitUntil { await lifecycle.pendingInterruptibleCount == 0 }
        XCTAssertTrue(settled)
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [])
    }

    // MARK: Shutdown

    func testShutdownIsIdempotentAndTouchesAnIdleCoreNever() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.shutdown()
        try await lifecycle.shutdown(timeout: 1)
        XCTAssertEqual(core.commandCalls, [])

        try await lifecycle.start(MockCore.configuration())
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await lifecycle.shutdown(timeout: 5) }
            }
        }
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop], "concurrent shutdowns must stop the core once")
    }

    func testShutdownInterruptsAStartInFlight() async throws {
        let core = MockCore()
        core.setHonoursCancellation(true)
        core.setDelay(milliseconds: 5_000, for: .start)
        let lifecycle = CoreLifecycle(core: core)

        let starter = Task { () -> CoreError? in
            do {
                try await lifecycle.start(MockCore.configuration())
                return nil
            } catch {
                return error as? CoreError
            }
        }
        let reachedStarting = await waitUntil { await lifecycle.state == .starting }
        XCTAssertTrue(reachedStarting)

        let began = Date()
        try await lifecycle.shutdown(timeout: 3)
        XCTAssertLessThan(elapsedMilliseconds(since: began), 3_000, "shutdown waited for the slow start")
        let startError = await starter.value
        XCTAssertEqual(startError, .cancelled(operation: .start))

        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        let history = await lifecycle.history
        XCTAssertEqual(history.map { $0.event }, [.start, .startFailed, .stop, .stopSucceeded])
    }

    func testShutdownAfterAFailedStopCanBeRepeated() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setError(MockCore.Failure("busy"), for: .stop)
        await assertThrows(.operationFailed(operation: .stop, message: "busy")) {
            try await lifecycle.shutdown()
        }
        var state = await lifecycle.state
        XCTAssertEqual(state, .failed)

        core.setError(nil, for: .stop)
        try await lifecycle.shutdown()
        state = await lifecycle.state
        XCTAssertEqual(state, .idle)
    }

    func testStartIssuedAfterShutdownStillRuns() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 30, for: .stop)
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())

        async let down: Void = lifecycle.shutdown()
        let stopping = await waitUntil { await lifecycle.state == .stopping }
        XCTAssertTrue(stopping)
        // Submitted after the shutdown: it is a new request, not a victim.
        try await lifecycle.start(MockCore.configuration())
        try await down
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(core.commandCalls, [.start, .stop, .start])
    }

    // MARK: Stress

    func testConcurrentStartStopShutdownStress() async throws {
        let rounds = 40
        var startsThatReachedTheCore = 0
        var stopsThatReachedTheCore = 0
        for round in 0..<rounds {
            let core = MockCore()
            core.setHonoursCancellation(round % 2 == 0)
            core.setDelay(milliseconds: UInt64(1 + round % 4), for: .start)
            core.setDelay(milliseconds: UInt64(round % 3), for: .stop)
            core.setDelay(milliseconds: 1, for: .reload)
            let lifecycle = CoreLifecycle(core: core, historyLimit: 10_000)

            await withTaskGroup(of: Void.self) { group in
                for number in 0..<24 {
                    group.addTask {
                        switch (number + round) % 8 {
                        case 0, 1:
                            _ = try? await lifecycle.start(MockCore.configuration())
                        case 2:
                            _ = try? await lifecycle.start(MockCore.configuration(), timeout: 0.002)
                        case 3:
                            _ = try? await lifecycle.stop()
                        case 4:
                            _ = try? await lifecycle.shutdown()
                        case 5:
                            _ = try? await lifecycle.reload(MockCore.configuration(), timeout: 0.002)
                        case 6:
                            _ = await lifecycle.deliver(.memoryPressure(.warning), timeout: 0.01)
                        default:
                            let cancelled = Task { try await lifecycle.start(MockCore.configuration()) }
                            await Task.yield()
                            cancelled.cancel()
                            _ = try? await cancelled.value
                        }
                    }
                }
            }

            // Whatever the interleaving was, a final shutdown must reach
            // `idle` with every operation accounted for.
            try await lifecycle.shutdown(timeout: 10)
            let drained = await waitUntil { await lifecycle.pendingInterruptibleCount == 0 }
            XCTAssertTrue(drained, "round \(round): operations still registered")
            let state = await lifecycle.state
            XCTAssertEqual(state, .idle, "round \(round)")
            // 0 when every command of the round was cancelled before its turn.
            XCTAssertLessThanOrEqual(core.maximumConcurrentCommands, 1, "round \(round): core operations overlapped")
            startsThatReachedTheCore += core.commandCalls.filter { $0 == .start }.count
            stopsThatReachedTheCore += core.commandCalls.filter { $0 == .stop }.count

            let history = await lifecycle.history
            assertLegalChain(history, endsIn: .idle)
            let commands = history.filter { CoreLifecycleTable.commands.contains($0.event) }.count
            XCTAssertEqual(commands * 2, history.count, "round \(round): a command has no outcome")
            XCTAssertEqual(commands, core.commandCalls.count, "round \(round)")
        }
        // The rounds must have exercised the core, not only the queue.
        // (How often depends on scheduling: about one start in every second
        // round survives the shutdowns racing with it.)
        XCTAssertGreaterThan(startsThatReachedTheCore, 0)
        XCTAssertGreaterThan(stopsThatReachedTheCore, 0)
    }

    func testStressWithACoreThatIgnoresCancellation() async throws {
        let core = MockCore()
        core.setDelay(milliseconds: 4, for: .start)
        core.setDelay(milliseconds: 2, for: .stop)
        let lifecycle = CoreLifecycle(core: core, historyLimit: 10_000)

        // Starts that give up at different moments: before their turn, inside
        // the core, or never; shutdowns that give up early or wait.
        let timeouts: [TimeInterval?] = [nil, 0.003, 0.02, 0.001]
        await withTaskGroup(of: Void.self) { group in
            for number in 0..<120 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(number) * 300_000)
                    if number % 2 == 0 {
                        _ = try? await lifecycle.start(MockCore.configuration(), timeout: timeouts[(number / 2) % 4])
                    } else {
                        _ = try? await lifecycle.shutdown(timeout: timeouts[(number / 2) % 4])
                    }
                }
            }
        }
        try await lifecycle.shutdown(timeout: 30)
        let state = await lifecycle.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        let history = await lifecycle.history
        assertLegalChain(history, endsIn: .idle)
        // How many starts get through depends on scheduling (between 2 and
        // a dozen in practice); at least one must, or nothing was exercised.
        XCTAssertGreaterThanOrEqual(core.commandCalls.filter { $0 == .start }.count, 1, "the stress never reached the core")
        // A start whose caller gave up is never recorded as a success:
        // every success in the history belongs to a caller that was told so.
        let abandoned = history.filter { $0.event == .startFailed }.count
        let succeeded = history.filter { $0.event == .startSucceeded }.count
        XCTAssertEqual(abandoned + succeeded, core.commandCalls.filter { $0 == .start }.count)
    }

    // MARK: System events

    func testSystemEventsReachOnlyARunningCore() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        var delivered = await lifecycle.deliver(.willSleep)
        XCTAssertFalse(delivered)

        try await lifecycle.start(MockCore.configuration())
        delivered = await lifecycle.deliver(.willSleep, timeout: 5)
        XCTAssertTrue(delivered)
        delivered = await lifecycle.deliver(.memoryPressure(.critical), timeout: 5)
        XCTAssertTrue(delivered)
        delivered = await lifecycle.deliver(.didWake)
        XCTAssertTrue(delivered)
        XCTAssertEqual(core.receivedEvents, [.willSleep, .memoryPressure(.critical), .didWake])

        try await lifecycle.stop()
        delivered = await lifecycle.deliver(.didWake)
        XCTAssertFalse(delivered)
        XCTAssertEqual(core.receivedEvents.count, 3)
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
    }

    func testSystemEventBehindAStuckOperationIsDroppedAtItsDeadline() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        try await lifecycle.start(MockCore.configuration())
        core.setHang(for: .stop)
        let stopper = Task { try await lifecycle.stop() }
        let stopping = await waitUntil { await lifecycle.state == .stopping }
        XCTAssertTrue(stopping)

        let began = Date()
        let delivered = await lifecycle.deliver(.willSleep, timeout: 0.05)
        XCTAssertFalse(delivered)
        XCTAssertLessThan(elapsedMilliseconds(since: began), 3_000, "sleep handling must not wait for a stuck engine")

        core.releaseHang(for: .stop)
        try await stopper.value
        let drained = await waitUntil { await lifecycle.pendingInterruptibleCount == 0 }
        XCTAssertTrue(drained)
        XCTAssertEqual(core.receivedEvents, [])
    }

    func testDefaultSystemEventHandlerIsANoOp() async {
        struct PlainCore: NetworkCore {
            let descriptor = CoreDescriptor(id: "plain", displayName: "Plain", version: "1", capabilities: .none)
            func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport { .valid }
            func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {}
            func stop() async throws {}
            func reload(_ configuration: CoreConfiguration) async throws {}
            func statistics() async throws -> CoreStatistics { CoreStatistics(capturedAt: Date()) }
            func health() async -> CoreHealth { CoreHealth(status: .healthy, checkedAt: Date()) }
        }
        let lifecycle = CoreLifecycle(core: PlainCore())
        try? await lifecycle.start(CoreConfiguration(coreID: "plain", format: "json", payload: Data("{}".utf8)))
        let delivered = await lifecycle.deliver(.memoryPressure(.warning), timeout: 5)
        XCTAssertTrue(delivered)
    }

    // MARK: Observers

    func testObserverIsRemovedWhenItsConsumerIsCancelled() async throws {
        let lifecycle = CoreLifecycle(core: MockCore())
        let consumer = Task {
            for await _ in await lifecycle.stateUpdates() {}
        }
        let registered = await waitUntil { await lifecycle.observerCount == 1 }
        XCTAssertTrue(registered)
        consumer.cancel()
        await consumer.value
        let removed = await waitUntil { await lifecycle.observerCount == 0 }
        XCTAssertTrue(removed, "a cancelled consumer left its registration behind")
    }

    func testObserverIsRemovedWhenTheStreamIsDropped() async throws {
        let lifecycle = CoreLifecycle(core: MockCore())
        do {
            _ = await lifecycle.stateUpdates()
        }
        let removed = await waitUntil { await lifecycle.observerCount == 0 }
        XCTAssertTrue(removed)
    }

    func testStreamEndsWhenTheLifecycleGoesAway() async throws {
        var lifecycle: CoreLifecycle? = CoreLifecycle(core: MockCore())
        let stream = await lifecycle!.stateUpdates()
        lifecycle = nil
        let consumer = Task { () -> [CoreLifecycleState] in
            var seen: [CoreLifecycleState] = []
            for await state in stream { seen.append(state) }
            return seen
        }
        let seen = await consumer.value
        XCTAssertEqual(seen, [.idle], "the stream must end instead of hanging its consumer")
    }

    func testManyObserversSeeTheSameOrderedStates() async throws {
        let core = MockCore()
        let lifecycle = CoreLifecycle(core: core)
        var consumers: [Task<[CoreLifecycleState], Never>] = []
        for _ in 0..<10 {
            let stream = await lifecycle.stateUpdates()
            consumers.append(Task {
                var seen: [CoreLifecycleState] = []
                for await state in stream {
                    seen.append(state)
                    if seen.count == 5 { break }
                }
                return seen
            })
        }
        try await lifecycle.start(MockCore.configuration())
        try await lifecycle.stop()
        for consumer in consumers {
            let seen = await consumer.value
            XCTAssertEqual(seen, [.idle, .starting, .running, .stopping, .idle])
        }
        let removed = await waitUntil { await lifecycle.observerCount == 0 }
        XCTAssertTrue(removed)
    }

    // MARK: Errors

    func testTimedOutError() {
        let error = CoreError.timedOut(operation: .stop, seconds: 5)
        XCTAssertEqual(error.code, "timed_out")
        XCTAssertEqual(error.description, "stop did not finish within 5.0 s")
        XCTAssertEqual(CoreError.normalise(error, during: .start), error)
    }
}

/// `CoreDeadline` on its own.
final class CoreDeadlineTests: XCTestCase {
    func testReturnsTheValueWhenInTime() async throws {
        let value = try await CoreDeadline.run(.statistics, timeout: 5) { 42 }
        XCTAssertEqual(value, 42)
        let unbounded = try await CoreDeadline.run(.statistics, timeout: nil) { "ok" }
        XCTAssertEqual(unbounded, "ok")
    }

    func testTimesOutEvenWhenTheBodyIgnoresCancellation() async throws {
        let began = Date()
        await assertThrows(.timedOut(operation: .statistics, seconds: 0.05)) {
            _ = try await CoreDeadline.run(.statistics, timeout: 0.05) { () -> Int in
                // Detached: unaffected by cancellation of the body's task.
                await Task.detached { try? await Task.sleep(nanoseconds: 1_500_000_000) }.value
                return 1
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0, "the caller waited for the body")
    }

    func testBodyIsCancelledAtTheDeadline() async throws {
        let observed = OnceGate<Bool>()
        await assertThrows(.timedOut(operation: .health, seconds: 0.03)) {
            _ = try await CoreDeadline.run(.health, timeout: 0.03) { () -> Int in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    observed.resolve(.success(false))
                } catch {
                    observed.resolve(.success(true))
                }
                return 1
            }
        }
        let sawCancellation = try await withCheckedThrowingContinuation { observed.install($0) }
        XCTAssertTrue(sawCancellation)
    }

    func testCallerCancellation() async throws {
        let task = Task { () -> CoreError? in
            do {
                _ = try await CoreDeadline.run(.reload, timeout: 30) { () -> Int in
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return 1
                }
                return nil
            } catch {
                return error as? CoreError
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let error = await task.value
        XCTAssertEqual(error, .cancelled(operation: .reload))
    }

    func testErrorsAreNormalised() async throws {
        await assertThrows(.operationFailed(operation: .statistics, message: "boom")) {
            _ = try await CoreDeadline.run(.statistics, timeout: 5) { () -> Int in
                throw MockCore.Failure("boom")
            }
        }
        await assertThrows(.notRunning(state: .idle)) {
            _ = try await CoreDeadline.run(.statistics, timeout: 5) { () -> Int in
                throw CoreError.notRunning(state: .idle)
            }
        }
    }

    func testZeroAndNegativeTimeoutsExpireAtOnce() async throws {
        for timeout in [0.0, -1.0] {
            await assertThrows(.timedOut(operation: .start, seconds: timeout)) {
                _ = try await CoreDeadline.run(.start, timeout: timeout) { () -> Int in
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return 1
                }
            }
        }
    }

    func testNonFiniteAndHugeTimeoutsMeanNoDeadline() {
        XCTAssertNil(CoreDeadline.nanoseconds(for: nil))
        XCTAssertNil(CoreDeadline.nanoseconds(for: .infinity))
        XCTAssertNil(CoreDeadline.nanoseconds(for: .nan))
        XCTAssertNil(CoreDeadline.nanoseconds(for: CoreDeadline.maximumSeconds + 1))
        XCTAssertEqual(CoreDeadline.nanoseconds(for: 1.5), 1_500_000_000)
        XCTAssertEqual(CoreDeadline.nanoseconds(for: -3), 0)
    }

    func testGateKeepsTheFirstResultOnly() async throws {
        let gate = OnceGate<Int>()
        XCTAssertTrue(gate.resolve(.success(1)))
        XCTAssertFalse(gate.resolve(.success(2)))
        XCTAssertFalse(gate.resolve(.failure(CoreError.cancelled(operation: .start))))
        let value = try await withCheckedThrowingContinuation { gate.install($0) }
        XCTAssertEqual(value, 1)
    }

    func testManyConcurrentDeadlinesAllResolveExactlyOnce() async throws {
        let outcomes = await withTaskGroup(of: Bool.self, returning: (ok: Int, late: Int).self) { group in
            for number in 0..<200 {
                group.addTask {
                    do {
                        _ = try await CoreDeadline.run(.statistics, timeout: 0.5) { () -> Int in
                            if number % 2 == 0 {
                                try await Task.sleep(nanoseconds: 60_000_000_000)
                            }
                            return number
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var ok = 0
            var late = 0
            for await result in group {
                if result { ok += 1 } else { late += 1 }
            }
            return (ok, late)
        }
        XCTAssertEqual(outcomes.ok + outcomes.late, 200)
        XCTAssertEqual(outcomes.late, 100, "exactly the slow half must time out")
    }
}
