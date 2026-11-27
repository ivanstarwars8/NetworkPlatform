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
            stored.outbounds = try profile.outbounds.enumerated().map { index, outbound in
                try outbound.replacingInlineSecrets { slot, value in
                    let reference = SecretReference(identifier: "\(profile.id.uuidString)/\(index)/\(slot.rawValue)")
                    try secrets.setSecret(value, for: reference)
                    written.append(reference)
                    return reference
                }
            }
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

    /// Removes a profile and its secrets.
    public func remove(id: UUID) throws {
        guard let profile = library.profiles.first(where: { $0.id == id }) else { return }
        library.profiles.removeAll { $0.id == id }
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
