// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46082491332 (workflow apple.yml)
// (Rebuilt from the version compiled on macOS CI in GitHub Actions run 46073714202.)
//
// Диагностика движка (level Профи, area Инструменты): which engine runs and why, its versions, the Go runtime's
// memory and goroutines as the bridge reports them, the extension's phys_footprint, uptime, traffic counters and
// the last errors (redacted). Data: the `.diagnostics` and `.statistics` provider messages. Refreshed every 2 s
// only while the screen is visible, the app is active and the tunnel is connected; nothing is estimated — a value
// the extension did not report is not shown.

import DesignSystem
import EngineSelection
import ProfileLibrary
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.scenePhase) private var scenePhase

    private var refreshing: Bool { tunnel.status == .connected && scenePhase == .active }

    var body: some View {
        List {
            engineSection
            memorySection
            trafficSection
            errorsSection
        }
        .bykGroupedList()
        .navigationTitle("Диагностика движка")
        .refreshable { await refresh() }
        .task(id: refreshing) {
            guard refreshing else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var engineSection: some View {
        Section {
            ValueRow("Туннель", value: tunnel.phase.stateWord)
            if let start = tunnel.currentStart {
                ValueRow("Движок", value: start.attempt.engine.displayName)
                ValueRow("Как запущен", value: DiagnosticsView.originText(start.attempt.origin))
            } else if let coreID = tunnel.selectedCoreID {
                ValueRow("Расширение", value: coreID, technical: true)
            }
            if let d = tunnel.diagnostics {
                if let version = d.coreVersion { ValueRow("Версия ядра", value: version, technical: true) }
                if let go = d.goVersion { ValueRow("Версия Go", value: go, technical: true) }
                if let abi = d.bridgeABI { ValueRow("ABI моста", value: "\(abi)", technical: true) }
                ValueRow("Состояние движка", value: d.coreState, technical: true)
                if let uptime = d.uptimeSeconds { ValueRow("Работает", value: UnitFormat.duration(seconds: uptime)) }
            } else if tunnel.status != .connected {
                note("Туннель не подключён — движок не запущен.")
            } else if tunnel.diagnosticsError == nil {
                note("Жду ответа расширения.")
            }
            ValueRow("Движки в сборке", value: tunnel.catalog.coreIDs.joined(separator: ", "), technical: true)
        } header: {
            SectionHeader("Движок")
        }
        .bykRow()
    }

    @ViewBuilder private var memorySection: some View {
        if let d = tunnel.diagnostics {
            Section {
                if let footprint = d.physicalFootprintBytes {
                    ValueRow("Расширение целиком", value: UnitFormat.bytes(footprint))
                }
                if let live = d.goHeapLiveBytes { ValueRow("Куча Go после сборки", value: UnitFormat.bytes(live)) }
                if let objects = d.goHeapObjectsBytes { ValueRow("Объекты в куче Go", value: UnitFormat.bytes(objects)) }
                if let mapped = d.goMappedBytes { ValueRow("Взято Go у системы", value: UnitFormat.bytes(mapped)) }
                if let stacks = d.goStacksBytes { ValueRow("Стеки горутин", value: UnitFormat.bytes(stacks)) }
                if let limit = d.goMemoryLimitBytes, limit > 0 { ValueRow("Предел памяти Go", value: UnitFormat.bytes(UInt64(limit))) }
                if let goroutines = d.goroutines { ValueRow("Горутины", value: "\(goroutines)") }
                if let cycles = d.gcCycles { ValueRow("Сборок мусора", value: "\(cycles)") }
                ValueRow("Сигналы нехватки памяти", value: "\(d.memoryPressureWarnings), критических \(d.memoryPressureCriticals)")
            } header: {
                SectionHeader("Память")
            } footer: {
                Text("«Расширение целиком» — phys_footprint процесса, его ограничивает система. Остальное сообщает среда Go моста.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
            .bykRow()
        }
    }

    @ViewBuilder private var trafficSection: some View {
        Section {
            if let traffic = tunnel.traffic {
                ValueRow("Отправлено", value: UnitFormat.bytes(traffic.uplinkBytes))
                ValueRow("Получено", value: UnitFormat.bytes(traffic.downlinkBytes))
            } else {
                note("Счётчиков нет: они приходят только от подключённого туннеля.")
            }
            if let error = tunnel.trafficError {
                MessageRow(.error, "Счётчики не получены: \(error)")
            }
        } header: {
            SectionHeader("Трафик с подключения")
        }
        .bykRow()
    }

    @ViewBuilder private var errorsSection: some View {
        Section {
            if let error = tunnel.diagnosticsError { MessageRow(.error, error) }
            if let d = tunnel.diagnostics {
                if let error = d.lifecycleError { MessageRow(.error, "Движок: \(error)") }
                if let error = d.bridgeError { MessageRow(.error, "Мост: \(error)") }
                ForEach(Array(d.recentErrors.reversed().enumerated()), id: \.offset) { _, record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DiagnosticsView.time(record.timeUnixMilliseconds) + " · " + record.kind)
                            .font(.bykCaption)
                            .foregroundStyle(Color.bykSecondaryInk)
                        Text(record.message)
                            .font(.bykTechnical(.footnote))
                            .foregroundStyle(Color.bykInk)
                            .fixedSize(horizontal: false, vertical: true)
                            #if !os(tvOS)
                            .textSelection(.enabled)
                            #endif
                    }
                }
                if let dropped = d.logRecordsDropped, dropped > 0 {
                    note("Журнал движка потерял \(RussianPlural.phrase(Int(clamping: dropped), one: "запись", few: "записи", many: "записей")) из-за переполнения очереди.")
                }
            }
            ValueRow("Последняя остановка", value: tunnel.lastDisconnectError ?? "нет")
            ValueRow("Приложение", value: tunnel.lastError ?? "нет")
            if let notice = tunnel.supervisorNotice { MessageRow(.warning, notice) }
        } header: {
            SectionHeader("Последние ошибки")
        }
        .bykRow()
    }

    // MARK: Helpers

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.bykFootnote)
            .foregroundStyle(Color.bykSecondaryInk)
    }

    private func refresh() async {
        guard tunnel.status == .connected else { return }
        await tunnel.refreshDiagnostics()
        await tunnel.refreshTraffic()
    }

    static func originText(_ origin: StartAttempt.Origin) -> String {
        switch origin {
        case .user: return "вручную"
        case .rollback: return "откат к последней рабочей настройке"
        case .engineFallback: return "запасной движок после сбоя"
        }
    }

    static func time(_ unixMilliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(unixMilliseconds) / 1000).formatted(date: .omitted, time: .standard)
    }
}
