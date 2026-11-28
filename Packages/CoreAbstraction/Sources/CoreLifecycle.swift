// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation

// MARK: - States, events, table

public enum CoreLifecycleState: String, Hashable, Sendable, Codable, CaseIterable {
    /// Nothing is running; the core holds no resources.
    case idle
    case starting
    case running
    case reloading
    case stopping
    /// An operation failed or the core exited on its own. The core may still
    /// hold resources: `stop` cleans up, `start` tries again.
    case failed
}

public enum CoreLifecycleEvent: String, Hashable, Sendable, Codable, CaseIterable {
    case start
    case startSucceeded
    case startFailed
    case reload
    case reloadSucceeded
    case reloadFailed
    case stop
    case stopSucceeded
    case stopFailed
    case unexpectedExit
}

/// The transition table as a pure function, so it can be tested exhaustively
/// and reused by code that only needs to know what is allowed.
public enum CoreLifecycleTable {
    /// The state after `event` in `state`, or `nil` when the event is illegal
    /// there.
    public static func nextState(from state: CoreLifecycleState, on event: CoreLifecycleEvent) -> CoreLifecycleState? {
        switch (state, event) {
        case (.idle, .start): return .starting
        case (.failed, .start): return .starting
        case (.starting, .startSucceeded): return .running
        case (.starting, .startFailed): return .failed
        case (.running, .reload): return .reloading
        case (.reloading, .reloadSucceeded): return .running
        case (.reloading, .reloadFailed): return .failed
        case (.running, .stop): return .stopping
        case (.failed, .stop): return .stopping
        case (.stopping, .stopSucceeded): return .idle
        case (.stopping, .stopFailed): return .failed
        case (.running, .unexpectedExit): return .failed
        default: return nil
        }
    }

    /// Events a caller may request (the others are produced internally).
    public static let commands: [CoreLifecycleEvent] = [.start, .reload, .stop]
}

public struct CoreLifecycleTransition: Hashable, Sendable {
    public let from: CoreLifecycleState
    public let event: CoreLifecycleEvent
    public let to: CoreLifecycleState
    public let at: Date
}

// MARK: - Lifecycle actor

/// Drives one `NetworkCore` through its lifecycle.
///
/// Guarantees:
/// - **Serialisation.** `start`, `stop`, `reload`, `shutdown`, `deliver` and
///   `reportUnexpectedExit` reach the core strictly one after another in the
///   order they were called, even though each of them suspends while the
///   core works. The actor itself is never blocked while the core works, so
///   `state`, `lastError`, `history` and `stateUpdates()` always answer.
/// - **Legality.** When its turn comes, an operation that the transition
///   table does not allow in the current state throws
///   `CoreError.illegalTransition` and changes nothing.
/// - **Normalised errors.** Everything thrown is a `CoreError`.
/// - **Bounded waiting.** Every command takes an optional `timeout`. When it
///   passes, the caller gets `CoreError.timedOut` and stops waiting. The core
///   is never entered concurrently to "break" a stuck call: the queue stays
///   blocked until the stuck call returns, and the owner of the process is
///   expected to terminate it (ADR-0001 §4, the emergency path).
/// - **Cancellation.** Cancelling the task that called `start` or `reload`,
///   or their deadline passing, makes the call throw at once and cancels the
///   operation: one that has not reached the core yet never will, one inside
///   the core is cancelled cooperatively. A `start` abandoned this way never
///   leaves the lifecycle in `running` by finishing late: its late success is
///   recorded as a failure, so that `shutdown` cleans the core up.
///   `stop` and `shutdown` are clean-up: nothing cancels them, a deadline
///   only ends the waiting.
///
/// After `start` threw `timedOut` or `cancelled` the caller must call
/// `shutdown`: the core may be in any state, including (when it finished at
/// the very instant the caller gave up) `running`.
public actor CoreLifecycle {
    public nonisolated let descriptor: CoreDescriptor

    public private(set) var state: CoreLifecycleState = .idle
    /// The error of the most recent failure; cleared by a successful start.
    public private(set) var lastError: CoreError?
    /// The most recent transitions, oldest first (bounded by `historyLimit`).
    public private(set) var history: [CoreLifecycleTransition] = []

    let core: any NetworkCore
    private let historyLimit: Int
    private let clock: @Sendable () -> Date
    private var tail: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<CoreLifecycleState>.Continuation] = [:]
    /// Cancellation handles of the interruptible operations that are queued
    /// or in flight, for `shutdown`.
    private var interruptible: [UInt64: @Sendable () -> Void] = [:]
    private var nextOperationID: UInt64 = 0

    public init(
        core: any NetworkCore,
        historyLimit: Int = 64,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.core = core
        self.descriptor = core.descriptor
        self.historyLimit = max(1, historyLimit)
        self.clock = clock
    }

    deinit {
        // A consumer that outlives the lifecycle must not wait forever.
        for continuation in observers.values {
            continuation.finish()
        }
    }

    // MARK: Commands

    /// Starts the core. Legal in `idle` and `failed`.
    ///
    /// The configuration is checked structurally first (right core, non-empty,
    /// within `CoreConfiguration.maximumPayloadBytes`); a rejected
    /// configuration throws without changing the state.
    ///
    /// `timeout` (seconds) bounds the whole wait, including the time spent
    /// queued behind other operations. `nil` waits without a deadline.
    public func start(
        _ configuration: CoreConfiguration,
        options: CoreStartOptions = .none,
        timeout: TimeInterval? = nil
    ) async throws {
        try await submit(.start, timeout: timeout, interruptible: true) { [self] in
            try await self.performStart(configuration, options: options)
        }
    }

    /// Stops the core. Legal in `running` and `failed`. Issued during a
    /// `start`, it waits for the start to finish; use `shutdown` to interrupt
    /// the start instead.
    public func stop(timeout: TimeInterval? = nil) async throws {
        try await submit(.stop, timeout: timeout, interruptible: false) { [self] in
            try await self.performStop()
        }
    }

    /// Brings the core to `idle` from whatever state it is in. Idempotent.
    ///
    /// Cancels every `start`, `reload` and `deliver` that is queued or in
    /// flight, then waits its turn and stops the core unless it is already
    /// idle. Throws when the core's `stop` fails (the state is then `failed`
    /// and `shutdown` may be called again) or when `timeout` passes.
    public func shutdown(timeout: TimeInterval? = nil) async throws {
        for cancel in interruptible.values {
            cancel()
        }
        try await submit(.stop, timeout: timeout, interruptible: false) { [self] in
            try await self.performShutdown()
        }
    }

    /// Replaces the configuration of a running core. Legal in `running`, and
    /// only for cores that declare `CoreFeature.hotReload`.
    public func reload(_ configuration: CoreConfiguration, timeout: TimeInterval? = nil) async throws {
        try await submit(.reload, timeout: timeout, interruptible: true) { [self] in
            try await self.performReload(configuration)
        }
    }

    /// Passes a system event to the core, serialised with the commands.
    /// Returns `true` when the core was running at its turn and received the
    /// event; `false` when it was not running, when `timeout` passed first or
    /// when the event was cancelled by `shutdown` or by the caller.
    @discardableResult
    public func deliver(_ event: CoreSystemEvent, timeout: TimeInterval? = nil) async -> Bool {
        let delivered = try? await submit(.systemEvent, timeout: timeout, interruptible: true) { [self] in
            try await self.performDelivery(event)
        }
        return delivered ?? false
    }

    /// Tells the lifecycle that the core stopped by itself (watchdog path).
    /// Returns `true` when this moved a running core to `failed`, `false`
    /// when the core was not running by the time the report was processed.
    @discardableResult
    public func reportUnexpectedExit(_ message: String) async -> Bool {
        let result = try? await submit(.health, timeout: nil, interruptible: false) { [self] () -> Bool in
            await self.performUnexpectedExit(message)
        }
        return result ?? false
    }

    // MARK: Queries

    /// Asks the core to check a configuration. Allowed in any state.
    public func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport {
        do {
            try CoreLifecycle.checkStructure(configuration, for: descriptor)
            return try await core.validate(configuration)
        } catch {
            throw CoreError.normalise(error, during: .validate)
        }
    }

    /// Statistics of a running core; throws `CoreError.notRunning` otherwise.
    ///
    /// Not serialised with the commands: a `stop` may begin while the core is
    /// still answering (see the `NetworkCore` contract). There is no deadline
    /// here; wrap the call in `CoreDeadline.run` when the core is not trusted
    /// to answer.
    public func statistics() async throws -> CoreStatistics {
        guard state == .running || state == .reloading else {
            throw CoreError.notRunning(state: state)
        }
        do {
            return try await core.statistics()
        } catch {
            throw CoreError.normalise(error, during: .statistics)
        }
    }

    /// The newest connections of a running core; throws `CoreError.notRunning` otherwise, and
    /// `unsupportedFeature(.connectionList)` for a core that keeps no list. Not serialised, no deadline (as
    /// `statistics`).
    public func connections(limit: Int) async throws -> CoreConnectionSnapshot {
        guard state == .running || state == .reloading else {
            throw CoreError.notRunning(state: state)
        }
        do {
            return try await core.connections(limit: limit)
        } catch {
            throw CoreError.normalise(error, during: .statistics)
        }
    }

    /// Health of the core. For a core that is not running the answer is
    /// synthesised from the lifecycle state instead of asking the core.
    public func health() async -> CoreHealth {
        switch state {
        case .running, .reloading:
            return await core.health()
        case .failed:
            return CoreHealth(
                status: .unhealthy,
                detail: lastError?.description ?? "the core failed",
                checkedAt: clock(),
                lastError: lastError
            )
        case .idle, .starting, .stopping:
            return CoreHealth(status: .unknown, detail: "the core is \(state.rawValue)", checkedAt: clock())
        }
    }

    /// A stream that yields the current state immediately and then every
    /// state change. A slow consumer keeps only the newest 64 states. The
    /// stream ends when the lifecycle is deallocated; the registration is
    /// dropped when the consumer stops iterating or is cancelled.
    public func stateUpdates() -> AsyncStream<CoreLifecycleState> {
        let id = UUID()
        var captured: AsyncStream<CoreLifecycleState>.Continuation?
        let stream = AsyncStream<CoreLifecycleState>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            captured = continuation
        }
        guard let continuation = captured else { return stream }
        continuation.yield(state)
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.removeObserver(id) }
        }
        return stream
    }

    /// Number of live `stateUpdates()` registrations (for leak tests).
    var observerCount: Int { observers.count }

    /// Number of interruptible operations queued or in flight (for tests).
    var pendingInterruptibleCount: Int { interruptible.count }

    // MARK: Serialisation

    /// Runs `operation` after every previously submitted operation has
    /// finished, and waits for it for at most `timeout` seconds.
    ///
    /// There is no suspension between reading and replacing `tail`, so the
    /// chain order is the order of calls. The waiting happens outside the
    /// actor (`CoreDeadline.value` is not isolated), so a stuck operation
    /// blocks the chain but never the actor.
    private func submit<T: Sendable>(
        _ kind: CoreOperation,
        timeout: TimeInterval?,
        interruptible isInterruptible: Bool,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // A caller that is already cancelled gets a definite answer: nothing
        // is queued and the core is not touched.
        if isInterruptible, Task.isCancelled {
            throw CoreError.cancelled(operation: kind)
        }
        let previous = tail
        let task = Task<T, Error> {
            if let previous = previous {
                await previous.value
            }
            return try await operation()
        }
        nextOperationID &+= 1
        let id = nextOperationID
        if isInterruptible {
            interruptible[id] = { task.cancel() }
        }
        tail = Task<Void, Never> { [weak self] in
            _ = await task.result
            await self?.forgetOperation(id)
        }
        return try await CoreDeadline.value(of: task, operation: kind, timeout: timeout, interruptible: isInterruptible)
    }

    private func forgetOperation(_ id: UInt64) {
        interruptible[id] = nil
    }

    // MARK: Operations (always run one at a time)

    private func performStart(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
        // Abandoned while it was queued: the core is not touched.
        if Task.isCancelled {
            throw CoreError.cancelled(operation: .start)
        }
        guard CoreLifecycleTable.nextState(from: state, on: .start) != nil else {
            throw CoreError.illegalTransition(from: state, event: .start)
        }
        try CoreLifecycle.checkStructure(configuration, for: descriptor)
        apply(.start)
        do {
            try await core.start(configuration, options: options)
        } catch {
            let normalised = CoreError.normalise(error, during: .start)
            lastError = normalised
            apply(.startFailed)
            throw normalised
        }
        if Task.isCancelled {
            // The caller gave up (deadline, cancellation, shutdown) while the
            // core kept working and finished. Nobody is waiting for this
            // start, so the engine must not be left running: `failed` makes
            // the following `shutdown` stop it.
            let abandoned = CoreError.cancelled(operation: .start)
            lastError = abandoned
            apply(.startFailed)
            throw abandoned
        }
        lastError = nil
        apply(.startSucceeded)
    }

    private func performStop() async throws {
        guard CoreLifecycleTable.nextState(from: state, on: .stop) != nil else {
            throw CoreError.illegalTransition(from: state, event: .stop)
        }
        apply(.stop)
        do {
            try await core.stop()
        } catch {
            let normalised = CoreError.normalise(error, during: .stop)
            lastError = normalised
            apply(.stopFailed)
            throw normalised
        }
        apply(.stopSucceeded)
    }

    private func performShutdown() async throws {
        switch state {
        case .idle:
            return
        case .running, .failed:
            try await performStop()
        case .starting, .reloading, .stopping:
            // Unreachable while operations are serial; kept as an error
            // instead of a trap because this runs inside a network extension.
            throw CoreError.illegalTransition(from: state, event: .stop)
        }
    }

    private func performReload(_ configuration: CoreConfiguration) async throws {
        if Task.isCancelled {
            throw CoreError.cancelled(operation: .reload)
        }
        guard CoreLifecycleTable.nextState(from: state, on: .reload) != nil else {
            throw CoreError.illegalTransition(from: state, event: .reload)
        }
        guard core.capabilities.features.contains(.hotReload) else {
            throw CoreError.unsupportedFeature(.hotReload)
        }
        try CoreLifecycle.checkStructure(configuration, for: descriptor)
        apply(.reload)
        do {
            try await core.reload(configuration)
        } catch {
            let normalised = CoreError.normalise(error, during: .reload)
            lastError = normalised
            apply(.reloadFailed)
            throw normalised
        }
        apply(.reloadSucceeded)
    }

    private func performDelivery(_ event: CoreSystemEvent) async throws -> Bool {
        if Task.isCancelled {
            throw CoreError.cancelled(operation: .systemEvent)
        }
        guard state == .running else {
            return false
        }
        await core.handleSystemEvent(event)
        return true
    }

    private func performUnexpectedExit(_ message: String) -> Bool {
        guard CoreLifecycleTable.nextState(from: state, on: .unexpectedExit) != nil else {
            return false
        }
        lastError = .unexpectedExit(message: CoreError.clip(message))
        apply(.unexpectedExit)
        return true
    }

    // MARK: Helpers

    /// Checks that do not need the core: the document is for this core, is
    /// not empty and is not oversized.
    static func checkStructure(_ configuration: CoreConfiguration, for descriptor: CoreDescriptor) throws {
        guard configuration.coreID == descriptor.id else {
            throw CoreError.configurationMismatch(expected: descriptor.id, actual: configuration.coreID)
        }
        guard !configuration.payload.isEmpty else {
            throw CoreError.invalidConfiguration(issues: [
                CoreValidationIssue(severity: .error, message: "configuration payload is empty"),
            ])
        }
        guard configuration.payload.count <= CoreConfiguration.maximumPayloadBytes else {
            throw CoreError.invalidConfiguration(issues: [
                CoreValidationIssue(
                    severity: .error,
                    message: "configuration payload is \(configuration.payload.count) bytes, "
                        + "the limit is \(CoreConfiguration.maximumPayloadBytes)"
                ),
            ])
        }
    }

    /// Applies an event that is legal by construction (commands are checked
    /// before they are applied, outcomes follow their command).
    private func apply(_ event: CoreLifecycleEvent) {
        guard let next = CoreLifecycleTable.nextState(from: state, on: event) else {
            assertionFailure("illegal internal transition \(state) + \(event)")
            return
        }
        history.append(CoreLifecycleTransition(from: state, event: event, to: next, at: clock()))
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        state = next
        for continuation in observers.values {
            continuation.yield(next)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
