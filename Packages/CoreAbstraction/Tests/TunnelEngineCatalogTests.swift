// Verified on Linux only (Swift 5.10.1, swift test). Tests Extensions/PacketTunnel/Shared/TunnelEngineCatalog.swift
// through the SharedIPC link (see TunnelIPCTests.swift).
import Foundation
import XCTest

final class TunnelEngineCatalogTests: XCTestCase {
    private let app = "org.example.networkplatform"

    func testDualPicksTheExtensionByEngine() {
        let dual = TunnelEngineCatalog(entries: [.xray, .mihomo])
        XCTAssertEqual(dual.providerBundleIdentifier(for: "xray", appBundleIdentifier: app), "org.example.networkplatform.PacketTunnelXray")
        XCTAssertEqual(dual.providerBundleIdentifier(for: "mihomo", appBundleIdentifier: app), "org.example.networkplatform.PacketTunnelMihomo")
        XCTAssertEqual(dual.coreID(forProviderBundleIdentifier: "org.example.networkplatform.PacketTunnelMihomo", appBundleIdentifier: app), "mihomo")
        XCTAssertEqual(dual.defaultEntry, .xray)
        XCTAssertEqual(dual.coreIDs, ["xray", "mihomo"])
    }

    func testSingleEngineBuildsKnowOnlyTheirExtension() {
        let mihomoOnly = TunnelEngineCatalog(entries: [.mihomo])
        XCTAssertNil(mihomoOnly.providerBundleIdentifier(for: "xray", appBundleIdentifier: app), "no Xray extension in MihomoOnly")
        XCTAssertNil(mihomoOnly.coreID(forProviderBundleIdentifier: "org.example.networkplatform.PacketTunnelXray", appBundleIdentifier: app))
        XCTAssertEqual(mihomoOnly.defaultEntry, .mihomo)

        let xrayOnly = TunnelEngineCatalog(entries: [.xray])
        XCTAssertNil(xrayOnly.providerBundleIdentifier(for: "mihomo", appBundleIdentifier: app))
        XCTAssertEqual(xrayOnly.providerBundleIdentifier(for: "xray", appBundleIdentifier: app), "org.example.networkplatform.PacketTunnelXray")
    }

    func testForeignOrMissingIdentifiersAreNotOurs() {
        let dual = TunnelEngineCatalog(entries: [.xray, .mihomo])
        XCTAssertNil(dual.coreID(forProviderBundleIdentifier: "com.other.app.PacketTunnelXray", appBundleIdentifier: app))
        XCTAssertNil(dual.coreID(forProviderBundleIdentifier: "org.example.networkplatform.PacketTunnel", appBundleIdentifier: app), "the old single-extension identifier")
        XCTAssertNil(dual.providerBundleIdentifier(for: "xray", appBundleIdentifier: ""), "no bundle identifier, no extension")
        XCTAssertNil(dual.providerBundleIdentifier(for: "sing-box", appBundleIdentifier: app))
        XCTAssertNil(TunnelEngineCatalog(entries: []).defaultEntry)
    }

    func testExplicitExtensionIdentifierWinsOverTheSuffix() {
        // The "Byk" build: app com.gbnconnect.app, Xray extension com.gbnconnect.app.tun (Byk.xcconfig).
        let byk = TunnelEngineCatalog(entries: [.xray], bundleIdentifiers: ["xray": "com.gbnconnect.app.tun"])
        XCTAssertEqual(byk.providerBundleIdentifier(for: "xray", appBundleIdentifier: "com.gbnconnect.app"), "com.gbnconnect.app.tun")
        XCTAssertEqual(byk.coreID(forProviderBundleIdentifier: "com.gbnconnect.app.tun", appBundleIdentifier: "com.gbnconnect.app"), "xray")
        XCTAssertNil(byk.coreID(forProviderBundleIdentifier: "com.gbnconnect.app.PacketTunnelXray", appBundleIdentifier: "com.gbnconnect.app"))

        // Dual with only Xray overridden: Mihomo keeps the suffix rule; an empty value is ignored.
        let dual = TunnelEngineCatalog(entries: [.xray, .mihomo], bundleIdentifiers: ["xray": "a.b.tun", "mihomo": ""])
        XCTAssertEqual(dual.providerBundleIdentifier(for: "mihomo", appBundleIdentifier: app), "org.example.networkplatform.PacketTunnelMihomo")
        XCTAssertEqual(dual.providerBundleIdentifier(for: "xray", appBundleIdentifier: app), "a.b.tun")
        XCTAssertNil(dual.providerBundleIdentifier(for: "xray", appBundleIdentifier: ""), "no app identifier, no extension")
    }

    func testBykDualNamesBothExtensions() {
        // The Byk Dual build: com.gbnconnect.app.tun (Xray) and com.gbnconnect.app.mihomo (Byk.xcconfig).
        XCTAssertEqual(TunnelEngineCatalog.infoPlistKeys["mihomo"], "NPMihomoExtensionBundleIdentifier")
        let byk = TunnelEngineCatalog(entries: [.xray, .mihomo], bundleIdentifiers: ["xray": "com.gbnconnect.app.tun", "mihomo": "com.gbnconnect.app.mihomo"])
        XCTAssertEqual(byk.providerBundleIdentifier(for: "mihomo", appBundleIdentifier: "com.gbnconnect.app"), "com.gbnconnect.app.mihomo")
        XCTAssertEqual(byk.coreID(forProviderBundleIdentifier: "com.gbnconnect.app.mihomo", appBundleIdentifier: "com.gbnconnect.app"), "mihomo")
        XCTAssertEqual(byk.coreID(forProviderBundleIdentifier: "com.gbnconnect.app.tun", appBundleIdentifier: "com.gbnconnect.app"), "xray")
    }

    func testTheTestBuildDeclaresNoEngine() {
        // The package tests compile Shared/ without flavour conditions; the app gets them from the xcconfig.
        XCTAssertEqual(TunnelEngineCatalog.thisBuild.entries, [])
    }
}
