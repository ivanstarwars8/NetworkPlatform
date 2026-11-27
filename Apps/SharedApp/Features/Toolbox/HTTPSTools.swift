// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Время HTTPS-запроса (phases of one request) and Сертификат TLS (the chain the server presents and the
// system's verdict). Both use HTTPSProbe: one GET, bounded in time and bytes.

import DesignSystem
import NetworkToolbox
import SwiftUI

struct HTTPSTimingTool: View {
    @State private var address = ""
    @State private var running = false
    @State private var result: HTTPSProbeResult?
    @State private var inputError: String?

    var body: some View {
        List {
            Section {
                TechnicalField(title: "Адрес: example.com или https://example.com/path", text: $address)
            } header: {
                SectionHeader("Что открыть")
            }
            .bykRow()

            Section {
                RunButton(title: "Измерить", running: running, enabled: !address.isEmpty, action: start)
                    .listRowBackground(Color.clear)
                TunnelPathNote()
            }

            if let inputError = inputError {
                Section { MessageRow(.error, inputError) }.bykRow()
            }

            if let result = result {
                if let error = result.error {
                    Section { MessageRow(.error, error) }.bykRow()
                }
                if let stamps = result.timestamps {
                    let phases = HTTPPhases(stamps)
                    Section {
                        VerdictRow(
                            phases.firstByte.map { "Первый байт: \(Measure.duration($0))" } ?? "Ответа нет",
                            detail: phases.total.map { "Всего \(Measure.duration($0))" },
                            tone: result.error == nil ? .neutral : .problem
                        )
                        PhaseBar(phases: phases)
                        ValueRow("Имя (DNS)", value: Measure.optionalDuration(phases.dns))
                        ValueRow("Соединение TCP", value: Measure.optionalDuration(phases.connect))
                        ValueRow("Рукопожатие TLS", value: Measure.optionalDuration(phases.tls))
                        ValueRow("Ожидание ответа", value: Measure.optionalDuration(phases.firstByte))
                    } header: {
                        SectionHeader("Фазы")
                    }
                    .bykRow()
                }
                Section {
                    if let code = result.statusCode {
                        ValueRow("Код ответа", value: "\(code)", technical: true)
                    }
                    if let name = result.protocolName {
                        ValueRow("Протокол", value: name, technical: true)
                    }
                    if let remote = result.remoteAddress {
                        ValueRow("Адрес сервера", value: remote, technical: true)
                    }
                    ValueRow("Прочитано", value: UnitFormat.bytes(UInt64(result.bytesRead)) + (result.truncated ? ", дальше не читали" : ""))
                    if let trusted = result.trusted {
                        ValueRow("Сертификат", value: trusted ? "система доверяет" : "система не доверяет")
                    }
                } header: {
                    SectionHeader("Соединение")
                }
                .bykRow()
            }

            Section {
                EmptyView()
            } footer: {
                MethodNote("Один запрос GET в новом сеансе без кэша и cookie. Фазы записывает система (URLSessionTaskMetrics); фаза, которой не было, не выдумывается. Тело читается до \(UnitFormat.bytes(UInt64(HTTPProbeLimits.maximumBodyBytes))), ожидание — до \(Int(HTTPProbeLimits.timeout)) с. Проверяются только адреса https://.")
            }
        }
        .bykGroupedList()
        .navigationTitle("Время HTTPS-запроса")
    }

    private func start() {
        switch URLInput.httpsURL(address) {
        case let .failure(error):
            inputError = error.message
        case let .success(url):
            inputError = nil
            running = true
            result = nil
            Task {
                result = await HTTPSProbe.run(url)
                running = false
            }
        }
    }
}

/// The phases of one request as one horizontal bar, each segment proportional to its measured time. Ink
/// shades only: this is a measurement, not a state.
struct PhaseBar: View {
    let phases: HTTPPhases

    private var segments: [(label: String, value: Double, opacity: Double)] {
        [
            ("DNS", phases.dns ?? 0, 0.25),
            ("TCP", phases.connect ?? 0, 0.45),
            ("TLS", phases.tls ?? 0, 0.65),
            ("Ответ", phases.firstByte ?? 0, 0.9),
        ]
    }

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        if total > 0 {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(segments.indices, id: \.self) { index in
                        let segment = segments[index]
                        if segment.value > 0 {
                            Rectangle()
                                .fill(Color.bykInk.opacity(segment.opacity))
                                .frame(width: max(2, (proxy.size.width - 6) * segment.value / total))
                        }
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityHidden(true)
        }
    }
}

struct CertificateTool: View {
    @State private var host = ""
    @State private var port = "443"
    @State private var running = false
    @State private var checkedHost = ""
    @State private var result: HTTPSProbeResult?
    @State private var inputError: String?

    var body: some View {
        List {
            Section {
                TechnicalField(title: "Узел: example.com", text: $host)
                TechnicalField(title: "Порт", text: $port, keyboardNumeric: true)
            } header: {
                SectionHeader("Чей сертификат")
            }
            .bykRow()

            Section {
                RunButton(title: "Получить сертификат", running: running, enabled: HostInput.host(host) != nil, action: start)
                    .listRowBackground(Color.clear)
                TunnelPathNote()
            }

            if let inputError = inputError {
                Section { MessageRow(.error, inputError) }.bykRow()
            }

            if let result = result {
                if result.chain.isEmpty {
                    Section {
                        MessageRow(.error, result.error ?? "Сервер не прислал сертификат.")
                    }
                    .bykRow()
                } else {
                    Section {
                        trustVerdict(result)
                    }
                    .bykRow()
                    ForEach(Array(result.chain.enumerated()), id: \.offset) { index, certificate in
                        Section {
                            CertificateRows(certificate: certificate, host: index == 0 ? checkedHost : nil)
                        } header: {
                            SectionHeader(index == 0 ? "Сертификат сервера" : "Выше по цепочке, \(index)")
                        }
                        .bykRow()
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                MethodNote("Сертификаты берутся из рукопожатия TLS запроса GET; доверие оценивает система, как для любого приложения. Разбор показывает основное: имена, сроки, ключ и отпечаток SHA-256. Цепочку, которой система не доверяет, видно, но запрос на этом останавливается.")
            }
        }
        .bykGroupedList()
        .navigationTitle("Сертификат TLS")
    }

    @ViewBuilder private func trustVerdict(_ result: HTTPSProbeResult) -> some View {
        let leaf = result.chain[0]
        let covers = leaf.covers(host: checkedHost)
        if result.trusted == true, covers {
            VerdictRow("Система доверяет", detail: "Цепочка проверена, имя \(checkedHost) есть в сертификате.", tone: .good)
        } else if result.trusted == true {
            VerdictRow("Доверие есть, имя не совпало", detail: "Сертификат действителен, но имени \(checkedHost) в нём нет.", tone: .problem)
        } else {
            VerdictRow("Система не доверяет", detail: result.trustFailure ?? "Цепочка не прошла проверку системы.", tone: .problem)
        }
    }

    private func start() {
        guard let cleanHost = HostInput.host(host), let portNumber = HostInput.port(port) else {
            inputError = "Проверьте узел и порт."
            return
        }
        let ascii = HostName.ascii(cleanHost) ?? cleanHost
        let hostPart = SocketEndpoint(address: ascii, port: portNumber)?.isIPv6 == true ? "[\(ascii)]" : ascii
        guard let url = URL(string: "https://\(hostPart):\(portNumber)/") else {
            inputError = "Адрес не разобран. Проверьте узел."
            return
        }
        inputError = nil
        checkedHost = ascii
        running = true
        result = nil
        Task {
            result = await HTTPSProbe.run(url)
            running = false
        }
    }
}

struct CertificateRows: View {
    let certificate: CertificateSummary
    let host: String?

    var body: some View {
        ValueRow("Кому", value: certificate.subjectTitle)
        if let organization = certificate.subjectOrganization, organization != certificate.subjectTitle {
            ValueRow("Организация", value: organization)
        }
        ValueRow("Кем выдан", value: certificate.issuerTitle)
        if let start = certificate.notBefore {
            ValueRow("Действует с", value: Measure.dateTime.string(from: start))
        }
        if let end = certificate.notAfter {
            ValueRow("Действует до", value: Measure.dateTime.string(from: end))
        }
        validityRow
        if !certificate.dnsNames.isEmpty {
            ValueRow("Имена", value: certificate.dnsNames.prefix(20).joined(separator: "\n"), technical: true)
        }
        if !certificate.ipAddresses.isEmpty {
            ValueRow("Адреса", value: certificate.ipAddresses.joined(separator: "\n"), technical: true)
        }
        ValueRow("Ключ", value: certificate.publicKey)
        ValueRow("Подпись", value: certificate.signatureAlgorithm)
        ValueRow("Серийный номер", value: certificate.serialNumberHex, technical: true)
        ValueRow("SHA-256", value: certificate.sha256Fingerprint, technical: true)
    }

    @ViewBuilder private var validityRow: some View {
        switch certificate.validity(at: Date()) {
        case .notYetValid:
            MessageRow(.warning, "Срок действия ещё не начался.")
        case .expired:
            MessageRow(.error, "Срок действия истёк.")
        case let .valid(daysLeft) where daysLeft < 14:
            MessageRow(.warning, "Истекает через \(RussianPlural.phrase(daysLeft, one: "день", few: "дня", many: "дней")).")
        case let .valid(daysLeft):
            ValueRow("Осталось", value: RussianPlural.phrase(daysLeft, one: "день", few: "дня", many: "дней"))
        case .unknown:
            EmptyView()
        }
    }
}
