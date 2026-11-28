// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
// (Merged on main with byk/routing, compiled in run 46077240856; recompile on main pending.)
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
                .environmentObject(library.routing)
                .bykScreen()
                .task {
                    SubscriptionBackgroundRefresh.library = library
                    await tunnel.refresh()
                    // Subscriptions whose interval has passed; no timer runs after this.
                    await library.refreshStaleSubscriptions()
                }
                .onChange(of: tunnel.status) { old, new in
                    // Only a tunnel that was up or on its way: installing the configuration also moves the
                    // status from invalid to disconnected, right after the start request was compiled.
                    if new == .disconnected, old != .disconnected, old != .invalid {
                        library.tunnelStopped()
                    }
                }
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 520)
                #endif
        }

        #if os(iOS)
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                SubscriptionBackgroundRefresh.schedule(library: library)
            }
        }
        .backgroundTask(.appRefresh(SubscriptionBackgroundRefresh.identifier)) {
            await SubscriptionBackgroundRefresh.perform()
        }
        #endif

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
