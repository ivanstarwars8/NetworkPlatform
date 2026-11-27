// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46083058268 (workflow apple.yml)
//
// Проверки сети (level Профи, area Инструменты): the list of network tools. Each tool runs only when the
// user presses its button, is bounded in time and bytes (NetworkToolbox.ProbeLimits, HTTPProbeLimits) and says
// how it measures and what the platform does not allow.

import DesignSystem
import SwiftUI

struct ToolboxScreen: View {
    private enum Tool: String, CaseIterable, Identifiable {
        case tcpPing, port, dns, https, certificate, addresses, dnsLeak

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tcpPing: return "Пинг TCP"
            case .port: return "Проверка порта"
            case .dns: return "Запрос DNS"
            case .https: return "Время HTTPS-запроса"
            case .certificate: return "Сертификат TLS"
            case .addresses: return "Адреса и IPv6"
            case .dnsLeak: return "Утечка DNS"
            }
        }

        var summary: String {
            switch self {
            case .tcpPing: return "Время установки соединения до узла, потери, разброс."
            case .port: return "Открыт, закрыт или молчит порт на узле."
            case .dns: return "Записи A и AAAA через выбранный резолвер."
            case .https: return "DNS, соединение, TLS и первый байт по отдельности."
            case .certificate: return "Кому выдан, кем, до какого числа и доверяет ли система."
            case .addresses: return "Адреса устройства, доступность IPv4 и IPv6, внешний адрес."
            case .dnsLeak: return "Идут ли запросы DNS мимо туннеля."
            }
        }

        var systemImage: String {
            switch self {
            case .tcpPing: return "arrow.left.arrow.right"
            case .port: return "door.left.hand.open"
            case .dns: return "character.book.closed"
            case .https: return "timer"
            case .certificate: return "checkmark.seal"
            case .addresses: return "network"
            case .dnsLeak: return "drop"
            }
        }

        @MainActor @ViewBuilder var screen: some View {
            switch self {
            case .tcpPing: TCPPingTool()
            case .port: PortCheckTool()
            case .dns: DNSLookupTool()
            case .https: HTTPSTimingTool()
            case .certificate: CertificateTool()
            case .addresses: AddressesTool()
            case .dnsLeak: DNSLeakTool()
            }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(Tool.allCases) { tool in
                    NavigationLink {
                        tool.screen
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title).font(.bykBody)
                                Text(tool.summary)
                                    .font(.bykFootnote)
                                    .foregroundStyle(Color.bykSecondaryInk)
                            }
                        } icon: {
                            Image(systemName: tool.systemImage)
                                .foregroundStyle(Color.bykSecondaryInk)
                        }
                    }
                    .bykRow()
                }
            } footer: {
                MethodNote("Каждая проверка запускается только кнопкой и ограничена по времени. Результаты остаются на устройстве и не попадают в диагностику.")
            }
        }
        .bykGroupedList()
        .navigationTitle("Проверки сети")
    }
}
