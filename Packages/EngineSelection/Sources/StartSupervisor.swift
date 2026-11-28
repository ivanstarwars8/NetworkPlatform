// Verified on Linux (Swift 5.10, swift test). What happens when a start fails: roll back to the profile's last
// known good configuration, or (Авто only) try the other engine once, within the engine-switch limits of
// AdaptiveBalancer (Documentation/Architecture/engine-choice.md, adaptive-selection.md).
//
// Inputs are tunnel states and the time; there is no latency, throughput or score input at all, so nothing
// measured can ever cause a tunnel restart. Every automatic retry follows a failed start, at most one per user
// action, and a failed retry ends the sequence: no loops.

import AdaptiveBalancer
import DomainModels
import Foundation
import ProfileLibrary

/// One start of the tunnel as the app requested it.
public struct StartAttempt: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Hashable, Sendable {
        /// The user pressed connect.
        case user
        /// Automatic return to the last known good configuration after a failed start.
        case rollback
        /// Automatic start with the other engine after a failed start (Авто only).
        case engineFallback
    }

    public var profileID: UUID
    public var engine: TunnelEngine
    /// SHA-256 (hex) of the compiled configuration: identifies exactly what was started.
    public var configurationDigest: String
    public var origin: Origin

    public init(profileID: UUID, engine: TunnelEngine, configurationDigest: String, origin: Origin) {
        self.profileID = profileID
        self.engine = engine
        self.configurationDigest = configurationDigest
        self.origin = origin
    }
}

/// The last configuration of a profile that started and stayed up through probation.
public struct LastKnownGood: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var engine: TunnelEngine
    public var configurationDigest: String
    /// The profile as stored when it worked: secret references only, never secrets.
    public var profile: Profile
    public var recordedAt: Date

    public init(profileID: UUID, engine: TunnelEngine, configurationDigest: String, profile: Profile, recordedAt: Date) {
        self.profileID = profileID
        self.engine = engine
        self.configurationDigest = configurationDigest
        self.profile = profile
        self.recordedAt = recordedAt
    }
}

/// The tunnel states the supervisor reacts to (a projection of `NEVPNStatus`).
public enum ObservedTunnelState: Hashable, Sendable {
    case connecting
    case connected
    case reasserting
    case disconnecting
    case disconnected
}

/// What the app should do.
public enum SupervisorAction: Hashable, Sendable {
    case none
    /// The attempt passed probation: record it as the profile's last known good.
    case confirmed(StartAttempt)
    /// Start again automatically.
    case retry(Retry, after: StartAttempt)
    /// The attempt failed and nothing more is tried automatically.
    case gaveUp(GiveUpReason, after: StartAttempt)
}

public enum Retry: Hashable, Sendable {
    case rollback(LastKnownGood)
    case switchEngine(to: TunnelEngine)
}

public enum GiveUpReason: Hashable, Sendable {
    /// The automatic retry itself failed.
    case retryFailed
    /// No last known good configuration and no other engine to try.
    case nothingToRetry
    /// The other engine would carry the profile, but the engine-switch limit is reached.
    case engineSwitchLimited(detail: String)
}

/// What the supervisor needs to know about the profile when a start fails.
public struct FailureContext: Hashable, Sendable {
    public var lastKnownGood: LastKnownGood?
    public var preference: EnginePreference
    /// The other engine, when it carries the profile completely. A fallback never loses features silently:
    /// a partial engine is not a fallback target.
    public var completeAlternative: TunnelEngine?

    public init(lastKnownGood: LastKnownGood?, preference: EnginePreference, completeAlternative: TunnelEngine?) {
        self.lastKnownGood = lastKnownGood
        self.preference = preference
        self.completeAlternative = completeAlternative
    }
}

public struct StartSupervisor: Sendable {
    /// Seconds a start must stay connected to count as good (AdaptiveBalancer `ProbationPolicy.window`).
    public let probationWindow: Double
    /// Limits of automatic engine switches (AdaptiveBalancer `EngineSwitchPolicy`: `minimumInterval` and
    /// `rateLimit`); `isEnabled == false` turns the fallback off.
    public let engineSwitch: EngineSwitchPolicy

    private enum Phase: Hashable, Sendable {
        case idle
        /// Requested; the system has not reported progress yet. A `disconnected` seen now is a stale
        /// notification from before the start (saving the VPN configuration emits some) and is ignored.
        case requested
        case starting
        case connected(since: Double)
    }

    public private(set) var attempt: StartAttempt?
    private var phase: Phase = .idle
    /// Monotonic times of automatic engine switches.
    private var engineSwitchTimes: [Double] = []

    public init(probationWindow: Double, engineSwitch: EngineSwitchPolicy) {
        self.probationWindow = max(0, probationWindow)
        self.engineSwitch = engineSwitch
    }

    /// Probation of the Wi-Fi policy and the engine-switch limits of the cellular one: the stricter rate
    /// limit, because the app does not know the path class when a start fails.
    public static var standard: StartSupervisor {
        StartSupervisor(
            probationWindow: SelectionPolicy.wifiDefault().probation.window,
            engineSwitch: SelectionPolicy.cellularDefault().engineSwitch
        )
    }

    /// A start was requested. `now` is monotonic seconds.
    public mutating func began(_ attempt: StartAttempt, at now: Double) {
        self.attempt = attempt
        phase = .requested
        if attempt.origin == .engineFallback {
            engineSwitchTimes.append(now)
        }
    }

    /// The user stopped the tunnel (or cancelled the start): nothing is retried and nothing is recorded.
    public mutating func userStopped() {
        attempt = nil
        phase = .idle
    }

    public mutating func observe(_ state: ObservedTunnelState, at now: Double, context: () -> FailureContext) -> SupervisorAction {
        guard let attempt = attempt else { return .none }
        switch state {
        case .connecting, .reasserting:
            if phase == .requested { phase = .starting }
            return .none
        case .connected:
            if phase == .requested || phase == .starting { phase = .connected(since: now) }
            return tick(at: now)
        case .disconnecting:
            return .none
        case .disconnected:
            if phase == .requested { return .none }
            if case let .connected(since) = phase, now - since >= probationWindow {
                // It worked; a later drop is not a start failure (and the confirmation was missed only
                // because no tick ran in time).
                self.attempt = nil
                phase = .idle
                return .confirmed(attempt)
            }
            self.attempt = nil
            phase = .idle
            return failure(of: attempt, at: now, context: context())
        }
    }

    /// Called once when the probation window may have elapsed (a one-shot timer, or the app becoming active).
    public mutating func tick(at now: Double) -> SupervisorAction {
        guard let attempt = attempt, case let .connected(since) = phase, now - since >= probationWindow else { return .none }
        self.attempt = nil
        phase = .idle
        return .confirmed(attempt)
    }

    private func failure(of attempt: StartAttempt, at now: Double, context: FailureContext) -> SupervisorAction {
        guard attempt.origin == .user else { return .gaveUp(.retryFailed, after: attempt) }
        if let good = context.lastKnownGood, good.profileID == attempt.profileID,
           good.configurationDigest != attempt.configurationDigest {
            return .retry(.rollback(good), after: attempt)
        }
        guard context.preference == .automatic, let other = context.completeAlternative, other != attempt.engine else {
            return .gaveUp(.nothingToRetry, after: attempt)
        }
        if let limit = engineSwitchBlocker(at: now) {
            return .gaveUp(.engineSwitchLimited(detail: limit), after: attempt)
        }
        return .retry(.switchEngine(to: other), after: attempt)
    }

    /// Why an automatic engine switch is not allowed now, or `nil`.
    func engineSwitchBlocker(at now: Double) -> String? {
        guard engineSwitch.isEnabled else { return "engine switching is disabled" }
        if let last = engineSwitchTimes.last, now - last < engineSwitch.minimumInterval {
            return "last engine switch \(Int(now - last)) s ago, minimum interval \(Int(engineSwitch.minimumInterval)) s"
        }
        let recent = engineSwitchTimes.filter { now - $0 < engineSwitch.rateLimit.window }.count
        if recent >= engineSwitch.rateLimit.maximumSwitches {
            return "\(recent) engine switches in the last \(Int(engineSwitch.rateLimit.window)) s, limit \(engineSwitch.rateLimit.maximumSwitches)"
        }
        return nil
    }
}

// MARK: - Russian copy

public extension SupervisorAction {
    /// The message shown after an automatic action, or `nil` when there is nothing to say.
    var russianNotice: String? {
        switch self {
        case .none, .confirmed:
            return nil
        case let .retry(.rollback(good), after: failed):
            if good.engine != failed.engine {
                return "\(failed.engine.displayName) не запустился. Возвращаю последнюю рабочую настройку профиля (\(good.engine.displayName))."
            }
            return "Новая настройка не запустилась. Возвращаю последнюю рабочую настройку профиля."
        case let .retry(.switchEngine(to: engine), after: failed):
            return "\(failed.engine.displayName) не запустился. Пробую \(engine.displayName): он поддерживает всё в профиле."
        case let .gaveUp(reason, after: failed):
            switch reason {
            case .retryFailed:
                return failed.origin == .rollback
                    ? "Последняя рабочая настройка тоже не запустилась. Проверьте сеть и профиль, затем подключитесь снова."
                    : "\(failed.engine.displayName) тоже не запустился. Проверьте сеть и профиль, затем подключитесь снова."
            case .nothingToRetry:
                return nil
            case .engineSwitchLimited:
                return "Движок недавно уже переключался автоматически, поэтому сейчас не переключаю. Подключитесь снова или выберите движок вручную."
            }
        }
    }
}
