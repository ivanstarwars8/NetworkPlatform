// Logic verified on Linux only (Swift 5.10.1, swift test, CoreAbstraction tests through the SharedIPC link).
// In the app and the extensions: compiled on macOS CI, never run (GitHub Actions run 46045764184, workflow apple.yml).
//
// Which engines a build contains and which Packet Tunnel extension runs each of them (ADR-0001 §3 rules 1, 3
// and 5; ADR-0009). One extension per engine; the app selects it through
// `NETunnelProviderProtocol.providerBundleIdentifier`. Engine-neutral: identifiers and bundle suffixes only,
// no engine code (the app must not depend on engine modules).
//
// By default an extension's bundle identifier is the app's plus "." and the entry's suffix. A build whose
// extension has another identifier (the "Byk" build: com.gbnconnect.app.tun and com.gbnconnect.app.mihomo,
// Apps/Configurations/Byk.xcconfig) declares it in the app's Info.plist (`NPXrayExtensionBundleIdentifier`,
// `NPMihomoExtensionBundleIdentifier`, from NP_XRAY_/NP_MIHOMO_EXTENSION_BUNDLE_ID);
// `thisBuild` reads it into `bundleIdentifiers`, which wins over the suffix rule.

import Foundation

struct TunnelEngineCatalog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// `CoreDescriptor.id` of the engine (`TunnelStartRequest.coreID`).
        let coreID: String
        /// The extension's bundle identifier is the app's plus "." and this (Apps/project.yml), unless
        /// `bundleIdentifiers` names it.
        let extensionSuffix: String

        static let xray = Entry(coreID: "xray", extensionSuffix: "PacketTunnelXray")
        static let mihomo = Entry(coreID: "mihomo", extensionSuffix: "PacketTunnelMihomo")
    }

    /// In order of preference: the first is used when nothing names an engine.
    let entries: [Entry]
    /// Explicit extension bundle identifiers by `coreID`; an engine not listed uses the suffix rule.
    let bundleIdentifiers: [String: String]

    init(entries: [Entry], bundleIdentifiers: [String: String] = [:]) {
        self.entries = entries
        self.bundleIdentifiers = bundleIdentifiers.filter { !$0.value.isEmpty }
    }

    /// Info.plist keys of the app holding explicit extension bundle identifiers, by `coreID`.
    static let infoPlistKeys = ["xray": "NPXrayExtensionBundleIdentifier", "mihomo": "NPMihomoExtensionBundleIdentifier"]

    /// The engines of this build, from the flavour's compilation conditions (Apps/Configurations).
    static var thisBuild: TunnelEngineCatalog {
        var entries: [Entry] = []
        #if NP_ENGINE_XRAY
        entries.append(.xray)
        #endif
        #if NP_ENGINE_MIHOMO
        entries.append(.mihomo)
        #endif
        var identifiers: [String: String] = [:]
        for (coreID, key) in infoPlistKeys {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String { identifiers[coreID] = value }
        }
        return TunnelEngineCatalog(entries: entries, bundleIdentifiers: identifiers)
    }

    var coreIDs: [String] { entries.map(\.coreID) }

    var defaultEntry: Entry? { entries.first }

    /// The bundle identifier of the extension that runs `coreID`, or `nil` when this build has no such engine.
    func providerBundleIdentifier(for coreID: String, appBundleIdentifier: String) -> String? {
        guard !appBundleIdentifier.isEmpty, let entry = entries.first(where: { $0.coreID == coreID }) else { return nil }
        return identifier(of: entry, appBundleIdentifier: appBundleIdentifier)
    }

    /// The engine run by the extension with this bundle identifier, or `nil` when it is not one of this build's.
    func coreID(forProviderBundleIdentifier identifier: String, appBundleIdentifier: String) -> String? {
        guard !appBundleIdentifier.isEmpty else { return nil }
        return entries.first { self.identifier(of: $0, appBundleIdentifier: appBundleIdentifier) == identifier }?.coreID
    }

    private func identifier(of entry: Entry, appBundleIdentifier: String) -> String {
        bundleIdentifiers[entry.coreID] ?? appBundleIdentifier + "." + entry.extensionSuffix
    }
}
