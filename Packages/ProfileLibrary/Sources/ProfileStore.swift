import DomainModels
import Foundation

/// A failure of the profile store. Messages name the operation and the error type only: never a path, a
/// profile's content or a secret.
public struct ProfileStoreError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The user's profiles on disk: one JSON file (`profiles.json`) with the profiles and the selected one.
/// Inline secrets never reach the file: `add(_:)` moves them to the `SecretStore` and keeps references
/// (`<profile id>/<outbound index>/<slot>`). `resolveSecret` gives them back to the compiler.
///
/// Not thread-safe: owned by one actor (the app's main actor).
public final class ProfileStore {
    public static let fileName = "profiles.json"
    /// Largest profile file read back. A limit of this project.
    public static let maximumFileBytes = 16 * 1024 * 1024

    struct Library: Codable {
        static let currentVersion = 1
        var version: Int
        var profiles: [Profile]
        var selectedProfileID: UUID?
        /// Server choice per profile (UUID string → choice). Absent in files written before it existed;
        /// a missing entry means the default (`ProfileStore.defaultChoice`).
        var choices: [String: ServerChoice]?
    }

    public let directory: URL
    private let secrets: SecretStore
    private var library = Library(version: Library.currentVersion, profiles: [], selectedProfileID: nil)

    public var profiles: [Profile] { library.profiles }
    public var selectedProfileID: UUID? { library.selectedProfileID }
    public var selectedProfile: Profile? {
        library.selectedProfileID.flatMap { id in library.profiles.first { $0.id == id } }
    }

    public var fileURL: URL { directory.appendingPathComponent(ProfileStore.fileName) }

    /// Opens the store and reads the file if there is one. A missing file is an empty library.
    public init(directory: URL, secrets: SecretStore) throws {
        self.directory = directory
        self.secrets = secrets
        try load()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProfileStoreError("reading the profile file failed (\(type(of: error)))")
        }
        guard data.count <= ProfileStore.maximumFileBytes else {
            throw ProfileStoreError("the profile file exceeds \(ProfileStore.maximumFileBytes) bytes")
        }
        guard let decoded = try? JSONDecoder().decode(Library.self, from: data) else {
            throw ProfileStoreError("the profile file is not readable")
        }
        guard decoded.version == Library.currentVersion else {
            throw ProfileStoreError("the profile file has version \(decoded.version)")
        }
        library = decoded
        if let selected = library.selectedProfileID, !library.profiles.contains(where: { $0.id == selected }) {
            library.selectedProfileID = nil
        }
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(library).write(to: fileURL, options: [.atomic])
        } catch {
            throw ProfileStoreError("saving the profile file failed (\(type(of: error)))")
        }
    }

    /// Stores an imported profile, its inline secrets moved to the secret store. The first profile becomes
    /// the selected one. Returns the stored form (references instead of secrets).
    @discardableResult
    public func add(_ profile: Profile) throws -> Profile {
        var stored = profile
        var written: [SecretReference] = []
        do {
            stored.outbounds = try storeSecrets(of: profile, prefix: profile.id.uuidString, written: &written)
            library.profiles.removeAll { $0.id == profile.id }
            library.profiles.append(stored)
            if library.selectedProfileID == nil {
                library.selectedProfileID = stored.id
            }
            try save()
        } catch {
            written.forEach { secrets.removeSecret(for: $0) }
            library.profiles.removeAll { $0.id == profile.id }
            if library.selectedProfileID == profile.id { library.selectedProfileID = nil }
            if let error = error as? ProfileStoreError { throw error }
            throw ProfileStoreError("storing a secret failed (\(type(of: error)))")
        }
        return stored
    }

    /// Moves the inline secrets of `profile` to the secret store under `<prefix>/<outbound index>/<slot>`.
    private func storeSecrets(of profile: Profile, prefix: String, written: inout [SecretReference]) throws -> [Outbound] {
        var references: [SecretReference] = []
        defer { written.append(contentsOf: references) }
        return try profile.outbounds.enumerated().map { index, outbound in
            try outbound.replacingInlineSecrets { slot, value in
                let reference = SecretReference(identifier: "\(prefix)/\(index)/\(slot.rawValue)")
                try secrets.setSecret(value, for: reference)
                references.append(reference)
                return reference
            }
        }
    }

    /// Replaces a stored profile's servers and name with those of `updated` (a refreshed subscription),
    /// keeping its id, its place in the list and the selection. New secrets are written under a new prefix
    /// first, so a failure leaves the stored profile and its secrets untouched; the old secrets are removed
    /// only after the file is saved. Returns the stored form.
    @discardableResult
    public func replace(_ updated: Profile) throws -> Profile {
        guard let index = library.profiles.firstIndex(where: { $0.id == updated.id }) else {
            throw ProfileStoreError("no such profile")
        }
        let previous = library.profiles[index]
        var stored = updated
        var written: [SecretReference] = []
        let prefix = "\(updated.id.uuidString)/r\(UUID().uuidString.prefix(8))"
        do {
            stored.outbounds = try storeSecrets(of: updated, prefix: prefix, written: &written)
            library.profiles[index] = stored
            if case let .server(tag)? = library.choices?[updated.id.uuidString], stored.outbound(tagged: tag) == nil {
                library.choices?[updated.id.uuidString] = .automatic
            }
            try save()
        } catch {
            written.forEach { secrets.removeSecret(for: $0) }
            library.profiles[index] = previous
            if let error = error as? ProfileStoreError { throw error }
            throw ProfileStoreError("storing a secret failed (\(type(of: error)))")
        }
        let kept = Set(ProfileStore.secretReferences(of: stored).map(\.identifier))
        for reference in ProfileStore.secretReferences(of: previous) where !kept.contains(reference.identifier) {
            secrets.removeSecret(for: reference)
        }
        return stored
    }

    /// The server choice of a profile. Default: «Авто» for a profile the engine can choose in
    /// (`AutomaticGroup.applies`), otherwise its selected server.
    public func choice(forProfile id: UUID) -> ServerChoice {
        guard let profile = library.profiles.first(where: { $0.id == id }) else { return .automatic }
        return ProfileStore.effectiveChoice(library.choices?[id.uuidString], of: profile)
    }

    static func effectiveChoice(_ stored: ServerChoice?, of profile: Profile) -> ServerChoice {
        guard AutomaticGroup.applies(to: profile) else {
            return .server(tag: profile.selectedTag ?? profile.outbounds.first?.tag ?? "")
        }
        switch stored {
        case let .server(tag)? where profile.outbound(tagged: tag) != nil:
            return .server(tag: tag)
        default:
            return .automatic
        }
    }

    /// Stores the server choice of a profile. A server choice also becomes the profile's selected tag.
    public func setChoice(_ choice: ServerChoice, forProfile id: UUID) throws {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError("no such profile")
        }
        let previous = library
        switch choice {
        case .automatic:
            guard AutomaticGroup.applies(to: library.profiles[index]) else {
                throw ProfileStoreError("this profile has a single server")
            }
        case let .server(tag):
            guard library.profiles[index].outbound(tagged: tag) != nil else {
                throw ProfileStoreError("no such server in the profile")
            }
            library.profiles[index].selectedTag = tag
        }
        var choices = library.choices ?? [:]
        choices[id.uuidString] = choice
        library.choices = choices
        do {
            try save()
        } catch {
            library = previous
            throw error
        }
    }

    /// Gives a server of a profile another display name. The tag (its key) does not change.
    public func renameServer(_ tag: String, inProfile id: UUID, to name: String) throws {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }),
              let position = library.profiles[index].outbounds.firstIndex(where: { $0.tag == tag }) else {
            throw ProfileStoreError("no such server in the profile")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else {
            throw ProfileStoreError("the name is empty or too long")
        }
        let previous = library
        library.profiles[index].outbounds[position].name = trimmed
        do {
            try save()
        } catch {
            library = previous
            throw error
        }
    }

    /// Renames a profile.
    public func renameProfile(_ id: UUID, to name: String) throws {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError("no such profile")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else {
            throw ProfileStoreError("the name is empty or too long")
        }
        let previous = library
        library.profiles[index].name = trimmed
        do {
            try save()
        } catch {
            library = previous
            throw error
        }
    }

    /// Removes a profile and its secrets.
    public func remove(id: UUID) throws {
        guard let profile = library.profiles.first(where: { $0.id == id }) else { return }
        library.profiles.removeAll { $0.id == id }
        library.choices?[id.uuidString] = nil
        if library.selectedProfileID == id {
            library.selectedProfileID = library.profiles.first?.id
        }
        try save()
        for reference in ProfileStore.secretReferences(of: profile) {
            secrets.removeSecret(for: reference)
        }
    }

    public func select(id: UUID) throws {
        guard library.profiles.contains(where: { $0.id == id }) else {
            throw ProfileStoreError("no such profile")
        }
        library.selectedProfileID = id
        try save()
    }

    /// Chooses the outbound (or group) of a profile that traffic goes to.
    public func selectTag(_ tag: String, inProfile id: UUID) throws {
        guard let index = library.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError("no such profile")
        }
        let profile = library.profiles[index]
        guard profile.outbound(tagged: tag) != nil || profile.group(tagged: tag) != nil else {
            throw ProfileStoreError("no such server in the profile")
        }
        library.profiles[index].selectedTag = tag
        try save()
    }

    /// The resolver the compilers take: the secret behind a reference, `nil` when it is missing.
    public func resolveSecret(_ reference: SecretReference) -> String? {
        secrets.secret(for: reference)
    }

    /// The secrets of one profile, read now, keyed by reference identifier: a value that can travel to a
    /// compiler on another thread (`ProfileStore` itself stays on its actor). Missing secrets are absent and
    /// make the compiler report the outbound.
    public func resolvedSecrets(of profile: Profile) -> [String: String] {
        var result: [String: String] = [:]
        for reference in ProfileStore.secretReferences(of: profile) {
            result[reference.identifier] = secrets.secret(for: reference)
        }
        return result
    }

    /// Every reference a stored profile holds.
    static func secretReferences(of profile: Profile) -> [SecretReference] {
        profile.outbounds.flatMap(\.storedSecretReferences)
    }
}

extension Outbound {
    /// The secret references of a stored outbound, in the slots `replacingInlineSecrets` fills.
    fileprivate var storedSecretReferences: [SecretReference] {
        var values: [SecretValue?] = [
            credentials.userID, credentials.password, credentials.privateKey, credentials.preSharedKey,
        ]
        if case .hysteria2(let settings) = self.settings { values.append(settings.obfuscation?.password) }
        switch stream.transport {
        case .quic(let settings): values.append(settings.key)
        case .kcp(let settings): values.append(settings.seed)
        default: break
        }
        return values.compactMap { $0?.secretReference }
    }
}
