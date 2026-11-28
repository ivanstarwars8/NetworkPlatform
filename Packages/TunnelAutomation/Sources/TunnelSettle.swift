// How a shortcut decides that a connect or disconnect request has finished: the tunnel state reported by
// NEVPNStatus (raw values, so this file needs no NetworkExtension and is tested on Linux).

import Foundation

public enum TunnelSettle {
    /// NEVPNStatus raw values: invalid 0, disconnected 1, connecting 2, connected 3, reasserting 4, disconnecting 5.
    public enum Goal: Sendable {
        case connected
        case disconnected
    }

    /// Whether waiting for `goal` is over at status `raw`: the goal is reached, or the tunnel ended up in the
    /// opposite final state (a failed start falls back to "disconnected").
    public static func isSettled(statusRawValue raw: Int, goal: Goal, sawTransition: Bool) -> Bool {
        switch goal {
        case .connected:
            if raw == 3 { return true }
            // "disconnected" right after the request may be the state before the start; only after a
            // transition (connecting) does it mean the start failed.
            return (raw == 1 || raw == 0) && sawTransition
        case .disconnected:
            return raw == 1 || raw == 0
        }
    }

    /// Whether `raw` is an intermediate state (connecting, reasserting, disconnecting).
    public static func isTransition(statusRawValue raw: Int) -> Bool {
        raw == 2 || raw == 4 || raw == 5
    }
}
