// Verified on Linux (Swift 5.10, swift test). Per-profile engine preference and last known good record, in one
// JSON file next to profiles.json. No secrets: the last known good profile holds secret references only, and the
// configuration is identified by its SHA-256.

import Foundation

public struct EngineChoiceStoreError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Not thread-safe: owned by one actor (the app's main actor), like `ProfileStore`.
public final class EngineChoiceStore {
    public static let fileName = "engine-choices.json"
    /// Largest file read back. A limit of this project.
    public static let maximumFileBytes = 16 * 1024 * 1024

    struct Contents: Codable, Equatable {
        static let currentVersion = 1
        var version: Int
        var preferences: [UUID: EnginePreference]
        var lastKnownGood: [UUID: LastKnownGood]
    }

    public let directory: URL
    private var contents = Contents(version: Contents.currentVersion, preferences: [:], lastKnownGood: [:])

    public var fileURL: URL { directory.appendingPathComponent(EngineChoiceStore.fileName) }

    /// Opens the store; a missing file is empty. An unreadable file is reported, not silently replaced.
    public init(directory: URL) throws {
        self.directory = directory
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw EngineChoiceStoreError("reading the engine choices failed (\(type(of: error)))")
        }
        guard data.count <= EngineChoiceStore.maximumFileBytes,
              let decoded = try? JSONDecoder().decode(Contents.self, from: data),
              decoded.version == Contents.currentVersion else {
            throw EngineChoiceStoreError("the engine choices file is not readable")
        }
        contents = decoded
    }

    public func preference(for profileID: UUID) -> EnginePreference {
        contents.preferences[profileID] ?? .automatic
    }

    public func setPreference(_ preference: EnginePreference, for profileID: UUID) throws {
        if preference == .automatic {
            contents.preferences.removeValue(forKey: profileID)
        } else {
            contents.preferences[profileID] = preference
        }
        try save()
    }

    public func lastKnownGood(for profileID: UUID) -> LastKnownGood? {
        contents.lastKnownGood[profileID]
    }

    public func recordGood(_ record: LastKnownGood) throws {
        contents.lastKnownGood[record.profileID] = record
        try save()
    }

    /// Drops everything about a removed profile.
    public func forget(_ profileID: UUID) throws {
        contents.preferences.removeValue(forKey: profileID)
        contents.lastKnownGood.removeValue(forKey: profileID)
        try save()
    }

    /// Drops records of profiles that no longer exist.
    public func retain(only profileIDs: Set<UUID>) throws {
        let before = contents
        contents.preferences = contents.preferences.filter { profileIDs.contains($0.key) }
        contents.lastKnownGood = contents.lastKnownGood.filter { profileIDs.contains($0.key) }
        if contents != before { try save() }
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(contents).write(to: fileURL, options: [.atomic])
        } catch {
            throw EngineChoiceStoreError("saving the engine choices failed (\(type(of: error)))")
        }
    }
}
