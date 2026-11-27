// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Diagnostics for testers: the tunnel state (NEVPNStatus), the extension's engine report and the bridge's
// byte counters over the provider-message IPC (`.status`, `.statistics`), and the last errors, redacted.
// Refreshed every 2 s while the screen is open and the tunnel is connected.

import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        List {
            Section("Tunnel") {
                LabeledContent("State", value: ContentView.label(for: tunnel.status))
                LabeledContent("Extension engine", value: tunnel.selectedCoreID ?? "none")
                LabeledContent("Engines in this build", value: tunnel.catalog.coreIDs.joined(separator: ", "))
            }
            Section("Engine") {
                if let report = tunnel.engineReport {
                    LabeledContent("Engine", value: report.coreID ?? "none")
                    LabeledContent("State", value: report.coreState)
                    if let footprint = report.physicalFootprintBytes {
                        LabeledContent("Extension memory", value: DiagnosticsView.bytes(footprint))
                    }
                    LabeledContent("Memory warnings", value: "\(report.memoryPressureWarnings) / critical \(report.memoryPressureCriticals)")
                    if let error = report.lastError {
                        LabeledContent("Engine error", value: error)
                    }
                } else {
                    Text(tunnel.status == .connected ? "No report yet" : "Not connected")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Traffic") {
                if let traffic = tunnel.traffic {
                    LabeledContent("Up", value: DiagnosticsView.bytes(traffic.uplinkBytes))
                    LabeledContent("Down", value: DiagnosticsView.bytes(traffic.downlinkBytes))
                } else {
                    Text("No counters").foregroundStyle(.secondary)
                }
                if let error = tunnel.trafficError {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section("Last errors") {
                LabeledContent("Last disconnect", value: tunnel.lastDisconnectError ?? "none")
                LabeledContent("App", value: tunnel.lastError ?? "none")
            }
            Section {
                Button("Refresh") {
                    Task { await refresh() }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh() async {
        guard tunnel.status == .connected else { return }
        await tunnel.queryEngine()
        await tunnel.refreshTraffic()
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
}
