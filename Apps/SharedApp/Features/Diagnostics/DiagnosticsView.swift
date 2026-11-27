// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
// (Restyled from the version compiled on macOS CI in GitHub Actions run 46055850203; same data and refresh rule.)
//
// Диагностика движка (level Профи, area Инструменты): the tunnel state (NEVPNStatus), the extension's engine
// report and the bridge's byte counters over the provider-message IPC (`.status`, `.statistics`), and the last
// errors, redacted. Refreshed every 2 s only while the screen is visible, the app is active and the tunnel is
// connected.

import DesignSystem
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.scenePhase) private var scenePhase

    private var refreshing: Bool { tunnel.status == .connected && scenePhase == .active }

    var body: some View {
        List {
            Section {
                ValueRow("Состояние", value: tunnel.phase.stateWord)
                ValueRow("Движок расширения", value: tunnel.selectedCoreID ?? "нет", technical: tunnel.selectedCoreID != nil)
                ValueRow("Движки в сборке", value: tunnel.catalog.coreIDs.joined(separator: ", "), technical: true)
            } header: {
                SectionHeader("Туннель")
            }
            .bykRow()

            Section {
                if let report = tunnel.engineReport {
                    ValueRow("Движок", value: report.coreID ?? "нет", technical: report.coreID != nil)
                    ValueRow("Состояние движка", value: report.coreState, technical: true)
                    if let footprint = report.physicalFootprintBytes {
                        ValueRow("Память расширения", value: UnitFormat.bytes(footprint))
                    }
                    ValueRow("Предупреждения о памяти", value: "\(report.memoryPressureWarnings), критических \(report.memoryPressureCriticals)")
                    if let error = report.lastError {
                        MessageRow(.error, "Ошибка движка: \(error)")
                    }
                } else {
                    Text(tunnel.status == .connected ? "Отчёта ещё нет." : "Туннель не подключён — движок не запущен.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            } header: {
                SectionHeader("Движок")
            }
            .bykRow()

            Section {
                if let traffic = tunnel.traffic {
                    ValueRow("Отправлено", value: UnitFormat.bytes(traffic.uplinkBytes))
                    ValueRow("Получено", value: UnitFormat.bytes(traffic.downlinkBytes))
                } else {
                    Text("Счётчиков нет: они приходят только от подключённого туннеля.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
                if let error = tunnel.trafficError {
                    MessageRow(.error, "Счётчики не получены: \(error)")
                }
            } header: {
                SectionHeader("Трафик с подключения")
            }
            .bykRow()

            Section {
                ValueRow("Последняя остановка", value: tunnel.lastDisconnectError ?? "нет")
                ValueRow("Приложение", value: tunnel.lastError ?? "нет")
            } header: {
                SectionHeader("Последние ошибки")
            }
            .bykRow()

            Section {
                Button("Обновить") {
                    Task { await refresh() }
                }
                .disabled(tunnel.status != .connected)
            }
            .bykRow()
        }
        .bykGroupedList()
        .navigationTitle("Диагностика движка")
        .task(id: refreshing) {
            guard refreshing else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        guard tunnel.status == .connected else { return }
        await tunnel.queryEngine()
        await tunnel.refreshTraffic()
    }
}
