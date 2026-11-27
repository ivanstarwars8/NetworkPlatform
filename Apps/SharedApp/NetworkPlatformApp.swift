// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// App shell shared by all platforms: profiles (import, selection, compilation for the start request) and the
// tunnel (VPN configuration, start/stop, diagnostics). The app links no engine (ADR-0001 rule 2).
// Navigation per platform is in Shell/RootView.swift; macOS adds a menu bar item (Shell/MenuBarContent.swift).

import DesignSystem
import SwiftUI

@main
struct NetworkPlatformApp: App {
    @StateObject private var tunnel = TunnelController()
    @StateObject private var library = ProfileLibraryModel(catalog: .thisBuild)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppearanceSetup.apply()
    }

    var body: some Scene {
        WindowGroup(id: RootView.windowID) {
            RootView()
                .environmentObject(tunnel)
                .environmentObject(library)
                .bykScreen()
                .task { await tunnel.refresh() }
                // A probation timer may not have fired while the app was suspended.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { tunnel.probationElapsed() }
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 520)
                #endif
        }

        #if os(macOS)
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(tunnel)
                .environmentObject(library)
        } label: {
            MenuBarLabel(phase: ConnectionPhase(vpnStatusRawValue: tunnel.status.rawValue))
        }
        #endif
    }
}
