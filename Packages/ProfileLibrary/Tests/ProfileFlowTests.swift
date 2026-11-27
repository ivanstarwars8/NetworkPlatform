import ConfigurationEngine
import DomainModels
import Foundation
@testable import ProfileLibrary
import XCTest

/// Secrets in memory, for the tests only (the app uses `KeychainSecretStore`).
final class MemorySecretStore: SecretStore {
    var items: [String: String] = [:]
    var failWrites = false

    func setSecret(_ value: String, for reference: SecretReference) throws {
        if failWrites { throw SecretStoreError(status: -1) }
        items[reference.identifier] = value
    }

    func secret(for reference: SecretReference) -> String? {
        items[reference.identifier]
    }

    func removeSecret(for reference: SecretReference) {
        items[reference.identifier] = nil
    }
}

/// The non-UI path of the app: pasted text → import → store (secrets out of the file) → compile →
/// `TunnelStartRequest` → hand-off file → what the extension reads back.
final class ProfileFlowTests: XCTestCase {
    // Documentation addresses (RFC 5737) and a test key; no real server.
    static let uuid = "1cc9207f-5dda-4274-bb0d-9d105c95c6e8"
    static let uuid2 = "6f2c3a9e-0b7d-4c61-9e5a-2d8f4b1c7a30"
    static let realityKey = "VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4"
    static let vless = "vless://\(uuid)@192.0.2.1:443?type=tcp&security=reality&sni=www.example.org"
        + "&fp=chrome&pbk=\(realityKey)&sid=0a1b&flow=xtls-rprx-vision#lab"
    static let trojan = "trojan://s3cret-pass-1@192.0.2.2:443?security=tls&sni=example.org#lab"

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeDirectory: URL { directory.appendingPathComponent("Profiles", isDirectory: true) }

    // MARK: Classification

    func testClassify() throws {
        XCTAssertEqual(try ImportInput.classify("  \(Self.vless)\n"), .shareLink(Self.vless))
        XCTAssertEqual(
            try ImportInput.classify("https://sub.example.org/s/abc"),
            .subscriptionURL(URL(string: "https://sub.example.org/s/abc")!)
        )
        XCTAssertEqual(try ImportInput.classify("\(Self.vless)\n\(Self.trojan)"), .subscriptionBody("\(Self.vless)\n\(Self.trojan)"))
        XCTAssertEqual(try ImportInput.classify("dmxlc3M6Ly8="), .subscriptionBody("dmxlc3M6Ly8="))
        XCTAssertThrowsError(try ImportInput.classify("  \n "))
        XCTAssertThrowsError(try ImportInput.classify("https://"))
    }

    // MARK: Import

    func testShareLinkImportKeepsReport() throws {
        let result = try ProfileImporter().importShareLink(Self.vless.replacingOccurrences(of: "#lab", with: "&unknownparam=1#lab"))
        XCTAssertEqual(result.profile.outbounds.count, 1)
        XCTAssertEqual(result.profile.selectedTag, "lab")
        XCTAssertEqual(result.profile.source, .shareLink)
        XCTAssertTrue(result.notices.contains { $0.text.contains("unknownparam") }, "\(result.notices)")
        XCTAssertFalse(result.notices.contains { $0.text.contains("=1") }, "parameter values are not shown")
    }

    func testSubscriptionBase64DeduplicatesTagsAndReportsFailures() throws {
        let body = [Self.vless, Self.trojan.replacingOccurrences(of: "#lab", with: "#lab"), "vless://broken", "foo://x"]
            .joined(separator: "\n")
        let encoded = Data(body.utf8).base64EncodedString()
        let input = try ImportInput.classify(encoded)
        let result = try ProfileImporter().importOffline(input)
        XCTAssertEqual(result.profile.outbounds.map(\.tag), ["lab", "lab (2)"])
        XCTAssertEqual(result.profile.selectedTag, "lab")
        XCTAssertEqual(result.profile.validate(), [])
        XCTAssertTrue(result.notices.contains { $0.text.contains("base64") })
        XCTAssertEqual(result.notices.filter { $0.severity == .error }.count, 2, "\(result.notices)")
        for notice in result.notices {
            XCTAssertFalse(notice.text.contains(Self.uuid), "notices must not contain credentials")
            XCTAssertFalse(notice.text.contains("broken"), "skipped lines are not echoed")
        }
    }

    func testSubscriptionWithoutUsableLinksFailsWithReasons() {
        XCTAssertThrowsError(try ProfileImporter().importSubscription(text: "vless://broken\nfoo://bar", sourceURL: nil)) { error in
            let failure = error as? ProfileImportFailure
            XCTAssertNotNil(failure)
            XCTAssertGreaterThanOrEqual(failure?.notices.filter { $0.severity == .error }.count ?? 0, 2)
        }
    }

    func testSubscriptionURLKeepsSourceButNotInNotices() throws {
        let url = URL(string: "https://sub.example.org/token-abcdef")!
        let result = try ProfileImporter().importSubscription(text: Self.vless, sourceURL: url)
        XCTAssertEqual(result.profile.source, .subscription(url: url.absoluteString))
        XCTAssertEqual(result.profile.name, "sub.example.org")
        XCTAssertFalse(result.notices.contains { $0.text.contains("token-abcdef") })
    }

    // MARK: Store

    func testStoreMovesSecretsOutOfTheFileAndReloads() throws {
        let secrets = MemorySecretStore()
        let store = try ProfileStore(directory: storeDirectory, secrets: secrets)
        let imported = try ProfileImporter().importSubscription(text: "\(Self.vless)\n\(Self.trojan)", sourceURL: nil)
        let stored = try store.add(imported.profile)
        XCTAssertTrue(stored.outbounds.allSatisfy { $0.inlineSecretSlots.isEmpty })
        XCTAssertEqual(secrets.items.count, 2)
        XCTAssertEqual(store.selectedProfileID, stored.id, "the first profile is selected")

        let file = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains(Self.uuid), "the profile file must not hold secrets")
        XCTAssertFalse(file.contains("s3cret-pass-1"))

        let reopened = try ProfileStore(directory: storeDirectory, secrets: secrets)
        XCTAssertEqual(reopened.profiles, [stored])
        XCTAssertEqual(reopened.selectedProfileID, stored.id)

        try reopened.selectTag("lab (2)", inProfile: stored.id)
        XCTAssertThrowsError(try reopened.selectTag("nope", inProfile: stored.id))
        let second = try reopened.add(try ProfileImporter().importShareLink(Self.vless).profile)
        try reopened.select(id: second.id)
        XCTAssertEqual(try ProfileStore(directory: storeDirectory, secrets: secrets).selectedProfile?.id, second.id)

        try reopened.remove(id: second.id)
        try reopened.remove(id: stored.id)
        XCTAssertTrue(secrets.items.isEmpty, "removing a profile removes its secrets")
        XCTAssertNil(reopened.selectedProfileID)
        XCTAssertTrue(try ProfileStore(directory: storeDirectory, secrets: secrets).profiles.isEmpty)
    }

    func testFailedSecretWriteStoresNothing() throws {
        let secrets = MemorySecretStore()
        secrets.failWrites = true
        let store = try ProfileStore(directory: storeDirectory, secrets: secrets)
        XCTAssertThrowsError(try store.add(try ProfileImporter().importShareLink(Self.vless).profile))
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testCorruptFileIsRefused() throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: storeDirectory.appendingPathComponent(ProfileStore.fileName))
        XCTAssertThrowsError(try ProfileStore(directory: storeDirectory, secrets: MemorySecretStore()))
    }

    // MARK: Compile and hand-off

    private func storedProfile(_ text: String) throws -> (ProfileStore, Profile) {
        let store = try ProfileStore(directory: storeDirectory, secrets: MemorySecretStore())
        let result = try ProfileImporter().importOffline(try ImportInput.classify(text))
        return (store, try store.add(result.profile))
    }

    func testXrayCompileToHandoffRoundTrip() throws {
        let (store, profile) = try storedProfile("\(Self.vless)\n\(Self.trojan)")
        try store.selectTag("lab (2)", inProfile: profile.id)
        let selected = try XCTUnwrap(store.selectedProfile)
        let secrets = store.resolvedSecrets(of: selected)
        XCTAssertEqual(secrets.count, 2)
        XCTAssertEqual(store.resolveSecret(SecretReference(identifier: "\(selected.id.uuidString)/1/password")), "s3cret-pass-1")
        let compiled = try TunnelStartCompiler().compile(selected, for: .xray, resolveSecret: { secrets[$0.identifier] })
        XCTAssertEqual(compiled.coreID, "xray")
        XCTAssertEqual(compiled.format, "json")
        XCTAssertFalse(compiled.description.contains("s3cret"), "description leaves the configuration out")

        let text = String(decoding: compiled.configuration, as: UTF8.self)
        XCTAssertTrue(text.contains("s3cret-pass-1"), "secrets are inline in the compiled configuration")
        XCTAssertTrue(text.contains(Self.uuid))
        XCTAssertTrue(text.contains("\"tun\""), "compiled with the tunnel inbound")

        let request = TunnelStartRequest(compiled: compiled)
        XCTAssertEqual(request.network.mtu, TunnelAddressing.standard.mtu)
        XCTAssertEqual(request.network.ipv4Address, TunnelAddressing.standard.ipv4Address)
        XCTAssertEqual(request.network.remoteAddress, "192.0.2.1", "first proxy address given as an IP")
        XCTAssertTrue(request.network.excludedRoutes.contains(TunnelRoute.host("192.0.2.2")))
        try request.network.validate()

        // ADR-0008: the start options carry a small reference, the file the request.
        let handoff = ConfigurationHandoff(directory: directory.appendingPathComponent("StartHandoff"))
        let reference = try handoff.write(request)
        let options = try reference.startOptions()
        let boxed = try XCTUnwrap(options[TunnelIPC.startReferenceOptionKey] as? NSData)
        let optionText = String(decoding: boxed as Data, as: UTF8.self)
        XCTAssertFalse(optionText.contains("s3cret"), "start options must not carry the configuration")
        XCTAssertLessThan(boxed.length, TunnelIPC.maximumStartReferenceBytes)

        let received = try handoff.consume(try XCTUnwrap(TunnelStartReference.from(startOptions: options)))
        XCTAssertEqual(received, request)
        XCTAssertEqual(try JSONValue.parse(jsonText: String(decoding: received.configuration, as: UTF8.self))["outbounds"]?.arrayValue?.isEmpty, false)
    }

    func testMihomoCompileToHandoff() throws {
        let (store, profile) = try storedProfile(Self.vless)
        let secrets = store.resolvedSecrets(of: profile)
        XCTAssertEqual(secrets.count, 1)
        let compiled = try TunnelStartCompiler().compile(profile, for: .mihomo, resolveSecret: { secrets[$0.identifier] })
        XCTAssertEqual(compiled.format, "yaml")
        let request = TunnelStartRequest(compiled: compiled)
        XCTAssertEqual(request.coreID, "mihomo")
        let handoff = ConfigurationHandoff(directory: directory.appendingPathComponent("StartHandoff"))
        XCTAssertEqual(try handoff.consume(try handoff.write(request)), request)
        XCTAssertTrue(String(decoding: request.configuration, as: UTF8.self).contains(Self.uuid))
    }

    func testMissingSecretBlocksCompilation() throws {
        let (_, profile) = try storedProfile(Self.trojan)
        XCTAssertThrowsError(try TunnelStartCompiler().compile(profile, for: .xray, resolveSecret: { _ in nil })) { error in
            let failure = try? XCTUnwrap(error as? TunnelCompileFailure)
            XCTAssertFalse(failure?.notices.isEmpty ?? true)
            XCTAssertFalse(failure?.summary.contains("s3cret") ?? true)
        }
    }

    func testEngineIdentifiersMatchTheCatalog() {
        XCTAssertEqual(TunnelEngine.xray.rawValue, TunnelEngineCatalog.Entry.xray.coreID)
        XCTAssertEqual(TunnelEngine.mihomo.rawValue, TunnelEngineCatalog.Entry.mihomo.coreID)
    }
}
