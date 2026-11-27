// Verified on Linux only (Swift 5.10.1, swift test). Not yet run on Apple platforms.
import Foundation

/// The start options of the bridge (`Cores/Bridge/engine/options.go`). The bridge refuses unknown fields,
/// so only fields it defines are encoded, and zero values are left out to keep its defaults.
///
/// These are run-time parameters next to the configuration (ADR-0001 §4–5); the configuration document
/// itself is never touched.
struct XrayBridgeOptions: Encodable, Equatable {
    struct Memory: Encodable, Equatable {
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

/// `engine.Health`; the fields the adapter uses.
struct XrayBridgeHealth: Decodable, Equatable {
    let state: String?
    let uptimeMs: Int64?
    let coreRunning: Bool?
    let lastErrorCode: Int32?
    let lastError: String?
    let logDropped: UInt64?
}

/// `npb_version` data.
struct XrayBridgeVersion: Decodable, Equatable {
    let abi: Int32?
    let core: String?
    let go: String?
}

/// One record of `npb_log_read` (`engine.LogRecord`). Messages of the core may contain destination
/// addresses: hosts must log them as private (ADR-0003 §4).
public struct XrayLogRecord: Decodable, Hashable, Sendable {
    public let seq: UInt64
    public let timeUnixMilliseconds: Int64
    public let level: String?
    public let kind: String
    public let message: String

    enum CodingKeys: String, CodingKey {
        case seq
        case timeUnixMilliseconds = "t"
        case level = "lvl"
        case kind
        case message = "msg"
    }

    public init(seq: UInt64, timeUnixMilliseconds: Int64, level: String?, kind: String, message: String) {
        self.seq = seq
        self.timeUnixMilliseconds = timeUnixMilliseconds
        self.level = level
        self.kind = kind
        self.message = message
    }
}
