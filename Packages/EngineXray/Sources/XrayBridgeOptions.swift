// Verified on Linux only (Swift 5.10.1, swift test). Not yet run on Apple platforms.
import Foundation

/// The start options of the bridge (`Cores/Bridge/engine/options.go`). The bridge refuses unknown fields,
/// so only fields it defines are encoded, and zero values are left out to keep its defaults.
///
/// These are run-time parameters next to the configuration (ADR-0001 §4–5); the configuration document
/// itself is never touched.
struct XrayBridgeOptions: Encodable, Equatable {
    struct Memory: Encodable, Equatable {
        /// `memory.profile`; the bridge fills the profile's values for the fields left out.
        var profile: String?
        var limitBytes: Int64?
        var gcPercent: Int?
    }

    struct Tun: Encodable, Equatable {
        var mode: String?
        var fd: Int32?
        var mtu: Int?
        var outQueueBytes: Int?
    }

    var startTimeoutMs: Int?
    var stopTimeoutMs: Int?
    var logLevel: String?
    var accessLog: Bool?
    var memory: Memory?
    var tun: Tun?

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of optionals and integers cannot fail.
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// `engine.ConfigSummary` (no addresses or secrets in it).
struct XrayConfigSummary: Decodable, Equatable {
    struct Handler: Decodable, Equatable {
        let tag: String?
        let type: String?
    }

    let inbounds: [Handler]?
    let outbounds: [Handler]?
    let hasTun: Bool?
    let depth: String?
}

/// `engine.Stats`.
struct XrayBridgeStats: Decodable, Equatable {
    struct Counter: Decodable, Equatable {
        let tag: String
        let uplink: Int64
        let downlink: Int64
    }

    let uptimeMs: Int64?
    let inbounds: [Counter]?
    let outbounds: [Counter]?
}
