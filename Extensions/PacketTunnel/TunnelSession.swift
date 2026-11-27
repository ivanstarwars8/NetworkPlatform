// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
//
// It imports only Foundation and CoreAbstraction and is also unit-tested,
// through a symbolic link in Packages/CoreAbstraction/Tests, on Linux and on
// the macOS CI runner (`swift test`), against a mock engine and a fake
// interface. It has never run inside an extension. It is meant to move into
// the `TunnelHost` package module (ADR-0004 §2.3).
//
// The order of operations of one tunnel process, without Network Extension:
// what happens to the engine and to the interface settings on start, on a
// failed start, on stop, and when these overlap. `PacketTunnelProvider`
// supplies the platform calls as `TunnelHostHooks`.

import CoreAbstraction
import Foundation

/// Deadlines in seconds. Limits of this project, not of the platform: the
/// time the system gives an extension to start or stop is not documented and
/// was not measured.
struct TunnelDeadlines: Sendable {
    /// The engine's own start, after the interface settings are applied.
    var engineStart: TimeInterval = 20
    /// The engine's stop. Kept short: the system terminates extensions that
    /// are slow to stop, at a moment it does not announce.
    var engineStop: TimeInterval = 5
    var statistics: TimeInterval = 2
    /// Sleep, wake and memory-pressure notifications.
    var systemEvent: TimeInterval = 2
    /// Between reporting a wedged engine and leaving the process, so that
    /// the completion of the start or stop call reaches the system.
    var exitGrace: TimeInterval = 0.5

    static let standard = TunnelDeadlines()
}

/// The platform side of a tunnel session. Not Sendable on purpose: the hooks
/// are called only from the task that passed them in.
struct TunnelHostHooks {
    /// Applies the interface settings (`setTunnelNetworkSettings`).
    var applySettings: (TunnelNetworkPlan) async throws -> Void
    /// Removes them again (`setTunnelNetworkSettings(nil)`).
    var clearSettings: () async throws -> Void
    /// Creates the task that takes the tunnel down when the engine fails.
    var makeWatchdog: (CoreLifecycle) -> Task<Void, Never>
    /// An engine call never returned: the process cannot host another
    /// engine and should be replaced.
    var engineWedged: () -> Void
    /// Receives codes and bounded messages, never configuration data.
    var log: (String) -> Void
}

/// The mutable state of one tunnel process. An actor, because the provider's
/// entry points, the watchdog and the memory-pressure handler run
/// concurrently.
///
/// A start owns a generation number. Everything a start does to the session
/// names its generation and is refused once a stop was requested, so a start
/// that lost the race cannot leave anything behind.
actor TunnelSession {
    private var generation: UInt64 = 0
    /// The generation that owns the session: a start in flight or a tunnel
    /// that is up. `nil` when the process hosts nothing.
    private var active: UInt64?
    private var startInFlight = false
    private var stopRequested = false
    private var settingsApplied = false
    private var pressureInFlight = false
    private var watchdog: Task<Void, Never>?

    private(set) var wedged = false
    private(set) var lifecycle: CoreLifecycle?
    private(set) var coreID: String?

    var isActive: Bool { active != nil }

    func beginStart() throws -> UInt64 {
        guard !wedged else {
            throw TunnelIPCError(.engineWedged, "a previous engine call never returned")
        }
        guard active == nil else {
            throw TunnelIPCError(.alreadyRunning, "this tunnel process already hosts a session")
        }
        generation &+= 1
        active = generation
        startInFlight = true
        stopRequested = false
        settingsApplied = false
        return generation
    }

    /// Throws when the start of `generation` must not go on.
    func checkpoint(generation: UInt64) throws {
        guard active == generation, !stopRequested else {
            throw CoreError.cancelled(operation: .start)
        }
    }

    func attach(lifecycle: CoreLifecycle, coreID: String, generation: UInt64) throws {
        try checkpoint(generation: generation)
        self.lifecycle = lifecycle
        self.coreID = coreID
    }

    func markSettingsApplied(generation: UInt64) throws {
        try checkpoint(generation: generation)
        settingsApplied = true
    }

    func markRunning(generation: UInt64, watchdog newWatchdog: Task<Void, Never>) throws {
        try checkpoint(generation: generation)
        watchdog?.cancel()
        watchdog = newWatchdog
        startInFlight = false
    }

    /// What a failed start has to undo. The session stays owned by the
    /// generation until `finish`.
    func leftovers(generation: UInt64) -> (lifecycle: CoreLifecycle?, settingsApplied: Bool) {
        guard active == generation else { return (nil, false) }
        watchdog?.cancel()
        watchdog = nil
        return (lifecycle, settingsApplied)
    }

    func finish(generation: UInt64) {
        guard active == generation else { return }
        clear()
    }

    /// Cancels the watchdog and hands the lifecycle over for stopping.
    func beginStop() -> CoreLifecycle? {
        stopRequested = true
        watchdog?.cancel()
        watchdog = nil
        return lifecycle
    }

    /// Releases the session after a stop, unless a start is still unwinding
    /// (it releases the session itself, after its own rollback).
    func finishStop() {
        guard !startInFlight else { return }
        clear()
    }

    func markWedged() {
        wedged = true
    }

    /// At most one memory-pressure notification is in flight: under pressure
    /// is the wrong time to pile up tasks. Returns whether the engine got it.
    @discardableResult
    func forwardMemoryPressure(_ level: CoreMemoryPressureLevel, timeout: TimeInterval) async -> Bool {
        guard !pressureInFlight, let lifecycle = lifecycle else { return false }
        pressureInFlight = true
        let delivered = await lifecycle.deliver(.memoryPressure(level), timeout: timeout)
        pressureInFlight = false
        return delivered
    }

    private func clear() {
        watchdog?.cancel()
        watchdog = nil
        lifecycle = nil
        coreID = nil
        active = nil
        startInFlight = false
        settingsApplied = false
    }
}

/// Start and stop of a tunnel session.
///
/// Guarantees (each has a test):
/// - a start that fails after the interface settings were applied clears
///   them and brings the engine back to idle before it reports the failure;
/// - a stop that arrives during a start interrupts it; the start then fails
///   with `cancelled` and rolls itself back;
/// - a second start while a session exists is refused and disturbs nothing;
/// - no wait on the engine is unbounded; an engine that does not stop in
///   time marks the process as wedged, and no later start is accepted.
enum TunnelRunner {
    /// Starts a session. `prepare` runs after the session is reserved, so a
    /// refused duplicate start never consumes a hand-off file; it returns the
    /// request and the engine to run it.
    static func start(
        session: TunnelSession,
        deadlines: TunnelDeadlines,
        hooks: TunnelHostHooks,
        prepare: () throws -> (request: TunnelStartRequest, core: any NetworkCore)
    ) async throws -> TunnelStartRequest {
        let generation = try await session.beginStart()
        do {
            let prepared = try prepare()
            try await run(prepared.request, core: prepared.core, generation: generation, session: session, deadlines: deadlines, hooks: hooks)
            return prepared.request
        } catch {
            await rollBack(generation: generation, session: session, deadlines: deadlines, hooks: hooks)
            throw error
        }
    }

    private static func run(
        _ request: TunnelStartRequest,
        core: any NetworkCore,
        generation: UInt64,
        session: TunnelSession,
        deadlines: TunnelDeadlines,
        hooks: TunnelHostHooks
    ) async throws {
        try request.network.validate()
        let lifecycle = CoreLifecycle(core: core)
        // From here on a stop finds the lifecycle and can interrupt it.
        try await session.attach(lifecycle: lifecycle, coreID: request.coreID, generation: generation)

        // Marked before the call: a call that fails half-way may still have
        // changed the interface, and clearing settings twice is harmless.
        try await session.markSettingsApplied(generation: generation)
        try await hooks.applySettings(request.network)
        try await session.checkpoint(generation: generation)

        let configuration = CoreConfiguration(
            coreID: CoreIdentifier(request.coreID),
            format: request.format,
            payload: request.configuration
        )
        let options = CoreStartOptions(tunnelFileDescriptor: nil, mtu: request.network.mtu, memoryLimitBytes: nil)
        try await lifecycle.start(configuration, options: options, timeout: deadlines.engineStart)
        if let selection = request.groupSelection {
            // The user's server, pinned before the start completes. A failure fails the start: running on
            // another server than the one chosen would be a silent change of route.
            try await CoreDeadline.run(.statistics, timeout: deadlines.statistics) {
                try await lifecycle.selectGroupMember(group: selection.group, member: selection.member)
            }
        }

        // The session refuses this when a stop arrived in the meantime; the
        // start then fails and is rolled back.
        let watchdog = hooks.makeWatchdog(lifecycle)
        do {
            try await session.markRunning(generation: generation, watchdog: watchdog)
        } catch {
            watchdog.cancel()
            throw error
        }
    }

    /// Undoes a failed start: engine first, then the interface.
    private static func rollBack(
        generation: UInt64,
        session: TunnelSession,
        deadlines: TunnelDeadlines,
        hooks: TunnelHostHooks
    ) async {
        let leftovers = await session.leftovers(generation: generation)
        if let lifecycle = leftovers.lifecycle {
            await shutDown(lifecycle, session: session, deadlines: deadlines, hooks: hooks)
        }
        if leftovers.settingsApplied {
            do {
                try await hooks.clearSettings()
            } catch {
                hooks.log("clearing network settings failed: \(describe(error))")
            }
        }
        // Only now may another start begin: two engines never overlap.
        await session.finish(generation: generation)
    }

    /// Stops the session. Safe at any time, including during a start and
    /// when nothing runs.
    static func stop(session: TunnelSession, deadlines: TunnelDeadlines, hooks: TunnelHostHooks) async {
        // The watchdog goes first, so that a failing stop is not reported as
        // an engine that died on its own. A start in flight sees the request
        // at its next checkpoint, or is interrupted inside the engine by the
        // shutdown below, and rolls itself back.
        if let lifecycle = await session.beginStop() {
            await shutDown(lifecycle, session: session, deadlines: deadlines, hooks: hooks)
        }
        await session.finishStop()
    }

    /// Brings the engine to idle within the stop deadline.
    private static func shutDown(
        _ lifecycle: CoreLifecycle,
        session: TunnelSession,
        deadlines: TunnelDeadlines,
        hooks: TunnelHostHooks
    ) async {
        do {
            try await lifecycle.shutdown(timeout: deadlines.engineStop)
        } catch {
            hooks.log("engine stop failed: \(describe(error))")
            if case .timedOut = CoreError.normalise(error, during: .stop) {
                await session.markWedged()
                hooks.engineWedged()
            }
        }
    }

    /// Codes and bounded messages only.
    static func describe(_ error: Error) -> String {
        if let core = error as? CoreError { return "\(core.code): \(core.description)" }
        if let ipc = error as? TunnelIPCError { return ipc.summary }
        // Foreign errors may quote paths or data; only their type is kept.
        return String(describing: type(of: error))
    }
}
