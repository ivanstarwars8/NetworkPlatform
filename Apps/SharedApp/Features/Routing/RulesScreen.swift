// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46077240856 (workflow apple.yml)
//
// Правила (level Расширенный, area Настройки): the preset, own rules (order, on/off, edit, delete) and lists
// downloaded by address. Everything is compiled by Packages/RoutingPolicy into the routing table both engines
// get; the route simulator (Маршрут) answers from the same table. Changes apply at the next connection.

import DesignSystem
import RoutingPolicy
import SwiftUI

struct RulesScreen: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @EnvironmentObject private var tunnel: TunnelController
    @State private var editingRule: CustomRule?
    @State private var addingRule = false
    @State private var addingList = false

    var body: some View {
        List {
            if tunnel.phase.action != .connect {
                Section {
                    MessageRow(.info, "Изменения применятся при следующем подключении.").bykRow()
                }
            }

            Section {
                ForEach(RoutingPreset.allCases, id: \.self) { preset in
                    Button {
                        routing.setPreset(preset)
                    } label: {
                        SelectableRow(preset.title, subtitle: preset.summary, isSelected: routing.settings.preset == preset)
                    }
                    .bykRow()
                }
            } header: {
                SectionHeader("Основа")
            } footer: {
                Text("Свои правила и списки проверяются раньше основы. Локальные сети и адреса серверов профиля всегда идут напрямую.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            Section {
                if routing.settings.customRules.isEmpty {
                    Text("Своих правил нет. Например: домен банка — напрямую, рекламная сеть — блокировать.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                        .bykRow()
                }
                ForEach(routing.settings.customRules) { rule in
                    Button {
                        editingRule = rule
                    } label: {
                        CustomRuleRow(rule: rule)
                    }
                    .contextMenu {
                        Button(rule.isEnabled ? "Выключить" : "Включить") {
                            routing.setRuleEnabled(rule.id, !rule.isEnabled)
                        }
                        Button("Удалить", role: .destructive) {
                            routing.deleteRule(rule.id)
                        }
                    }
                    .bykRow()
                }
                #if !os(tvOS)
                .onMove { routing.moveRules(from: $0, to: $1) }
                .onDelete { routing.deleteRules(at: $0) }
                #endif
                Button {
                    addingRule = true
                } label: {
                    Label("Добавить правило", systemImage: "plus")
                        .font(.bykBody)
                }
                .bykRow()
            } header: {
                SectionHeader("Свои правила")
            } footer: {
                Text("Проверяются сверху вниз, срабатывает первое подходящее.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            Section {
                ForEach(routing.settings.remoteRuleSets) { list in
                    RemoteListRow(list: list, isDownloading: routing.downloading.contains(list.id), hasEntries: (routing.cachedEntryCounts[list.id] ?? 0) > 0)
                        .contextMenu {
                            Button("Удалить", role: .destructive) {
                                routing.deleteList(list.id)
                            }
                        }
                        .bykRow()
                }
                #if !os(tvOS)
                .onMove { routing.moveLists(from: $0, to: $1) }
                .onDelete { routing.deleteLists(at: $0) }
                #endif
                Button {
                    addingList = true
                } label: {
                    Label("Добавить список по ссылке", systemImage: "plus")
                        .font(.bykBody)
                }
                .bykRow()
                if !routing.settings.remoteRuleSets.isEmpty {
                    Button("Обновить все списки") {
                        Task { await routing.downloadAll() }
                    }
                    .disabled(!routing.downloading.isEmpty)
                    .bykRow()
                }
            } header: {
                SectionHeader("Списки по ссылке")
            } footer: {
                Text("Текстовые списки доменов и адресов. Обновляются, только когда вы нажмёте «Обновить». В одном списке до \(routing.limits.maximumEntriesPerSet) записей, во всех вместе — до \(routing.limits.maximumTotalEntries): правила работают внутри расширения с ограниченной памятью.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            if let error = routing.lastError {
                Section {
                    MessageRow(.error, error).bykRow()
                }
            }
        }
        .bykGroupedList()
        .navigationTitle("Правила")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
        .sheet(item: $editingRule) { rule in
            RuleEditor(original: rule)
                .environmentObject(routing)
        }
        .sheet(isPresented: $addingRule) {
            RuleEditor(original: nil)
                .environmentObject(routing)
        }
        .sheet(isPresented: $addingList) {
            RemoteListEditor()
                .environmentObject(routing)
        }
    }
}

/// One own rule: what it compares, the value, where it sends traffic; dimmed when off.
struct CustomRuleRow: View {
    let rule: CustomRule

    var body: some View {
        HStack(spacing: CGFloat(Spacing.s)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.value)
                    .font(rule.kind.isTechnical ? .bykTechnical(.body) : .bykBody)
                    .foregroundStyle(Color.bykInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.isEnabled ? rule.kind.title : "\(rule.kind.title) · выключено")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
            Spacer(minLength: CGFloat(Spacing.xs))
            TargetLabel(target: rule.target)
        }
        .opacity(rule.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Where traffic goes, as a quiet text label. Never bronze: bronze means the tunnel is working.
struct TargetLabel: View {
    let target: RuleTarget

    var body: some View {
        Text(target.title)
            .font(.byk(.footnote, weight: .medium))
            .foregroundStyle(target == .block ? Color.bykAlert : Color.bykSecondaryInk)
    }
}

/// One downloaded list: name, size, when updated, the last error; on/off and refresh.
struct RemoteListRow: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    let list: RemoteRuleSet
    let isDownloading: Bool
    let hasEntries: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Spacing.xxs)) {
            HStack(spacing: CGFloat(Spacing.s)) {
                Toggle(isOn: Binding(get: { list.isEnabled }, set: { routing.setListEnabled(list.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.name).font(.bykBody).foregroundStyle(Color.bykInk)
                        Text(status)
                            .font(.bykFootnote)
                            .foregroundStyle(Color.bykSecondaryInk)
                    }
                }
            }
            HStack {
                TargetLabel(target: list.target)
                Spacer()
                Button(isDownloading ? "Загружаю…" : "Обновить") {
                    Task { await routing.download(list.id) }
                }
                .font(.bykFootnote)
                .disabled(isDownloading)
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
            }
            if let error = list.lastError {
                MessageRow(.error, hasEntries
                    ? "Не обновился: \(error). Работают записи прошлой загрузки."
                    : "Не загрузился: \(error). Проверьте адрес и нажмите «Обновить».")
            }
        }
    }

    private var status: String {
        guard let updated = list.updatedAt else { return "Ещё не загружен" }
        var parts: [String] = []
        if list.domainCount > 0 { parts.append(RussianPlural.phrase(list.domainCount, one: "домен", few: "домена", many: "доменов")) }
        if list.addressCount > 0 { parts.append(RussianPlural.phrase(list.addressCount, one: "сеть", few: "сети", many: "сетей")) }
        parts.append("обновлён " + updated.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

/// Add or edit one own rule. The value is checked as it is typed; Save is available only for a valid rule.
struct RuleEditor: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @Environment(\.dismiss) private var dismiss
    let original: CustomRule?

    @State private var kind: RuleMatchKind = .domainSuffix
    @State private var text = ""
    @State private var target: RuleTarget = .direct
    @State private var isEnabled = true
    @State private var loaded = false

    private var result: Result<CustomRule, PolicyInputError> {
        CustomRule.make(id: original?.id ?? UUID(), kind: kind, text: text, target: target, isEnabled: isEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $kind) {
                        ForEach(RuleMatchKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    } label: {
                        Text("Что сравнивать").font(.bykBody)
                    }
                    .bykRow()
                    TextField(kind.placeholder, text: $text)
                        .font(kind.isTechnical ? .bykTechnical(.body) : .bykBody)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(kind.isTechnical ? .numbersAndPunctuation : .URL)
                        #endif
                        .bykRow()
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let error) = result {
                        MessageRow(.warning, error.message).bykRow()
                    }
                } header: {
                    SectionHeader("Условие")
                } footer: {
                    Text(footer)
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }

                Section {
                    Picker(selection: $target) {
                        ForEach(RuleTarget.allCases, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    } label: {
                        Text("Куда").font(.bykBody)
                    }
                    .bykRow()
                    Toggle(isOn: $isEnabled) {
                        Text("Правило включено").font(.bykBody)
                    }
                    .bykRow()
                } header: {
                    SectionHeader("Действие")
                }

                if let original = original {
                    Section {
                        Button("Удалить правило", role: .destructive) {
                            routing.deleteRule(original.id)
                            dismiss()
                        }
                        .bykRow()
                    }
                }
            }
            .bykGroupedList()
            .navigationTitle(original == nil ? "Новое правило" : "Правило")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        if case .success(let rule) = result {
                            routing.saveRule(rule)
                            dismiss()
                        }
                    }
                    .disabled({ if case .success = result { return false } else { return true } }())
                }
            }
            .onAppear {
                guard !loaded, let original = original else { return }
                loaded = true
                kind = original.kind
                text = original.value
                target = original.target
                isEnabled = original.isEnabled
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    private var footer: String {
        switch kind {
        case .domain: return "Только это имя, без поддоменов. Русские домены можно писать как есть."
        case .domainSuffix: return "Имя и все его поддомены: example.com подходит и для mail.example.com."
        case .domainKeyword: return "Любое имя, в котором есть это слово."
        case .ipCIDR: return "Один адрес или сеть с длиной префикса."
        case .port: return "Порт назначения или диапазон."
        case .network: return "tcp или udp."
        }
    }
}

/// Add a list by address: name, address, where its entries send traffic. Downloads right away.
struct RemoteListEditor: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var target: RuleTarget = .tunnel

    private var urlResult: Result<URL, PolicyInputError> { RemoteRuleSet.validateURL(address) }
    private var canAdd: Bool {
        if case .success = urlResult { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                        .font(.bykBody)
                        .bykRow()
                    TextField("https://example.com/list.txt", text: $address)
                        .font(.bykTechnical(.body))
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .bykRow()
                    if !address.isEmpty, case .failure(let error) = urlResult {
                        MessageRow(.warning, error.message).bykRow()
                    }
                } header: {
                    SectionHeader("Список")
                } footer: {
                    Text("Подходят списки по одному домену или адресу в строке, а также строки DOMAIN-SUFFIX, DOMAIN, IP-CIDR и payload-списки. Регулярные выражения и ключевые слова пропускаются.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
                Section {
                    Picker(selection: $target) {
                        ForEach(RuleTarget.allCases, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    } label: {
                        Text("Куда").font(.bykBody)
                    }
                    .bykRow()
                } header: {
                    SectionHeader("Действие")
                }
            }
            .bykGroupedList()
            .navigationTitle("Список по ссылке")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        guard case .success(let url) = urlResult else { return }
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let list = RemoteRuleSet(name: trimmed.isEmpty ? (url.host ?? "Список") : trimmed, url: url.absoluteString, target: target)
                        dismiss()
                        Task { await routing.addList(list) }
                    }
                    .disabled(!canAdd)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}
