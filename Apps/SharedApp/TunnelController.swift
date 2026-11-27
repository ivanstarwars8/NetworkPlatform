// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
// (User-facing messages translated to Russian; otherwise as compiled on macOS CI in GitHub Actions run 46055850203.)
//
// Control-plane side of the tunnel (ADR-0003 §3.1): owns the
// `NETunnelProviderManager`, mirrors `NEVPNStatus` (the source of truth about
// the tunnel) and talks to the extension over `sendProviderMessage`.
//
// Every request to the extension goes through `send(_:)`: it has a deadline,
// honours cancellation and throws only `TunnelIPCError`. The rules of the
// exchange (`TunnelExchange`, `TunnelPendingReply`) and of the configuration
// hand-off (`ConfigurationHandoff`) are in Extensions/PacketTunnel/Shared and
// are tested on Linux; this file adds only the Network Extension calls.
//
// Engines: one extension per engine (ADR-0001 §3). The build's engines and
// their extensions come from `TunnelEngineCatalog` (Shared/). There is one VPN
// configuration; `connect(with:)` points its `providerBundleIdentifier` at the
// extension of the request's engine before starting (ADR-0001 rule 5; whether
// the system accepts that rewrite is check E-3 on a device).
//
// The start request is compiled by `ProfileLibraryModel` (selected profile) and
// passed to `connect(with:)`. `connect()` starts without a request, which works
// only when the extension has a snapshot.
//
// Diagnostics: `lastDisconnectError` is the system's record of why the tunnel
// last stopped (the extension's start error, `fetchLastDisconnectError`), and
// `traffic` the bridge's byte counters (`.statistics` message). Texts shown are
// passed through `ConfigValueRedactor` (UUIDs and IP literals removed).
//
// Not implemented: On-Demand rules.

import ConfigurationEngine
import Foundation
// NetworkExtension has no Sendable annotations: `loadAllFromPreferences()`
// returns non-Sendable managers to the main actor, where they stay.
@preconcurrency import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isInstalled = false
    @Published private(set) var engineReport: TunnelStatusReport?
    @Published private(set) var lastError: String?
    /// The engine whose extension the VPN configuration points at.
    @Published private(set) var selectedCoreID: String?
    /// Why the tunnel last stopped, as the system recorded it; redacted.
    @Published private(set) var lastDisconnectError: String?
    /// Byte counters of the running engine, from the last `refreshTraffic()`.
    @Published private(set) var traffic: TunnelTrafficReport?
    @Published private(set) var trafficError: String?

    /// The engines of this build (flavour conditions).
    let catalog = TunnelEngineCatalog.thisBuild

    private var manager: NETunnelProviderManager?
    private var statusObserver: NotificationObservation?
    private var nextRequestID: UInt64 = 1
    private var queryInFlight = false

    private var appBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    /// The bundle identifier of the extension that runs `coreID` in this
    /// build (Apps/project.yml), `nil` when the build has no such engine.
    func providerBundleIdentifier(for coreID: String) -> String? {
        catalog.providerBundleIdentifier(for: coreID, appBundleIdentifier: appBundleIdentifier)
    }

    /// Finds the VPN configuration that belongs to one of our extensions, if any.
    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let catalog = self.catalog
            let app = appBundleIdentifier
            let ours = managers.first { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol,
                      let identifier = proto.providerBundleIdentifier else { return false }
                return catalog.coreID(forProviderBundleIdentifier: identifier, appBundleIdentifier: app) != nil
            }
            adopt(ours)
        } catch {
            lastError = "Не удалось прочитать настройки VPN: \(error.localizedDescription). Перезапустите приложение."
        }
    }

    /// Creates and saves the VPN configuration, pointed at the extension of
    /// this build's first engine. The system asks the user for permission.
    func install() async {
        guard let coreID = catalog.defaultEntry?.coreID, let provider = providerBundleIdentifier(for: coreID) else {
            lastError = "В этой сборке нет расширения с движком — подключение невозможно."
            return
        }
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = provider
        // Required by the system and shown in Settings; not used for routing.
        proto.serverAddress = "NetworkPlatform"

        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = "NetworkPlatform"
        newManager.isEnabled = true
        do {
            try await newManager.saveToPreferences()
            // A freshly saved manager must be reloaded before it can start.
            try await newManager.loadFromPreferences()
            adopt(newManager)
            lastError = nil
        } catch {
            lastError = "Не удалось добавить конфигурацию VPN: \(error.localizedDescription). Разрешите VPN, когда система спросит, и подключитесь снова."
        }
    }

    /// Starts the tunnel without a request: the extension reuses its
    /// snapshot of the last successful start, or refuses.
    func connect() {
        start(options: nil)
    }

    /// Starts the tunnel with a compiled request. The extension is the one of
    /// the request's engine. The request goes to the extension through a file
    /// in the App Group container; the start options carry only a reference to
    /// it (length and SHA-256 included).
    func connect(with request: TunnelStartRequest) async {
        guard manager != nil else { return }
        guard await selectExtension(for: request.coreID) else { return }
        do {
            let handoff = ConfigurationHandoff(directory: try ConfigurationHandoff.sharedDirectory())
            let reference = try handoff.write(request)
            let options = try reference.startOptions()
            if !start(options: options) {
                // The extension will never read the file.
                handoff.discard(reference)
            }
        } catch let error as TunnelIPCError {
            lastError = "Не удалось передать профиль расширению: \(error.summary). Попробуйте подключиться ещё раз."
        } catch {
            lastError = "Не удалось передать профиль расширению. Попробуйте подключиться ещё раз."
        }
    }

    @discardableResult
    private func start(options: [String: NSObject]?) -> Bool {
        guard let manager = manager else { return false }
        do {
            try manager.connection.startVPNTunnel(options: options)
            lastError = nil
            return true
        } catch {
            lastError = "Туннель не запустился: \(error.localizedDescription)."
            return false
        }
    }

    /// Points the VPN configuration at the extension of `coreID` (one engine
    /// per extension process, ADR-0001). Saved only when it changes; a change
    /// takes effect at the next start, so it is refused while the tunnel runs.
    private func selectExtension(for coreID: String) async -> Bool {
        guard let manager = manager, let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        guard let provider = providerBundleIdentifier(for: coreID) else {
            lastError = "В этой сборке нет расширения для движка \(coreID)."
            return false
        }
        if proto.providerBundleIdentifier == provider { return true }
        guard status == .disconnected || status == .invalid else {
            lastError = "Отключитесь, чтобы перейти на движок \(coreID)."
            return false
        }
        proto.providerBundleIdentifier = provider
        manager.protocolConfiguration = proto
        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            selectedCoreID = coreID
            return true
        } catch {
            lastError = "Не удалось переключить движок: \(error.localizedDescription)."
            return false
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    /// Asks the running extension for the engine state.
    func queryEngine() async {
        // One query at a time: replies to overlapping queries would race for
        // the same published property.
        guard !queryInFlight else { return }
        queryInFlight = true
        defer { queryInFlight = false }

        let request = makeRequest(.status)
        do {
            var report = try TunnelExchange.statusReport(of: try await send(request), for: request)
            // The tunnel may have gone down while the reply was on its way.
            guard status == .connected else {
                engineReport = nil
                return
            }
            if let error = report.lastError {
                report.lastError = TunnelController.redacted(error)
            }
            engineReport = report
            lastError = nil
        } catch let error as TunnelIPCError {
            engineReport = nil
            lastError = "Расширение не ответило: \(TunnelController.redacted(error.summary))."
        } catch {
            engineReport = nil
            lastError = "Расширение не ответило."
        }
    }

    /// Traffic counters of the running engine.
    func queryTraffic() async throws -> TunnelTrafficReport {
        let request = makeRequest(.statistics)
        return try TunnelExchange.trafficReport(of: try await send(request), for: request)
    }

    /// Updates `traffic`; only while connected (nobody answers otherwise).
    func refreshTraffic() async {
        guard status == .connected else {
            traffic = nil
            trafficError = nil
            return
        }
        do {
            traffic = try await queryTraffic()
            trafficError = nil
        } catch let error as TunnelIPCError {
            trafficError = TunnelController.redacted(error.summary)
        } catch {
            trafficError = "\(type(of: error))"
        }
    }

    /// Removes configuration-shaped values (UUIDs, IP literals) from a text before it is shown. The
    /// extension's errors carry no configuration by construction (ADR-0003 §4); this is a second guard.
    nonisolated static func redacted(_ text: String) -> String {
        ConfigValueRedactor().redact(text)
    }

    /// Asks the system why the tunnel last stopped (the error the extension threw from `startTunnel` or
    /// passed to `cancelTunnelWithError`).
    private func fetchLastDisconnectError() {
        guard let connection = manager?.connection else { return }
        connection.fetchLastDisconnectError { [weak self] error in
            // Reduced to text here: the error is not Sendable.
            let text = error.map { TunnelController.describeDisconnect($0) }
            Task { @MainActor in
                self?.lastDisconnectError = text
            }
        }
    }

    nonisolated private static func describeDisconnect(_ error: Error) -> String {
        let nsError = error as NSError
        let text = "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        return ConfigValueRedactor().redact(text)
    }

    // MARK: Channel

    private func makeRequest(_ body: TunnelRequest.Body) -> TunnelRequest {
        let request = TunnelRequest(version: TunnelIPC.protocolVersion, id: nextRequestID, body: body)
        nextRequestID &+= 1
        return request
    }

    /// The single path to the extension. Returns the raw reply, or throws a
    /// `TunnelIPCError`: `.notConnected`, `.sendFailed`, `.timedOut`,
    /// `.cancelled`, `.messageTooLarge`.
    ///
    /// A message to an extension that is not running may never be answered,
    /// so nothing is sent unless the tunnel is connected, and the wait is
    /// bounded in any case.
    private func send(
        _ request: TunnelRequest,
        timeout: TimeInterval = TunnelIPC.defaultRequestTimeout
    ) async throws -> Data? {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession else {
            throw TunnelIPCError(.notConnected, "the tunnel is not connected")
        }
        let message = try TunnelExchange.encode(request)
        let pending = TunnelPendingReply()
        do {
            // Called here, on the main actor: the session is not Sendable and
            // never leaves it. Only `pending` (Sendable) enters the handler.
            try session.sendProviderMessage(message) { reply in
                pending.fulfil(reply)
            }
        } catch {
            throw TunnelIPCError(.sendFailed, "the system refused the message: \(type(of: error))")
        }
        return try await pending.wait(timeout: timeout)
    }

    // MARK: Status

    private func adopt(_ newManager: NETunnelProviderManager?) {
        // Dropping the previous observation unregisters it.
        statusObserver = nil
        manager = newManager
        isInstalled = newManager != nil
        if let identifier = (newManager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier {
            selectedCoreID = catalog.coreID(forProviderBundleIdentifier: identifier, appBundleIdentifier: appBundleIdentifier)
        } else {
            selectedCoreID = nil
        }
        status = newManager?.connection.status ?? .invalid
        if status != .connected {
            engineReport = nil
            traffic = nil
        }
        if status == .disconnected {
            fetchLastDisconnectError()
        }
        guard let connection = newManager?.connection else { return }
        statusObserver = NotificationObservation(
            NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: connection,
                queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue (requested above), so this is
                // the main actor; the status is read from the manager the
                // controller holds instead of capturing the connection.
                MainActor.assumeIsolated {
                    self?.statusDidChange()
                }
            }
        )
    }

    private func statusDidChange() {
        status = manager?.connection.status ?? .invalid
        if status != .connected {
            engineReport = nil
            traffic = nil
        }
        if status == .disconnected {
            fetchLastDisconnectError()
        }
    }
}

/// Owns one `NotificationCenter` registration and removes it when released,
/// so the controller needs no `deinit` and cannot leak the observer.
private final class NotificationObservation {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
