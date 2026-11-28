// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
//
// The app's on-demand latency test while disconnected: a TCP connect to each server's address, at most
// `ConnectProbePlan.maximumServers` servers, `concurrency` at a time, each bounded by `timeoutSeconds`. It
// runs only when the user asks and ends when it is done; there is no background probing. While connected the
// engine measures through the tunnel instead (Xray observatory / Mihomo url-test), so this test is not offered.
//
// The number is the time until the TCP handshake completes: network distance to the server, without the
// proxy handshake. The UI labels it as such.

import Foundation
import Network
import ProfileLibrary

enum ConnectProbe {
    static func run(_ targets: [ConnectProbePlan.Target]) async -> [ConnectMeasurement] {
        var results: [ConnectMeasurement] = []
        await withTaskGroup(of: ConnectMeasurement.self) { group in
            var pending = targets[...]
            func launch() {
                guard let target = pending.popFirst() else { return }
                group.addTask { await measure(target) }
            }
            for _ in 0..<ConnectProbePlan.concurrency { launch() }
            while let result = await group.next() {
                results.append(result)
                launch()
            }
        }
        return results
    }

    private static func measure(_ target: ConnectProbePlan.Target) async -> ConnectMeasurement {
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            return ConnectMeasurement(tag: target.tag, milliseconds: nil, at: Date())
        }
        let parameters = NWParameters.tcp
        // The test must not go through our own tunnel if the system still routes through it.
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: parameters)
        let outcome = ProbeOutcome()
        let started = DispatchTime.now().uptimeNanoseconds
        let queue = DispatchQueue(label: "probe")
        let milliseconds: Int? = await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    outcome.finish(Int(elapsed))
                case .failed, .cancelled:
                    outcome.finish(nil)
                case .waiting:
                    // No route or refused: not reachable now.
                    outcome.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + ConnectProbePlan.timeoutSeconds) {
                outcome.finish(nil)
            }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return ConnectMeasurement(tag: target.tag, milliseconds: milliseconds, at: Date())
    }
}

/// Resumes the continuation exactly once, whichever of ready, failure or timeout comes first. All calls
/// happen on the probe's serial queue.
private final class ProbeOutcome: @unchecked Sendable {
    var continuation: CheckedContinuation<Int?, Never>?

    func finish(_ value: Int?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
