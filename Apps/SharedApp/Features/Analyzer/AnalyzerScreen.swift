// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46083058268 (workflow apple.yml)
//
// Анализатор (level Профи, area Инструменты): live traffic graph, outbound counters, connections, the error
// and network-change timeline, and the redacted diagnostics bundle. Samples are taken once per second only
// while this screen is visible, the app is active and the tunnel is connected; history is bounded and can be
// cleared. Numbers come from the engine's counters only.

import DesignSystem
import NetworkToolbox
import SwiftUI

struct AnalyzerScreen: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var store: AnalyzerStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingClear = false
    /// Built on request (not on every refresh): the redactor runs once per press.
    @State private var bundleText: String?

    private var sampling: Bool { tunnel.status == .connected && scenePhase == .active }

    var body: some View {
        List {
            trafficSection
            outboundSection
            connectionSection
            eventSection
            exportSection
        }
        .bykGroupedList()
        .navigationTitle("Анализатор")
        .task(id: sampling) {
            guard sampling else {
                store.pause()
                return
            }
            while !Task.isCancelled {
                await store.sample(using: tunnel)
                try? await Task.sleep(for: .seconds(1))
            }
            store.pause()
        }
        .confirmationDialog("Очистить историю анализатора?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                store.clear()
                bundleText = nil
            }
        } message: {
            Text("График, закрытые соединения и события будут удалены. Туннель это не затронет.")
        }
    }

    // MARK: Traffic

    @ViewBuilder private var trafficSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: CGFloat(Spacing.l)) {
                LiveNumber(label: "Вниз", bitsPerSecond: store.latest?.downBitsPerSecond)
                LiveNumber(label: "Вверх", bitsPerSecond: store.latest?.upBitsPerSecond)
                Spacer(minLength: 0)
            }
            .padding(.vertical, CGFloat(Spacing.xs))
            TrafficGraphView(points: store.points)
                .frame(height: 140)
                .padding(.vertical, CGFloat(Spacing.xs))
            if let uptime = store.uptimeSeconds, tunnel.status == .connected {
                ValueRow("Движок работает", value: Self.uptimeText(uptime))
            }
        } header: {
            SectionHeader("Трафик")
        } footer: {
            MethodNote(tunnel.status == .connected
                ? "Скорость — разница счётчиков движка за секунду. Последние 5 минут, пока экран открыт; сплошная линия — вниз, пунктир — вверх."
                : "Туннель не подключён: счётчиков нет.")
        }
        .bykRow()
    }

    static func uptimeText(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? "\(hours) ч \(minutes) мин" : (minutes > 0 ? "\(minutes) мин \(rest) с" : "\(rest) с")
    }

    // MARK: Outbounds

    @ViewBuilder private var outboundSection: some View {
        if tunnel.status == .connected {
            Section {
                if store.outbounds.isEmpty {
                    Text("Этот движок не считает трафик по выходам (так у Mihomo) или выходы ещё не передавали данных.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                } else {
                    ForEach(store.outbounds, id: \.tag) { outbound in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outbound.tag).font(.bykTechnical(.body))
                            Text("↓ \(UnitFormat.bytes(outbound.downlinkBytes))   ↑ \(UnitFormat.bytes(outbound.uplinkBytes))")
                                .font(.bykFootnote)
                                .foregroundStyle(Color.bykSecondaryInk)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                SectionHeader("Выходы")
            } footer: {
                MethodNote("Байты с запуска движка по тегам выходов конфигурации.")
            }
            .bykRow()
        }
    }

    // MARK: Connections

    @ViewBuilder private var connectionSection: some View {
        if tunnel.status == .connected || !store.connections.recentlyClosed.isEmpty {
            Section {
                if let active = store.connectionTotal ?? store.activeConnections {
                    ValueRow("Активных", value: "\(active)")
                }
                switch store.connectionListSupported {
                case .some(false):
                    Text("Движок Xray не ведёт список соединений; доступны только счётчики.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                case .some(true):
                    ForEach(store.connections.active.prefix(30)) { record in
                        ConnectionRow(record: record, closed: nil)
                    }
                    if store.connections.active.count > 30 {
                        Text("Показаны 30 самых новых из \(store.connections.active.count).")
                            .font(.bykFootnote)
                            .foregroundStyle(Color.bykSecondaryInk)
                    }
                case .none:
                    if tunnel.status == .connected {
                        ProgressView()
                    }
                }
                if let error = store.connectionError {
                    MessageRow(.error, "Список не получен: \(error)")
                }
            } header: {
                SectionHeader("Соединения")
            }
            .bykRow()

            if !store.connections.recentlyClosed.isEmpty {
                Section {
                    ForEach(store.connections.recentlyClosed.prefix(30)) { closed in
                        ConnectionRow(record: closed.record, closed: closed.closed)
                    }
                } header: {
                    SectionHeader("Недавно закрытые")
                } footer: {
                    MethodNote("Соединения, которые исчезли из списка движка, пока экран был открыт. До \(ConnectionTracker.recentCapacity) последних.")
                }
                .bykRow()
            }
        }
    }

    // MARK: Events

    @ViewBuilder private var eventSection: some View {
        Section {
            let events = store.timeline.events.reversed().prefix(50)
            if events.isEmpty {
                Text("Событий пока нет.").font(.bykFootnote).foregroundStyle(Color.bykSecondaryInk)
            }
            ForEach(Array(events)) { event in
                EventRow(event: event)
            }
        } header: {
            SectionHeader("События")
        } footer: {
            MethodNote("Смена состояния туннеля, ошибки и смена сети с запуска приложения, до \(EventTimeline.capacity) последних.")
        }
        .bykRow()
    }

    // MARK: Export and clear

    @ViewBuilder private var exportSection: some View {
        Section {
            if let text = bundleText {
                #if !os(tvOS)
                ShareLink(
                    item: text,
                    subject: Text("Диагностика «Быка»"),
                    preview: SharePreview("Диагностика «Быка»")
                ) {
                    Label("Поделиться диагностикой", systemImage: "square.and.arrow.up")
                }
                #endif
                Text(text)
                    .font(.bykTechnical(.caption))
                    .foregroundStyle(Color.bykSecondaryInk)
                    .lineLimit(12)
                    .textSelectionIfAvailable()
            }
            Button(bundleText == nil ? "Собрать диагностику" : "Собрать заново") {
                bundleText = DiagnosticsBundleBuilder.text(tunnel: tunnel, store: store)
            }
            Button("Очистить историю", role: .destructive) { confirmingClear = true }
        } footer: {
            MethodNote("В диагностику попадают состояния, счётчики, ошибки и события. Ключи, пароли, идентификаторы, адреса серверов, имена узлов и список соединений удаляются. Собранный текст можно прочитать до отправки.")
        }
        .bykRow()
    }
}

/// A big live number in the display face (Unbounded), with its label. Shows a dash until two samples exist.
struct LiveNumber: View {
    let label: String
    let bitsPerSecond: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let value = bitsPerSecond {
                let parts = UnitFormat.speed(bitsPerSecond: value)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.value)
                        .font(.byk(.title, family: .display, weight: .medium))
                        .monospacedDigit()
                    Text(parts.unit).font(.bykFootnote).foregroundStyle(Color.bykSecondaryInk)
                }
            } else {
                Text("—").font(.byk(.title, family: .display, weight: .medium)).foregroundStyle(Color.bykSecondaryInk)
            }
            Text(label).font(.bykCaption).foregroundStyle(Color.bykSecondaryInk)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Down (solid ink) and up (dashed secondary ink) over the window; a gap in sampling breaks the line rather
/// than drawing a made-up slope. No fill, no gradient.
struct TrafficGraphView: View {
    let points: [RatePoint]

    var body: some View {
        let maximum = TrafficGraph.axisMaximum(points)
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Path { path in
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = size.height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color.bykSeparator, lineWidth: 1)

                line(\.upBitsPerSecond, in: size, maximum: maximum)
                    .stroke(Color.bykSecondaryInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                line(\.downBitsPerSecond, in: size, maximum: maximum)
                    .stroke(Color.bykInk, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                Text(Measure.speed(maximum))
                    .font(.bykCaption)
                    .foregroundStyle(Color.bykSecondaryInk)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("График скорости за последние минуты")
    }

    private func line(_ value: KeyPath<RatePoint, Double>, in size: CGSize, maximum: Double) -> Path {
        Path { path in
            guard let last = points.last else { return }
            let window = Double(TrafficGraph.capacity)
            var previous: RatePoint?
            for point in points {
                let age = last.time.timeIntervalSince(point.time)
                guard age <= window else { continue }
                let x = size.width * CGFloat(1 - age / window)
                let y = size.height * CGFloat(1 - min(point[keyPath: value] / maximum, 1))
                if let previous = previous, point.time.timeIntervalSince(previous.time) <= 2.5 {
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.move(to: CGPoint(x: x, y: y))
                }
                previous = point
            }
        }
    }
}

struct ConnectionRow: View {
    let record: ConnectionRecord
    let closed: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.destination).font(.bykTechnical(.body)).lineLimit(1).truncationMode(.middle)
            Text(details).font(.bykFootnote).foregroundStyle(Color.bykSecondaryInk).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [record.network.uppercased()]
        if !record.chain.isEmpty { parts.append(record.chain.joined(separator: " → ")) }
        if let rule = record.rule { parts.append(rule) }
        parts.append("↓ \(UnitFormat.bytes(record.downloadBytes)) ↑ \(UnitFormat.bytes(record.uploadBytes))")
        if let closed = closed { parts.append("закрыто в \(Measure.clock.string(from: closed))") }
        return parts.joined(separator: " · ")
    }
}

struct EventRow: View {
    let event: EventTimeline.Event

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.text).font(.bykFootnote).foregroundStyle(Color.bykInk).fixedSize(horizontal: false, vertical: true)
                Text(event.repeats > 1 ? "\(Measure.clock.string(from: event.time)) · ×\(event.repeats)" : Measure.clock.string(from: event.time))
                    .font(.bykCaption)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(event.kind == .error ? Color.bykAlert : Color.bykSecondaryInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch event.kind {
        case .tunnel: return "power"
        case .network: return "antenna.radiowaves.left.and.right"
        case .error: return "exclamationmark.triangle"
        }
    }
}
