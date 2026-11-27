// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// macOS menu bar item: the horn as a template image (filled when connected), the state, connect/disconnect,
// the profile in use, and a way back to the window. Same action as the connection screen.

#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI

struct MenuBarLabel: View {
    let phase: ConnectionPhase

    var body: some View {
        if let image = MenuBarLabel.image(fill: phase.hornFill) {
            Image(nsImage: image)
                .accessibilityLabel(Text("Бык: \(phase.stateWord)"))
        } else {
            Image(systemName: phase == .connected ? "network.badge.shield.half.filled" : "network")
        }
    }

    /// The horn rendered once per fill value as an 18 pt template image (the menu bar tints it).
    @MainActor private static var cache: [Double: NSImage] = [:]

    @MainActor static func image(fill: Double) -> NSImage? {
        if let cached = cache[fill] { return cached }
        let renderer = ImageRenderer(content:
            HornGlyph(fill: fill)
                .frame(width: 18, height: 18)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache[fill] = image
        return image
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let phase = tunnel.phase
        Text(phase.stateWord)

        if let title = phase.actionTitle {
            Button(title) {
                Task { await tunnel.performPrimaryAction(library: library) }
            }
            .disabled(phase.action == .connect && library.connectBlocker != nil)
        }
        if phase.action == .connect, let blocker = library.connectBlocker {
            Text(blocker)
        }

        if !library.profiles.isEmpty {
            Divider()
            Picker("Профиль", selection: Binding<UUID?>(
                get: { library.selectedProfileID },
                set: { id in if let id = id { library.select(id) } }
            )) {
                ForEach(library.profiles, id: \.id) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .disabled(phase.action != .connect)
        }

        if let error = tunnel.lastError ?? library.lastError {
            Divider()
            Text(error)
        }

        Divider()
        Button("Открыть окно «Бык»") {
            openWindow(id: RootView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Завершить") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
#endif
