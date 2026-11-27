// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
// (Rebuilt from ContentView.swift, compiled on macOS CI in GitHub Actions run 46055850203; same behaviour.)
//
// Профили (level Обычный): the profiles, which one is in use, its servers; adding a profile from a pasted share
// link, subscription address or subscription body; the import report; deleting a profile.

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
                                subtitle: ProfilesScreen.serverCount(profile.outbounds.count),
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
                    Text("Ссылка на сервер (vless://, trojan://, ss:// и другие), адрес подписки https:// или текст подписки целиком. Адрес подписки загружается один раз, без cookies и кэша.")
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

/// Servers of one profile: use the profile, choose the server traffic goes to, or delete the profile.
struct ProfileDetailView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    let profileID: UUID

    var body: some View {
        if let profile = library.profiles.first(where: { $0.id == profileID }) {
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
                            Text("Профиль меняется после отключения.")
                                .font(.bykFootnote)
                                .foregroundStyle(Color.bykSecondaryInk)
                        }
                    }
                }

                Section {
                    ForEach(profile.outbounds, id: \.tag) { outbound in
                        Button {
                            library.selectServer(outbound.tag, inProfile: profile.id)
                        } label: {
                            SelectableRow(
                                outbound.name.isEmpty ? outbound.tag : outbound.name,
                                subtitle: outbound.kind.rawValue,
                                isSelected: outbound.tag == profile.selectedTag
                            )
                        }
                        .disabled(tunnelBusy && profile.id == library.selectedProfileID)
                        .bykRow()
                    }
                } header: {
                    SectionHeader(ProfilesScreen.serverCount(profile.outbounds.count).capitalizedFirst)
                }

                Section {
                    Button("Удалить профиль", role: .destructive) {
                        confirmingDelete = true
                    }
                    .foregroundStyle(Color.bykAlert)
                    .bykRow()
                }
            }
            .bykGroupedList()
            .navigationTitle(profile.name)
            .confirmationDialog("Удалить профиль «\(profile.name)»?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    library.remove(profile.id)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Серверы и ключи профиля будут удалены с этого устройства.")
            }
        } else {
            EmptyStateView(title: "Профиль удалён", message: "Выберите другой профиль в списке.")
        }
    }

    private var tunnelBusy: Bool { tunnel.phase.action != .connect }
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
}
