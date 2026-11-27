// Logic verified on Linux only (Swift 5.10.1, swift test, CoreAbstraction tests through the SharedIPC link).
// In the app and the extensions: compiled on macOS CI, never run (GitHub Actions run 46045764184, workflow apple.yml).
//
// Which engines a build contains and which Packet Tunnel extension runs each of them (ADR-0001 §3 rules 1, 3
// and 5; ADR-0009). One extension per engine; the app selects it through
// `NETunnelProviderProtocol.providerBundleIdentifier`. Engine-neutral: identifiers and bundle suffixes only,
// no engine code (the app must not depend on engine modules).

import Foundation

struct TunnelEngineCatalog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// `CoreDescriptor.id` of the engine (`TunnelStartRequest.coreID`).
        let coreID: String
        /// The extension's bundle identifier is the app's plus "." and this (Apps/project.yml).
        let extensionSuffix: String

        static let xray = Entry(coreID: "xray", extensionSuffix: "PacketTunnelXray")
        static let mihomo = Entry(coreID: "mihomo", extensionSuffix: "PacketTunnelMihomo")
    }

    /// In order of preference: the first is used when nothing names an engine.
    let entries: [Entry]

    /// The engines of this build, from the flavour's compilation conditions (Apps/Configurations).
    static var thisBuild: TunnelEngineCatalog {
        var entries: [Entry] = []
        #if NP_ENGINE_XRAY
        entries.append(.xray)
        #endif
        #if NP_ENGINE_MIHOMO
        entries.append(.mihomo)
        #endif
        return TunnelEngineCatalog(entries: entries)
    }

    var coreIDs: [String] { entries.map(\.coreID) }

    var defaultEntry: Entry? { entries.first }

    /// The bundle identifier of the extension that runs `coreID`, or `nil` when this build has no such engine.
    func providerBundleIdentifier(for coreID: String, appBundleIdentifier: String) -> String? {
        guard !appBundleIdentifier.isEmpty, let entry = entries.first(where: { $0.coreID == coreID }) else { return nil }
        return appBundleIdentifier + "." + entry.extensionSuffix
    }

    /// The engine run by the extension with this bundle identifier, or `nil` when it is not one of this build's.
    func coreID(forProviderBundleIdentifier identifier: String, appBundleIdentifier: String) -> String? {
        guard !appBundleIdentifier.isEmpty else { return nil }
        return entries.first { appBundleIdentifier + "." + $0.extensionSuffix == identifier }?.coreID
    }
}
