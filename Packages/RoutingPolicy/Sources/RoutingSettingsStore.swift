import Foundation

/// Why the store could not read or write.
public struct RoutingStoreError: Error, Hashable, Sendable {
    public var message: String
}

/// Keeps `RoutingSettings` in `routing.json` and the compact entries of each downloaded list in
/// `rulesets/<id>.json`, in one directory. Writes are atomic. Nothing here holds secrets, but list
/// addresses may carry tokens: the store never logs.
public final class RoutingSettingsStore {
    public let directory: URL
    public private(set) var settings: RoutingSettings
    private var cache: [UUID: CompiledRuleSet] = [:]

    private var settingsURL: URL { directory.appendingPathComponent("routing.json") }
    private var ruleSetDirectory: URL { directory.appendingPathComponent("rulesets", isDirectory: true) }

    public init(directory: URL) throws {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RoutingStoreError(message: "каталог настроек не создаётся")
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("routing.json")) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(RoutingSettings.self, from: data)
                guard decoded.schemaVersion <= RoutingSettings.currentSchemaVersion else {
                    throw RoutingStoreError(message: "настройки сохранены более новой версией приложения")
                }
                settings = decoded
            } catch let error as RoutingStoreError {
                throw error
            } catch {
                throw RoutingStoreError(message: "файл настроек повреждён")
            }
        } else {
            settings = RoutingSettings()
        }
        for list in settings.remoteRuleSets {
            if let data = try? Data(contentsOf: ruleSetURL(list.id)),
               let content = try? JSONDecoder().decode(CompiledRuleSet.self, from: data) {
                cache[list.id] = content
            }
        }
    }

    /// Cached entries of every list that has them.
    public var ruleSets: [UUID: CompiledRuleSet] { cache }

    public func save(_ new: RoutingSettings) throws {
        try write(new, to: settingsURL)
        let removed = Set(settings.remoteRuleSets.map(\.id)).subtracting(new.remoteRuleSets.map(\.id))
        settings = new
        for id in removed {
            cache[id] = nil
            try? FileManager.default.removeItem(at: ruleSetURL(id))
        }
    }

    /// Stores freshly downloaded entries of a list and its metadata together.
    public func storeRuleSet(_ content: CompiledRuleSet, for id: UUID, updating new: RoutingSettings) throws {
        try FileManager.default.createDirectory(at: ruleSetDirectory, withIntermediateDirectories: true)
        try write(content, to: ruleSetURL(id))
        cache[id] = content
        try save(new)
    }

    public func compiler(limits: RuleSetLimits = .standard) -> RoutingPolicyCompiler {
        RoutingPolicyCompiler(settings: settings, ruleSets: cache, limits: limits)
    }

    private func ruleSetURL(_ id: UUID) -> URL {
        ruleSetDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RoutingStoreError(message: "файл не записался")
        }
    }
}
