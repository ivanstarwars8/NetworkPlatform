// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode

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

            Text("This build contains no engine. Connecting is expected to fail.")
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
