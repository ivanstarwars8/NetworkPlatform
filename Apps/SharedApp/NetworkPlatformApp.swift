// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// App shell shared by all platforms: profiles (import, selection, compilation
// for the start request) and the tunnel (VPN configuration, start/stop,
// diagnostics). The app links no engine (ADR-0001 rule 2).

import SwiftUI

@main
struct NetworkPlatformApp: App {
    @StateObject private var tunnel = TunnelController()
    @StateObject private var library = ProfileLibraryModel(catalog: .thisBuild)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .environmentObject(library)
                .task { await tunnel.refresh() }
        }
    }
}
