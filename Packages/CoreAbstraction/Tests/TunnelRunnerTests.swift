// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
//
// Tests of Extensions/PacketTunnel/TunnelSession.swift (linked into this
// target next to this file): the order of engine and interface operations of
// a tunnel process, against `MockCore` and a fake interface.
import Foundation
import XCTest
@testable import CoreAbstraction

/// Stands in for the system side of a packet tunnel: records what happened
/// to the interface settings and whether the watchdog and the "wedged" hook
/// were used.
private final class FakeInterface: @unchecked Sendable {
    enum Event: Equatable {
        case apply
        case clear
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var applyError: Error?
    private var applyDelay: UInt64 = 0
    private var wedgedCalls = 0
    private var watchdogs = 0
    private var messages: [String] = []

    func setApplyError(_ error: Error?) {
        lock.lock()
        applyError = error
        lock.unlock()
    }

    func setApplyDelay(milliseconds: UInt64) {
        lock.lock()
        applyDelay = milliseconds * 1_000_000
        lock.unlock()
    }

    private func read<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var events: [Event] { read { recorded } }
    var wedgedCount: Int { read { wedgedCalls } }
    var watchdogCount: Int { read { watchdogs } }
    var log: [String] { read { messages } }

    /// `true` when settings are applied and not cleared since.
    var settingsInPlace: Bool { read { recorded.last == .apply } }

    func hooks() -> TunnelHostHooks {
        TunnelHostHooks(
            applySettings: { _ in
                let plan = self.read { () -> (Error?, UInt64) in
                    self.recorded.append(.apply)
                    return (self.applyError, self.applyDelay)
                }
                if plan.1 > 0 {
                    try? await Task.sleep(nanoseconds: plan.1)
                }
                if let error = plan.0 {
                    throw error
                }
            },
            clearSettings: {
                self.read { self.recorded.append(.clear) }
            },
            makeWatchdog: { lifecycle in
                self.read { self.watchdogs += 1 }
                return Task {
                    for await state in await lifecycle.stateUpdates() where state == .idle || state == .failed {
                        return
                    }
                }
            },
            engineWedged: {
                self.read { self.wedgedCalls += 1 }
            },
            log: { message in
                self.read { self.messages.append(message) }
            }
        )
    }
}

private let fastDeadlines = TunnelDeadlines(engineStart: 5, engineStop: 5, statistics: 1, systemEvent: 1, exitGrace: 0)

private func request(coreID: String = "mock", mtu: Int = 1500) -> TunnelStartRequest {
    TunnelStartRequest(
        coreID: coreID,
        format: "json",
        configuration: Data("{}".utf8),
        network: TunnelNetworkPlan(
            remoteAddress: "192.0.2.1",
            ipv4Address: "198.18.0.1",
            ipv4SubnetMask: "255.255.255.252",
            ipv6Address: nil,
            ipv6PrefixLength: nil,
            dnsServers: ["198.18.0.2"],
            mtu: mtu,
            routesAllIPv4: true,
            routesAllIPv6: false
        )
    )
}

// Free functions, so that tasks in the tests do not capture the test case.
private func start(
    _ session: TunnelSession,
    _ interface: FakeInterface,
    _ core: MockCore,
    deadlines: TunnelDeadlines = fastDeadlines,
    request startRequest: TunnelStartRequest = request()
) async throws {
    _ = try await TunnelRunner.start(session: session, deadlines: deadlines, hooks: interface.hooks()) {
        (startRequest, core)
    }
}

private func startError(
    _ session: TunnelSession,
    _ interface: FakeInterface,
    _ core: MockCore,
    deadlines: TunnelDeadlines = fastDeadlines,
    request startRequest: TunnelStartRequest = request()
) async -> Error? {
    do {
        try await start(session, interface, core, deadlines: deadlines, request: startRequest)
        return nil
    } catch {
        return error
    }
}

final class TunnelRunnerTests: XCTestCase {
    // MARK: Plain paths

    func testStartThenStop() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()

        try await start(session, interface, core)
        var lifecycle = await session.lifecycle
        let state = await lifecycle?.state
        XCTAssertEqual(state, .running)
        XCTAssertEqual(interface.events, [.apply])
        XCTAssertEqual(interface.watchdogCount, 1)
        XCTAssertEqual(core.startedOptions?.mtu, 1500)
        let coreID = await session.coreID
        XCTAssertEqual(coreID, "mock")

        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        lifecycle = await session.lifecycle
        XCTAssertNil(lifecycle)
        let active = await session.isActive
        XCTAssertFalse(active)
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        // On a normal stop the system removes the settings itself.
        XCTAssertEqual(interface.events, [.apply])
    }

    func testStopWithoutASessionDoesNothing() async {
        let session = TunnelSession()
        let interface = FakeInterface()
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        XCTAssertEqual(interface.events, [])
        XCTAssertEqual(interface.wedgedCount, 0)
    }

    func testSessionCanBeReusedAfterStop() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        for _ in 0..<3 {
            let core = MockCore()
            try await start(session, interface, core)
            await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
            XCTAssertEqual(core.commandCalls, [.start, .stop])
        }
        XCTAssertEqual(interface.events, [.apply, .apply, .apply])
    }

    // MARK: Rollback

    func testEngineFailureAfterSettingsWereAppliedRollsThemBack() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        core.setError(MockCore.Failure("no route"), for: .start)

        let error = await startError(session, interface, core)
        XCTAssertEqual(error as? CoreError, .operationFailed(operation: .start, message: "no route"))
        XCTAssertEqual(interface.events, [.apply, .clear], "settings of a failed start must be removed")
        XCTAssertFalse(interface.settingsInPlace)
        // The engine was cleaned up as well (stop after a failed start).
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(interface.watchdogCount, 0)
        let active = await session.isActive
        XCTAssertFalse(active)

        // And the process is usable again.
        let healthy = MockCore()
        try await start(session, interface, healthy)
        XCTAssertEqual(interface.events, [.apply, .clear, .apply])
    }

    func testSettingsFailureNeverStartsTheEngine() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        interface.setApplyError(MockCore.Failure("settings rejected"))
        let core = MockCore()

        let error = await startError(session, interface, core)
        XCTAssertNotNil(error)
        XCTAssertEqual(core.commandCalls, [], "the engine must not start without an interface")
        // Cleared although the call failed: it may have changed the interface.
        XCTAssertEqual(interface.events, [.apply, .clear])
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    func testInvalidPlanIsRefusedBeforeAnythingIsTouched() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        let error = await startError(session, interface, core, request: request(mtu: 12))
        XCTAssertEqual((error as? TunnelIPCError)?.code, .invalidNetworkPlan)
        XCTAssertEqual(interface.events, [])
        XCTAssertEqual(core.commandCalls, [])
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    func testPrepareFailureReleasesTheSession() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        do {
            _ = try await TunnelRunner.start(session: session, deadlines: fastDeadlines, hooks: interface.hooks()) {
                throw CoreError.coreNotRegistered("absent")
            }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CoreError, .coreNotRegistered("absent"))
        }
        XCTAssertEqual(interface.events, [])
        try await start(session, interface, MockCore())
    }

    func testEngineStartDeadlineRollsBack() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        core.setHonoursCancellation(true)
        core.setDelay(milliseconds: 10_000, for: .start)
        var deadlines = fastDeadlines
        deadlines.engineStart = 0.1

        let began = Date()
        let error = await startError(session, interface, core, deadlines: deadlines)
        XCTAssertEqual(error as? CoreError, .timedOut(operation: .start, seconds: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        XCTAssertEqual(interface.events, [.apply, .clear])
        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(interface.wedgedCount, 0)
    }

    // MARK: Overlap

    func testStopDuringEngineStartInterruptsItAndRollsBack() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        core.setHonoursCancellation(true)
        core.setDelay(milliseconds: 10_000, for: .start)

        let starter = Task { await startError(session, interface, core) }
        let inEngine = await waitUntil { core.commandCalls == [.start] }
        XCTAssertTrue(inEngine)

        let began = Date()
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        XCTAssertLessThan(Date().timeIntervalSince(began), 4, "stop waited for the slow start")
        let error = await starter.value
        XCTAssertEqual(error as? CoreError, .cancelled(operation: .start))

        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(core.maximumConcurrentCommands, 1)
        XCTAssertEqual(interface.events, [.apply, .clear])
        XCTAssertEqual(interface.watchdogCount, 0)
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    func testStopWhileSettingsAreBeingAppliedPreventsTheEngineStart() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        interface.setApplyDelay(milliseconds: 200)
        let core = MockCore()

        let starter = Task { await startError(session, interface, core) }
        let applying = await waitUntil { interface.events == [.apply] }
        XCTAssertTrue(applying)
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())

        let error = await starter.value
        XCTAssertEqual(error as? CoreError, .cancelled(operation: .start))
        XCTAssertEqual(core.commandCalls, [], "the engine started after a stop")
        XCTAssertEqual(interface.events, [.apply, .clear])
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    func testStopRightAfterTheEngineStartedStillWins() async throws {
        // The engine ignores cancellation and reports success after the stop
        // was requested: the session must not end up running.
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        core.setDelay(milliseconds: 150, for: .start)

        let starter = Task { await startError(session, interface, core) }
        let inEngine = await waitUntil { core.commandCalls == [.start] }
        XCTAssertTrue(inEngine)
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        let error = await starter.value
        XCTAssertNotNil(error)

        XCTAssertEqual(core.commandCalls, [.start, .stop])
        XCTAssertEqual(interface.events, [.apply, .clear])
        let lifecycle = await session.lifecycle
        XCTAssertNil(lifecycle)
    }

    func testSecondStartIsRefusedAndDisturbsNothing() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let first = MockCore()
        try await start(session, interface, first)

        let second = MockCore(id: "second")
        var prepared = false
        do {
            _ = try await TunnelRunner.start(session: session, deadlines: fastDeadlines, hooks: interface.hooks()) {
                prepared = true
                return (request(coreID: "second"), second)
            }
            XCTFail("a second start was accepted")
        } catch {
            XCTAssertEqual((error as? TunnelIPCError)?.code, .alreadyRunning)
        }
        XCTAssertFalse(prepared, "a refused start must not consume its request")
        XCTAssertEqual(second.commandCalls, [])
        XCTAssertEqual(interface.events, [.apply])
        let lifecycle = await session.lifecycle
        let state = await lifecycle?.state
        XCTAssertEqual(state, .running)
        let coreID = await session.coreID
        XCTAssertEqual(coreID, "mock")
    }

    func testStartDuringARollbackWaitsOutOrIsRefused() async throws {
        // While a failed start is still stopping its engine, another start
        // must not bring up a second engine.
        let session = TunnelSession()
        let interface = FakeInterface()
        let failing = MockCore()
        failing.setError(MockCore.Failure("x"), for: .start)
        failing.setDelay(milliseconds: 200, for: .stop)

        let starter = Task { await startError(session, interface, failing) }
        let unwinding = await waitUntil { failing.commandCalls == [.start, .stop] }
        XCTAssertTrue(unwinding)

        let second = MockCore(id: "second")
        let error = await startError(session, interface, second, request: request(coreID: "second"))
        XCTAssertEqual((error as? TunnelIPCError)?.code, .alreadyRunning)
        XCTAssertEqual(second.commandCalls, [])
        _ = await starter.value
        try await start(session, interface, second, request: request(coreID: "second"))
    }

    // MARK: Wedged engine

    func testEngineThatDoesNotStopWedgesTheProcess() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        try await start(session, interface, core)
        core.setHang(for: .stop)
        var deadlines = fastDeadlines
        deadlines.engineStop = 0.1

        let began = Date()
        await TunnelRunner.stop(session: session, deadlines: deadlines, hooks: interface.hooks())
        XCTAssertLessThan(Date().timeIntervalSince(began), 4, "stopTunnel must return at its deadline")
        XCTAssertEqual(interface.wedgedCount, 1)
        let wedged = await session.wedged
        XCTAssertTrue(wedged)
        XCTAssertTrue(interface.log.contains { $0.contains("timed_out") })

        // No engine may be started next to the stuck one.
        let next = MockCore()
        let error = await startError(session, interface, next)
        XCTAssertEqual((error as? TunnelIPCError)?.code, .engineWedged)
        XCTAssertEqual(next.commandCalls, [])
        core.releaseHang(for: .stop)
    }

    func testEngineStuckInStartWedgesTheProcessOnRollback() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        core.setHang(for: .start)
        var deadlines = fastDeadlines
        deadlines.engineStart = 0.05
        deadlines.engineStop = 0.05

        let error = await startError(session, interface, core, deadlines: deadlines)
        XCTAssertEqual(error as? CoreError, .timedOut(operation: .start, seconds: 0.05))
        XCTAssertEqual(interface.wedgedCount, 1)
        // The interface is released even though the engine is stuck.
        XCTAssertEqual(interface.events, [.apply, .clear])
        XCTAssertEqual(core.commandCalls, [.start], "the stuck engine was entered again")
        core.releaseHang(for: .start)
    }

    func testEngineStopErrorIsLoggedButDoesNotWedge() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        try await start(session, interface, core)
        core.setError(MockCore.Failure("SECRET-IN-ENGINE-ERROR"), for: .stop)
        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
        XCTAssertEqual(interface.wedgedCount, 0)
        XCTAssertEqual(interface.log.count, 1)
        let active = await session.isActive
        XCTAssertFalse(active)
    }

    // MARK: Memory pressure

    func testMemoryPressureIsForwardedOnceAtATime() async throws {
        let session = TunnelSession()
        let interface = FakeInterface()
        let core = MockCore()
        var delivered = await session.forwardMemoryPressure(.warning, timeout: 1)
        XCTAssertFalse(delivered, "nothing runs yet")

        try await start(session, interface, core)
        core.setDelay(milliseconds: 100, for: .systemEvent)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<20 {
                group.addTask { await session.forwardMemoryPressure(.critical, timeout: 5) }
            }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.filter { $0 }.count, 1, "a burst must reach the engine once")
        XCTAssertEqual(core.receivedEvents, [.memoryPressure(.critical)])

        delivered = await session.forwardMemoryPressure(.warning, timeout: 5)
        XCTAssertTrue(delivered, "the next notification after the burst goes through")
    }

    // MARK: Stress

    func testRandomStartsAndStopsNeverLeaveAnEngineOrSettingsBehind() async throws {
        for round in 0..<25 {
            let session = TunnelSession()
            let interface = FakeInterface()
            interface.setApplyDelay(milliseconds: UInt64(round % 3))
            let cores = (0..<6).map { index -> MockCore in
                let core = MockCore()
                core.setHonoursCancellation(index % 2 == 0)
                core.setDelay(milliseconds: UInt64(1 + (index + round) % 5), for: .start)
                core.setDelay(milliseconds: UInt64(index % 2), for: .stop)
                if (index + round) % 4 == 3 {
                    core.setError(MockCore.Failure("refused"), for: .start)
                }
                return core
            }

            let succeeded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for (index, core) in cores.enumerated() {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 1_000_000)
                        return await startError(session, interface, core) == nil
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 1_500_000)
                        await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())
                        return false
                    }
                }
                var count = 0
                for await result in group where result { count += 1 }
                return count
            }
            await TunnelRunner.stop(session: session, deadlines: fastDeadlines, hooks: interface.hooks())

            let active = await session.isActive
            XCTAssertFalse(active, "round \(round)")
            XCTAssertEqual(interface.wedgedCount, 0, "round \(round)")
            var startedEngines = 0
            for core in cores {
                XCTAssertEqual(core.maximumConcurrentCommands <= 1, true, "round \(round)")
                let calls = core.commandCalls
                // An engine that was entered was also stopped, exactly once.
                if calls.contains(.start) {
                    startedEngines += 1
                    XCTAssertEqual(calls, [.start, .stop], "round \(round)")
                } else {
                    XCTAssertEqual(calls, [], "round \(round)")
                }
            }
            // Every failed start cleared its settings; a start that
            // succeeded leaves them to the system, which removes them on stop.
            let applies = interface.events.filter { $0 == .apply }.count
            let clears = interface.events.filter { $0 == .clear }.count
            XCTAssertGreaterThanOrEqual(applies, startedEngines, "round \(round)")
            XCTAssertEqual(applies - clears, succeeded, "round \(round): a failed start kept its settings")
        }
    }
}
