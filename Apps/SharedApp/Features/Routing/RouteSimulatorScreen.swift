// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46077240856 (workflow apple.yml)
//
// Маршрут (level Профи, area Инструменты): enter a domain, an address, a port and a protocol and see where the
// connection goes, which rule decided and why. The answer comes from RoutingPolicy's RouteExplainer over the
// same table the engines are compiled from (RouteSimulator — the matcher checked against Xray's router), for
// the selected profile and the current settings. Nothing runs in the background; one evaluation per tap.

import DesignSystem
import DomainModels
import RoutingEngine
import RoutingPolicy
import SwiftUI

struct RouteSimulatorScreen: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var query = RouteQuery()
    @State private var answer: RouteAnswer?
    @State private var policy: CompiledPolicy?
    @State private var error: String?

    var body: some View {
        if let profile = library.selectedProfile {
            List {
                Section {
                    TextField("Домен, например example.com", text: $query.domain)
                        .font(.bykBody)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .bykRow()
                    TextField("Адрес, например 203.0.113.7", text: $query.address)
                        .font(.bykTechnical(.body))
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .bykRow()
                    LabeledContent {
                        TextField("443", text: $query.port)
                            .font(.bykTechnical(.body))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS) || os(visionOS)
                            .keyboardType(.numberPad)
                            #endif
                    } label: {
                        Text("Порт").font(.bykBody)
                    }
                    .bykRow()
                    Picker(selection: $query.network) {
                        Text("TCP").tag(NetworkKind.tcp)
                        Text("UDP").tag(NetworkKind.udp)
                    } label: {
                        Text("Протокол").font(.bykBody)
                    }
                    .pickerStyle(.segmented)
                    .bykRow()
                } header: {
                    SectionHeader("Соединение")
                } footer: {
                    Text("Можно указать и домен, и адрес: так соединение выглядит в туннеле, когда имя сайта известно.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }

                Section {
                    Button("Проверить") { check(profile) }
                        .buttonStyle(.bykPrimary)
                        .listRowBackground(Color.clear)
                        .plainListRow()
                    if let error = error {
                        MessageRow(.error, error).bykRow()
                    }
                }

                if let answer = answer, let policy = policy {
                    RouteAnswerSection(answer: answer, policy: policy, settings: routing.settings, serverName: serverName(profile))
                }
            }
            .bykGroupedList()
            .navigationTitle("Маршрут")
            .onChange(of: routing.settings) { answer = nil }
            .onChange(of: library.selectedProfileID) { answer = nil }
        } else {
            EmptyStateView(
                title: "Нет профиля",
                message: "Маршрут зависит от сервера профиля. Добавьте и выберите профиль на вкладке «Профили»."
            )
            .navigationTitle("Маршрут")
        }
    }

    private func check(_ profile: Profile) {
        switch routing.compiler.compile(for: profile) {
        case .failure(let failure):
            error = "Правила не собираются: \(failure.message) Исправьте их на экране «Правила»."
            answer = nil
        case .success(let compiled):
            let servers = profile.outbounds.map(\.server.host).filter { IPAddress($0) != nil }.map(TunnelRoute.host)
            do {
                let explainer = try RouteExplainer(policy: compiled, bypass: servers + TunnelAddressing.localRoutes)
                switch explainer.explain(query) {
                case .success(let result):
                    policy = compiled
                    answer = result
                    error = nil
                case .failure(let input):
                    error = input.message
                    answer = nil
                }
            } catch {
                self.error = "Правила не собираются: \(error)."
                answer = nil
            }
        }
    }

    private func serverName(_ profile: Profile) -> String {
        guard let tag = profile.selectedTag ?? profile.outbounds.first?.tag else { return profile.name }
        if let outbound = profile.outbound(tagged: tag) { return outbound.name.isEmpty ? tag : outbound.name }
        return profile.group(tagged: tag)?.name ?? tag
    }
}

/// The answer: where the connection goes, then why.
struct RouteAnswerSection: View {
    let answer: RouteAnswer
    let policy: CompiledPolicy
    let settings: RoutingSettings
    let serverName: String

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: CGFloat(Spacing.xxs)) {
                Text(answer.target.title)
                    .font(.bykTitle)
                    .foregroundStyle(answer.target == .block ? Color.bykAlert : Color.bykInk)
                if answer.target == .tunnel {
                    Text(serverName)
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }
            .padding(.vertical, CGFloat(Spacing.xxs))
            .accessibilityElement(children: .combine)
            .bykRow()

            Text(reason)
                .font(.bykBody)
                .foregroundStyle(Color.bykInk)
                .fixedSize(horizontal: false, vertical: true)
                .bykRow()

            if let kind = answer.matchedKind, let value = answer.matchedValue {
                ValueRow(kind.title, value: value, technical: kind.isTechnical)
                    .bykRow()
            }
            if let domain = answer.normalisedDomain, domain.contains("xn--") {
                ValueRow("Имя для сравнения", value: domain, technical: true).bykRow()
            }
            if !answer.bypassesTunnel {
                ValueRow("Правило в движке", value: answer.engineRuleTag, technical: true).bykRow()
                if answer.checkedBefore > 0 || answer.disabledBefore > 0 {
                    ValueRow("Проверено раньше", value: earlierText).bykRow()
                }
                if !answer.shadowedRules.isEmpty {
                    MessageRow(.info, "Подходят и правила ниже (\(answer.shadowedRules.map { "№\($0 + 1)" }.joined(separator: ", "))), но срабатывает первое.")
                        .bykRow()
                }
            }
        } header: {
            SectionHeader("Ответ")
        } footer: {
            Text("Ответ считается по тем же правилам, что получает движок. В туннеле имя сайта берётся из первого пакета соединения (TLS, HTTP, QUIC) или из ответа DNS; без имени решают только правила по адресу, порту и протоколу.")
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
        }
    }

    private var earlierText: String {
        var parts: [String] = []
        if answer.checkedBefore > 0 {
            parts.append(RussianPlural.phrase(answer.checkedBefore, one: "правило не подошло", few: "правила не подошли", many: "правил не подошли"))
        }
        if answer.disabledBefore > 0 {
            parts.append(RussianPlural.phrase(answer.disabledBefore, one: "выключено", few: "выключены", many: "выключены"))
        }
        return parts.joined(separator: ", ")
    }

    private var reason: String {
        if answer.bypassesTunnel {
            return "Адрес не попадает в туннель: это локальная сеть или адрес сервера профиля. Система отправляет его напрямую до всех правил."
        }
        guard let origin = answer.origin else {
            return "Ни одно правило не подошло — действует основа «\(settings.preset.title)»: \(settings.preset.finalTarget.title.lowercased())."
        }
        switch origin {
        case .custom(let id):
            let number = (settings.customRules.firstIndex { $0.id == id } ?? 0) + 1
            return "Сработало своё правило №\(number)."
        case .remote(let id):
            let name = settings.remoteRuleSets.first { $0.id == id }?.name ?? "без названия"
            return "Сработал список «\(name)»."
        case .preset(let preset, let groupID):
            let group = PresetLists.groups(of: preset).first { $0.id == groupID }?.title ?? groupID
            return "Сработала основа «\(preset.title)», встроенный список «\(group)»."
        }
    }
}
