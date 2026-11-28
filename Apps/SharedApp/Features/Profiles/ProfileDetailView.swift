// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
//
// One profile: use it, choose «Авто» or a server, see each server's latency and where the number comes
// from, rename or hide servers, open the subscription settings, delete the profile.
//
// Latency is never estimated. Connected: the engine's own health check through each server, read from the
// extension about every 10 s, only while this screen is visible and the app is active. Disconnected: the
// app's TCP connect test, only when the user taps «Проверить». A server without a measurement shows none.
// Choosing a server of the running profile switches it inside the engine, without restarting the tunnel.

import DesignSystem
import DomainModels
import ProfileLibrary
import SwiftUI

struct ProfileDetailView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingDelete = false
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    let profileID: UUID

    private struct RenameTarget: Identifiable {
        var id: String { tag ?? "profile" }
        /// `nil`: the profile itself.
        var tag: String?
    }

    /// Engine measurements are read only for this combination; any change restarts or ends the task.
    private var readsEngine: Bool {
        scenePhase == .active && library.running?.profileID == profileID && library.running?.plan != nil
            && tunnel.status == .connected
    }

    var body: some View {
        if let profile = library.profile(profileID) {
            content(profile)
        } else {
            EmptyStateView(title: "Профиль удалён", message: "Выберите другой профиль в списке.")
        }
    }

    @ViewBuilder private func content(_ profile: Profile) -> some View {
        let isSubscription = library.isSubscription(profile)
        List {
            if profile.id != library.selectedProfileID {
                Section {
                    Button("Использовать этот профиль") {
                        library.select(profile.id)
                    }
                    .buttonStyle(.bykPrimary)
                    .disabled(tunnelBusy)
                    .listRowBackground(Color.clear)
                    .plainListRow()
                } footer: {
                    if tunnelBusy {
                        FootnoteText("Профиль меняется после отключения.")
                    }
                }
            }

            if AutomaticGroup.applies(to: profile) {
                automaticSection(profile)
            }

            EngineChoiceSection(profile: profile, isLocked: tunnelBusy && profile.id == library.selectedProfileID)

            serversSection(profile, isSubscription: isSubscription)

            if let error = library.selectionError, library.running?.profileID == profile.id {
                Section {
                    MessageRow(.warning, error).bykRow()
                }
            }

            Section {
                if isSubscription {
                    NavigationLink {
                        SubscriptionSettingsView(profileID: profile.id)
                    } label: {
                        SubscriptionSummaryRow(profileID: profile.id)
                    }
                    .bykRow()
                }
                Button("Переименовать профиль") {
                    renameText = profile.name
                    renaming = RenameTarget(tag: nil)
                }
                .bykRow()
                Button("Удалить профиль", role: .destructive) {
                    confirmingDelete = true
                }
                .foregroundStyle(Color.bykAlert)
                .bykRow()
            }
        }
        .bykGroupedList()
        .navigationTitle(profile.name)
        .toolbar {
            if tunnel.phase.action == .connect, !ConnectProbePlan.targets(of: profile).isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await library.runConnectTest(profile.id) }
                    } label: {
                        if library.testingProfiles.contains(profile.id) {
                            ProgressView()
                        } else {
                            Label("Проверить", systemImage: "gauge.with.dots.needle.33percent")
                        }
                    }
                    .disabled(library.testingProfiles.contains(profile.id))
                    .accessibilityLabel("Проверить задержку серверов")
                }
            }
        }
        .task(id: readsEngine) {
            guard readsEngine else { return }
            while !Task.isCancelled {
                await library.refreshEngineMeasurements(tunnel: tunnel)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .alert(renaming?.tag == nil ? "Название профиля" : "Название сервера", isPresented: renamingBinding) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let tag = renaming?.tag {
                    library.renameServer(tag, inProfile: profile.id, to: renameText)
                } else {
                    library.renameProfile(profile.id, to: renameText)
                }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        } message: {
            if renaming?.tag != nil && isSubscription {
                Text("Новое название сохранится и после обновления подписки.")
            }
        }
        .confirmationDialog("Удалить профиль «\(profile.name)»?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                library.remove(profile.id)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Серверы и ключи профиля будут удалены с этого устройства.")
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    // MARK: Авто

    @ViewBuilder private func automaticSection(_ profile: Profile) -> some View {
        let choice = library.choice(of: profile.id)
        Section {
            Button {
                Task { await library.choose(.automatic, inProfile: profile.id, tunnel: tunnel) }
            } label: {
                SelectableRow(
                    "Авто",
                    subtitle: "Самый быстрый из отвечающих серверов",
                    isSelected: choice == .automatic
                )
            }
            .disabled(!canChoose(in: profile))
            .bykRow()
        } header: {
            SectionHeader("Выбор сервера")
        } footer: {
            FootnoteText(explanation(profile, choice: choice))
        }
    }

    private func explanation(_ profile: Profile, choice: ServerChoice) -> String {
        let book = library.health[profile.id] ?? ServerHealthBook(tags: [])
        let running = library.running?.profileID == profile.id ? library.running : nil
        var names: [String: String] = [:]
        for outbound in profile.outbounds { names[outbound.tag] = ProfileLibraryModel.name(of: outbound) }
        let connected = running != nil && tunnel.status == .connected
        var text = AutoExplanation.text(
            .init(connected: connected, choice: choice, current: running?.currentTag, engine: running?.engine ?? library.plannedEngine(for: profile), names: names),
            book: book
        )
        if tunnel.phase.action != .connect && running == nil && profile.id == library.selectedProfileID {
            text += " Выбор применится при следующем подключении."
        }
        return text
    }

    // MARK: Servers

    @ViewBuilder private func serversSection(_ profile: Profile, isSubscription: Bool) -> some View {
        let choice = library.choice(of: profile.id)
        let book = library.health[profile.id]
        let running = library.running?.profileID == profile.id && tunnel.status == .connected ? library.running : nil
        Section {
            ForEach(profile.outbounds, id: \.tag) { outbound in
                Button {
                    Task { await library.choose(.server(tag: outbound.tag), inProfile: profile.id, tunnel: tunnel) }
                } label: {
                    ServerRow(
                        name: ProfileLibraryModel.name(of: outbound),
                        protocolName: outbound.kind.displayName,
                        latency: book?.latest[outbound.tag],
                        failing: book?.isFailing(outbound.tag, now: Date()) ?? false,
                        isChosen: choice == .server(tag: outbound.tag) || !AutomaticGroup.applies(to: profile) && outbound.tag == profile.selectedTag,
                        isCurrent: running?.currentTag == outbound.tag
                    )
                }
                .disabled(!canChoose(in: profile))
                .bykRow()
                .contextMenu {
                    Button("Переименовать") {
                        renameText = ProfileLibraryModel.name(of: outbound)
                        renaming = RenameTarget(tag: outbound.tag)
                    }
                    if isSubscription && profile.outbounds.count > 1 {
                        Button("Скрыть", role: .destructive) {
                            library.hideServer(outbound.tag, inProfile: profile.id)
                        }
                    }
                }
                #if os(iOS) || os(visionOS)
                .swipeActions(edge: .trailing) {
                    if isSubscription && profile.outbounds.count > 1 {
                        Button("Скрыть", role: .destructive) {
                            library.hideServer(outbound.tag, inProfile: profile.id)
                        }
                    }
                    Button("Переименовать") {
                        renameText = ProfileLibraryModel.name(of: outbound)
                        renaming = RenameTarget(tag: outbound.tag)
                    }
                    .tint(Color.bykSecondaryInk)
                }
                #endif
            }
        } header: {
            SectionHeader(ProfilesScreen.serverCount(profile.outbounds.count).capitalizedFirst)
        } footer: {
            FootnoteText(serversFooter(profile))
        }
    }

    private func serversFooter(_ profile: Profile) -> String {
        if library.running?.profileID == profile.id && tunnel.status == .connected {
            if library.running?.plan != nil {
                return "Задержка — проверка движка через каждый сервер раз в \(AutomaticGroup.intervalSeconds / 60) мин. Выбор сервера применяется сразу, без переподключения."
            }
            return "Сервер меняется после переподключения."
        }
        if tunnel.phase.action == .connect {
            let tested = ConnectProbePlan.targets(of: profile).count
            if tested == 0 {
                return "Задержку этих серверов покажет движок после подключения: они работают поверх UDP."
            }
            return "«Проверить» измеряет время TCP-соединения с адресом сервера (до \(ConnectProbePlan.maximumServers) серверов). Это расстояние по сети, без рукопожатия прокси; точнее покажет движок после подключения."
        }
        return "Выбор применится при следующем подключении."
    }

    /// Choosing is possible while disconnected, and while connected when the running profile can switch live.
    private func canChoose(in profile: Profile) -> Bool {
        if tunnel.phase.action == .connect { return true }
        return library.switchesLive(profile.id, tunnel: tunnel)
    }

    private var tunnelBusy: Bool { tunnel.phase.action != .connect }
}

/// One server: name, protocol, the measured latency and its source, the user's choice and the server in use.
struct ServerRow: View {
    let name: String
    let protocolName: String
    let latency: ServerLatency?
    let failing: Bool
    let isChosen: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: CGFloat(Spacing.s)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(isChosen ? .bykBodyEmphasis : .bykBody)
                    .foregroundStyle(Color.bykInk)
                    .lineLimit(2)
                HStack(spacing: CGFloat(Spacing.xxs)) {
                    Text(protocolName)
                    if isCurrent {
                        Text("·")
                        // Bronze: traffic of the working tunnel goes through this server.
                        Text("сейчас через него").foregroundStyle(Color.bykAccentText)
                    }
                }
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
            }
            Spacer(minLength: CGFloat(Spacing.xs))
            LatencyLabel(latency: latency, failing: failing)
            if isChosen {
                Image(systemName: "checkmark")
                    .font(.byk(.body, weight: .semibold))
                    .foregroundStyle(Color.bykInk)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// A measured latency with its source, or nothing when there is no measurement.
struct LatencyLabel: View {
    let latency: ServerLatency?
    let failing: Bool

    var body: some View {
        if let latency = latency {
            VStack(alignment: .trailing, spacing: 2) {
                if latency.alive, let value = latency.milliseconds {
                    Text("\(value) мс")
                        .font(.byk(.footnote, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.bykInk)
                } else {
                    Text(failing ? "не отвечает" : "нет ответа")
                        .font(.byk(.footnote, weight: .medium))
                        .foregroundStyle(Color.bykAlert)
                }
                Text(latency.source == .engine ? "движок" : "TCP")
                    .font(.bykCaption)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(latency))
        }
    }

    private func accessibilityText(_ latency: ServerLatency) -> String {
        let source = latency.source == .engine ? "по проверке движка" : "по проверке соединения"
        if latency.alive, let value = latency.milliseconds { return "\(value) миллисекунд \(source)" }
        return "Не отвечает \(source)"
    }
}

/// A footnote under a section.
struct FootnoteText: View {
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

extension ProxyProtocolKind {
    /// The protocol as people write it.
    var displayName: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMess"
        case .trojan: return "Trojan"
        case .shadowsocks: return "Shadowsocks"
        case .socks: return "SOCKS"
        case .http: return "HTTP"
        case .hysteria: return "Hysteria"
        case .hysteria2: return "Hysteria 2"
        case .tuic: return "TUIC"
        case .wireGuard: return "WireGuard"
        case .amneziaWG: return "AmneziaWG"
        default: return rawValue
        }
    }
}
