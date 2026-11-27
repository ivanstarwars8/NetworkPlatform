// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Apple TV: one dashboard driven by the remote — the horn (focusable, press to connect or disconnect), the
// state, the profile in use, adding a profile. No tabs, no levels.

#if os(tvOS)
import DesignSystem
import SwiftUI

struct TVDashboard: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var showingImport = false

    var body: some View {
        let phase = tunnel.phase
        HStack(alignment: .center, spacing: 80) {
            HornConnectControl(
                phase: phase,
                throughput: nil,
                isEnabled: phase.action != .connect || library.connectBlocker == nil,
                disabledHint: library.connectBlocker,
                scale: .large
            ) {
                Task { await tunnel.performPrimaryAction(library: library) }
            }
            .frame(maxWidth: .infinity)

            NavigationStack {
                List {
                    if !library.profiles.isEmpty {
                        Section {
                            Picker(selection: Binding<UUID?>(
                                get: { library.selectedProfileID },
                                set: { id in if let id = id { library.select(id) } }
                            )) {
                                ForEach(library.profiles, id: \.id) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            } label: {
                                Text("Профиль").font(.bykBody)
                            }
                            .disabled(phase.action != .connect)
                        } header: {
                            SectionHeader("Профиль")
                        }
                    }
                    Section {
                        Button("Добавить профиль") { showingImport = true }
                    }
                    if let error = tunnel.lastError ?? library.lastError {
                        Section {
                            MessageRow(.error, error)
                        }
                    }
                }
            }
            .frame(width: 760)
        }
        .padding(60)
        .background(Color.bykBackground.ignoresSafeArea())
        .sheet(isPresented: $showingImport) {
            ImportView(isPresented: $showingImport)
                .environmentObject(library)
        }
    }
}
#endif
