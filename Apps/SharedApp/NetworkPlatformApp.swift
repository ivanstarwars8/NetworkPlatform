// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// App shell shared by the iOS and macOS targets. It installs the VPN
// configuration and starts or stops the tunnel; nothing else. No profiles, no
// import, no engine: see STATUS.md.

import SwiftUI

@main
struct NetworkPlatformApp: App {
    @StateObject private var tunnel = TunnelController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tunnel)
                .task { await tunnel.refresh() }
        }
    }
}
