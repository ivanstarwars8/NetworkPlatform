// The registration point of the app's screens (Documentation/Design/DESIGN.md §6). Foundation only: the
// visibility rules are unit-tested on Linux (Packages/DesignSystem/Tests/DesignSystemTests/AppShell links this
// file). The SwiftUI side — which view a destination opens — is AppDestination+View.swift.
//
// Adding a screen: put its views in Features/<Name>/, add a case here with its level and area, and map the case
// to its view in AppDestination+View.swift. A case exists only together with a working screen: the enum is the
// list of what the user can open, so nothing unfinished is ever shown.

import Foundation

/// The three levels of the specification. A level shows its own screens and those of the levels below it;
/// screens of higher levels are hidden, never shown disabled.
enum ExperienceLevel: String, CaseIterable, Comparable, Sendable {
    /// Connect, profile, speed, tunnel state.
    case basic
    /// Servers, groups, rules, DNS, statistics.
    case advanced
    /// Route simulator, toolbox, analyser, engine diagnostics, performance.
    case pro

    /// UserDefaults key of the chosen level.
    static let storageKey = "experienceLevel"

    var title: String {
        switch self {
        case .basic: return "Обычный"
        case .advanced: return "Расширенный"
        case .pro: return "Профи"
        }
    }

    var summary: String {
        switch self {
        case .basic: return "Подключение, профили и скорость."
        case .advanced: return "Серверы, группы, правила, DNS и статистика."
        case .pro: return "Инструменты для сетевых инженеров: диагностика движка."
        }
    }

    private var rank: Int {
        switch self {
        case .basic: return 0
        case .advanced: return 1
        case .pro: return 2
        }
    }

    static func < (lhs: ExperienceLevel, rhs: ExperienceLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Levels the user can choose: the basic level and every level that adds at least one screen. A level
    /// that would change nothing is not offered.
    static var selectable: [ExperienceLevel] {
        allCases.filter { level in
            level == .basic || AppDestination.allCases.contains { $0.level == level }
        }
    }

    /// The level in effect for a stored value: unknown values fall back to basic; a stored level that is not
    /// selectable (no screens of its own yet) acts as the highest selectable level below it.
    static func effective(storedRawValue: String?) -> ExperienceLevel {
        let stored = storedRawValue.flatMap(ExperienceLevel.init(rawValue:)) ?? .basic
        return selectable.filter { $0 <= stored }.max() ?? .basic
    }
}

/// Top-level areas: the tabs on iPhone, the sidebar sections on iPad, Mac and Vision Pro.
enum AppArea: String, CaseIterable, Sendable {
    case connection
    case profiles
    case tools
    case settings

    var title: String {
        switch self {
        case .connection: return "Подключение"
        case .profiles: return "Профили"
        case .tools: return "Инструменты"
        case .settings: return "Настройки"
        }
    }

    /// SF Symbol of the tab.
    var systemImage: String {
        switch self {
        case .connection: return "power"
        case .profiles: return "list.bullet.rectangle"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }

    /// Destinations of this area visible at `level`, in declaration order.
    func destinations(at level: ExperienceLevel) -> [AppDestination] {
        AppDestination.visible(at: level).filter { $0.area == self }
    }

    /// Areas that have at least one visible destination; an empty area (Инструменты below Профи) is hidden.
    static func visible(at level: ExperienceLevel) -> [AppArea] {
        allCases.filter { !$0.destinations(at: level).isEmpty }
    }
}

/// Every screen the user can open. Only screens that exist and work are listed.
enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case connection
    case profiles
    case engineDiagnostics
    case settings

    var id: String { rawValue }

    /// The lowest level the screen is shown at.
    var level: ExperienceLevel {
        switch self {
        case .connection, .profiles, .settings: return .basic
        case .engineDiagnostics: return .pro
        }
    }

    var area: AppArea {
        switch self {
        case .connection: return .connection
        case .profiles: return .profiles
        case .engineDiagnostics: return .tools
        case .settings: return .settings
        }
    }

    var title: String {
        switch self {
        case .connection: return "Подключение"
        case .profiles: return "Профили"
        case .engineDiagnostics: return "Диагностика движка"
        case .settings: return "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "power"
        case .profiles: return "list.bullet.rectangle"
        case .engineDiagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
    }

    /// One line under the title in the tools list.
    var summary: String? {
        switch self {
        case .engineDiagnostics: return "Движок и почему он выбран, версии, память Go и расширения, горутины, ошибки."
        case .connection, .profiles, .settings: return nil
        }
    }

    static func visible(at level: ExperienceLevel) -> [AppDestination] {
        allCases.filter { $0.level <= level }
    }
}
