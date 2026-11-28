// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
// (Changed from the file compiled on macOS CI in GitHub Actions run 46073714202.)
//
// Профили (level Обычный): the profiles, which one is in use, its choice («Авто» or a server) and subscription
// state; adding a profile from a pasted share link, subscription address or subscription body; the import
// report. One profile (servers, engine): ProfileDetailView.swift, EngineChoiceSection.swift; subscription
// settings: SubscriptionSettingsView.swift.

import DesignSystem
import DomainModels
import ProfileLibrary
import SwiftUI

struct ProfilesScreen: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var showingImport = false

    var body: some View {
        List {
            if library.profiles.isEmpty {
                Section {
                    EmptyStateView(
                        title: "Профилей пока нет",
                        message: "Профиль — это набор серверов из ссылки или подписки. Добавьте первый.",
                        systemImage: "tray",
                        actionTitle: "Добавить профиль"
                    ) {
                        showingImport = true
                    }
                    .listRowBackground(Color.clear)
                    .plainListRow()
                }
            } else {
                Section {
                    ForEach(library.profiles, id: \.id) { profile in
                        NavigationLink {
                            ProfileDetailView(profileID: profile.id)
                        } label: {
                            SelectableRow(
                                profile.name,
                                subtitle: subtitle(of: profile),
                                isSelected: profile.id == library.selectedProfileID
                            )
                        }
                        .bykRow()
                    }
                } footer: {
                    Text("Отмеченный профиль используется при подключении.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }

            if let error = library.lastError {
                Section {
                    MessageRow(.error, error).bykRow()
                }
            }
        }
        .bykGroupedList()
        .refreshable {
            // Pull to refresh: every subscription profile, one after another.
            for profile in library.profiles where library.isSubscription(profile) {
                await library.refreshSubscription(profile.id)
            }
        }
        .navigationTitle("Профили")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImport = true
                } label: {
                    Label("Добавить профиль", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportView(isPresented: $showingImport)
                .environmentObject(library)
        }
    }

    /// «12 серверов · Авто · обновлена 2 часа назад»: what the row needs to tell, nothing invented.
    private func subtitle(of profile: Profile) -> String {
        var parts = [ProfilesScreen.serverCount(profile.outbounds.count)]
        if AutomaticGroup.applies(to: profile) {
            switch library.choice(of: profile.id) {
            case .automatic:
                parts.append("Авто")
            case let .server(tag):
                parts.append(profile.outbound(tagged: tag).map(ProfileLibraryModel.name(of:)) ?? tag)
            }
        }
        if library.isSubscription(profile) {
            parts.append(SubscriptionSummaryRow.line(
                library.subscriptionRecords[profile.id], refreshing: library.refreshingSubscriptions.contains(profile.id)
            ).lowercasedFirst)
        }
        return parts.joined(separator: " · ")
    }

    static func serverCount(_ count: Int) -> String {
        RussianPlural.phrase(count, one: "сервер", few: "сервера", many: "серверов")
    }
}

/// Pasted text → profile. The importers' notices stay visible after a successful import.
struct ImportView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var imported = false

    private var canImport: Bool {
        !library.isImporting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if os(tvOS)
                    TextField("vless://… или https://…", text: $text)
                        .autocorrectionDisabled()
                    #else
                    TextEditor(text: $text)
                        .font(.bykTechnical(.footnote))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .bykRow()
                    #endif
                } header: {
                    SectionHeader("Ссылка или подписка")
                } footer: {
                    Text("Ссылка на сервер (vless://, trojan://, ss:// и другие), адрес подписки https:// или текст подписки целиком. Подписка загружается без cookies и кэша и потом обновляется сама — раз в сутки, это можно изменить в настройках подписки.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }

                Section {
                    Button(library.isImporting ? "Загружаю…" : "Добавить") {
                        Task {
                            imported = await library.importText(text)
                            if imported { text = "" }
                        }
                    }
                    .buttonStyle(.bykPrimary)
                    .disabled(!canImport)
                    .listRowBackground(Color.clear)
                    .plainListRow()

                    if imported {
                        MessageRow(.info, "Профиль добавлен.").bykRow()
                    }
                    if let error = library.lastError {
                        MessageRow(.error, error).bykRow()
                    }
                }

                if !library.importNotices.isEmpty {
                    Section {
                        NoticeList(notices: library.importNotices)
                    } header: {
                        SectionHeader("Отчёт импорта")
                    }
                }
            }
            .bykGroupedList()
            .navigationTitle("Новый профиль")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { isPresented = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}

/// Notices of an import or a compilation, most severe marked.
struct NoticeList: View {
    let notices: [ProfileNotice]

    var body: some View {
        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
            MessageRow(notice.severity.messageKind, notice.text).bykRow()
        }
    }
}

extension String {
    /// "3 сервера" → "3 сервера"; "серверы" → "Серверы". Section headers are sentence case.
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }

    /// "Обновлена 2 часа назад" → "обновлена 2 часа назад", inside a line joined with "·".
    var lowercasedFirst: String {
        guard let first = first else { return self }
        return String(first).lowercased() + dropFirst()
    }
}
