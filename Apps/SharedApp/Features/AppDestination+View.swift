// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
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
        }
    }
}
