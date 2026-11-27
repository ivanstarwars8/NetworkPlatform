// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
// (User-facing messages translated to Russian; otherwise as compiled on macOS CI in GitHub Actions run 46055850203.)
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
import EngineSelection
import Foundation
import ProfileLibrary

/// A compiled start and what identifies it: the request for the hand-off, the attempt for the supervisor, and
/// the stored profile it was compiled from (recorded as last known good when the start proves itself).
struct PreparedStart {
    var request: TunnelStartRequest
    var attempt: StartAttempt
    var profileSnapshot: Profile
    var decision: EngineDecision?
}

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
    /// Per-profile engine preferences, bumped on every change so that views re-read decisions.
    @Published private(set) var engineChoiceRevision = 0

    /// The engines of this build (flavour), in the catalog's order.
    let availableEngines: [TunnelEngine]
    let chooser: EngineChooser

    private var store: ProfileStore?
    private var choices: EngineChoiceStore?
    /// Engine support per profile, valid while the stored profile is unchanged (compiling is cheap but not free).
    private var supportCache: [UUID: (profile: Profile, supports: [EngineSupport])] = [:]

    /// Largest subscription body downloaded. The decoder applies the same limit.
    private let maximumSubscriptionBytes = ImportLimits.standard.maximumSubscriptionBytes

    init(catalog: TunnelEngineCatalog) {
        let engines = catalog.coreIDs.compactMap(TunnelEngine.init(rawValue:))
        availableEngines = engines
        chooser = EngineChooser(available: engines)
        do {
            let service = (Bundle.main.bundleIdentifier ?? "NetworkPlatform") + ".profiles"
            let directory = try ProfileLibraryModel.storeDirectory()
            store = try ProfileStore(directory: directory, secrets: KeychainSecretStore(service: service))
            do {
                choices = try EngineChoiceStore(directory: directory)
            } catch let error as EngineChoiceStoreError {
                lastError = "Выбор движков не прочитался (\(error.message)); для всех профилей действует «Авто»."
            } catch {
                lastError = "Выбор движков не прочитался (\(type(of: error))); для всех профилей действует «Авто»."
            }
        } catch let error as ProfileStoreError {
            lastError = "Профили не открылись: \(error.message)."
        } catch {
            lastError = "Профили не открылись (\(type(of: error)))."
        }
        publish()
        try? choices?.retain(only: Set(profiles.map(\.id)))
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
            lastError = "Не удалось импортировать: \(ProfileImporter.describe(failure)). Проверьте ссылку или подписку."
        } catch let error as ProfileStoreError {
            lastError = "Профиль не сохранился: \(error.message)."
        } catch let error as SubscriptionDownloadError {
            lastError = "Подписка не загрузилась: \(error.message). Проверьте адрес и сеть."
        } catch {
            lastError = "Не удалось импортировать: \(ProfileImporter.describe(error)). Проверьте ссылку или подписку."
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
            throw SubscriptionDownloadError(message: "ошибка сети \(error.code.rawValue)")
        } catch {
            throw SubscriptionDownloadError(message: "\(type(of: error))")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubscriptionDownloadError(message: "сервер ответил HTTP \(http.statusCode)")
        }
        guard data.count <= maximumSubscriptionBytes else {
            throw SubscriptionDownloadError(message: "ответ больше \(maximumSubscriptionBytes) байт")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionDownloadError(message: "ответ не текст UTF-8")
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
        supportCache[id] = nil
        try? choices?.forget(id)
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

    // MARK: Engine choice

    func enginePreference(for profileID: UUID) -> EnginePreference {
        choices?.preference(for: profileID) ?? .automatic
    }

    func setEnginePreference(_ preference: EnginePreference, for profileID: UUID) {
        guard let choices = choices else {
            lastError = "Выбор движка не сохраняется: файл выбора движков не открылся."
            return
        }
        do {
            try choices.setPreference(preference, for: profileID)
            engineChoiceRevision &+= 1
            lastError = nil
        } catch let error as EngineChoiceStoreError {
            lastError = "Выбор движка не сохранился: \(error.message)."
        } catch {
            lastError = "Выбор движка не сохранился (\(type(of: error)))."
        }
    }

    func lastKnownGood(for profileID: UUID) -> LastKnownGood? {
        choices?.lastKnownGood(for: profileID)
    }

    /// How completely each engine of the build carries the profile, from the compilers' reports.
    func engineSupports(for profile: Profile) -> [EngineSupport] {
        if let cached = supportCache[profile.id], cached.profile == profile { return cached.supports }
        guard let store = store else { return [] }
        let secrets = store.resolvedSecrets(of: profile)
        let supports = availableEngines.map { engine in
            EngineSupport.assess(profile, engine: engine, resolveSecret: { secrets[$0.identifier] })
        }
        supportCache[profile.id] = (profile, supports)
        return supports
    }

    /// The engine the next start of `profile` uses and why.
    func engineDecision(for profile: Profile) -> EngineDecision {
        chooser.decide(
            preference: enginePreference(for: profile.id),
            supports: engineSupports(for: profile),
            lastWorkingEngine: lastKnownGood(for: profile.id)?.engine
        )
    }

    /// What the supervisor needs when a start of `attempt` fails.
    func failureContext(for attempt: StartAttempt) -> FailureContext {
        guard let profile = profiles.first(where: { $0.id == attempt.profileID }) else {
            return FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: nil)
        }
        let alternative = engineSupports(for: profile).first { $0.engine != attempt.engine && $0.level == .complete }?.engine
        return FailureContext(
            lastKnownGood: lastKnownGood(for: profile.id),
            preference: enginePreference(for: profile.id),
            completeAlternative: alternative
        )
    }

    /// Records a start that passed probation as the profile's last known good.
    func recordGood(_ start: PreparedStart) {
        guard let choices = choices, profiles.contains(where: { $0.id == start.attempt.profileID }) else { return }
        let record = LastKnownGood(
            profileID: start.attempt.profileID,
            engine: start.attempt.engine,
            configurationDigest: start.attempt.configurationDigest,
            profile: start.profileSnapshot,
            recordedAt: Date()
        )
        do {
            try choices.recordGood(record)
            engineChoiceRevision &+= 1
        } catch {
            // Not fatal: only the rollback target is not updated.
        }
    }

    // MARK: Compilation

    /// Compiles the selected profile with the engine of its decision. `nil` when nothing is selected or the
    /// compilation is blocked; `compileNotices` and `lastError` then say why. What the engine leaves out is
    /// listed in `compileNotices` before the start, never dropped silently.
    func makeStartRequest() -> PreparedStart? {
        guard let profile = store?.selectedProfile else {
            lastError = "Сначала добавьте и выберите профиль."
            return nil
        }
        let decision = engineDecision(for: profile)
        guard let engine = decision.engine else {
            compileNotices = decision.supports.flatMap(\.blockers).map { ProfileNotice(.error, $0) }
            lastError = "Профиль нельзя запустить: \(decision.explanation)"
            return nil
        }
        guard var prepared = compile(profile, for: engine, origin: .user) else { return nil }
        prepared.decision = decision
        compileNotices = decision.losses.map { ProfileNotice(.warning, "\(engine.displayName): \($0.russianText)") }
            + compileNotices.filter { $0.severity == .error }
        return prepared
    }

    /// The selected profile compiled for another engine (automatic fallback after a failed start).
    func prepareFallback(to engine: TunnelEngine, profileID: UUID) -> PreparedStart? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        return compile(profile, for: engine, origin: .engineFallback)
    }

    /// The profile's last known good configuration, compiled again. Refused when the result is not the
    /// configuration that worked (the profile's secrets or the compiler changed since).
    func prepareRollback(to good: LastKnownGood) -> PreparedStart? {
        guard let prepared = compile(good.profile, for: good.engine, origin: .rollback) else { return nil }
        guard prepared.attempt.configurationDigest == good.configurationDigest else {
            lastError = "Вернуть последнюю рабочую настройку нельзя: профиль или приложение изменились с тех пор. Подключитесь снова."
            return nil
        }
        return prepared
    }

    private func compile(_ profile: Profile, for engine: TunnelEngine, origin: StartAttempt.Origin) -> PreparedStart? {
        guard let store = store else { return nil }
        let secrets = store.resolvedSecrets(of: profile)
        do {
            let compiled = try TunnelStartCompiler().compile(profile, for: engine, resolveSecret: { secrets[$0.identifier] })
            compileNotices = compiled.notices
            lastError = nil
            let request = TunnelStartRequest(compiled: compiled)
            let attempt = StartAttempt(
                profileID: profile.id,
                engine: engine,
                configurationDigest: TunnelDigest.sha256Hex(request.configuration),
                origin: origin
            )
            return PreparedStart(request: request, attempt: attempt, profileSnapshot: profile, decision: nil)
        } catch let failure as TunnelCompileFailure {
            compileNotices = failure.notices
            lastError = "Профиль нельзя запустить: \(failure.summary)."
        } catch {
            lastError = "Профиль нельзя запустить (\(type(of: error)))."
        }
        return nil
    }
}
