// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46083058268 (workflow apple.yml)
//
// Builds the exportable diagnostics text from engine-neutral facts only: app and system versions, tunnel and
// engine state, counters, outbound counters under neutral names, and the event timeline. Everything passes
// NetworkToolbox.DiagnosticsRedactor (keys, passwords, UUIDs, addresses, host names removed). Profiles,
// server addresses, connection destinations and toolbox results are never read here.

import DesignSystem
import Foundation
import NetworkToolbox

@MainActor
enum DiagnosticsBundleBuilder {
    static func text(tunnel: TunnelController, store: AnalyzerStore) -> String {
        var sections: [DiagnosticsBundle.Section] = []

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        sections.append(.init(title: "Приложение", lines: [
            ("Версия", "\(version) (\(build))"),
            ("Система", "\(platformName) \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"),
            ("Движки в сборке", tunnel.catalog.coreIDs.joined(separator: ", ")),
        ]))

        var tunnelLines: [(String, String)] = [
            ("Состояние", ConnectionPhase(vpnStatusRawValue: tunnel.status.rawValue).stateWord),
            ("Движок расширения", tunnel.selectedCoreID ?? "нет"),
        ]
        if let report = tunnel.engineReport {
            tunnelLines.append(("Состояние движка", report.coreState))
            if let footprint = report.physicalFootprintBytes {
                tunnelLines.append(("Память расширения", UnitFormat.bytes(footprint)))
            }
            tunnelLines.append(("Предупреждения о памяти", "\(report.memoryPressureWarnings), критических \(report.memoryPressureCriticals)"))
            if let error = report.lastError { tunnelLines.append(("Ошибка движка", error)) }
        }
        if let uptime = store.uptimeSeconds { tunnelLines.append(("Движок работает", AnalyzerScreen.uptimeText(uptime))) }
        if let traffic = tunnel.traffic {
            tunnelLines.append(("Отправлено", UnitFormat.bytes(traffic.uplinkBytes)))
            tunnelLines.append(("Получено", UnitFormat.bytes(traffic.downlinkBytes)))
        }
        if let active = store.connectionTotal ?? store.activeConnections {
            tunnelLines.append(("Активных соединений", "\(active)"))
        }
        tunnelLines.append(("Последняя остановка", tunnel.lastDisconnectError ?? "нет"))
        tunnelLines.append(("Ошибка приложения", tunnel.lastError ?? "нет"))
        if let path = store.currentPath { tunnelLines.append(("Сеть", path)) }
        sections.append(.init(title: "Туннель", lines: tunnelLines))

        if !store.outbounds.isEmpty {
            let names = DiagnosticsBundle.neutralNames(for: store.outbounds.map(\.tag))
            let lines = store.outbounds
                .sorted { (names[$0.tag] ?? "") < (names[$1.tag] ?? "") }
                .map { outbound in
                    (names[outbound.tag] ?? "выход", "вниз \(UnitFormat.bytes(outbound.downlinkBytes)), вверх \(UnitFormat.bytes(outbound.uplinkBytes))")
                }
            sections.append(.init(title: "Выходы", lines: lines))
        }

        let formatter = ISO8601DateFormatter()
        let events = store.timeline.events.map { event -> (String, String) in
            let kind: String
            switch event.kind {
            case .tunnel: kind = "туннель"
            case .network: kind = "сеть"
            case .error: kind = "ошибка"
            }
            let suffix = event.repeats > 1 ? " (×\(event.repeats))" : ""
            return ("\(formatter.string(from: event.time)) \(kind)", event.text + suffix)
        }
        if !events.isEmpty {
            sections.append(.init(title: "События", lines: events))
        }
        return DiagnosticsBundle(sections: sections).text()
    }

    private static var platformName: String {
        #if os(iOS)
        return "iOS/iPadOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "?"
        #endif
    }
}
