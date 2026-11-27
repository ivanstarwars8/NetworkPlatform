// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Subscription settings of one profile: refresh now, how often to refresh automatically, the last update
// (when, what changed, or what went wrong), and resetting the user's edits. The address is never shown in
// full: it often carries an access token; only its host is shown.

import DesignSystem
import ProfileLibrary
import SwiftUI

struct SubscriptionSettingsView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var confirmingReset = false
    let profileID: UUID

    var body: some View {
        if let profile = library.profile(profileID), let record = library.subscriptionRecords[profileID] {
            List {
                Section {
                    if let host = SubscriptionManager.url(of: profile)?.host {
                        ValueRow("Сервер подписки", value: host, technical: true).bykRow()
                    }
                    SubscriptionStatusRows(record: record, refreshing: library.refreshingSubscriptions.contains(profileID))
                }

                Section {
                    Button(library.refreshingSubscriptions.contains(profileID) ? "Обновляю…" : "Обновить сейчас") {
                        Task { await library.refreshSubscription(profileID) }
                    }
                    .buttonStyle(.bykPrimary)
                    .disabled(library.refreshingSubscriptions.contains(profileID))
                    .listRowBackground(Color.clear)
                    .plainListRow()
                }

                Section {
                    Picker(selection: intervalBinding(record)) {
                        ForEach(SubscriptionInterval.allCases, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    } label: {
                        Text("Обновлять").font(.bykBody)
                    }
                    .bykRow()
                } header: {
                    SectionHeader("Автообновление")
                } footer: {
                    FootnoteText(intervalFooter(record))
                }

                Section {
                    let edits = record.edits
                    ValueRow("Переименовано", value: "\(edits.names.count)").bykRow()
                    ValueRow("Скрыто", value: "\(edits.hidden.count)").bykRow()
                    if !edits.isEmpty {
                        Button("Сбросить правки", role: .destructive) {
                            confirmingReset = true
                        }
                        .foregroundStyle(Color.bykAlert)
                        .bykRow()
                    }
                } header: {
                    SectionHeader("Ваши правки")
                } footer: {
                    FootnoteText("Новые названия и скрытые серверы сохраняются при каждом обновлении. Сервер узнаётся по протоколу, адресу и порту.")
                }
            }
            .bykGroupedList()
            .navigationTitle("Подписка")
            .confirmationDialog("Сбросить правки?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Сбросить и обновить", role: .destructive) {
                    library.resetSubscriptionEdits(profileID)
                    Task { await library.refreshSubscription(profileID) }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Скрытые серверы вернутся, названия станут такими, как у поставщика.")
            }
        } else {
            EmptyStateView(title: "Подписки нет", message: "Этот профиль добавлен не из подписки.")
        }
    }

    private func intervalBinding(_ record: SubscriptionRecord) -> Binding<SubscriptionInterval> {
        Binding(get: { record.interval }, set: { library.setInterval($0, for: profileID) })
    }

    private func intervalFooter(_ record: SubscriptionRecord) -> String {
        if record.interval == .manual {
            return "Подписка обновляется, только когда вы нажимаете «Обновить сейчас»."
        }
        #if os(iOS)
        return "Подписка обновляется при запуске приложения, если прошло больше выбранного времени, и в фоне, когда система разрешит."
        #else
        return "Подписка обновляется при запуске приложения, если прошло больше выбранного времени."
        #endif
    }
}

/// When the subscription was last updated and how it went.
struct SubscriptionStatusRows: View {
    let record: SubscriptionRecord
    let refreshing: Bool

    var body: some View {
        ValueRow("Обновлено", value: record.lastSuccess.map(SubscriptionStatusRows.relative) ?? "ещё нет").bykRow()
        if refreshing {
            HStack(spacing: CGFloat(Spacing.xs)) {
                ProgressView()
                Text("Загружаю подписку…").font(.bykFootnote).foregroundStyle(Color.bykSecondaryInk)
            }
            .bykRow()
        } else if let outcome = record.lastOutcome {
            switch outcome {
            case let .updated(diff):
                MessageRow(.info, diff.summary).bykRow()
                if !diff.added.isEmpty {
                    ValueRow("Новые", value: SubscriptionStatusRows.names(diff.added)).bykRow()
                }
                if !diff.removed.isEmpty {
                    ValueRow("Удалены", value: SubscriptionStatusRows.names(diff.removed)).bykRow()
                }
            case .notModified:
                MessageRow(.info, "Сервер подписки ответил, что изменений нет.").bykRow()
            case let .failed(message):
                MessageRow(.error, "Последнее обновление не удалось: \(message). Проверьте сеть и нажмите «Обновить сейчас».").bykRow()
            }
        }
    }

    static func names(_ list: [String]) -> String {
        let shown = list.prefix(3).joined(separator: ", ")
        return list.count > 3 ? "\(shown) и ещё \(list.count - 3)" : shown
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The subscription line in a profile: when it was updated, or that the last update failed.
struct SubscriptionSummaryRow: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    let profileID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Подписка").font(.bykBody).foregroundStyle(Color.bykInk)
            Text(SubscriptionSummaryRow.line(library.subscriptionRecords[profileID], refreshing: library.refreshingSubscriptions.contains(profileID)))
                .font(.bykFootnote)
                .foregroundStyle(isFailed ? Color.bykAlert : Color.bykSecondaryInk)
        }
    }

    private var isFailed: Bool {
        if case .failed? = library.subscriptionRecords[profileID]?.lastOutcome { return true }
        return false
    }

    static func line(_ record: SubscriptionRecord?, refreshing: Bool) -> String {
        if refreshing { return "Обновляю…" }
        guard let record = record else { return "Ещё не обновлялась" }
        if case .failed? = record.lastOutcome { return "Обновление не удалось" }
        guard let success = record.lastSuccess else { return "Ещё не обновлялась" }
        return "Обновлена \(SubscriptionStatusRows.relative(success))"
    }
}
