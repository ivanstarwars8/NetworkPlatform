// Verified on Linux (Swift 5.10, swift test). The engine a profile starts with: the user's choice per profile
// (Авто / Xray / Mihomo) and the automatic rule (Documentation/Architecture/engine-choice.md).

import Foundation
import ProfileLibrary

/// What the user chose for one profile.
public enum EnginePreference: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case xray
    case mihomo

    public var engine: TunnelEngine? {
        switch self {
        case .automatic: return nil
        case .xray: return .xray
        case .mihomo: return .mihomo
        }
    }

    public init(engine: TunnelEngine) {
        switch engine {
        case .xray: self = .xray
        case .mihomo: self = .mihomo
        }
    }
}

/// The engine a start uses and why.
public struct EngineDecision: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The build has one engine.
        case onlyEngineInBuild
        /// The user chose this engine for the profile.
        case chosenByUser
        /// Auto: every engine carries the profile; the one that last ran it successfully is kept.
        case keepsWorkingEngine
        /// Auto: every engine carries the profile and none ran it yet: the build's first engine.
        case defaultEngine
        /// Auto: only this engine carries the whole profile.
        case onlyCompleteEngine
        /// Auto: no engine carries the whole profile; this one leaves out the least. `losses` lists it.
        case fewestLosses
        /// No engine of the build can run the profile.
        case noEngineCanRun
        /// The user's engine cannot run the profile (or is not in this build).
        case chosenEngineCannotRun
    }

    /// `nil` when nothing can start.
    public var engine: TunnelEngine?
    public var preference: EnginePreference
    public var reason: Reason
    /// What the chosen engine leaves out. Never empty silently: the UI shows every entry before a start.
    public var losses: [FeatureLoss]
    /// Another engine of the build that carries more of the profile than the chosen one.
    public var betterAlternative: TunnelEngine?
    /// Support of every engine of the build, in the build's order.
    public var supports: [EngineSupport]

    public var canStart: Bool { engine != nil }
}

/// Decides per profile. Engine choice is a profile decision, never a latency race: the inputs are what the
/// compilers can express and which engine last ran the profile; measurements do not enter.
public struct EngineChooser: Sendable {
    /// The engines of this build, in preference order (`TunnelEngineCatalog` order).
    public let available: [TunnelEngine]

    public init(available: [TunnelEngine]) {
        self.available = available
    }

    /// - Parameters:
    ///   - supports: assessments of the available engines (others are ignored).
    ///   - lastWorkingEngine: the engine of the profile's last known good start, if any.
    public func decide(
        preference: EnginePreference,
        supports allSupports: [EngineSupport],
        lastWorkingEngine: TunnelEngine?
    ) -> EngineDecision {
        let supports = available.compactMap { engine in allSupports.first { $0.engine == engine } }
        func support(_ engine: TunnelEngine) -> EngineSupport? { supports.first { $0.engine == engine } }
        func decision(_ engine: TunnelEngine?, _ reason: EngineDecision.Reason) -> EngineDecision {
            let chosen = engine.flatMap(support)
            let chosenLevel = chosen?.level ?? .unsupported
            let chosenLosses = chosen?.losses.count ?? Int.max
            let better = supports.first { other in
                other.engine != engine && other.level != .unsupported
                    && (other.level > chosenLevel || (other.level == chosenLevel && other.losses.count < chosenLosses))
            }?.engine
            return EngineDecision(
                engine: engine, preference: preference, reason: reason,
                losses: chosen?.losses ?? [], betterAlternative: better, supports: supports
            )
        }

        if let wanted = preference.engine {
            guard let s = support(wanted), s.level != .unsupported else {
                return decision(nil, .chosenEngineCannotRun)
            }
            return decision(wanted, available.count == 1 ? .onlyEngineInBuild : .chosenByUser)
        }

        let runnable = supports.filter { $0.level != .unsupported }
        guard !runnable.isEmpty else { return decision(nil, .noEngineCanRun) }
        if available.count == 1 { return decision(runnable[0].engine, .onlyEngineInBuild) }

        let complete = runnable.filter { $0.level == .complete }
        if complete.count > 1 {
            if let sticky = lastWorkingEngine, complete.contains(where: { $0.engine == sticky }) {
                return decision(sticky, .keepsWorkingEngine)
            }
            return decision(complete[0].engine, .defaultEngine)
        }
        if let only = complete.first {
            return decision(only.engine, .onlyCompleteEngine)
        }
        // Nothing complete: the fewest losses; on a tie the engine that last worked, then build order.
        let fewest = runnable.map(\.losses.count).min() ?? 0
        let tied = runnable.filter { $0.losses.count == fewest }
        if let sticky = lastWorkingEngine, tied.contains(where: { $0.engine == sticky }) {
            return decision(sticky, .fewestLosses)
        }
        return decision(tied[0].engine, .fewestLosses)
    }
}

// MARK: - Russian copy

public extension TunnelEngine {
    /// Display name. Engine names are proper names and stay as they are.
    var displayName: String {
        switch self {
        case .xray: return "Xray"
        case .mihomo: return "Mihomo"
        }
    }
}

public extension EnginePreference {
    var title: String {
        switch self {
        case .automatic: return "Авто"
        case .xray: return "Xray"
        case .mihomo: return "Mihomo"
        }
    }
}

public extension FeatureLoss {
    /// One line for the user: what is affected and how. The compiler's detail is technical English and is
    /// shown after the Russian start of the sentence.
    var russianText: String {
        switch kind {
        case .unsupported: return "Не поддерживается — \(path): \(detail)"
        case .dropped: return "Будет пропущено — \(path): \(detail)"
        case .approximated: return "Будет передано приблизительно — \(path): \(detail)"
        case .excludedServer: return "Сервер \(path) не войдёт в настройку"
        }
    }
}

public extension EngineDecision {
    /// Why this engine, in one or two sentences; says what is lost when something is.
    var explanation: String {
        let name = engine?.displayName ?? ""
        let lossesClause = losses.isEmpty
            ? ""
            : " " + RussianCount.phrase(losses.count, one: "возможность профиля", few: "возможности профиля", many: "возможностей профиля")
                + " при этом не будет работать как задано — список ниже."
        switch reason {
        case .onlyEngineInBuild:
            return "В этой сборке один движок — \(name).\(lossesClause)"
        case .chosenByUser:
            var text = "Движок выбран вручную.\(lossesClause)"
            if let better = betterAlternative { text += " \(better.displayName) поддерживает этот профиль полнее." }
            return text
        case .keepsWorkingEngine:
            return "Оба движка поддерживают всё в профиле. Оставлен \(name): с ним профиль уже работал."
        case .defaultEngine:
            return "Оба движка поддерживают всё в профиле. Выбран \(name) — первый движок этой сборки."
        case .onlyCompleteEngine:
            let others = supports.filter { $0.engine != engine }
            let otherText = others.map { other -> String in
                other.level == .unsupported
                    ? "\(other.engine.displayName) не может запустить этот профиль"
                    : "\(other.engine.displayName) не поддерживает часть профиля"
            }.joined(separator: "; ")
            return "Выбран \(name): только он поддерживает всё в профиле (\(otherText))."
        case .fewestLosses:
            return "Ни один движок не поддерживает профиль целиком. Выбран \(name): он теряет меньше всего.\(lossesClause)"
        case .noEngineCanRun:
            return "Ни один движок этой сборки не может запустить профиль. Проверьте профиль или добавьте другой."
        case .chosenEngineCannotRun:
            var text = "\(preference.title) не может запустить этот профиль."
            if let better = betterAlternative { text += " Выберите «Авто» или \(better.displayName)." }
            return text
        }
    }
}

/// Russian plural forms (one/few/many) for this module's sentences. The app uses DesignSystem's `RussianPlural`;
/// this module does not depend on the design system.
enum RussianCount {
    static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let n = abs(count) % 100
        if (11...14).contains(n) { return many }
        switch n % 10 {
        case 1: return one
        case 2, 3, 4: return few
        default: return many
        }
    }

    static func phrase(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) \(form(count, one: one, few: few, many: many))"
    }
}
