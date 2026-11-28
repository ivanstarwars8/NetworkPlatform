// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Shortcuts actions (App Intents): connect, disconnect, toggle, choose a profile, report the state. They run in the
// app's process (openAppWhenRun = false; the system launches the app in the background if needed) and act on the
// same TunnelController and ProfileLibraryModel as the windows (Shell/AppModel.swift), through the same paths as
// the connect control (Shell/ConnectionActions.swift). Users combine them with Shortcuts automations (joining a
// Wi-Fi network, a Focus turning on, a time of day) and on iOS 18 can put a shortcut into Control Center or on the
// Action button.
//
// Apple TV has no Shortcuts app: the intents are not built for tvOS. The first connection must be made in the app
// (the system asks for VPN permission, which a background action cannot show).

#if !os(tvOS)
import AppIntents
import DesignSystem
import Foundation
import TunnelAutomation

/// An error a shortcut shows to the user: what happened and what to do.
struct TunnelIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("\(message)")
    }
}

@MainActor
enum TunnelIntentActions {
    static var tunnel: TunnelController { AppModel.tunnel }
    static var library: ProfileLibraryModel { AppModel.library }

    /// Connects with the selected profile and waits (event-driven, at most 20 s) for the result.
    static func connect() async throws -> String {
        await tunnel.refresh()
        if tunnel.phase == .connected { return "Уже подключено." }
        guard tunnel.isInstalled else {
            throw TunnelIntentError(message: "VPN ещё не настроен. Откройте «Бык» и подключитесь один раз — система попросит разрешение.")
        }
        if let blocker = library.connectBlocker {
            throw TunnelIntentError(message: "\(blocker) Это делается в приложении «Бык».")
        }
        await tunnel.connect(using: library)
        if let error = library.lastError ?? tunnel.lastError {
            throw TunnelIntentError(message: error)
        }
        await tunnel.waitUntilSettled(.connected, seconds: 20)
        return outcome(expecting: .connected)
    }

    /// Stops the tunnel; on-demand is suspended until the next manual connect, as with the button.
    static func disconnect() async throws -> String {
        await tunnel.refresh()
        guard tunnel.isInstalled, tunnel.phase.action == .disconnect else { return "Уже отключено." }
        await tunnel.disconnect()
        await tunnel.waitUntilSettled(.disconnected, seconds: 10)
        return outcome(expecting: .disconnected)
    }

    static func toggle() async throws -> String {
        await tunnel.refresh()
        switch tunnel.phase.action {
        case .disconnect: return try await disconnect()
        default: return try await connect()
        }
    }

    /// Selects a profile. If the tunnel is running, it is restarted with the new profile.
    static func select(profileID: UUID) async throws -> String {
        await tunnel.refresh()
        guard let profile = library.profiles.first(where: { $0.id == profileID }) else {
            throw TunnelIntentError(message: "Такого профиля больше нет. Выберите профиль заново в настройках действия.")
        }
        let wasRunning = tunnel.phase.action == .disconnect
        if wasRunning {
            await tunnel.disconnect()
            await tunnel.waitUntilSettled(.disconnected, seconds: 10)
        }
        library.select(profile.id)
        if let error = library.lastError {
            throw TunnelIntentError(message: error)
        }
        guard wasRunning else { return "Выбран профиль «\(profile.name)». Он будет использован при следующем подключении." }
        let result = try await connect()
        return "Профиль «\(profile.name)». \(result)"
    }

    static func statusText() async -> String {
        await tunnel.refresh()
        var parts = [tunnel.phase.stateWord + "."]
        if let profile = library.selectedProfile {
            parts.append("Профиль «\(profile.name)».")
        }
        if tunnel.platform.offersOnDemand {
            parts.append(tunnel.onDemandStatus.shortTitle + ".")
        }
        return parts.joined(separator: " ")
    }

    private static func outcome(expecting goal: TunnelSettle.Goal) -> String {
        switch (goal, tunnel.phase) {
        case (.connected, .connected): return "Подключено."
        case (.disconnected, .disconnected), (.disconnected, .notConfigured): return "Отключено."
        case (.connected, .disconnected):
            let reason = tunnel.lastDisconnectError.map { " \($0)" } ?? ""
            return "Не подключилось.\(reason) Откройте «Бык», чтобы увидеть подробности."
        default:
            return "\(tunnel.phase.stateWord)… Состояние ещё меняется."
        }
    }
}

struct ConnectTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Подключить"
    static let description = IntentDescription("Подключает туннель с выбранным в «Быке» профилем.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await TunnelIntentActions.connect()))
    }
}

struct DisconnectTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Отключить"
    static let description = IntentDescription("Отключает туннель. Автоподключение приостанавливается до следующего подключения.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await TunnelIntentActions.disconnect()))
    }
}

struct ToggleTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Переключить подключение"
    static let description = IntentDescription("Подключает, если туннель отключён, и отключает, если подключён.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await TunnelIntentActions.toggle()))
    }
}

struct SelectProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Выбрать профиль"
    static let description = IntentDescription("Выбирает профиль. Если туннель работает, он переподключается с новым профилем.")
    static let openAppWhenRun = false

    @Parameter(title: "Профиль")
    var profile: ProfileEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Выбрать профиль \(\.$profile)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: try await TunnelIntentActions.select(profileID: profile.id)))
    }
}

struct TunnelStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Состояние подключения"
    static let description = IntentDescription("Сообщает, подключён ли туннель, какой профиль выбран и включено ли автоподключение.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = await TunnelIntentActions.statusText()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// A profile of the library, for the profile parameter. Only the identifier and the name leave the library.
struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Профиль"
    static let defaultQuery = ProfileEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        await MainActor.run {
            AppModel.library.profiles
                .filter { identifiers.contains($0.id) }
                .map { ProfileEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        await MainActor.run {
            AppModel.library.profiles.map { ProfileEntity(id: $0.id, name: $0.name) }
        }
    }
}

/// Phrases for Siri and the actions shown in Shortcuts without setup.
struct BykShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: ["Подключить \(.applicationName)", "Включить \(.applicationName)"],
            shortTitle: "Подключить",
            systemImageName: "power"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(),
            phrases: ["Отключить \(.applicationName)", "Выключить \(.applicationName)"],
            shortTitle: "Отключить",
            systemImageName: "power.dotted"
        )
        AppShortcut(
            intent: TunnelStatusIntent(),
            phrases: ["Состояние \(.applicationName)"],
            shortTitle: "Состояние",
            systemImageName: "info.circle"
        )
    }
}
#endif
