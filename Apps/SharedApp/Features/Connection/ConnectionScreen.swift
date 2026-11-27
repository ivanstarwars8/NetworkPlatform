// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Подключение (level Обычный): the horn connect control, the profile and server in use, and what went wrong.
// Live speed comes from the extension's byte counters, sampled once per second only while this screen is
// visible, the app is active and the tunnel is connected (the `.task` below ends otherwise). Nothing here sits
// in the packet path.

import DesignSystem
import DomainModels
import EngineSelection
import ProfileLibrary
import SwiftUI

struct ConnectionScreen: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var meter = ThroughputMeter()
    @State private var throughput: Throughput?
    @State private var showingImport = false

    private var phase: ConnectionPhase { tunnel.phase }

    /// Sampling runs only for this combination; any change restarts or ends the task.
    private var sampling: Bool { phase.showsThroughput && scenePhase == .active }

    var body: some View {
        List {
            Section {
                HornConnectControl(
                    phase: phase,
                    throughput: throughput,
                    isEnabled: phase.action != .connect || library.connectBlocker == nil,
                    disabledHint: library.connectBlocker
                ) {
                    Task { await tunnel.performPrimaryAction(library: library) }
                }
                .padding(.vertical, CGFloat(Spacing.l))
                .listRowBackground(Color.clear)
                .plainListRow()
            }

            if library.profiles.isEmpty {
                Section {
                    EmptyStateView(
                        title: "Профилей пока нет",
                        message: "Добавьте ссылку на сервер или адрес подписки — и можно подключаться.",
                        actionTitle: "Добавить профиль"
                    ) {
                        showingImport = true
                    }
                    .listRowBackground(Color.clear)
                    .plainListRow()
                }
            } else {
                profileSection
            }

            let messages = self.messages
            if !messages.isEmpty {
                Section {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        MessageRow(message.kind, message.text).bykRow()
                    }
                } header: {
                    SectionHeader("Сообщения")
                }
            }
        }
        .bykGroupedList()
        .navigationTitle("Подключение")
        .sheet(isPresented: $showingImport) {
            ImportView(isPresented: $showingImport)
                .environmentObject(library)
        }
        .task(id: sampling) {
            await sampleTraffic()
        }
    }

    // MARK: Profile and server

    @ViewBuilder private var profileSection: some View {
        let busy = phase.action == .disconnect || phase.action == .none
        Section {
            Picker(selection: profileSelection) {
                ForEach(library.profiles, id: \.id) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            } label: {
                Text("Профиль").font(.bykBody)
            }
            .disabled(busy)
            .bykRow()

            if let profile = library.selectedProfile, profile.outbounds.count > 1 {
                Picker(selection: serverSelection(of: profile)) {
                    ForEach(profile.outbounds, id: \.tag) { outbound in
                        Text(outbound.name.isEmpty ? outbound.tag : outbound.name).tag(Optional(outbound.tag))
                    }
                } label: {
                    Text("Сервер").font(.bykBody)
                }
                .disabled(busy)
                .bykRow()
            }

            if let profile = library.selectedProfile, library.availableEngines.count > 1 {
                ValueRow("Движок", value: engineLine(for: profile)).bykRow()
            }
        } header: {
            SectionHeader("Маршрут")
        } footer: {
            if busy {
                Text("Профиль и сервер меняются после отключения.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
        }
    }

    private var profileSelection: Binding<UUID?> {
        Binding(
            get: { library.selectedProfileID },
            set: { id in if let id = id { library.select(id) } }
        )
    }

    private func serverSelection(of profile: Profile) -> Binding<String?> {
        Binding(
            get: { profile.selectedTag },
            set: { tag in if let tag = tag { library.selectServer(tag, inProfile: profile.id) } }
        )
    }

    /// The engine running now (when this profile is up) or the one the next start will use.
    private func engineLine(for profile: Profile) -> String {
        _ = library.engineChoiceRevision
        if let start = tunnel.currentStart, start.attempt.profileID == profile.id, phase.action != .connect {
            let name = start.attempt.engine.displayName
            return start.attempt.origin == .rollback ? "\(name), последняя рабочая настройка" : name
        }
        let decision = library.engineDecision(for: profile)
        guard let engine = decision.engine else { return "не подходит ни один" }
        return decision.preference == .automatic ? "Авто: \(engine.displayName)" : engine.displayName
    }

    // MARK: Messages

    private var messages: [(kind: MessageKind, text: String)] {
        var list: [(kind: MessageKind, text: String)] = []
        if let notice = tunnel.supervisorNotice { list.append((.warning, notice)) }
        if let error = tunnel.lastError { list.append((.error, error)) }
        if phase.action == .connect, library.compileNotices.isEmpty, let profile = library.selectedProfile {
            let decision = library.engineDecision(for: profile)
            if let engine = decision.engine, !decision.losses.isEmpty {
                let count = RussianPlural.phrase(decision.losses.count, one: "возможность", few: "возможности", many: "возможностей")
                list.append((.warning, "\(engine.displayName) не передаст \(count) профиля. Подробности — в профиле, раздел «Движок»."))
            }
        }
        if let error = library.lastError { list.append((.error, error)) }
        if phase == .disconnected || phase == .notConfigured, let reason = tunnel.lastDisconnectError {
            list.append((.warning, "Туннель остановился: \(reason)"))
        }
        for notice in library.compileNotices {
            list.append((kind: notice.severity.messageKind, text: notice.text))
        }
        return list
    }

    // MARK: Live speed

    private func sampleTraffic() async {
        meter.reset()
        throughput = nil
        guard sampling else { return }
        while !Task.isCancelled {
            await tunnel.refreshTraffic()
            if let counters = tunnel.traffic {
                let sample = TrafficSample(
                    uplinkBytes: counters.uplinkBytes,
                    downlinkBytes: counters.downlinkBytes,
                    time: ProcessInfo.processInfo.systemUptime
                )
                if let measured = meter.add(sample) {
                    throughput = measured
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

extension ProfileNotice.Severity {
    var messageKind: MessageKind {
        switch self {
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}

extension View {
    /// A list row without separators where the platform has them (the horn and empty state are not rows).
    func plainListRow() -> some View {
        #if os(iOS) || os(macOS) || os(visionOS)
        return self.listRowSeparator(.hidden)
        #else
        return self
        #endif
    }
}
