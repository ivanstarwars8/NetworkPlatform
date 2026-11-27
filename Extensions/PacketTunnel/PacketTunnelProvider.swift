// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 45987643793 (workflow apple.yml)
//
// Minimal Packet Tunnel host (ADR-0001 §4, ADR-0003 §2–3).
//
// What it does: takes a start reference (from the app) or its own snapshot
// (when the system starts it), applies the interface settings, drives one
// engine through `CoreLifecycle`, answers app messages, watches the engine
// and the memory pressure of the process, forwards sleep and wake.
//
// The order of operations (start, rollback, stop, their overlap) lives in
// TunnelSession.swift, which is tested on Linux; this file only supplies the
// Network Extension calls. See Documentation/Architecture/control-plane-lifecycle.md.
//
// Rules this file keeps:
// - Every wait on the engine has a deadline (`TunnelDeadlines`).
// - An engine call that never returns leaves the process unusable (one
//   engine instance per process, ADR-0001). The process then exits after
//   reporting the failure: the emergency path of ADR-0001 §4.
// - No task captures the provider strongly, and nothing non-Sendable crosses
//   a task boundary except through `ProviderReference`.
//
// Engines: in flavours with Xray (`NP_ENGINE_XRAY`) the registry holds the
// `XrayCore` adapter (Packages/EngineXray) over the C archive of the bridge
// (XrayBridgeBinding.swift), with the packet pump on `packetFlow`. In any
// other flavour the registry stays empty and a start ends with
// `core_not_registered`. Nothing of this has run on a device.
//
// What is missing, and therefore what this file cannot do yet:
// - The utun file descriptor is not located (ADR-0001 §4, risk R-08), so
//   `CoreStartOptions.tunnelFileDescriptor` is always `nil`.
// - Network path changes are not observed.

import CoreAbstraction
#if NP_ENGINE_XRAY
import EngineXray
#endif
import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NetworkPlatform.PacketTunnel", category: "tunnel")

    /// The engines linked into this extension. One engine per tunnel process
    /// (ADR-0001 §3, rule 1). Filled by `registerEngines()` on the first start.
    private let registry = CoreRegistry()

    private let session = TunnelSession()
    private let memoryMonitor = MemoryPressureMonitor()

    private let deadlines = TunnelDeadlines.standard

    // MARK: Start and stop

    override func startTunnel(options: [String: NSObject]?) async throws {
        #if NP_ENGINE_XRAY
        let abi = XrayBridgeInfo.abiVersion
        log.info("xray bridge linked, abi \(abi), \(XrayBridgeInfo.versionJSON(), privacy: .public)")
        if abi != XrayBridgeInfo.expectedABIVersion {
            log.error("xray bridge abi \(abi) differs from the expected \(XrayBridgeInfo.expectedABIVersion)")
        }
        #endif
        registerEngines()
        do {
            // Decoded here, synchronously: the options dictionary is not
            // Sendable and must not travel further.
            let reference = try TunnelStartReference.from(startOptions: options)
            // Not fatal when unavailable: a start with a fresh request does
            // not need the snapshot, it only cannot save one.
            let snapshots = try? ConfigurationSnapshotStore.inOwnContainer()
            let registry = self.registry

            let request = try await TunnelRunner.start(session: session, deadlines: deadlines, hooks: makeHooks()) {
                let request: TunnelStartRequest
                if let reference = reference {
                    let handoff = ConfigurationHandoff(directory: try ConfigurationHandoff.sharedDirectory())
                    // ADR-0008: both sides remove leftovers older than `staleAfter`.
                    defer { handoff.removeStale() }
                    request = try handoff.consume(reference)
                } else if let saved = try snapshots?.load() {
                    // Started by the system: the last successful request is reused.
                    request = saved
                } else {
                    throw TunnelIPCError(.noConfiguration, "no start reference and no saved snapshot")
                }
                // Fails before the interface is touched when the engine is
                // not in this build.
                return (request, try registry.makeCore(CoreIdentifier(request.coreID)))
            }

            startMemoryMonitor()
            if !(await session.isActive) {
                // A stop won the race right after the start completed.
                memoryMonitor.stop()
            }
            if reference != nil, let snapshots = snapshots {
                do {
                    try snapshots.save(request)
                } catch {
                    // The tunnel works; only system-initiated starts are affected.
                    log.error("snapshot was not saved: \(TunnelRunner.describe(error), privacy: .public)")
                }
            }
        } catch {
            // The description never contains the configuration: `CoreError`
            // and `TunnelIPCError` carry codes and bounded messages only.
            log.error("start failed: \(TunnelRunner.describe(error), privacy: .public)")
            throw PacketTunnelProvider.bridged(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("stop requested, reason \(reason.rawValue)")
        memoryMonitor.stop()
        await TunnelRunner.stop(session: session, deadlines: deadlines, hooks: makeHooks())
    }

    /// The platform calls the session logic needs. The closures are used
    /// only by the call they are passed to and do not outlive it.
    private func makeHooks() -> TunnelHostHooks {
        let log = self.log
        let exitGrace = deadlines.exitGrace
        return TunnelHostHooks(
            applySettings: { [unowned self] plan in
                try await self.setTunnelNetworkSettings(TunnelNetworkSettingsBuilder.makeSettings(for: plan))
            },
            clearSettings: { [unowned self] in
                try await self.setTunnelNetworkSettings(nil)
            },
            makeWatchdog: { [unowned self] lifecycle in
                self.makeWatchdog(for: lifecycle)
            },
            engineWedged: {
                log.fault("engine did not stop in time, the tunnel process will exit")
                DispatchQueue.global().asyncAfter(deadline: .now() + exitGrace) {
                    exit(EXIT_FAILURE)
                }
            },
            log: { message in
                log.error("\(message, privacy: .public)")
            }
        )
    }

    /// Registers the engines of this flavour once per process. The factory
    /// runs when a start request names the engine.
    private func registerEngines() {
        #if NP_ENGINE_XRAY
        guard registry.descriptor(for: XrayCore.identifier) == nil else { return }
        let bridge = XrayBridgeBinding()
        let descriptor = XrayCore.makeDescriptor(bridge: bridge)
        let io = PacketTunnelFlowIO(flow: packetFlow)
        let session = self.session
        let log = self.log
        var settings = XrayCoreSettings()
        // Starting point from the bridge's Linux measurements (Cores/Bridge/README.md,
        // "Память"): 24-32 MiB limit, GC 50 %. Not measured on a device (E-4).
        settings.memoryLimitBytes = 32 << 20
        settings.gcPercent = 50
        let fixedSettings = settings
        let events = XrayCoreEvents(
            unexpectedExit: { message in
                log.error("\(message, privacy: .public)")
                Task {
                    if let lifecycle = await session.lifecycle {
                        await lifecycle.reportUnexpectedExit(message)
                    }
                }
            },
            log: { record in
                // Core messages may name destinations: private (ADR-0003 §4).
                log.log(
                    level: PacketTunnelProvider.logType(record.level),
                    "xray \(record.kind, privacy: .public): \(record.message, privacy: .private)"
                )
            }
        )
        do {
            try registry.register(descriptor) {
                XrayCore(bridge: bridge, packetIO: io, descriptor: descriptor, settings: fixedSettings, events: events)
            }
            log.info("engine registered: \(descriptor.id.rawValue, privacy: .public) \(descriptor.version, privacy: .public)")
        } catch {
            log.error("engine registration failed: \(TunnelRunner.describe(error), privacy: .public)")
        }
        #endif
    }

    private static func logType(_ level: String?) -> OSLogType {
        switch level {
        case "debug": return .debug
        case "info": return .info
        case "error": return .error
        default: return .default
        }
    }

    private func startMemoryMonitor() {
        let session = self.session
        let timeout = deadlines.systemEvent
        memoryMonitor.start { [log] level, footprint in
            log.warning("memory pressure \(level.rawValue, privacy: .public), footprint \(footprint ?? 0) bytes")
            let mapped: CoreMemoryPressureLevel = level == .critical ? .critical : .warning
            Task { await session.forwardMemoryPressure(mapped, timeout: timeout) }
        }
    }

    /// Watchdog (ADR-0001 §4): an engine that stops by itself must take the
    /// tunnel down, otherwise the interface keeps capturing traffic that
    /// nothing forwards.
    private func makeWatchdog(for lifecycle: CoreLifecycle) -> Task<Void, Never> {
        let provider = ProviderReference(self)
        let log = self.log
        return Task {
            for await state in await lifecycle.stateUpdates() {
                if Task.isCancelled { return }
                if state == .failed {
                    let failure: Error = await lifecycle.lastError ?? CoreError.unexpectedExit(message: "engine failed")
                    if Task.isCancelled { return }
                    log.error("engine failed, cancelling tunnel: \(TunnelRunner.describe(failure), privacy: .public)")
                    provider.cancelTunnel(with: PacketTunnelProvider.bridged(failure))
                    return
                }
                if state == .idle { return }
            }
        }
    }

    // MARK: Sleep and wake

    override func sleep() async {
        // Bounded: the system waits for this before the device sleeps.
        guard let lifecycle = await session.lifecycle else { return }
        let delivered = await lifecycle.deliver(.willSleep, timeout: deadlines.systemEvent)
        log.info("sleep, engine notified: \(delivered)")
    }

    override func wake() {
        let session = self.session
        let log = self.log
        let timeout = deadlines.systemEvent
        Task {
            guard let lifecycle = await session.lifecycle else { return }
            let delivered = await lifecycle.deliver(.didWake, timeout: timeout)
            log.info("wake, engine notified: \(delivered)")
        }
    }

    // MARK: App messages

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let response = await respond(to: messageData)
        return TunnelExchange.encode(response)
    }

    private func respond(to messageData: Data) async -> TunnelResponse {
        let request: TunnelRequest
        switch TunnelExchange.decodeRequest(messageData) {
        case let .rejection(response):
            return response
        case let .request(decoded):
            request = decoded
        }

        switch request.body {
        case .status:
            return TunnelResponse(version: TunnelIPC.protocolVersion, id: request.id, outcome: .status(await statusReport()))
        case .statistics:
            guard let lifecycle = await session.lifecycle else {
                return TunnelExchange.failure(id: request.id, .notRunning, "no engine is running")
            }
            do {
                // Bounded: an engine that does not answer must not keep the
                // app's request, and this task, alive.
                let statistics = try await CoreDeadline.run(.statistics, timeout: deadlines.statistics) {
                    try await lifecycle.statistics()
                }
                let report = TunnelTrafficReport(
                    uplinkBytes: statistics.traffic.uplinkBytes,
                    downlinkBytes: statistics.traffic.downlinkBytes
                )
                return TunnelResponse(version: TunnelIPC.protocolVersion, id: request.id, outcome: .statistics(report))
            } catch {
                let normalised = CoreError.normalise(error, during: .statistics)
                return TunnelExchange.failure(
                    id: request.id,
                    TunnelIPCError.Code(rawValue: normalised.code),
                    normalised.description
                )
            }
        }
    }

    /// Never waits for the engine: the lifecycle actor answers while the
    /// engine works.
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

    /// The system reports tunnel errors as `NSError`; a bare Swift enum would
    /// lose its text on the way.
    private static func bridged(_ error: Error) -> NSError {
        NSError(
            domain: "NetworkPlatform.Tunnel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: TunnelRunner.describe(error)]
        )
    }
}

/// Lets a task reach the provider without keeping it alive and without
/// claiming that the provider is Sendable. `cancelTunnelWithError` is the
/// only call made through it; Network Extension allows it from any thread.
private final class ProviderReference: @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?

    init(_ provider: NEPacketTunnelProvider) {
        self.provider = provider
    }

    func cancelTunnel(with error: NSError) {
        provider?.cancelTunnelWithError(error)
    }
}
