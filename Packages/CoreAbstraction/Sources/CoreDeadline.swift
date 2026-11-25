// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation

/// A one-shot rendezvous between a waiting caller and whoever produces its
/// result first: the operation, a timer, or cancellation of the caller.
///
/// The first `resolve` wins; later ones are ignored and report `false`. The
/// result may arrive before the waiter does.
final class OnceGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    /// Hands the continuation over. Resumes it at once when the result is
    /// already known.
    func install(_ newContinuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let known = result {
            lock.unlock()
            newContinuation.resume(with: known)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    /// Returns `true` when this call decided the outcome.
    @discardableResult
    func resolve(_ newResult: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = newResult
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: newResult)
        return true
    }
}

/// Bounded waiting for work that may never finish.
///
/// Structured concurrency cannot express this: a task group waits for all of
/// its children, so a child that ignores cancellation (an engine call stuck
/// in foreign code) would hold the group, and the caller, forever. Here the
/// caller always returns when the deadline passes; the work is cancelled
/// cooperatively and left to finish on its own.
public enum CoreDeadline {
    /// The longest deadline honoured, in seconds. Anything larger, and any
    /// non-finite value, means "no deadline".
    public static let maximumSeconds: TimeInterval = 86_400

    /// Runs `body` and waits for it for at most `timeout` seconds.
    ///
    /// - Throws: `CoreError.timedOut` when the deadline passes first,
    ///   `CoreError.cancelled` when the calling task is cancelled first, and
    ///   otherwise whatever `body` throws, normalised to `CoreError`.
    ///
    /// In the first two cases the task running `body` is cancelled and
    /// detached from the caller: `body` must honour cancellation or be safe
    /// to abandon.
    public static func run<Value: Sendable>(
        _ operation: CoreOperation,
        timeout: TimeInterval?,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task<Value, Error> {
            do {
                return try await body()
            } catch {
                throw CoreError.normalise(error, during: operation)
            }
        }
        return try await value(of: task, operation: operation, timeout: timeout, interruptible: true)
    }

    /// Waits for `task` for at most `timeout` seconds.
    ///
    /// `interruptible` decides what the deadline and cancellation of the
    /// caller do. `true`: either of them ends the wait and cancels `task`.
    /// `false` (clean-up work such as stopping an engine): the deadline ends
    /// the wait but `task` is never cancelled, and cancellation of the caller
    /// is ignored.
    static func value<Value: Sendable>(
        of task: Task<Value, Error>,
        operation: CoreOperation,
        timeout: TimeInterval?,
        interruptible: Bool
    ) async throws -> Value {
        let gate = OnceGate<Value>()

        // Unstructured on purpose, see the type comment.
        Task<Void, Never> {
            gate.resolve(await task.result)
        }

        var timer: Task<Void, Never>?
        if let nanoseconds = nanoseconds(for: timeout), let seconds = timeout {
            timer = Task<Void, Never> {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                if gate.resolve(.failure(CoreError.timedOut(operation: operation, seconds: seconds))), interruptible {
                    task.cancel()
                }
            }
        }
        defer { timer?.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
            }
        } onCancel: {
            guard interruptible else { return }
            if gate.resolve(.failure(CoreError.cancelled(operation: operation))) {
                task.cancel()
            }
        }
    }

    /// `nil` means "wait without a deadline".
    static func nanoseconds(for timeout: TimeInterval?) -> UInt64? {
        guard let seconds = timeout, seconds.isFinite, seconds <= maximumSeconds else {
            return nil
        }
        return UInt64(max(0, seconds) * 1_000_000_000)
    }
}
