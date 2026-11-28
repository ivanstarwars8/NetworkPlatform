// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46083058268 (workflow apple.yml)
//
// Запрос DNS (records A/AAAA through a resolver the user picks) and Утечка DNS (NetworkToolbox.DNSPathCheck:
// the system's resolvers against the tunnel's, plus one query straight to the tunnel's resolver). No
// third-party leak-test service is involved.

import DesignSystem
import DomainModels
import NetworkToolbox
import SwiftUI

struct DNSLookupTool: View {
    enum ResolverChoice: Hashable {
        case system
        case tunnel
        case preset(String)
        case custom
    }

    enum RecordChoice: String, CaseIterable, Identifiable {
        case both, a, aaaa
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: return "A и AAAA"
            case .a: return "A (IPv4)"
            case .aaaa: return "AAAA (IPv6)"
            }
        }
        var types: [DNSRecordType] {
            switch self {
            case .both: return [.a, .aaaa]
            case .a: return [.a]
            case .aaaa: return [.aaaa]
            }
        }
    }

    /// Public resolvers offered by name. The user chooses one explicitly; nothing is asked by default.
    struct Preset: Hashable {
        let name: String
        let address: String
    }

    static let presets: [Preset] = [
        Preset(name: "Cloudflare", address: "1.1.1.1"),
        Preset(name: "Google", address: "8.8.8.8"),
        Preset(name: "Яндекс", address: "77.88.8.8"),
        Preset(name: "Quad9", address: "9.9.9.9"),
    ]

    @EnvironmentObject private var tunnel: TunnelController
    @State private var name = ""
    @State private var resolver: ResolverChoice = .system
    @State private var customResolver = ""
    @State private var records: RecordChoice = .both
    @State private var running = false
    @State private var results: [Line] = []
    @State private var error: String?

    struct Line: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let technical: Bool
    }

    private var resolverEndpoint: SocketEndpoint?? {
        switch resolver {
        case .system: return .some(nil)
        case .tunnel: return SocketEndpoint(address: TunnelAddressing.standard.dnsIPv4Address, port: DNSClient.port).map { .some($0) }
        case let .preset(address): return SocketEndpoint(address: address, port: DNSClient.port).map { .some($0) }
        case .custom: return SocketEndpoint(address: customResolver, port: DNSClient.port).map { .some($0) }
        }
    }

    private var canRun: Bool {
        HostInput.host(name) != nil && resolverEndpoint != nil
    }

    var body: some View {
        List {
            Section {
                TechnicalField(title: "Имя: example.com", text: $name)
                Picker(selection: $records) {
                    ForEach(RecordChoice.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Записи").font(.bykBody)
                }
            } header: {
                SectionHeader("Что спросить")
            }
            .bykRow()

            Section {
                Picker(selection: $resolver) {
                    Text("Системный").tag(ResolverChoice.system)
                    if tunnel.status == .connected {
                        Text("Резолвер туннеля").tag(ResolverChoice.tunnel)
                    }
                    ForEach(Self.presets, id: \.address) { preset in
                        Text("\(preset.name), \(preset.address)").tag(ResolverChoice.preset(preset.address))
                    }
                    Text("Свой адрес").tag(ResolverChoice.custom)
                } label: {
                    Text("Резолвер").font(.bykBody)
                }
                if resolver == .custom {
                    TechnicalField(title: "IP резолвера", text: $customResolver)
                }
            } header: {
                SectionHeader("Кого спросить")
            } footer: {
                MethodNote(resolverNote)
            }
            .bykRow()

            Section {
                RunButton(title: "Спросить", running: running, enabled: canRun, action: start)
                    .listRowBackground(Color.clear)
                TunnelPathNote()
            }

            if let error = error {
                Section { MessageRow(.error, error) }.bykRow()
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { line in
                        ValueRow(line.title, value: line.value, technical: line.technical)
                    }
                } header: {
                    SectionHeader("Ответ")
                }
                .bykRow()
            }
        }
        .bykGroupedList()
        .navigationTitle("Запрос DNS")
        .onChange(of: tunnel.status) {
            if resolver == .tunnel, tunnel.status != .connected { resolver = .system }
        }
    }

    private var resolverNote: String {
        switch resolver {
        case .system:
            return "Через системный резолвер (getaddrinfo): так имя разрешают приложения. Время жизни записей система не сообщает."
        case .tunnel:
            return "Запрос UDP на резолвер туннеля \(TunnelAddressing.standard.dnsIPv4Address): отвечает движок туннеля."
        case .preset, .custom:
            return "Один запрос UDP на порт 53 выбранного резолвера, ожидание до \(Int(ProbeLimits.defaultTimeout)) с. Резолвер увидит имя, которое вы спрашиваете. DNS поверх HTTPS и TLS здесь не проверяется."
        }
    }

    private func start() {
        guard let host = HostInput.host(name), case let .some(endpoint) = resolverEndpoint else { return }
        let types = records.types
        running = true
        error = nil
        results = []
        Task {
            if let endpoint = endpoint {
                for type in types {
                    let outcome = await Blocking.run {
                        DNSClient.lookup(host, type: type, resolver: endpoint, timeout: ProbeLimits.defaultTimeout)
                    }
                    switch outcome {
                    case let .success(result):
                        results.append(Line(title: "\(type.name): код", value: result.response.responseCodeName, technical: true))
                        results.append(Line(title: "\(type.name): время ответа", value: Measure.duration(result.seconds), technical: false))
                        if result.response.truncated {
                            results.append(Line(title: "\(type.name)", value: "ответ обрезан (нужен TCP)", technical: false))
                        }
                        for record in result.response.answers {
                            results.append(Line(title: "\(record.type.name), TTL \(record.ttl) с", value: record.valueText, technical: true))
                        }
                        if result.response.answers.isEmpty {
                            results.append(Line(title: type.name, value: "записей нет", technical: false))
                        }
                    case let .failure(failure):
                        results.append(Line(title: type.name, value: failure.message, technical: false))
                    }
                }
            } else {
                guard let ascii = HostName.ascii(host) else {
                    error = "Имя не переводится в ASCII. Проверьте написание."
                    running = false
                    return
                }
                let outcome = await Blocking.run { SystemResolver.resolve(ascii, timeout: ProbeLimits.defaultTimeout) }
                switch outcome {
                case let .success(resolution):
                    results.append(Line(title: "Время", value: Measure.duration(resolution.seconds), technical: false))
                    for address in resolution.addresses {
                        let isV6 = SocketEndpoint(address: address, port: 0)?.isIPv6 ?? false
                        guard (isV6 && types.contains(.aaaa)) || (!isV6 && types.contains(.a)) else { continue }
                        results.append(Line(title: isV6 ? "AAAA" : "A", value: address, technical: true))
                    }
                    if results.count == 1 {
                        results.append(Line(title: "Адреса", value: "нет записей этого типа", technical: false))
                    }
                case let .failure(failure):
                    error = failure.message
                }
            }
            running = false
        }
    }
}

struct DNSLeakTool: View {
    @EnvironmentObject private var tunnel: TunnelController
    @State private var running = false
    @State private var check: DNSPathCheck?

    var body: some View {
        List {
            Section {
                RunButton(title: "Проверить", running: running, enabled: true, action: start)
                    .listRowBackground(Color.clear)
            } footer: {
                MethodNote("Проверка сравнивает резолверы, которые система использует сейчас, с резолверами туннеля (\(TunnelAddressing.standard.dnsServers.joined(separator: ", "))) и отправляет один запрос прямо резолверу туннеля. Сторонние сервисы не участвуют. Ограничение: видна системная настройка DNS, а не каждое приложение — программа со своим DNS поверх HTTPS обходит системный резолвер, и такая проверка этого не покажет.")
            }

            if let check = check {
                Section {
                    VerdictRow(check.title, detail: check.explanation, tone: tone(check.verdict))
                    ValueRow("Туннель", value: check.tunnelConnected ? "подключён" : "не подключён")
                    ValueRow(
                        "Резолверы системы",
                        value: check.systemResolvers.map { $0.isEmpty ? "нет" : $0.joined(separator: ", ") } ?? "не прочитаны",
                        technical: check.systemResolvers?.isEmpty == false
                    )
                    ValueRow("Резолверы туннеля", value: check.tunnelResolvers.joined(separator: ", "), technical: true)
                    ValueRow("Ответ резолвера туннеля", value: probeText(check.probe))
                } header: {
                    SectionHeader("Итог")
                }
                .bykRow()
            }
        }
        .bykGroupedList()
        .navigationTitle("Утечка DNS")
    }

    private func tone(_ verdict: DNSPathCheck.Verdict) -> VerdictRow.Tone {
        switch verdict {
        case .protected: return .good
        case .leaking, .tunnelResolverSilent: return .problem
        case .tunnelOff, .unknown: return .neutral
        }
    }

    private func probeText(_ probe: DNSPathCheck.ProbeResult) -> String {
        switch probe {
        case let .answered(seconds): return "есть, \(Measure.duration(seconds))"
        case let .failed(text): return text
        case .notRun: return "не спрашивали (туннель выключен)"
        }
    }

    private func start() {
        running = true
        let connected = tunnel.status == .connected
        let tunnelResolvers = TunnelAddressing.standard.dnsServers
        Task {
            let system = await Blocking.run { SystemDNSConfiguration.resolvers() }
            var probe = DNSPathCheck.ProbeResult.notRun
            if connected, let endpoint = SocketEndpoint(address: TunnelAddressing.standard.dnsIPv4Address, port: DNSClient.port) {
                let outcome = await Blocking.run {
                    DNSClient.lookup("apple.com", type: .a, resolver: endpoint, timeout: ProbeLimits.defaultTimeout)
                }
                switch outcome {
                case let .success(result): probe = .answered(seconds: result.seconds)
                case let .failure(failure): probe = .failed(failure.message)
                }
            }
            check = DNSPathCheck(tunnelConnected: connected, tunnelResolvers: tunnelResolvers, systemResolvers: system, probe: probe)
            running = false
        }
    }
}
