// The stored form of the automation settings and state: one JSON value in the app's defaults. Versioned so a
// future change can migrate; an unreadable or newer record falls back to defaults rather than failing.

import Foundation

public struct AutomationRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// UserDefaults key of the record.
    public static let storageKey = "automation.v1"

    public var version: Int
    public var settings: AutomationSettings
    public var state: OnDemandState

    public init(settings: AutomationSettings = AutomationSettings(), state: OnDemandState = OnDemandState()) {
        version = AutomationRecord.currentVersion
        self.settings = settings
        self.state = state
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Bools, strings and an Int: encoding cannot fail.
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Reads a stored record; nil, unreadable or newer data gives the defaults.
    public static func decode(_ data: Data?) -> AutomationRecord {
        guard let data = data,
              let record = try? JSONDecoder().decode(AutomationRecord.self, from: data),
              record.version <= currentVersion else {
            return AutomationRecord()
        }
        return record
    }
}
