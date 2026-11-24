// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Control-plane side of the tunnel (ADR-0003 §3.1): owns the
// `NETunnelProviderManager`, mirrors `NEVPNStatus` (the source of truth about
// the tunnel) and talks to the extension over `sendProviderMessage`.
//
// Not implemented: On-Demand rules, choosing between several extensions by
// `providerBundleIdentifier` (ADR-0001 §3, rule 5), compiling and sending a
// start request. `connect()` therefore starts the tunnel without options and
// the extension refuses to start.

import Foundation
import NetworkExtension

@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var isInstalled = false
    @Published private(set) var engineReport: TunnelStatusReport?
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var nextRequestID: UInt64 = 1

    /// The extension's bundle identifier is the app's plus a fixed suffix
    /// (Apps/project.yml).
    static var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "") + ".PacketTunnel"
    }

    /// Finds the VPN configuration that belongs to our extension, if any.
    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = managers.first { candidate in
                let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol
                return proto?.providerBundleIdentifier == TunnelController.providerBundleIdentifier
            }
            adopt(ours)
        } catch {
            lastError = "Loading VPN configurations failed: \(error.localizedDescription)"
        }
    }

    /// Creates and saves the VPN configuration. The system asks the user for
    /// permission.
    func install() async {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelController.providerBundleIdentifier
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
            lastError = "Installing the VPN configuration failed: \(error.localizedDescription)"
        }
    }

    func connect() {
        guard let manager = manager else { return }
        do {
            try manager.connection.startVPNTunnel(options: nil)
            lastError = nil
        } catch {
            lastError = "Starting the tunnel failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    /// Asks the running extension for the engine state. Only meaningful while
    /// the tunnel is connected: a message to a stopped extension may never be
    /// answered.
    func queryEngine() async {
        guard status == .connected, let session = manager?.connection as? NETunnelProviderSession else {
            engineReport = nil
            return
        }
        let request = TunnelRequest(version: TunnelIPC.protocolVersion, id: nextRequestID, body: .status)
        nextRequestID += 1
        do {
            let message = try JSONEncoder().encode(request)
            let reply: Data? = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(message) { data in
                        continuation.resume(returning: data)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            guard let reply = reply else {
                lastError = "The extension sent no reply."
                return
            }
            let response = try JSONDecoder().decode(TunnelResponse.self, from: reply)
            guard response.version == TunnelIPC.protocolVersion, response.id == request.id else {
                lastError = "The extension replied with an unexpected version or request id."
                return
            }
            switch response.outcome {
            case let .status(report):
                engineReport = report
                lastError = nil
            case .statistics:
                lastError = "The extension replied with the wrong kind of answer."
            case let .failure(failure):
                lastError = "\(failure.code): \(failure.message)"
            }
        } catch {
            lastError = "Querying the extension failed: \(error.localizedDescription)"
        }
    }

    private func adopt(_ newManager: NETunnelProviderManager?) {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
        manager = newManager
        isInstalled = newManager != nil
        status = newManager?.connection.status ?? .invalid
        guard let connection = newManager?.connection else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.status = connection.status
                if connection.status != .connected {
                    self.engineReport = nil
                }
            }
        }
    }
}
