// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46055850203 (workflow apple.yml)
//
// The app's side of profiles (main actor): import of pasted share links and subscriptions (a subscription
// address is downloaded here), the profile file with secrets in the Keychain (`ProfileStore`,
// `KeychainSecretStore`), and compilation of the selected profile into a `TunnelStartRequest` for the
// hand-off (ADR-0008). The logic below the UI is in Packages/ProfileLibrary and is unit-tested on Linux.
//
// Nothing here logs: the compiled configuration holds secrets inline, and notices are built from report
// texts that carry no configuration values.

import ConfigurationEngine
import DomainModels
import Foundation
import ProfileLibrary

@MainActor
final class ProfileLibraryModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var selectedProfileID: UUID?
    /// What the last import reported (warnings of the importers, skipped lines).
    @Published private(set) var importNotices: [ProfileNotice] = []
    /// Warnings and errors of the last compilation.
    @Published private(set) var compileNotices: [ProfileNotice] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isImporting = false
    /// The engine the next start compiles for; one of `availableEngines`.
    @Published var engine: TunnelEngine

    /// The engines of this build (flavour), in the catalog's order.
    let availableEngines: [TunnelEngine]

    private var store: ProfileStore?

    /// Largest subscription body downloaded. The decoder applies the same limit.
    private let maximumSubscriptionBytes = ImportLimits.standard.maximumSubscriptionBytes

    init(catalog: TunnelEngineCatalog) {
        let engines = catalog.coreIDs.compactMap(TunnelEngine.init(rawValue:))
        availableEngines = engines
        engine = engines.first ?? .xray
        do {
            let service = (Bundle.main.bundleIdentifier ?? "NetworkPlatform") + ".profiles"
            store = try ProfileStore(directory: try ProfileLibraryModel.storeDirectory(), secrets: KeychainSecretStore(service: service))
        } catch let error as ProfileStoreError {
            lastError = "Profiles could not be opened: \(error.message)"
        } catch {
            lastError = "Profiles could not be opened (\(type(of: error)))."
        }
        publish()
    }

    /// Application Support on iOS, macOS and visionOS. tvOS gives apps no persistent local storage, so the
    /// profiles live in caches there and may be purged by the system.
    private static func storeDirectory() throws -> URL {
        #if os(tvOS)
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
        return base.appendingPathComponent("Profiles", isDirectory: true)
    }

    private func publish() {
        profiles = store?.profiles ?? []
        selectedProfileID = store?.selectedProfileID
    }

    var selectedProfile: Profile? { store?.selectedProfile }

    // MARK: Import

    /// Imports pasted text: a share link, a subscription address (downloaded) or a subscription body.
    /// Returns `true` when a profile was added.
    @discardableResult
    func importText(_ text: String) async -> Bool {
        guard let store = store else { return false }
        isImporting = true
        defer { isImporting = false }
        importNotices = []
        let importer = ProfileImporter()
        do {
            let result: ProfileImportResult
            switch try ImportInput.classify(text) {
            case let .subscriptionURL(url):
                let body = try await downloadSubscription(url)
                result = try importer.importSubscription(text: body, sourceURL: url)
            case let other:
                result = try importer.importOffline(other)
            }
            try store.add(result.profile)
            importNotices = result.notices
            lastError = nil
            publish()
            return true
        } catch let failure as ProfileImportFailure {
            importNotices = failure.notices
            lastError = "Import failed: \(ProfileImporter.describe(failure))"
        } catch let error as ProfileStoreError {
            lastError = "Saving the profile failed: \(error.message)"
        } catch let error as SubscriptionDownloadError {
            lastError = "Downloading the subscription failed: \(error.message)"
        } catch {
            lastError = "Import failed: \(ProfileImporter.describe(error))"
        }
        return false
    }

    private struct SubscriptionDownloadError: Error {
        let message: String
    }

    /// Downloads a subscription body. Ephemeral session: the address often carries an access token, so
    /// nothing is cached or kept in cookies. Errors name the status or the error type, never the address.
    private func downloadSubscription(_ url: URL) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SubscriptionDownloadError(message: "network error \(error.code.rawValue)")
        } catch {
            throw SubscriptionDownloadError(message: "\(type(of: error))")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubscriptionDownloadError(message: "HTTP status \(http.statusCode)")
        }
        guard data.count <= maximumSubscriptionBytes else {
            throw SubscriptionDownloadError(message: "the body exceeds \(maximumSubscriptionBytes) bytes")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionDownloadError(message: "the body is not UTF-8 text")
        }
        return text
    }

    // MARK: Selection

    func select(_ id: UUID) {
        perform { try $0.select(id: id) }
    }

    func selectServer(_ tag: String, inProfile id: UUID) {
        perform { try $0.selectTag(tag, inProfile: id) }
    }

    func remove(_ id: UUID) {
        perform { try $0.remove(id: id) }
    }

    private func perform(_ change: (ProfileStore) throws -> Void) {
        guard let store = store else { return }
        do {
            try change(store)
            lastError = nil
        } catch let error as ProfileStoreError {
            lastError = error.message
        } catch {
            lastError = "\(type(of: error))"
        }
        publish()
    }

    // MARK: Compilation

    /// Compiles the selected profile for `engine`. `nil` when nothing is selected or the compilation is
    /// blocked; `compileNotices` and `lastError` then say why.
    func makeStartRequest() -> TunnelStartRequest? {
        guard let store = store, let profile = store.selectedProfile else {
            lastError = "Add and select a profile first."
            return nil
        }
        let secrets = store.resolvedSecrets(of: profile)
        do {
            let compiled = try TunnelStartCompiler().compile(profile, for: engine, resolveSecret: { secrets[$0.identifier] })
            compileNotices = compiled.notices
            lastError = nil
            return TunnelStartRequest(compiled: compiled)
        } catch let failure as TunnelCompileFailure {
            compileNotices = failure.notices
            lastError = "The profile cannot be started: \(failure.summary)"
        } catch {
            lastError = "The profile cannot be started (\(type(of: error)))."
        }
        return nil
    }
}
