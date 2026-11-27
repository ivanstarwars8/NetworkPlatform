// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// The tester's flow, plain SwiftUI: add a profile (paste a share link, a subscription address or body),
// pick it, connect or disconnect, see the import and compile notices, open Diagnostics.

import DomainModels
import NetworkExtension
import ProfileLibrary
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @State private var showingImport = false

    var body: some View {
        NavigationStack {
            List {
                Section("Tunnel") {
                    LabeledContent("Status", value: ContentView.label(for: tunnel.status))
                    if library.availableEngines.count > 1 {
                        Picker("Engine", selection: $library.engine) {
                            ForEach(library.availableEngines, id: \.self) { engine in
                                Text(engine.rawValue).tag(engine)
                            }
                        }
                        .disabled(tunnel.status != .disconnected && tunnel.status != .invalid)
                    }
                    connectButton
                    if let error = tunnel.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let error = library.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    NoticeList(notices: library.compileNotices)
                }

                Section("Profiles") {
                    if library.profiles.isEmpty {
                        Text("No profiles. Add one with a share link or a subscription.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.profiles, id: \.id) { profile in
                        HStack {
                            Button {
                                library.select(profile.id)
                            } label: {
                                HStack {
                                    Image(systemName: profile.id == library.selectedProfileID ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(profile.name)
                                        Text("\(profile.outbounds.count) server(s)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            NavigationLink("Details") {
                                ProfileDetailView(profileID: profile.id)
                            }
                        }
                    }
                    Button("Add profile") { showingImport = true }
                }

                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }
            }
            .navigationTitle("Profiles")
        }
        .sheet(isPresented: $showingImport) {
            ImportView(isPresented: $showingImport)
                .environmentObject(library)
        }
    }

    @ViewBuilder private var connectButton: some View {
        switch tunnel.status {
        case .disconnected, .invalid:
            Button("Connect") {
                Task { await connect() }
            }
            .disabled(library.selectedProfileID == nil)
        case .connecting, .connected, .reasserting:
            Button("Disconnect") { tunnel.disconnect() }
        case .disconnecting:
            Text("Disconnecting…")
        @unknown default:
            Text("Unknown state")
        }
    }

    private func connect() async {
        // Compiled first: a profile that cannot be compiled never touches the VPN configuration.
        guard let request = library.makeStartRequest() else { return }
        if !tunnel.isInstalled {
            await tunnel.install()
        }
        guard tunnel.isInstalled else { return }
        await tunnel.connect(with: request)
    }

    static func label(for status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "not configured"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}

/// Pasted text → profile. The importers' notices stay visible after a successful import.
struct ImportView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var imported = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Share link, subscription address or subscription body") {
                    #if os(tvOS)
                    TextField("vless://… or https://…", text: $text)
                        .autocorrectionDisabled()
                    #else
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                    #endif
                }
                Section {
                    Button(library.isImporting ? "Importing…" : "Import") {
                        Task {
                            imported = await library.importText(text)
                            if imported { text = "" }
                        }
                    }
                    .disabled(library.isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if imported {
                        Text("Profile added.")
                    }
                    if let error = library.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if !library.importNotices.isEmpty {
                    Section("Import report") {
                        NoticeList(notices: library.importNotices)
                    }
                }
            }
            .navigationTitle("Add profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

/// Servers of one profile: choose the one traffic goes to, or delete the profile.
struct ProfileDetailView: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    var body: some View {
        if let profile = library.profiles.first(where: { $0.id == profileID }) {
            List {
                Section("Servers") {
                    ForEach(profile.outbounds, id: \.tag) { outbound in
                        Button {
                            library.selectServer(outbound.tag, inProfile: profile.id)
                        } label: {
                            HStack {
                                Image(systemName: outbound.tag == profile.selectedTag ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(outbound.name.isEmpty ? outbound.tag : outbound.name)
                                    Text(outbound.kind.rawValue)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Delete profile", role: .destructive) {
                        library.remove(profile.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle(profile.name)
        } else {
            Text("The profile was removed.")
        }
    }
}

/// Notices of an import or a compilation, most severe marked.
struct NoticeList: View {
    let notices: [ProfileNotice]

    var body: some View {
        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
            Label {
                Text(notice.text).font(.footnote)
            } icon: {
                Image(systemName: NoticeList.symbol(for: notice.severity))
                    .foregroundStyle(NoticeList.color(for: notice.severity))
            }
        }
    }

    static func color(for severity: ProfileNotice.Severity) -> Color {
        switch severity {
        case .info: return .gray
        case .warning: return .orange
        case .error: return .red
        }
    }

    static func symbol(for severity: ProfileNotice.Severity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}
