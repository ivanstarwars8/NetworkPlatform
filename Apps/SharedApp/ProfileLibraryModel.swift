// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46079098963 (workflow apple.yml)
// (Subscriptions and server choice; merged on main with byk/routing's routing policy, compiled in run 46077240856.)
//
// The app's side of profiles (main actor): import of pasted share links and subscriptions, the profile file
// with secrets in the Keychain (`ProfileStore`, `KeychainSecretStore`), subscriptions (`SubscriptionManager`:
// conditional refresh, merge that keeps the user's edits), the server choice («Авто» or one server), the
// health of servers (`ServerHealthBook`, fed by the engine's measurements or the app's TCP test), and
// compilation of the selected profile into a `TunnelStartRequest` for the hand-off (ADR-0008). The logic
// below the UI is in Packages/ProfileLibrary and is unit-tested on Linux.
//
// Nothing here logs: the compiled configuration holds secrets inline, and notices are built from report
// texts that carry no configuration values. No timers: subscriptions refresh at launch when stale, from
// the system's background task (iOS), or when the user asks; engine measurements are read only while the
// profile screen is visible.

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

    /// Server choice per profile.
    @Published private(set) var choices: [UUID: ServerChoice] = [:]
    /// Subscription records (interval, last update, outcome) per subscription profile.
    @Published private(set) var subscriptionRecords: [UUID: SubscriptionRecord] = [:]
    @Published private(set) var refreshingSubscriptions: Set<UUID> = []
    /// Measurements per profile. In memory only: latency is a property of the current network.
    @Published private(set) var health: [UUID: ServerHealthBook] = [:]
    @Published private(set) var testingProfiles: Set<UUID> = []
    /// The compiled start that is (or was last) running: which profile, how to switch its servers inside the
    /// engine, and the server the engine reports as current (profile tag).
    @Published private(set) var running: RunningSelection?
    /// Why the last in-engine switch or measurement read failed; cleared by the next success.
    @Published private(set) var selectionError: String?

    struct RunningSelection: Equatable {
        var profileID: UUID
        var engine: TunnelEngine
        var plan: ServerSelectionPlan?
        var currentTag: String?
        var pinned: Bool
    }

    /// The engines of this build (flavour), in the catalog's order.
    let availableEngines: [TunnelEngine]
    /// Routing and DNS settings: every start request is compiled with them.
    let routing = RoutingSettingsModel()

    private var store: ProfileStore?
    private var subscriptions: SubscriptionManager?

    init(catalog: TunnelEngineCatalog) {
        let engines = catalog.coreIDs.compactMap(TunnelEngine.init(rawValue:))
        availableEngines = engines
        engine = engines.first ?? .xray
        do {
            let service = (Bundle.main.bundleIdentifier ?? "NetworkPlatform") + ".profiles"
            let directory = try ProfileLibraryModel.storeDirectory()
            let store = try ProfileStore(directory: directory, secrets: KeychainSecretStore(service: service))
            self.store = store
            subscriptions = SubscriptionManager(
                profiles: store,
                records: SubscriptionRecordStore(directory: directory),
                fetcher: URLSessionSubscriptionFetcher()
            )
        } catch let error as ProfileStoreError {
            lastError = "Профили не открылись: \(error.message)."
        } catch {
            lastError = "Профили не открылись (\(type(of: error)))."
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
        var choices: [UUID: ServerChoice] = [:]
        var records: [UUID: SubscriptionRecord] = [:]
        for profile in profiles {
            choices[profile.id] = store?.choice(forProfile: profile.id) ?? .automatic
            if let record = subscriptions?.record(for: profile.id) { records[profile.id] = record }
            // A book follows the profile's servers; measurements of servers that stay are kept.
            let tags = Set(profile.outbounds.map(\.tag))
            if health[profile.id]?.tags != tags {
                health[profile.id] = ServerHealthBook(tags: profile.outbounds.map(\.tag))
            }
        }
        for id in health.keys where !profiles.contains(where: { $0.id == id }) {
            health[id] = nil
        }
        self.choices = choices
        subscriptionRecords = records
    }

    var selectedProfile: Profile? { store?.selectedProfile }

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    func choice(of id: UUID) -> ServerChoice { choices[id] ?? .automatic }

    func isSubscription(_ profile: Profile) -> Bool { SubscriptionManager.url(of: profile) != nil }

    /// Display name of a server.
    static func name(of outbound: Outbound) -> String {
        outbound.name.isEmpty ? outbound.tag : outbound.name
    }

    // MARK: Import

    /// Imports pasted text: a share link, a subscription address (downloaded, then refreshed by its record)
    /// or a subscription body. Returns `true` when a profile was added.
    @discardableResult
    func importText(_ text: String) async -> Bool {
        guard let store = store else { return false }
        isImporting = true
        defer { isImporting = false }
        importNotices = []
        do {
            switch try ImportInput.classify(text) {
            case let .subscriptionURL(url):
                guard let subscriptions = subscriptions else { return false }
                let added = try await subscriptions.add(url: url)
                importNotices = added.notices
            case let other:
                let result = try ProfileImporter().importOffline(other)
                try store.add(result.profile)
                importNotices = result.notices
            }
            lastError = nil
            publish()
            return true
        } catch let failure as ProfileImportFailure {
            importNotices = failure.notices
            lastError = "Не удалось импортировать: \(ProfileImporter.describe(failure)). Проверьте ссылку или подписку."
        } catch let error as ProfileStoreError {
            lastError = "Профиль не сохранился: \(error.message)."
        } catch let failure as SubscriptionHTTP.Failure {
            lastError = "Подписка не загрузилась: \(failure.message). Проверьте адрес и сеть."
        } catch {
            lastError = "Не удалось импортировать: \(ProfileImporter.describe(error)). Проверьте ссылку или подписку."
        }
        return false
    }

    // MARK: Subscriptions

    /// Refreshes one subscription now (the user asked).
    func refreshSubscription(_ id: UUID) async {
        guard let subscriptions = subscriptions, !refreshingSubscriptions.contains(id) else { return }
        refreshingSubscriptions.insert(id)
        defer { refreshingSubscriptions.remove(id) }
        await subscriptions.refresh(id)
        publish()
    }

    /// Refreshes every subscription whose interval has passed. Called at launch and from the background task.
    func refreshStaleSubscriptions() async {
        guard let subscriptions = subscriptions else { return }
        let due = profiles.filter { subscriptionRecords[$0.id]?.isStale(at: Date()) == true }.map(\.id)
        guard !due.isEmpty else { return }
        refreshingSubscriptions.formUnion(due)
        defer { refreshingSubscriptions.subtract(due) }
        await subscriptions.refreshStale()
        publish()
    }

    /// When the system should wake the app for the next automatic refresh; `nil` when none is due.
    var nextSubscriptionRefresh: Date? { subscriptions?.nextRefresh() }

    func setInterval(_ interval: SubscriptionInterval, for id: UUID) {
        perform { _ in try self.subscriptions?.setInterval(interval, for: id) }
    }

    func renameServer(_ tag: String, inProfile id: UUID, to name: String) {
        guard let profile = profile(id) else { return }
        if isSubscription(profile) {
            perform { _ in try self.subscriptions?.renameServer(tag, inProfile: id, to: name) }
        } else {
            perform { try $0.renameServer(tag, inProfile: id, to: name) }
        }
    }

    func hideServer(_ tag: String, inProfile id: UUID) {
        perform { _ in try self.subscriptions?.hideServer(tag, inProfile: id) }
    }

    func resetSubscriptionEdits(_ id: UUID) {
        perform { _ in try self.subscriptions?.resetEdits(for: id) }
    }

    func renameProfile(_ id: UUID, to name: String) {
        perform { try $0.renameProfile(id, to: name) }
    }

    // MARK: Selection

    func select(_ id: UUID) {
        perform { try $0.select(id: id) }
    }

    func remove(_ id: UUID) {
        perform { try $0.remove(id: id) }
        subscriptions?.forget(id)
        publish()
    }

    /// Stores the server choice. When this profile is the one running and the engine can switch, the switch
    /// happens inside the engine, without restarting the tunnel; otherwise the choice applies at the next
    /// connect.
    func choose(_ choice: ServerChoice, inProfile id: UUID, tunnel: TunnelController) async {
        guard perform({ try $0.setChoice(choice, forProfile: id) }) else { return }
        guard let running = running, running.profileID == id, tunnel.status == .connected,
              let plan = running.plan else { return }
        guard let selection = plan.selection(for: choice) else {
            selectionError = "Этого сервера нет в запущенной конфигурации. Переподключитесь, чтобы выбрать его."
            return
        }
        do {
            try await tunnel.selectMember(group: selection.group, member: selection.member)
            selectionError = nil
            self.running?.pinned = choice != .automatic
            if case let .server(tag) = choice { self.running?.currentTag = tag }
            await refreshEngineMeasurements(tunnel: tunnel)
        } catch let error as TunnelIPCError {
            selectionError = "Сервер не переключился: \(TunnelController.redacted(error.summary)). Переподключитесь, чтобы применить выбор."
        } catch {
            selectionError = "Сервер не переключился. Переподключитесь, чтобы применить выбор."
        }
    }

    /// Whether choosing a server of `id` now switches inside the running engine (true) or needs a reconnect.
    func switchesLive(_ id: UUID, tunnel: TunnelController) -> Bool {
        guard let running = running, running.profileID == id, running.plan != nil else { return false }
        return tunnel.status == .connected
    }

    /// Reads the engine's own measurements of the running automatic group into the health book. Only while
    /// connected; the caller decides how often (the profile screen: about every 10 s while visible).
    func refreshEngineMeasurements(tunnel: TunnelController) async {
        guard let running = running, let plan = running.plan, tunnel.status == .connected else { return }
        do {
            let report = try await tunnel.queryGroups()
            guard self.running?.profileID == running.profileID else { return }
            if let measured = report.groups.first(where: { $0.tag == plan.measuredGroup }) {
                let members = measured.members.map {
                    EngineMemberMeasurement(engineTag: $0.tag, alive: $0.alive, delayMilliseconds: $0.delayMilliseconds, lastTry: $0.lastTry)
                }
                health[running.profileID]?.record(engine: members, plan: plan)
            }
            // The server in use: the selection group's current member, through «Авто» when that is current.
            let selectionGroup = report.groups.first { $0.tag == plan.group }
            var current = selectionGroup?.current
            if let automatic = plan.automaticMember, current == automatic {
                current = report.groups.first { $0.tag == plan.measuredGroup }?.current
            }
            self.running?.currentTag = current.flatMap { plan.profileTag(ofEngineTag: $0) }
            self.running?.pinned = plan.automaticMember == nil ? selectionGroup?.pinned != nil : selectionGroup?.current != plan.automaticMember
            selectionError = nil
        } catch let error as TunnelIPCError {
            selectionError = "Замеры движка недоступны: \(TunnelController.redacted(error.summary))."
        } catch {
            selectionError = "Замеры движка недоступны."
        }
    }

    /// The app's TCP connect test of a profile's servers, only while disconnected.
    func runConnectTest(_ id: UUID) async {
        guard let profile = profile(id), !testingProfiles.contains(id) else { return }
        let targets = ConnectProbePlan.targets(of: profile)
        guard !targets.isEmpty else { return }
        testingProfiles.insert(id)
        defer { testingProfiles.remove(id) }
        let results = await ConnectProbe.run(targets)
        health[id]?.record(connect: results)
    }

    /// Forgets which start is running (the tunnel stopped).
    func tunnelStopped() {
        running = nil
        selectionError = nil
    }

    @discardableResult
    private func perform(_ change: (ProfileStore) throws -> Void) -> Bool {
        guard let store = store else { return false }
        defer { publish() }
        do {
            try change(store)
            lastError = nil
            return true
        } catch let error as ProfileStoreError {
            lastError = error.message.capitalizedFirst + "."
        } catch {
            lastError = "\(type(of: error))"
        }
        return false
    }

    // MARK: Compilation

    /// Compiles the selected profile for `engine` with its server choice. `nil` when nothing is selected or
    /// the compilation is blocked; `compileNotices` and `lastError` then say why.
    func makeStartRequest() -> TunnelStartRequest? {
        guard let store = store, let profile = store.selectedProfile else {
            lastError = "Сначала добавьте и выберите профиль."
            return nil
        }
        let secrets = store.resolvedSecrets(of: profile)
        do {
            let compiled = try TunnelStartCompiler(policy: routing.compiler).compile(
                profile, for: engine, choice: store.choice(forProfile: profile.id), resolveSecret: { secrets[$0.identifier] }
            )
            compileNotices = compiled.notices
            lastError = nil
            var currentTag: String?
            if case let .server(tag) = compiled.choice { currentTag = tag }
            if compiled.selectionPlan == nil { currentTag = profile.selectedTag ?? profile.outbounds.first?.tag }
            running = RunningSelection(
                profileID: profile.id, engine: engine, plan: compiled.selectionPlan,
                currentTag: currentTag, pinned: compiled.choice != .automatic
            )
            return TunnelStartRequest(compiled: compiled)
        } catch let failure as TunnelCompileFailure {
            compileNotices = failure.notices
            lastError = "Профиль нельзя запустить: \(failure.summary)."
        } catch {
            lastError = "Профиль нельзя запустить (\(type(of: error)))."
        }
        return nil
    }
}
