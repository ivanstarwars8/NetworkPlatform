// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
// (compiled and unit-tested on Linux only, see the note in TunnelMessages.swift)
//
// One reply to one app message, with a deadline.
//
// `NETunnelProviderSession.sendProviderMessage` takes a response handler and
// promises nothing about it: when the extension is not running, is stopping
// or dies mid-request, the handler may never be called. A continuation
// wrapped directly around that handler would then never resume, and the
// waiting task would hang forever.
//
// Intended use, on the caller's own executor (nothing non-Sendable crosses a
// task boundary):
//
//     let pending = TunnelPendingReply()
//     do {
//         try session.sendProviderMessage(data) { pending.fulfil($0) }
//     } catch {
//         pending.fail(TunnelIPCError(.sendFailed, ...))
//     }
//     let reply = try await pending.wait(timeout: TunnelIPC.defaultRequestTimeout)

import Foundation

final class TunnelPendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data?, TunnelIPCError>?
    private var continuation: CheckedContinuation<Data?, Error>?
    private var waited = false

    /// The response handler. Safe to call from any thread, any number of
    /// times, before or after `wait`; only the first outcome counts.
    func fulfil(_ data: Data?) {
        resolve(.success(data))
    }

    func fail(_ error: TunnelIPCError) {
        resolve(.failure(error))
    }

    /// `true` once an outcome (reply, failure, time-out or cancellation) is
    /// recorded.
    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    /// Waits for the outcome for at most `timeout` seconds.
    ///
    /// Throws `TunnelIPCError` with `.timedOut` when the deadline passes and
    /// with `.cancelled` when the calling task is cancelled; in both cases a
    /// reply that arrives later is dropped. May be called once; a second call
    /// throws `.malformedRequest`.
    func wait(timeout: TimeInterval) async throws -> Data? {
        lock.lock()
        let alreadyWaited = waited
        waited = true
        lock.unlock()
        guard !alreadyWaited else {
            throw TunnelIPCError(.malformedRequest, "a pending reply can be awaited once")
        }

        let seconds = timeout.isFinite ? min(max(0, timeout), 3_600) : 3_600
        let timer = Task<Void, Never> { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            self?.resolve(.failure(TunnelIPCError(.timedOut, "no reply within \(seconds) s")))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (newContinuation: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if let known = result {
                    lock.unlock()
                    newContinuation.resume(with: known.mapError { $0 as Error })
                    return
                }
                continuation = newContinuation
                lock.unlock()
            }
        } onCancel: {
            resolve(.failure(TunnelIPCError(.cancelled, "the request was cancelled")))
        }
    }

    private func resolve(_ newResult: Result<Data?, TunnelIPCError>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: newResult.mapError { $0 as Error })
    }
}
