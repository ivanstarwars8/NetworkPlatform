// Verified on Linux only (Swift 5.10.1, swift test). Not yet run on Apple platforms.
import Foundation

/// The start options of the Mihomo bridge (`Cores/MihomoBridge/engine/options.go`). The bridge refuses unknown
/// fields (the Xray bridge's `accessLog`, `assetDir`, `disableStats`, `tun.fd` included), so only fields it
/// defines are encoded, and zero values are left out to keep its defaults and the profile's values.
struct MihomoBridgeOptions: Encodable, Equatable {
    struct Memory: Encodable, Equatable {
        /// `memory.profile`; the bridge fills the profile's values for the fields left out.
        var profile: String?
        var limitBytes: Int64?
        var gcPercent: Int?
    }

    struct Tun: Encodable, Equatable {
        /// Only "flow": the bridge has no fd mode.
        var mode: String?
        var mtu: Int?
        var outQueueBytes: Int?
        var inQueueBytes: Int?
    }

    var startTimeoutMs: Int?
    var stopTimeoutMs: Int?
    var homeDir: String?
    var logLevel: String?
    var tcpIdleTimeoutMs: Int?
    var udpIdleTimeoutMs: Int?
    var memory: Memory?
    var tun: Tun?

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of optionals, strings and integers cannot fail.
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// `engine.ConfigSummary` of the Mihomo bridge: counts and the list of settings the bridge changed or ignored
/// (no addresses or secrets in it).
struct MihomoConfigSummary: Decodable, Equatable {
    let mode: String?
    let proxies: Int?
    let rules: Int?
    let hasTun: Bool?
    let overridden: [String]?
    let depth: String?
}

/// `engine.Stats` of the Mihomo bridge: the core counts per connection, without a split by inbound or outbound.
struct MihomoBridgeStats: Decodable, Equatable {
    struct Total: Decodable, Equatable {
        let uplink: Int64
        let downlink: Int64
    }

    let uptimeMs: Int64?
    let total: Total?
    let connections: Int?
}

/// `engine.Connections` of the Mihomo bridge: the total and the newest tracked connections.
struct MihomoBridgeConnections: Decodable, Equatable {
    struct Item: Decodable, Equatable {
        let id: String
        let network: String
        let destination: String
        let rule: String?
        let chain: [String]?
        let upload: Int64
        let download: Int64
        let startMs: Int64
    }

    let total: Int
    let items: [Item]
}
