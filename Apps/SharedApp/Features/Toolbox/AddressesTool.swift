// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Адреса и IPv6: what the device knows without asking anyone (interface addresses, the system's path view of
// IPv4/IPv6), and — only after the user turns it on — the external address as seen by a named public service
// (Cloudflare's trace page, PublicAddressService), once over IPv4 and once over IPv6.

import DesignSystem
import Network
import NetworkToolbox
import SwiftUI

struct AddressesTool: View {
    @AppStorage("toolbox.publicAddressConsent") private var consent = false
    @State private var interfaces: [InterfaceAddress] = []
    @State private var path: PathSummary?
    @State private var publicV4: PublicLookup?
    @State private var publicV6: PublicLookup?
    @State private var asking = false

    enum PublicLookup {
        case found(PublicAddressService.Trace)
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                if let path = path {
                    ValueRow("Сеть", value: path.title)
                    ValueRow("IPv4", value: path.ipv4 ? "есть" : "нет")
                    ValueRow("IPv6", value: path.ipv6 ? "есть" : "нет")
                } else {
                    ProgressView()
                }
                ValueRow("Глобальный IPv6 на устройстве", value: hasGlobalIPv6 ? "есть" : "нет")
            } header: {
                SectionHeader("Доступность")
            } footer: {
                MethodNote("По данным системы о текущем пути (NWPathMonitor) и адресам интерфейсов; в сеть ничего не отправляется. «Есть IPv6» значит, что у пути есть маршрут IPv6, а не что конкретный сайт ответит.")
            }
            .bykRow()

            Section {
                if interfaces.isEmpty {
                    Text("Адресов нет.").font(.bykFootnote).foregroundStyle(Color.bykSecondaryInk)
                }
                ForEach(interfaces, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.address).font(.bykTechnical(.body)).textSelectionIfAvailable()
                        Text("\(item.interface) · \(item.isIPv6 ? "IPv6" : "IPv4") · \(item.scope.title)")
                            .font(.bykFootnote)
                            .foregroundStyle(Color.bykSecondaryInk)
                    }
                }
                Button("Обновить", action: refreshLocal)
            } header: {
                SectionHeader("Адреса устройства")
            }
            .bykRow()

            Section {
                Toggle(isOn: $consent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Спрашивать у \(PublicAddressService.name)").font(.bykBody)
                        Text("Внешний адрес виден только снаружи. Запрос уходит на 1.1.1.1 и 2606:4700:4700::1111; сервис увидит ваш адрес.")
                            .font(.bykFootnote)
                            .foregroundStyle(Color.bykSecondaryInk)
                    }
                }
                if consent {
                    RunButton(title: "Узнать внешний адрес", running: asking, enabled: true, action: askPublic)
                        .listRowBackground(Color.clear)
                    TunnelPathNote()
                    if let publicV4 = publicV4 { publicRow("Через IPv4", publicV4) }
                    if let publicV6 = publicV6 { publicRow("Через IPv6", publicV6) }
                }
            } header: {
                SectionHeader("Внешний адрес")
            } footer: {
                MethodNote("Выключено по умолчанию. Один запрос HTTPS на каждый адрес, не больше \(UnitFormat.bytes(UInt64(PublicAddressService.maximumBytes))) ответа, ожидание до 8 с.")
            }
            .bykRow()
        }
        .bykGroupedList()
        .navigationTitle("Адреса и IPv6")
        .task {
            refreshLocal()
            path = await PathSummary.current()
        }
    }

    private var hasGlobalIPv6: Bool {
        interfaces.contains { $0.isIPv6 && $0.scope == .global }
    }

    @ViewBuilder private func publicRow(_ title: String, _ lookup: PublicLookup) -> some View {
        switch lookup {
        case let .found(trace):
            ValueRow(title, value: trace.location.map { "\(trace.address) (\($0))" } ?? trace.address, technical: true)
        case let .failed(text):
            ValueRow(title, value: text)
        }
    }

    private func refreshLocal() {
        Task {
            let found = await Blocking.run { AddressClassifier.interfaceAddresses() }
            interfaces = found.filter { $0.scope != .loopback }
        }
    }

    private func askPublic() {
        asking = true
        publicV4 = nil
        publicV6 = nil
        Task {
            async let v4 = Self.lookup(PublicAddressService.ipv4URL)
            async let v6 = Self.lookup(PublicAddressService.ipv6URL)
            let (first, second) = await (v4, v6)
            publicV4 = first
            publicV6 = second
            asking = false
        }
    }

    private static func lookup(_ url: URL) async -> PublicLookup {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("сервис ответил ошибкой")
            }
            guard let trace = PublicAddressService.parse(data) else {
                return .failed("ответ не разобран")
            }
            return .found(trace)
        } catch let error as URLError where error.code == .timedOut || error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .notConnectedToInternet || error.code == .cannotFindHost {
            return .failed("недоступен")
        } catch {
            return .failed("не получилось: \(error.localizedDescription)")
        }
    }
}

/// The system's view of the current network path, read once.
struct PathSummary: Sendable {
    let title: String
    let ipv4: Bool
    let ipv6: Bool

    init(_ path: NWPath) {
        ipv4 = path.supportsIPv4
        ipv6 = path.supportsIPv6
        title = PathSummary.describe(path)
    }

    static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else {
            return path.status == .requiresConnection ? "нужно подключение" : "нет сети"
        }
        var kinds: [String] = []
        if path.usesInterfaceType(.wifi) { kinds.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { kinds.append("сотовая") }
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("кабель") }
        if path.usesInterfaceType(.other) { kinds.append("другая (возможно, VPN)") }
        if kinds.isEmpty { kinds.append("есть") }
        var text = kinds.joined(separator: ", ")
        if path.isExpensive { text += ", платная" }
        if path.isConstrained { text += ", экономия трафика" }
        return text
    }

    /// Starts a monitor, takes its first update and cancels it.
    static func current() async -> PathSummary {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = OnceFlag()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                // Drop the handler (it holds the monitor) and stop: one reading only.
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: PathSummary(path))
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

extension View {
    @ViewBuilder func textSelectionIfAvailable() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
