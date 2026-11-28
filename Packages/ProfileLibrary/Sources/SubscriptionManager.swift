import ConfigurationEngine
import DomainModels
import Foundation

/// Downloads a subscription body. The app implements it with an ephemeral `URLSession` (the address often
/// carries an access token: nothing cached, no cookies); tests use a fake. Errors are
/// `SubscriptionHTTP.Failure` with a message safe to show.
public protocol SubscriptionFetching: Sendable {
    func fetch(_ url: URL, headers: [String: String]) async throws -> SubscriptionHTTP.Result
}

/// The subscription records on disk: `subscriptions.json` next to `profiles.json`. No addresses, no secrets:
/// validators, dates, outcomes and the user's edits.
public final class SubscriptionRecordStore {
    public static let fileName = "subscriptions.json"
    static let maximumFileBytes = 4 * 1024 * 1024

    private struct File: Codable {
        static let currentVersion = 1
        var version: Int
        var records: [SubscriptionRecord]
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public let directory: URL
    public private(set) var records: [UUID: SubscriptionRecord] = [:]

    public var fileURL: URL { directory.appendingPathComponent(SubscriptionRecordStore.fileName) }

    /// Opens the records. A missing or unreadable file is an empty set: the records can be rebuilt (the next
    /// refresh downloads the full body), so a damaged file never blocks the profiles.
    public init(directory: URL) {
        self.directory = directory
        guard let data = try? Data(contentsOf: fileURL), data.count <= SubscriptionRecordStore.maximumFileBytes,
              let file = try? SubscriptionRecordStore.decoder.decode(File.self, from: data), file.version == File.currentVersion else {
            return
        }
        for record in file.records { records[record.profileID] = record }
    }

    public func record(for id: UUID) -> SubscriptionRecord? { records[id] }

    public func put(_ record: SubscriptionRecord) throws {
        let previous = records[record.profileID]
        records[record.profileID] = record
        do {
            try save()
        } catch {
            records[record.profileID] = previous
            throw error
        }
    }

    public func remove(_ id: UUID) throws {
        guard records.removeValue(forKey: id) != nil else { return }
        try save()
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let sorted = records.values.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
            try encoder.encode(File(version: File.currentVersion, records: sorted)).write(to: fileURL, options: [.atomic])
        } catch {
            throw ProfileStoreError("saving the subscription file failed (\(type(of: error)))")
        }
    }
}

/// Refreshes subscription profiles: conditional download, import, merge with the stored profile (keeping
/// the user's edits and choice), and a record of what happened. No timers: the app calls `refresh` when the
/// user asks, `refreshStale` at launch and from a system background task.
///
/// Not thread-safe: owned by the same actor as the `ProfileStore` (the app's main actor).
public final class SubscriptionManager {
    private let profiles: ProfileStore
    public let records: SubscriptionRecordStore
    private let fetcher: SubscriptionFetching
    private let importer: ProfileImporter
    private let clock: () -> Date
    private var inFlight = Set<UUID>()

    public init(
        profiles: ProfileStore,
        records: SubscriptionRecordStore,
        fetcher: SubscriptionFetching,
        importer: ProfileImporter = ProfileImporter(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.profiles = profiles
        self.records = records
        self.fetcher = fetcher
        self.importer = importer
        self.clock = clock
    }

    /// The subscription address of a profile, `nil` for other profiles.
    public static func url(of profile: Profile) -> URL? {
        guard case let .subscription(text) = profile.source else { return nil }
        return URL(string: text)
    }

    public func isRefreshing(_ id: UUID) -> Bool { inFlight.contains(id) }

    /// The record of a subscription profile; a default one (daily refresh) for a subscription profile that
    /// has none yet, `nil` for other profiles.
    public func record(for id: UUID) -> SubscriptionRecord? {
        if let record = records.record(for: id) { return record }
        guard let profile = profiles.profiles.first(where: { $0.id == id }), SubscriptionManager.url(of: profile) != nil else {
            return nil
        }
        return SubscriptionRecord(profileID: id)
    }

    /// Imports a subscription address as a new profile (first download) and starts its record.
    @discardableResult
    public func add(url: URL, interval: SubscriptionInterval = .day) async throws -> (profile: Profile, notices: [ProfileNotice]) {
        let result: SubscriptionHTTP.Result
        do {
            result = try await fetcher.fetch(url, headers: [:])
        } catch let failure as SubscriptionHTTP.Failure {
            throw failure
        } catch {
            throw SubscriptionHTTP.Failure("ошибка загрузки (\(type(of: error)))")
        }
        guard case let .body(text, entityTag, lastModified) = result else {
            throw SubscriptionHTTP.Failure("сервер ответил 304 на первый запрос")
        }
        let imported = try importer.importSubscription(text: text, sourceURL: url)
        let stored = try profiles.add(imported.profile)
        var record = SubscriptionRecord(profileID: stored.id, interval: interval)
        record.entityTag = entityTag
        record.lastModified = lastModified
        let now = clock()
        record.lastAttempt = now
        record.lastSuccess = now
        record.lastOutcome = .updated(SubscriptionDiff(added: stored.outbounds.map(\.name)))
        try? records.put(record)
        return (stored, imported.notices)
    }

    /// Refreshes one subscription profile. Never throws: the outcome is recorded and returned. A failure
    /// leaves the stored profile unchanged.
    @discardableResult
    public func refresh(_ id: UUID) async -> SubscriptionOutcome {
        guard let profile = profiles.profiles.first(where: { $0.id == id }), let url = SubscriptionManager.url(of: profile) else {
            return .failed("это не профиль подписки")
        }
        guard !inFlight.contains(id) else { return .failed("обновление уже идёт") }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        var record = record(for: id) ?? SubscriptionRecord(profileID: id)
        let outcome: SubscriptionOutcome
        do {
            let result = try await fetcher.fetch(url, headers: SubscriptionHTTP.requestHeaders(for: record))
            switch result {
            case .notModified:
                outcome = .notModified
            case let .body(text, entityTag, lastModified):
                // The profile may have changed while the download ran (the user renamed a server).
                guard let current = profiles.profiles.first(where: { $0.id == id }) else {
                    return .failed("профиль удалён")
                }
                let fresh = try importer.importSubscription(text: text, sourceURL: url)
                let merged = SubscriptionMerger.merge(stored: current, fresh: fresh.profile, edits: record.edits)
                guard !merged.profile.outbounds.isEmpty else {
                    throw SubscriptionHTTP.Failure("в подписке не осталось видимых серверов")
                }
                try profiles.replace(merged.profile)
                record.entityTag = entityTag
                record.lastModified = lastModified
                outcome = .updated(merged.diff)
            }
            record.lastSuccess = clock()
        } catch let failure as SubscriptionHTTP.Failure {
            outcome = .failed(failure.message)
        } catch let failure as ProfileImportFailure {
            outcome = .failed("подписка не разобрана: \(ProfileImporter.describe(failure))")
        } catch let error as ProfileStoreError {
            outcome = .failed("профиль не сохранился: \(error.message)")
        } catch {
            outcome = .failed("ошибка загрузки (\(type(of: error)))")
        }
        record.lastAttempt = clock()
        record.lastOutcome = outcome
        try? records.put(record)
        return outcome
    }

    /// Refreshes every subscription whose automatic refresh is due, one after another.
    @discardableResult
    public func refreshStale() async -> [UUID: SubscriptionOutcome] {
        let now = clock()
        var outcomes: [UUID: SubscriptionOutcome] = [:]
        for profile in profiles.profiles where SubscriptionManager.url(of: profile) != nil {
            guard let record = record(for: profile.id), record.isStale(at: now) else { continue }
            outcomes[profile.id] = await refresh(profile.id)
        }
        return outcomes
    }

    /// The earliest automatic refresh due among all subscriptions; `nil` when all are manual.
    public func nextRefresh() -> Date? {
        let now = clock()
        return profiles.profiles.compactMap { record(for: $0.id)?.nextRefresh(after: now) }.min()
    }

    public func setInterval(_ interval: SubscriptionInterval, for id: UUID) throws {
        guard var record = record(for: id) else { throw ProfileStoreError("это не профиль подписки") }
        record.interval = interval
        try records.put(record)
    }

    // MARK: Edits kept across refreshes

    /// Renames a server and remembers the name for later refreshes.
    public func renameServer(_ tag: String, inProfile id: UUID, to name: String) throws {
        try profiles.renameServer(tag, inProfile: id, to: name)
        guard var record = record(for: id), let identity = identity(of: tag, inProfile: id) else { return }
        record.edits.names[identity.key] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try records.put(record)
    }

    /// Hides a server now and on every later refresh. The last visible server cannot be hidden.
    public func hideServer(_ tag: String, inProfile id: UUID) throws {
        guard var record = record(for: id), let profile = profiles.profiles.first(where: { $0.id == id }),
              let identity = identity(of: tag, inProfile: id) else {
            throw ProfileStoreError("это не профиль подписки")
        }
        guard profile.outbounds.count > 1 else { throw ProfileStoreError("нельзя скрыть последний сервер") }
        var updated = profile
        updated.outbounds.removeAll { $0.tag == tag }
        if updated.selectedTag == tag { updated.selectedTag = updated.outbounds.first?.tag }
        record.edits.hidden.insert(identity.key)
        try profiles.replace(updated)
        try records.put(record)
    }

    /// Forgets every edit; the next refresh restores hidden servers and the provider's names.
    public func resetEdits(for id: UUID) throws {
        guard var record = record(for: id) else { return }
        record.edits = SubscriptionEdits()
        record.entityTag = nil
        record.lastModified = nil
        try records.put(record)
    }

    /// Drops the record of a removed profile.
    public func forget(_ id: UUID) {
        try? records.remove(id)
    }

    private func identity(of tag: String, inProfile id: UUID) -> ServerIdentity? {
        guard let profile = profiles.profiles.first(where: { $0.id == id }),
              let index = profile.outbounds.firstIndex(where: { $0.tag == tag }) else { return nil }
        return ServerIdentity.identities(of: profile.outbounds)[index]
    }
}
