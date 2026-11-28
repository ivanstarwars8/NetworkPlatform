// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly, MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46087955935 (workflow apple.yml)
//
// The app's single tunnel controller and profile library. The SwiftUI scenes and the App Intents
// (Features/Automation/TunnelIntents.swift) run in the same process and must act on the same objects: a shortcut
// that connects while a window is open shows up in that window at once, and a manual disconnect from either side
// suspends on-demand in one place.

import Foundation

@MainActor
enum AppModel {
    static let tunnel = TunnelController()
    static let library = ProfileLibraryModel(catalog: .thisBuild)
}
