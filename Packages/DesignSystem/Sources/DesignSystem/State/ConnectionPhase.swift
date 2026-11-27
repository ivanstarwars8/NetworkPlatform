// What the connect control shows for each tunnel state. The tunnel state itself is the system's
// (`NEVPNStatus`); this file maps its raw value so that the mapping is testable on Linux, where
// NetworkExtension does not exist.

/// The phase the connect control (and the menu bar item, the tvOS dashboard) displays.
public enum ConnectionPhase: Equatable, Sendable, CaseIterable {
    /// No VPN configuration yet: the first connect asks the system for permission.
    case notConfigured
    case disconnected
    case connecting
    case connected
    /// The system is re-establishing the tunnel (network change).
    case reasserting
    case disconnecting

    /// Maps `NEVPNStatus.rawValue` (invalid 0, disconnected 1, connecting 2, connected 3, reasserting 4,
    /// disconnecting 5). An unknown future value is shown as disconnected with no action, which is the
    /// state that promises nothing.
    public init(vpnStatusRawValue raw: Int) {
        switch raw {
        case 0: self = .notConfigured
        case 1: self = .disconnected
        case 2: self = .connecting
        case 3: self = .connected
        case 4: self = .reasserting
        case 5: self = .disconnecting
        default: self = .disconnected
        }
    }

    /// The word under the horn, in the display face. Sentence case, plain verbs.
    public var stateWord: String {
        switch self {
        case .notConfigured, .disconnected: return "Отключено"
        case .connecting: return "Подключаю"
        case .connected: return "Подключено"
        case .reasserting: return "Восстанавливаю"
        case .disconnecting: return "Отключаю"
        }
    }

    /// What tapping the control does.
    public enum Action: Equatable, Sendable {
        case connect
        case disconnect
        /// The control is shown but cannot be pressed (the system is stopping the tunnel).
        case none
    }

    public var action: Action {
        switch self {
        case .notConfigured, .disconnected: return .connect
        case .connecting, .connected, .reasserting: return .disconnect
        case .disconnecting: return .none
        }
    }

    /// Short label of the action (accessibility, menu bar, tvOS).
    public var actionTitle: String? {
        switch action {
        case .connect: return "Подключить"
        case .disconnect: return self == .connected ? "Отключить" : "Отменить"
        case .none: return nil
        }
    }

    /// How much of the horn is filled with bronze, 0 … 1. Only `connected` is full: bronze means
    /// "the tunnel is working". The in-between values are positions, not progress measurements.
    public var hornFill: Double {
        switch self {
        case .notConfigured, .disconnected: return 0
        case .connecting, .reasserting: return 0.5
        case .connected: return 1
        case .disconnecting: return 0.2
        }
    }

    /// The fill breathes while the outcome is unknown (unless Reduce Motion is on).
    public var isWaiting: Bool {
        switch self {
        case .connecting, .reasserting, .disconnecting: return true
        case .notConfigured, .disconnected, .connected: return false
        }
    }

    /// Live speed is shown only while connected; the counters are not queried otherwise.
    public var showsThroughput: Bool { self == .connected }

    /// A line under the state word that explains what happens next, when there is something to say.
    public var hint: String? {
        switch self {
        case .notConfigured: return "При первом подключении система попросит разрешить VPN."
        case .reasserting: return "Сеть сменилась, туннель поднимается заново."
        case .disconnected, .connecting, .connected, .disconnecting: return nil
        }
    }
}
