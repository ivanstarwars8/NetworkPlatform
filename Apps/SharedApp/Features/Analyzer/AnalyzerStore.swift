// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// State of the analyser, owned by the app (so a short trip to another screen does not wipe it) and bounded
// everywhere (NetworkToolbox: TrafficGraph.capacity points, EventTimeline.capacity events,
// ConnectionTracker.recentCapacity closed connections).
//
// Two kinds of input, both outside the packet path:
//   - events: tunnel status and error changes (observed from TunnelController's published values) and
//     network path changes (NWPathMonitor callbacks). Event-driven, no polling; recorded for the app's lifetime.
//   - samples: byte counters, per-outbound counters and the connection list, requested from the extension
//     once per second only while the analyser is visible, the app is active and the tunnel is connected
//     (AnalyzerScreen's `.task(id:)` ends otherwise).

import Combine
import DesignSystem
import Foundation
import Network
import NetworkToolbox

@MainActor
final class AnalyzerStore: ObservableObject {
    @Published private(set) var points: [RatePoint] = []
    @Published private(set) var latest: RatePoint?
    @Published private(set) var outbounds: [TunnelTrafficReport.Outbound] = []
    @Published private(set) var activeConnections: Int?
    @Published private(set) var uptimeSeconds: Double?
    @Published private(set) var connections = ConnectionTracker()
    @Published private(set) var connectionTotal: Int?
    /// `nil` until the engine was asked; false when it keeps no list (Xray).
    @Published private(set) var connectionListSupported: Bool?
    @Published private(set) var connectionError: String?
    @Published private(set) var timeline = EventTimeline()
    @Published private(set) var currentPath: String?

    private var sampler = RateSampler()
    private var history = BoundedHistory<RatePoint>(capacity: TrafficGraph.capacity)
    private var subscriptions: Set<AnyCancellable> = []
    private var monitor: NWPathMonitor?
    private weak var tunnel: TunnelController?

    // MARK: Events

    /// Starts recording events. Called once from the app; later calls do nothing.
    func attach(to tunnel: TunnelController) {
        guard self.tunnel == nil else { return }
        self.tunnel = tunnel

        tunnel.$status
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                let word = ConnectionPhase(vpnStatusRawValue: status.rawValue).stateWord
                self?.timeline.record(.tunnel, word)
                if status != .connected { self?.sampler.reset() }
            }
            .store(in: &subscriptions)

        for publisher in [tunnel.$lastError, tunnel.$lastDisconnectError, tunnel.$trafficError] {
            publisher
                .removeDuplicates()
                .compactMap { $0 }
                .sink { [weak self] text in self?.timeline.record(.error, text) }
                .store(in: &subscriptions)
        }

        tunnel.$engineReport
            .compactMap { $0?.lastError }
            .removeDuplicates()
            .sink { [weak self] text in self?.timeline.record(.error, "Движок: \(text)") }
            .store(in: &subscriptions)

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let text = PathSummary.describe(path)
            Task { @MainActor in self?.pathChanged(text) }
        }
        monitor.start(queue: DispatchQueue(label: "analyzer.path", qos: .utility))
        self.monitor = monitor
    }

    private func pathChanged(_ text: String) {
        guard text != currentPath else { return }
        let first = currentPath == nil
        currentPath = text
        timeline.record(.network, first ? "Сеть: \(text)" : "Сеть сменилась: \(text)")
    }

    // MARK: Samples

    /// One sampling step: counters, then the connection list where the engine keeps one.
    func sample(using tunnel: TunnelController) async {
        guard tunnel.status == .connected else {
            sampler.reset()
            return
        }
        do {
            let report = try await tunnel.queryTraffic()
            let point = sampler.add(
                up: report.uplinkBytes,
                down: report.downlinkBytes,
                monotonicTime: ProcessInfo.processInfo.systemUptime,
                wallTime: Date()
            )
            if let point = point {
                history.append(point)
                points = history.elements
                latest = point
            }
            outbounds = report.outbounds ?? []
            activeConnections = report.activeConnections
            uptimeSeconds = report.uptimeSeconds
        } catch let error as TunnelIPCError {
            timeline.record(.error, "Счётчики не получены: \(TunnelController.redacted(error.summary))")
            sampler.reset()
            latest = nil
        } catch {
            sampler.reset()
            latest = nil
        }

        guard connectionListSupported != false else { return }
        do {
            let report = try await tunnel.queryConnections()
            connectionListSupported = true
            connectionTotal = report.total
            connectionError = nil
            connections.update(report.items.map { item in
                ConnectionRecord(
                    id: item.id,
                    network: item.network,
                    destination: item.destination,
                    rule: item.rule,
                    chain: item.chain,
                    uploadBytes: item.uploadBytes,
                    downloadBytes: item.downloadBytes,
                    started: item.startedAt
                )
            })
        } catch let error as TunnelIPCError where error.code.rawValue == "unsupported_feature" {
            connectionListSupported = false
        } catch let error as TunnelIPCError {
            connectionError = TunnelController.redacted(error.summary)
        } catch {
            connectionError = "\(type(of: error))"
        }
    }

    /// The screen went away or the tunnel went down: the next rate needs two fresh samples.
    func pause() {
        sampler.reset()
        latest = nil
    }

    func clear() {
        history.removeAll()
        points = []
        latest = nil
        sampler.reset()
        connections.clear()
        connectionTotal = nil
        connectionError = nil
        timeline.clear()
    }
}
