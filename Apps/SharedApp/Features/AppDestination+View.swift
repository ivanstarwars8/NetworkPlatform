// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Which view each destination opens. A new screen adds its case in AppDestination.swift and one line here.

import SwiftUI

extension AppDestination {
    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .connection: ConnectionScreen()
        case .profiles: ProfilesScreen()
        case .engineDiagnostics: DiagnosticsView()
        case .settings: SettingsScreen()
        case .automation: AutomationScreen()
        }
    }
}
