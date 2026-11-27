// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Пинг TCP and Проверка порта: TCP handshakes from the app (NetworkToolbox.TCPProbe). The name is resolved
// once through the system resolver; then each attempt opens a socket, waits for the handshake or the timeout,
// and closes it without sending data.

import DesignSystem
import NetworkToolbox
import SwiftUI

/// Resolves a host for a connect probe: an IP literal as is, a name through the system resolver (first
/// address returned; ASCII form for Cyrillic names).
enum EndpointLookup {
    struct Resolved: Sendable {
        let endpoint: SocketEndpoint
        /// Time the system resolver took; `nil` for an IP literal.
        let seconds: Double?
    }

    static func endpoint(host: String, port: UInt16, timeout: Double) -> Result<Resolved, ResolutionError> {
        if let literal = SocketEndpoint(address: host, port: port) {
            return .success(Resolved(endpoint: literal, seconds: nil))
        }
        guard let ascii = HostName.ascii(host) else { return .failure(.failed("имя не переводится в ASCII")) }
        switch SystemResolver.resolve(ascii, timeout: timeout) {
        case let .failure(error):
            return .failure(error)
        case let .success(resolution):
            guard let first = resolution.addresses.first, let endpoint = SocketEndpoint(address: first, port: port) else {
                return .failure(.notFound)
            }
            return .success(Resolved(endpoint: endpoint, seconds: resolution.seconds))
        }
    }
}

struct TCPPingTool: View {
    @State private var host = ""
    @State private var port = "443"
    @State private var count = ProbeLimits.defaultPingCount
    @State private var running = false
    @State private var flag = CancelFlag()
    @State private var endpoint: SocketEndpoint?
    @State private var resolveSeconds: Double?
    @State private var outcomes: [TCPConnectOutcome] = []
    @State private var error: String?

    private var input: (String, UInt16)? {
        guard let host = HostInput.host(host), let port = HostInput.port(port) else { return nil }
        return (host, port)
    }

    var body: some View {
        List {
            Section {
                TechnicalField(title: "Узел: example.com или 192.0.2.1", text: $host)
                TechnicalField(title: "Порт", text: $port, keyboardNumeric: true)
                #if os(tvOS)
                Picker(selection: $count) {
                    ForEach([1, 3, 5, 10, 20], id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    Text("Попыток").font(.bykBody)
                }
                #else
                Stepper(value: $count, in: ProbeLimits.pingCountRange) {
                    Text("Попыток: \(count)").font(.bykBody)
                }
                #endif
            } header: {
                SectionHeader("Куда")
            }
            .bykRow()

            Section {
                RunButton(title: "Пинговать", running: running, enabled: input != nil, action: start, stop: { flag.cancel() })
                    .listRowBackground(Color.clear)
                TunnelPathNote()
            }

            if let error = error {
                Section { MessageRow(.error, error) }.bykRow()
            }

            if !outcomes.isEmpty, let endpoint = endpoint {
                let summary = LatencySummary(outcomes: outcomes)
                Section {
                    VerdictRow(
                        summary.average.map { Measure.duration($0) } ?? "Нет ответа",
                        detail: "\(summary.received) из \(summary.sent) — потери \(Int(summary.lossPercent.rounded()))%",
                        tone: summary.received == 0 ? .problem : .neutral
                    )
                    ValueRow("Адрес", value: endpoint.displayText, technical: true)
                    if let resolveSeconds = resolveSeconds {
                        ValueRow("Разрешение имени", value: Measure.duration(resolveSeconds))
                    }
                    if let minimum = summary.minimum, let maximum = summary.maximum {
                        ValueRow("Мин. / макс.", value: "\(Measure.duration(minimum)) / \(Measure.duration(maximum))")
                    }
                    if let jitter = summary.jitter {
                        ValueRow("Разброс", value: Measure.duration(jitter))
                    }
                } header: {
                    SectionHeader("Итог")
                }
                .bykRow()

                Section {
                    ForEach(Array(outcomes.enumerated()), id: \.offset) { index, outcome in
                        ValueRow("Попытка \(index + 1)", value: Self.describe(outcome))
                    }
                } header: {
                    SectionHeader("Попытки")
                }
                .bykRow()
            }

            Section {
                EmptyView()
            } footer: {
                MethodNote("Время — от отправки SYN до установленного соединения TCP; данные не отправляются. ICMP-пинг приложению на устройствах Apple недоступен, поэтому меряется TCP. До \(ProbeLimits.pingCountRange.upperBound) попыток, каждая не дольше \(Int(ProbeLimits.defaultTimeout)) с, между ними \(Measure.duration(ProbeLimits.pingInterval)).")
            }
        }
        .bykGroupedList()
        .navigationTitle("Пинг TCP")
        .onDisappear { flag.cancel() }
    }

    static func describe(_ outcome: TCPConnectOutcome) -> String {
        switch outcome {
        case let .connected(seconds): return Measure.duration(seconds)
        case .refused: return "отказ (порт закрыт)"
        case .timedOut: return "нет ответа"
        case let .failed(text): return "ошибка: \(text)"
        }
    }

    private func start() {
        guard let (host, port) = input else { return }
        let flag = CancelFlag()
        self.flag = flag
        running = true
        error = nil
        outcomes = []
        endpoint = nil
        let attempts = count
        Task {
            let lookup = await Blocking.run { EndpointLookup.endpoint(host: host, port: port, timeout: ProbeLimits.defaultTimeout) }
            switch lookup {
            case let .failure(failure):
                error = failure.message
            case let .success(resolved):
                let target = resolved.endpoint
                endpoint = target
                resolveSeconds = resolved.seconds
                let results = await Blocking.run {
                    TCPProbe.ping(target, count: attempts, timeout: ProbeLimits.defaultTimeout) { flag.isCancelled }
                }
                outcomes = results
            }
            running = false
        }
    }
}

struct PortCheckTool: View {
    @State private var host = ""
    @State private var port = ""
    @State private var running = false
    @State private var result: (endpoint: SocketEndpoint, state: PortState)?
    @State private var error: String?

    private var input: (String, UInt16)? {
        guard let host = HostInput.host(host), let port = HostInput.port(port) else { return nil }
        return (host, port)
    }

    var body: some View {
        List {
            Section {
                TechnicalField(title: "Узел: example.com или 192.0.2.1", text: $host)
                TechnicalField(title: "Порт: 1–65535", text: $port, keyboardNumeric: true)
            } header: {
                SectionHeader("Куда")
            }
            .bykRow()

            Section {
                RunButton(title: "Проверить", running: running, enabled: input != nil, action: start)
                    .listRowBackground(Color.clear)
                TunnelPathNote()
            }

            if let error = error {
                Section { MessageRow(.error, error) }.bykRow()
            }

            if let result = result {
                Section {
                    VerdictRow(result.state.title, detail: result.state.explanation, tone: tone(result.state))
                    ValueRow("Адрес", value: result.endpoint.displayText, technical: true)
                    if case let .open(seconds) = result.state {
                        ValueRow("Соединение за", value: Measure.duration(seconds))
                    }
                } header: {
                    SectionHeader("Итог")
                }
                .bykRow()
            }

            Section {
                EmptyView()
            } footer: {
                MethodNote("Одна попытка соединения TCP с ожиданием до \(Int(ProbeLimits.defaultTimeout)) с. «Нет ответа» не отличает фильтр от недоступного узла — так устроен TCP. Порты UDP так не проверить: на UDP нет рукопожатия.")
            }
        }
        .bykGroupedList()
        .navigationTitle("Проверка порта")
    }

    private func tone(_ state: PortState) -> VerdictRow.Tone {
        switch state {
        case .open: return .good
        case .closed, .noAnswer: return .neutral
        case .failed: return .problem
        }
    }

    private func start() {
        guard let (host, port) = input else { return }
        running = true
        error = nil
        result = nil
        Task {
            let lookup = await Blocking.run { EndpointLookup.endpoint(host: host, port: port, timeout: ProbeLimits.defaultTimeout) }
            switch lookup {
            case let .failure(failure):
                error = failure.message
            case let .success(resolved):
                let target = resolved.endpoint
                let outcome = await Blocking.run { TCPProbe.connect(to: target, timeout: ProbeLimits.defaultTimeout) }
                result = (target, PortState(outcome))
            }
            running = false
        }
    }
}
