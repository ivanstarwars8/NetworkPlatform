// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
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
/// - **Serialisation.** `start`, `stop`, `reload` and `reportUnexpectedExit`
///   run strictly one after another in the order they were called, even
///   though each of them suspends while the core works. A `stop` issued
///   during a slow `start` waits for the start to finish and then stops.
/// - **Legality.** When its turn comes, an operation that the transition
///   table does not allow in the current state throws
///   `CoreError.illegalTransition` and changes nothing.
/// - **Normalised errors.** Everything thrown is a `CoreError`.
///
/// Not provided here: time-outs. A core whose `start` or `stop` never returns
/// blocks the queue; the owner of the process is expected to enforce a
/// deadline (ADR-0001 §4: terminating the extension is the emergency path).
/// Cancelling the calling task does not interrupt an operation in progress.
public actor CoreLifecycle {
    public nonisolated let descriptor: CoreDescriptor

    public private(set) var state: CoreLifecycleState = .idle
    /// The error of the most recent failure; cleared by a successful start.
    public private(set) var lastError: CoreError?
    /// The most recent transitions, oldest first (bounded by `historyLimit`).
    public private(set) var history: [CoreLifecycleTransition] = []

    private let core: any NetworkCore
    private let historyLimit: Int
    private let clock: @Sendable () -> Date
    private var tail: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<CoreLifecycleState>.Continuation] = [:]

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

    // MARK: Commands

    /// Starts the core. Legal in `idle` and `failed`.
    ///
    /// The configuration is checked structurally first (right core, non-empty,
    /// within `CoreConfiguration.maximumPayloadBytes`); a rejected
    /// configuration throws without changing the state.
    public func start(_ configuration: CoreConfiguration, options: CoreStartOptions = .none) async throws {
        try await enqueue { [self] in
            try await self.performStart(configuration, options: options)
        }
    }

    /// Stops the core. Legal in `running` and `failed`.
    public func stop() async throws {
        try await enqueue { [self] in
            try await self.performStop()
        }
    }

    /// Replaces the configuration of a running core. Legal in `running`, and
    /// only for cores that declare `CoreFeature.hotReload`.
    public func reload(_ configuration: CoreConfiguration) async throws {
        try await enqueue { [self] in
            try await self.performReload(configuration)
        }
    }

    /// Tells the lifecycle that the core stopped by itself (watchdog path).
    /// Returns `true` when this moved a running core to `failed`, `false`
    /// when the core was not running by the time the report was processed.
    @discardableResult
    public func reportUnexpectedExit(_ message: String) async -> Bool {
        let result = try? await enqueue { [self] () -> Bool in
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
    /// state change. A slow consumer keeps only the newest 64 states.
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

    // MARK: Serialisation

    /// Runs `operation` after every previously enqueued operation has
    /// finished. There is no suspension between reading and replacing `tail`,
    /// so the chain order is the order of calls.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            if let previous = previous {
                await previous.value
            }
            return try await operation()
        }
        tail = Task<Void, Never> {
            _ = try? await task.value
        }
        return try await task.value
    }

    // MARK: Operations (always run one at a time)

    private func performStart(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
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

    private func performReload(_ configuration: CoreConfiguration) async throws {
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
