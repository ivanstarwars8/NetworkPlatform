// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46077240856 (workflow apple.yml)
//
// DNS (level Расширенный, area Настройки): resolver servers (UDP, TCP, DoH, DoT), servers for single domains,
// IPv6 answers and leak protection (on by default). Compiled into both engines' DNS sections by
// ConfigurationEngine; applies at the next connection.

import DesignSystem
import RoutingPolicy
import SwiftUI

struct DNSScreen: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var addingServer = false
    @State private var addingDomainServer = false

    private var dns: DNSSettings { routing.settings.dns }

    var body: some View {
        List {
            if tunnel.phase.action != .connect {
                Section {
                    MessageRow(.info, "Изменения применятся при следующем подключении.").bykRow()
                }
            }

            Section {
                if dns.servers.isEmpty {
                    ForEach(DNSServer.defaultServers, id: \.self) { server in
                        DNSServerRow(text: server, note: "по умолчанию")
                            .bykRow()
                    }
                }
                ForEach(dns.servers, id: \.self) { server in
                    DNSServerRow(text: server, note: nil)
                        .contextMenu {
                            Button("Удалить", role: .destructive) {
                                routing.setDNS { $0.servers.removeAll { $0 == server } }
                            }
                        }
                        .bykRow()
                }
                #if !os(tvOS)
                .onMove { source, destination in routing.setDNS { $0.servers.move(fromOffsets: source, toOffset: destination) } }
                .onDelete { offsets in routing.setDNS { $0.servers.remove(atOffsets: offsets) } }
                #endif
                Button {
                    addingServer = true
                } label: {
                    Label("Добавить сервер", systemImage: "plus").font(.bykBody)
                }
                .bykRow()
                if usesDoTWithXray {
                    MessageRow(.warning, "В списке есть DoT, а подключение идёт через Xray: Xray не умеет DoT, подключение не запустится. Уберите DoT-сервер или выберите движок Mihomo.")
                        .bykRow()
                }
            } header: {
                SectionHeader("Серверы")
            } footer: {
                Text("Запросы идут к серверам по порядку. Пустой список — серверы по умолчанию.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            Section {
                if dns.domainServers.isEmpty {
                    Text("Нет. Например, для домашней сети или корпоративного домена можно указать свой сервер.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                        .bykRow()
                }
                ForEach(dns.domainServers) { entry in
                    LabeledContent {
                        Text(entry.server)
                            .font(.bykTechnical(.footnote))
                            .foregroundStyle(Color.bykSecondaryInk)
                    } label: {
                        Text(entry.domain).font(.bykBody).foregroundStyle(Color.bykInk)
                    }
                    .contextMenu {
                        Button("Удалить", role: .destructive) {
                            routing.setDNS { $0.domainServers.removeAll { $0.id == entry.id } }
                        }
                    }
                    .bykRow()
                }
                #if !os(tvOS)
                .onDelete { offsets in routing.setDNS { $0.domainServers.remove(atOffsets: offsets) } }
                #endif
                Button {
                    addingDomainServer = true
                } label: {
                    Label("Добавить домен", systemImage: "plus").font(.bykBody)
                }
                .bykRow()
            } header: {
                SectionHeader("Для отдельных доменов")
            } footer: {
                Text("Домен и все его поддомены спрашиваются у указанного сервера.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            Section {
                Toggle(isOn: Binding(get: { dns.leakProtection }, set: { value in routing.setDNS { $0.leakProtection = value } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Защита от утечек").font(.bykBody)
                        Text(dns.leakProtection
                            ? "Все запросы DNS идут через VPN, даже к сайтам, которые открываются напрямую."
                            : "Запросы DNS идут по правилам: к серверу, который открывается напрямую, — напрямую. Провайдер может видеть, какие сайты вы открываете.")
                            .font(.bykFootnote)
                            .foregroundStyle(dns.leakProtection ? Color.bykSecondaryInk : Color.bykAlert)
                    }
                }
                .bykRow()
                Toggle(isOn: Binding(get: { dns.ipv6 }, set: { value in routing.setDNS { $0.ipv6 = value } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Адреса IPv6").font(.bykBody)
                        Text("Выключите, если сайты открываются медленно или не открываются через сеть без IPv6.")
                            .font(.bykFootnote)
                            .foregroundStyle(Color.bykSecondaryInk)
                    }
                }
                .bykRow()
            } header: {
                SectionHeader("Защита и адреса")
            }

            if let error = routing.lastError {
                Section {
                    MessageRow(.error, error).bykRow()
                }
            }
        }
        .bykGroupedList()
        .navigationTitle("DNS")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
        #endif
        .sheet(isPresented: $addingServer) {
            DNSServerEditor(domainMode: false)
                .environmentObject(routing)
        }
        .sheet(isPresented: $addingDomainServer) {
            DNSServerEditor(domainMode: true)
                .environmentObject(routing)
        }
    }

    private var usesDoTWithXray: Bool {
        // The engine the selected profile starts with (its engine choice); without a profile, the build's first.
        let engine = library.selectedProfile.map { library.plannedEngine(for: $0) } ?? library.availableEngines.first
        guard engine == .xray else { return false }
        let all = dns.servers + dns.domainServers.map(\.server)
        return all.contains { (try? DNSServer.parse($0).get())?.kind == .tls }
    }
}

struct DNSServerRow: View {
    let text: String
    let note: String?

    var body: some View {
        let kind = (try? DNSServer.parse(text).get())?.kind
        HStack(spacing: CGFloat(Spacing.s)) {
            Text(text)
                .font(.bykTechnical(.body))
                .foregroundStyle(Color.bykInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: CGFloat(Spacing.xs))
            Text([kind?.title, note].compactMap { $0 }.joined(separator: " · "))
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Adds a server, or (domain mode) a server for one domain.
struct DNSServerEditor: View {
    @EnvironmentObject private var routing: RoutingSettingsModel
    @Environment(\.dismiss) private var dismiss
    let domainMode: Bool
    @State private var server = ""
    @State private var domain = ""

    private var serverResult: Result<DNSServer, PolicyInputError> { DNSServer.parse(server) }
    private var domainValue: String? { HostName.ascii(domain.hasPrefix("*.") ? String(domain.dropFirst(2)) : domain) }

    private var canSave: Bool {
        guard case .success = serverResult else { return false }
        return !domainMode || domainValue != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if domainMode {
                    Section {
                        TextField("example.org", text: $domain)
                            .font(.bykBody)
                            .autocorrectionDisabled()
                            #if os(iOS) || os(visionOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .bykRow()
                        if !domain.isEmpty && domainValue == nil {
                            MessageRow(.warning, "Это не похоже на домен. Пример: example.org.").bykRow()
                        }
                    } header: {
                        SectionHeader("Домен")
                    }
                }
                Section {
                    TextField("https://dns.example/dns-query", text: $server)
                        .font(.bykTechnical(.body))
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .bykRow()
                    switch serverResult {
                    case .success(let parsed):
                        if !server.isEmpty {
                            ValueRow("Тип", value: parsed.kind.title).bykRow()
                            if let note = parsed.engineNote {
                                MessageRow(.warning, note).bykRow()
                            }
                        }
                    case .failure(let error):
                        if !server.isEmpty {
                            MessageRow(.warning, error.message).bykRow()
                        }
                    }
                } header: {
                    SectionHeader("Сервер")
                } footer: {
                    Text("1.1.1.1 — обычный DNS по UDP; tcp://1.1.1.1 — по TCP; tls://1.1.1.1 — DoT; https://… — DoH.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }
            .bykGroupedList()
            .navigationTitle(domainMode ? "Сервер для домена" : "Сервер DNS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        guard case .success(let parsed) = serverResult else { return }
                        if domainMode {
                            guard let name = domainValue else { return }
                            routing.setDNS { $0.domainServers.append(DomainDNSRule(domain: name, server: parsed.text)) }
                        } else {
                            routing.setDNS { settings in
                                if !settings.servers.contains(parsed.text) { settings.servers.append(parsed.text) }
                            }
                        }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }
}
