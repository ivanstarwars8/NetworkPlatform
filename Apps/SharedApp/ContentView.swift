// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46045764184 (workflow apple.yml)

import NetworkExtension
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tunnel: \(ContentView.label(for: tunnel.status))")
                .font(.headline)

            // The two states are independent (ADR-0003 §2): the tunnel can be
            // up while the engine does not answer.
            if let report = tunnel.engineReport {
                Text("Engine: \(report.coreID ?? "none"), \(report.coreState)")
                if let footprint = report.physicalFootprintBytes {
                    Text("Extension memory: \(footprint / 1024) KiB")
                }
                if let error = report.lastError {
                    Text("Engine error: \(error)")
                }
            } else {
                Text("Engine: no report")
            }

            Text("Engines in this build: \(tunnel.catalog.coreIDs.joined(separator: ", ")); extension: \(tunnel.selectedCoreID ?? "none")")
                .font(.footnote)
            Text("No profile is compiled yet: Connect works only with a snapshot saved by an earlier start.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = tunnel.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }

            HStack {
                if tunnel.isInstalled {
                    Button("Connect") { tunnel.connect() }
                        .disabled(tunnel.status != .disconnected)
                    Button("Disconnect") { tunnel.disconnect() }
                        .disabled(tunnel.status == .disconnected || tunnel.status == .invalid)
                    Button("Query engine") { Task { await tunnel.queryEngine() } }
                        .disabled(tunnel.status != .connected)
                } else {
                    Button("Install VPN configuration") { Task { await tunnel.install() } }
                }
            }
        }
        .padding()
    }

    static func label(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "not configured"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}
