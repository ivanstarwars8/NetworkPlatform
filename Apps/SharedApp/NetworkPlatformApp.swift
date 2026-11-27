// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/45966628451
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
