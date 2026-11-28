// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Автоподключение (level Обычный, area Настройки): when the system starts the tunnel by itself (on-demand rules),
// trusted Wi-Fi networks, all traffic through the tunnel (includeAllNetworks / excludeLocalNetworks), start at
// login on the Mac, and which Shortcuts actions exist. Every control maps to one system setting
// (Documentation/Architecture/automation.md); the mapping and the rules are in Packages/TunnelAutomation and in
// TunnelController. Nothing here polls: the screen shows the controller's published state.

import DesignSystem
import SwiftUI
import TunnelAutomation
#if os(macOS)
import ServiceManagement
#endif

struct AutomationScreen: View {
    @EnvironmentObject private var tunnel: TunnelController

    @State private var newNetwork = ""
    @State private var networkError: String?

    private var settings: AutomationSettings { tunnel.automation }
    private var platform: AutomationPlatform { tunnel.platform }

    var body: some View {
        List {
            if platform.offersOnDemand {
                onDemandSection
                if settings.connectOnDemand, platform.networkKinds.contains(.wifi) {
                    trustedSection
                }
            }
            if platform.offersTrafficLock {
                trafficLockSection
            }
            #if os(macOS)
            LaunchAtLoginSection()
            #endif
            if platform.offersShortcuts {
                shortcutsSection
            }
        }
        .bykGroupedList()
        .navigationTitle("Автоподключение")
    }

    // MARK: On-demand

    @ViewBuilder private var onDemandSection: some View {
        Section {
            Toggle(isOn: binding(\.connectOnDemand)) {
                Text("Подключаться автоматически").font(.bykBody)
            }
            .bykRow()
            if settings.connectOnDemand {
                ForEach(platform.networkKinds, id: \.self) { kind in
                    Toggle(isOn: binding(AutomationScreen.keyPath(for: kind))) {
                        Text(AutomationScreen.title(of: kind)).font(.bykBody)
                    }
                    .bykRow()
                }
            }
        } header: {
            SectionHeader("Автоподключение")
        } footer: {
            VStack(alignment: .leading, spacing: CGFloat(Spacing.xs)) {
                Footnote("Система сама поднимает туннель, когда устройство выходит в выбранную сеть. Используется профиль последнего успешного подключения; другой профиль начнёт работать после подключения вручную.")
                if let explanation = tunnel.onDemandStatus.explanation {
                    Footnote(explanation)
                }
                if settings.connectOnDemand {
                    Footnote("Если отключиться вручную, автоподключение приостановится до следующего подключения.")
                }
            }
        }
    }

    // MARK: Trusted networks

    @ViewBuilder private var trustedSection: some View {
        Section {
            ForEach(settings.trustedNetworks, id: \.self) { name in
                HStack {
                    Text(name).font(.bykBody)
                    Spacer()
                    #if os(macOS)
                    Button {
                        remove(name)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить сеть \(name)")
                    #endif
                }
                .bykRow()
            }
            .onDelete { offsets in
                var updated = settings
                updated.trustedNetworks.remove(atOffsets: offsets)
                tunnel.updateAutomation(updated)
            }

            HStack {
                TextField("Имя сети Wi-Fi", text: $newNetwork)
                    .font(.bykBody)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(addNetwork)
                Button("Добавить", action: addNetwork)
                    .disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .bykRow()

            if let networkError = networkError {
                MessageRow(.warning, networkError).bykRow()
            }

            if !settings.trustedNetworks.isEmpty {
                Toggle(isOn: binding(\.disconnectOnTrusted)) {
                    Text("Отключать туннель в этих сетях").font(.bykBody)
                }
                .bykRow()
            }
        } header: {
            SectionHeader("Доверенные сети Wi-Fi")
        } footer: {
            VStack(alignment: .leading, spacing: CGFloat(Spacing.xs)) {
                Footnote("В этих сетях туннель сам не поднимается. Имя вводится вручную, буква в букву: приложение не читает имя текущей сети.")
                if settings.disconnectOnTrusted {
                    Footnote("Пока вы в доверенной сети, подключиться вручную не получится — система сразу отключит туннель. Выключите это, если туннель иногда нужен и там.")
                }
            }
        }
    }

    private func addNetwork() {
        switch TrustedNetworks.adding(newNetwork, to: settings.trustedNetworks) {
        case let .success(list):
            var updated = settings
            updated.trustedNetworks = list
            tunnel.updateAutomation(updated)
            newNetwork = ""
            networkError = nil
        case let .failure(rejection):
            networkError = rejection.message
        }
    }

    private func remove(_ name: String) {
        var updated = settings
        updated.trustedNetworks.removeAll { $0 == name }
        tunnel.updateAutomation(updated)
    }

    // MARK: Traffic lock

    @ViewBuilder private var trafficLockSection: some View {
        Section {
            Toggle(isOn: binding(\.includeAllNetworks)) {
                Text("Весь трафик только через туннель").font(.bykBody)
            }
            .bykRow()
            if settings.includeAllNetworks {
                Toggle(isOn: binding(\.excludeLocalNetworks)) {
                    Text("Оставить доступ к локальной сети").font(.bykBody)
                }
                .bykRow()
            }
            if tunnel.trafficLockPending {
                MessageRow(.info, "Изменение применится, когда туннель отключится.").bykRow()
            }
        } header: {
            SectionHeader("Защита от утечек")
        } footer: {
            VStack(alignment: .leading, spacing: CGFloat(Spacing.xs)) {
                if settings.includeAllNetworks {
                    Footnote("Пока туннель не работает — отключён, переподключается или остановился с ошибкой, — интернет на устройстве недоступен. Чтобы вернуть его, подключитесь или выключите этот переключатель.")
                    Footnote(settings.excludeLocalNetworks
                        ? "Принтеры, AirPlay и устройства в домашней сети доступны напрямую, мимо туннеля."
                        : "Локальная сеть тоже идёт в туннель: принтеры, AirPlay и общий доступ к файлам могут не работать.")
                } else {
                    Footnote("Если включить, ничего не уходит в сеть мимо туннеля, даже пока он поднимается или упал. Цена — нет интернета, пока туннель не работает.")
                }
            }
        }
    }

    // MARK: Shortcuts

    @ViewBuilder private var shortcutsSection: some View {
        Section {
            ForEach(AutomationScreen.shortcutActions, id: \.self) { action in
                Text(action).font(.bykBody).bykRow()
            }
        } header: {
            SectionHeader("Быстрые команды")
        } footer: {
            Footnote(AutomationScreen.shortcutsFootnote)
        }
    }

    static let shortcutActions = ["Подключить", "Отключить", "Переключить подключение", "Выбрать профиль", "Состояние подключения"]

    static var shortcutsFootnote: String {
        #if os(macOS)
        return "Эти действия есть в приложении «Быстрые команды». Их можно запускать по расписанию, из строки меню или сочетанием клавиш. Первое подключение делается в приложении."
        #else
        return "Эти действия есть в приложении «Быстрые команды»: их можно запускать голосом, по автоматизации (подключение к Wi-Fi, режим фокусирования, время), а с iOS 18 — из Пункта управления и кнопкой действия. Первое подключение делается в приложении."
        #endif
    }

    // MARK: Helpers

    private func binding(_ keyPath: WritableKeyPath<AutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { tunnel.automation[keyPath: keyPath] },
            set: { value in
                var updated = tunnel.automation
                updated[keyPath: keyPath] = value
                tunnel.updateAutomation(updated)
            }
        )
    }

    static func keyPath(for kind: NetworkKind) -> WritableKeyPath<AutomationSettings, Bool> {
        switch kind {
        case .wifi: return \.connectOnWiFi
        case .cellular: return \.connectOnCellular
        case .wired: return \.connectOnWired
        }
    }

    static func title(of kind: NetworkKind) -> String {
        switch kind {
        case .wifi: return "В сетях Wi-Fi, кроме доверенных"
        case .cellular: return "По сотовой сети"
        case .wired: return "По кабелю (Ethernet)"
        }
    }
}

/// A footer line in the secondary ink.
struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.bykFootnote)
            .foregroundStyle(Color.bykSecondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(macOS)
/// Start at login through SMAppService.mainApp (macOS 13+). The state is read from the system each time the
/// section appears; the user may also change it in System Settings → General → Login Items.
struct LaunchAtLoginSection: View {
    @State private var status: SMAppService.Status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) }
            )) {
                Text("Открывать при входе в систему").font(.bykBody)
            }
            .bykRow()
            if status == .requiresApproval {
                MessageRow(.warning, "Система ждёт вашего разрешения. Включите «Бык» в настройках объектов входа.").bykRow()
                Button("Открыть объекты входа") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .bykRow()
            }
            if let error = error {
                MessageRow(.error, error).bykRow()
            }
        } header: {
            SectionHeader("Запуск")
        } footer: {
            Footnote("Значок в строке меню появится сразу после входа. Туннель при этом сам не подключается — для этого есть автоподключение.")
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Не удалось изменить запуск при входе: \(error.localizedDescription). Попробуйте в Системных настройках → Основные → Объекты входа."
        }
        status = SMAppService.mainApp.status
    }
}
#endif
