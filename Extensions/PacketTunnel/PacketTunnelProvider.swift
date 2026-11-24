// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Minimal Packet Tunnel host (ADR-0001 §4, ADR-0003 §2–3).
//
// What it does: takes a start request (from the app, or from its own snapshot
// when the system starts it), applies the interface settings, drives one
// engine through `CoreLifecycle`, answers app messages, watches the engine and
// the memory pressure of the process.
//
// What is missing, and therefore what this file cannot do yet:
// - No engine adapter exists in the repository, so the registry below is
//   empty and every start ends with `core_not_registered`. The tunnel never
//   comes up without an engine; that is the intended failure.
// - The utun file descriptor is not located (ADR-0001 §4, risk R-08), so
//   `CoreStartOptions.tunnelFileDescriptor` is always `nil`.
// - There is no deadline for a start or stop that never returns; ADR-0001 §4
//   makes terminating the process the emergency path, and that path is not
//   written.
// - Network changes, sleep and wake are not handled.

import CoreAbstraction
import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NetworkPlatform.PacketTunnel", category: "tunnel")

    /// The engines linked into this extension. One engine per tunnel process
    /// (ADR-0001 §3, rule 1). Nothing is registered: there is no adapter yet.
    private let registry = CoreRegistry()

    private let session = TunnelSession()
    private let memoryMonitor = MemoryPressureMonitor()

    // MARK: Start and stop

    override func startTunnel(options: [String: NSObject]?) async throws {
        do {
            try await start(options: options)
        } catch {
            memoryMonitor.stop()
            await session.clear()
            // The description never contains the configuration: `CoreError`
            // carries codes and bounded engine messages only.
            log.error("start failed: \(PacketTunnelProvider.describe(error), privacy: .public)")
            throw PacketTunnelProvider.bridged(error)
        }
    }

    private func start(options: [String: NSObject]?) async throws {
        let snapshots = try ConfigurationSnapshotStore.inOwnContainer()

        let request: TunnelStartRequest
        if let fresh = try TunnelStartRequest.from(startOptions: options) {
            request = fresh
        } else if let saved = try snapshots.load() {
            // Started by the system: the last successful request is reused.
            request = saved
        } else {
            throw TunnelIPCError(code: "no_configuration", message: "no start request and no saved snapshot")
        }

        // Fail before touching the interface when the engine is not in this build.
        let core = try registry.makeCore(CoreIdentifier(request.coreID))
        let lifecycle = CoreLifecycle(core: core)

        try await setTunnelNetworkSettings(TunnelNetworkSettingsBuilder.makeSettings(for: request.network))

        memoryMonitor.start { [log] level, footprint in
            // Recorded only. `NetworkCore` has no way to ask an engine to
            // release memory yet; adding one waits for measurements (R-03).
            log.warning("memory pressure \(level.rawValue, privacy: .public), footprint \(footprint ?? 0) bytes")
        }

        let configuration = CoreConfiguration(
            coreID: CoreIdentifier(request.coreID),
            format: request.format,
            payload: request.configuration
        )
        let startOptions = CoreStartOptions(tunnelFileDescriptor: nil, mtu: request.network.mtu, memoryLimitBytes: nil)
        try await lifecycle.start(configuration, options: startOptions)

        await session.attach(lifecycle: lifecycle, coreID: request.coreID)

        do {
            try snapshots.save(request)
        } catch {
            // The tunnel works; only system-initiated starts are affected.
            log.error("snapshot was not saved: \(PacketTunnelProvider.describe(error), privacy: .public)")
        }

        await session.setWatchdog(makeWatchdog(for: lifecycle))
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("stop requested, reason \(reason.rawValue)")
        // The watchdog goes first, so that a failing stop is not reported as
        // an engine that died on its own.
        let lifecycle = await session.detach()
        memoryMonitor.stop()
        guard let lifecycle = lifecycle else { return }
        do {
            try await lifecycle.stop()
        } catch {
            log.error("engine stop failed: \(PacketTunnelProvider.describe(error), privacy: .public)")
        }
    }

    /// Watchdog (ADR-0001 §4): an engine that stops by itself must take the
    /// tunnel down, otherwise the interface keeps capturing traffic that
    /// nothing forwards.
    private func makeWatchdog(for lifecycle: CoreLifecycle) -> Task<Void, Never> {
        Task { [weak self] in
            for await state in await lifecycle.stateUpdates() {
                if Task.isCancelled { return }
                if state == .failed {
                    let failure: Error = await lifecycle.lastError ?? CoreError.unexpectedExit(message: "engine failed")
                    self?.log.error("engine failed, cancelling tunnel: \(PacketTunnelProvider.describe(failure), privacy: .public)")
                    self?.cancelTunnelWithError(PacketTunnelProvider.bridged(failure))
                    return
                }
                if state == .idle { return }
            }
        }
    }

    // MARK: App messages

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let response = await respond(to: messageData)
        return try? JSONEncoder().encode(response)
    }

    private func respond(to messageData: Data) async -> TunnelResponse {
        func failure(_ id: UInt64, _ code: String, _ message: String) -> TunnelResponse {
            TunnelResponse(
                version: TunnelIPC.protocolVersion,
                id: id,
                outcome: .failure(TunnelIPCError(code: code, message: message))
            )
        }

        guard messageData.count <= TunnelIPC.maximumMessageBytes else {
            return failure(0, "message_too_large", "message exceeds \(TunnelIPC.maximumMessageBytes) bytes")
        }
        guard let request = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            return failure(0, "malformed_request", "message is not a tunnel request")
        }
        guard request.version == TunnelIPC.protocolVersion else {
            return failure(request.id, "unsupported_version", "extension speaks version \(TunnelIPC.protocolVersion)")
        }

        switch request.body {
        case .status:
            return TunnelResponse(version: TunnelIPC.protocolVersion, id: request.id, outcome: .status(await statusReport()))
        case .statistics:
            guard let lifecycle = await session.lifecycle else {
                return failure(request.id, "not_running", "no engine is running")
            }
            do {
                let statistics = try await lifecycle.statistics()
                let report = TunnelTrafficReport(
                    uplinkBytes: statistics.traffic.uplinkBytes,
                    downlinkBytes: statistics.traffic.downlinkBytes
                )
                return TunnelResponse(version: TunnelIPC.protocolVersion, id: request.id, outcome: .statistics(report))
            } catch {
                let normalised = CoreError.normalise(error, during: .statistics)
                return failure(request.id, normalised.code, normalised.description)
            }
        }
    }

    private func statusReport() async -> TunnelStatusReport {
        let counts = memoryMonitor.counts
        var report = TunnelStatusReport(
            coreID: await session.coreID,
            coreState: "absent",
            lastError: nil,
            physicalFootprintBytes: MemoryPressureMonitor.physicalFootprintBytes(),
            memoryPressureWarnings: counts.warnings,
            memoryPressureCriticals: counts.criticals
        )
        if let lifecycle = await session.lifecycle {
            report.coreState = await lifecycle.state.rawValue
            report.lastError = await lifecycle.lastError?.description
        }
        return report
    }

    // MARK: Errors

    private static func describe(_ error: Error) -> String {
        if let core = error as? CoreError { return "\(core.code): \(core.description)" }
        if let ipc = error as? TunnelIPCError { return "\(ipc.code): \(ipc.message)" }
        return String(describing: type(of: error))
    }

    /// The system reports tunnel errors as `NSError`; a bare Swift enum would
    /// lose its text on the way.
    private static func bridged(_ error: Error) -> NSError {
        NSError(
            domain: "NetworkPlatform.Tunnel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: describe(error)]
        )
    }
}

/// The mutable state of one tunnel process. An actor, because the provider's
/// entry points and the watchdog run concurrently.
private actor TunnelSession {
    private(set) var lifecycle: CoreLifecycle?
    private(set) var coreID: String?
    private var watchdog: Task<Void, Never>?

    func attach(lifecycle: CoreLifecycle, coreID: String) {
        self.lifecycle = lifecycle
        self.coreID = coreID
    }

    func setWatchdog(_ task: Task<Void, Never>) {
        watchdog?.cancel()
        watchdog = task
    }

    /// Cancels the watchdog and hands the lifecycle over for stopping.
    func detach() -> CoreLifecycle? {
        watchdog?.cancel()
        watchdog = nil
        let current = lifecycle
        lifecycle = nil
        return current
    }

    func clear() {
        watchdog?.cancel()
        watchdog = nil
        lifecycle = nil
        coreID = nil
    }
}
