// When automatic connection may actually be switched on in the system (NEVPNManager.isOnDemandEnabled).
//
// The user's choice (`AutomationSettings.connectOnDemand`) is not enough:
//
// - A tunnel started by the system carries no start request; the extension starts from its snapshot of the last
//   successful start. Until one manual connection succeeded there is no snapshot, and every automatic start would
//   fail and be retried by the system — so on-demand waits for the first successful connection.
// - With on-demand on, the system restarts a tunnel the user stopped. A manual disconnect therefore suspends
//   on-demand (first switched off, then the tunnel stopped); the next manual connect resumes it once the tunnel is
//   up. On-demand is not switched on before a manual start: the system could start the old snapshot first.
// - If on-demand is switched off outside the app (the VPN switch in system Settings does this), the app takes it
//   as a manual disconnect instead of switching it back on.

import Foundation

public struct OnDemandState: Codable, Equatable, Sendable {
    /// A manual connection reached "connected" since the VPN configuration was created.
    public var hasConnectedOnce: Bool
    /// The user stopped the tunnel (in the app, in a shortcut or in system Settings).
    public var suspendedByUser: Bool

    public init(hasConnectedOnce: Bool = false, suspendedByUser: Bool = false) {
        self.hasConnectedOnce = hasConnectedOnce
        self.suspendedByUser = suspendedByUser
    }

    /// The value for NEVPNManager.isOnDemandEnabled.
    public func systemEnabled(for settings: AutomationSettings, on platform: AutomationPlatform) -> Bool {
        status(for: settings, on: platform) == .active
    }

    public func status(for settings: AutomationSettings, on platform: AutomationPlatform) -> OnDemandStatus {
        guard platform.offersOnDemand, settings.connectOnDemand else { return .off }
        guard settings.connectsOnAnyNetwork(on: platform) else { return .noNetworkChosen }
        guard hasConnectedOnce else { return .waitingForFirstConnection }
        guard !suspendedByUser else { return .suspended }
        return .active
    }

    // MARK: Events

    /// A new VPN configuration was saved: the extension of this configuration has not started yet.
    public mutating func configurationCreated() {
        hasConnectedOnce = false
        suspendedByUser = false
    }

    /// The user asked to connect (app, menu bar, shortcut).
    public mutating func userConnected() {
        suspendedByUser = false
    }

    /// The user asked to disconnect.
    public mutating func userDisconnected() {
        suspendedByUser = true
    }

    /// The tunnel reached "connected".
    public mutating func tunnelConnected() {
        hasConnectedOnce = true
    }

    /// The configuration was read back from the system. If the app expected on-demand to be on and the system
    /// says it is off, someone switched it off outside the app: respect that.
    public mutating func reconcile(systemEnabled: Bool, settings: AutomationSettings, on platform: AutomationPlatform) {
        if !systemEnabled, self.systemEnabled(for: settings, on: platform) {
            suspendedByUser = true
        }
    }
}

public enum OnDemandStatus: String, Equatable, Sendable {
    case off
    /// On, but no network kind is chosen.
    case noNetworkChosen
    /// On, waits for the first successful manual connection.
    case waitingForFirstConnection
    /// On, paused by a manual disconnect until the next manual connect.
    case suspended
    /// On in the system.
    case active

    /// One line for the UI, or nil when there is nothing to say.
    public var explanation: String? {
        switch self {
        case .off, .active: return nil
        case .noNetworkChosen: return "Не выбрано ни одной сети — автоподключению не на чем срабатывать."
        case .waitingForFirstConnection: return "Включится после первого успешного подключения вручную."
        case .suspended: return "Приостановлено: вы отключились вручную. Включится снова при следующем подключении."
        }
    }

    /// Short state for the menu bar and for shortcuts.
    public var shortTitle: String {
        switch self {
        case .off: return "Автоподключение выключено"
        case .noNetworkChosen: return "Автоподключение: не выбраны сети"
        case .waitingForFirstConnection: return "Автоподключение ждёт первого подключения"
        case .suspended: return "Автоподключение приостановлено"
        case .active: return "Автоподключение включено"
        }
    }
}
