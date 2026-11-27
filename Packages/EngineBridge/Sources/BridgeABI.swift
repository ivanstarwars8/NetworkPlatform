// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never compiled against the real
// C archive on Linux; the bindings live in the extensions (Extensions/PacketTunnel/{Xray,Mihomo}BridgeBinding.swift).
import Foundation

/// The C ABI v1 of the Go bridges, one Swift method per `npb_*` function. Both bridges export the same 14
/// functions with the same signatures and envelopes (`Cores/Bridge/cabi/main.go`,
/// `Cores/MihomoBridge/cabi/main.go`, checked by `Cores/MihomoBridge/cabi/shape_test.go`); what differs per
/// engine is the configuration document, the options and the shape of a few `data` payloads.
///
/// The adapters talk to a bridge only through this protocol. The real implementation is a thin binding in
/// the engine's Packet Tunnel extension, the only target that links that C archive; tests use a fake.
/// Keeping the adapters on this side of the protocol is what lets them be compiled and tested on Linux.
///
/// Rules of the ABI the binding must keep:
/// - control-plane calls return the JSON object `{"code","error","data"}` the bridge produced, already
///   copied into a Swift string and released with `npb_free`;
/// - data-plane calls take caller-owned buffers and return a non-negative count or a negated bridge code;
/// - every function is safe to call from any thread; `start`, `stop`, `validate`, `tunRead` and `readLog`
///   may block (the adapter calls them only from its own threads, never from the Swift cooperative pool).
public protocol BridgeABI: Sendable {
    /// `npb_abi_version`.
    func abiVersion() -> Int32
    /// `npb_version`: `{"code":0,"data":{"abi":1,"core":"...","go":"..."}}` (Mihomo adds `"engine"`).
    func version() -> String
    /// `npb_validate`. Blocks while the core builds the configuration.
    func validate(configuration: Data, options: Data) -> String
    /// `npb_start`. Blocks until the core runs, fails, or the start timeout of the options elapses.
    func start(configuration: Data, options: Data) -> String
    /// `npb_stop`. Idempotent; interrupts a start in progress.
    func stop(timeoutMilliseconds: Int32) -> String
    /// `npb_stats`.
    func stats() -> String
    /// `npb_health`. Works in every state.
    func health() -> String
    /// `npb_memory`.
    func memory() -> String
    /// `npb_state`: 0 idle, 1 starting, 2 running, 3 stopping.
    func state() -> Int32
    /// `npb_log_read`: newline-terminated JSON records; 0 = nothing within the timeout. Needs >= 4 KiB.
    func readLog(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32
    /// `npb_tun_write`: a batch of frames; returns the number of packets consumed. The bridge may modify the
    /// bytes in place and does not keep the buffer.
    func tunWrite(_ batch: UnsafeMutableRawBufferPointer) -> Int32
    /// `npb_tun_read`: fills the buffer with whole frames; 0 = timeout elapsed.
    func tunRead(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32
}

/// The ABI version the adapters were written against.
public enum BridgeContract {
    public static let abiVersion: Int32 = 1
}

/// Result codes of the bridges (`Cores/Bridge/engine/errors.go`, copied as `Cores/MihomoBridge/engine/errors.go`;
/// the numbers are part of the ABI).
public struct BridgeCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let ok = BridgeCode(rawValue: 0)
    public static let invalidArgument = BridgeCode(rawValue: 1)
    public static let invalidState = BridgeCode(rawValue: 2)
    public static let configParse = BridgeCode(rawValue: 3)
    public static let configBuild = BridgeCode(rawValue: 4)
    public static let configUnsupported = BridgeCode(rawValue: 5)
    public static let startFailed = BridgeCode(rawValue: 6)
    public static let timeout = BridgeCode(rawValue: 7)
    public static let cancelled = BridgeCode(rawValue: 8)
    public static let stopFailed = BridgeCode(rawValue: 9)
    public static let internalError = BridgeCode(rawValue: 10)
    public static let notRunning = BridgeCode(rawValue: 11)
    public static let bufferTooSmall = BridgeCode(rawValue: 12)
    public static let closed = BridgeCode(rawValue: 13)

    public var description: String {
        switch rawValue {
        case 0: return "ok"
        case 1: return "invalid_argument"
        case 2: return "invalid_state"
        case 3: return "config_parse"
        case 4: return "config_build"
        case 5: return "config_unsupported"
        case 6: return "start_failed"
        case 7: return "timeout"
        case 8: return "cancelled"
        case 9: return "stop_failed"
        case 10: return "internal"
        case 11: return "not_running"
        case 12: return "buffer_too_small"
        case 13: return "closed"
        default: return "code_\(rawValue)"
        }
    }

    /// The code of a negative data-plane result.
    public static func fromDataPlane(_ result: Int32) -> BridgeCode {
        BridgeCode(rawValue: result == Int32.min ? Int32.max : -result)
    }
}

/// A decoded control-plane reply.
package struct BridgeReply<Payload: Decodable> {
    package let code: BridgeCode
    package let error: String
    package let data: Payload?

    private struct Envelope: Decodable {
        let code: Int32
        let error: String?
        let data: Payload?
    }

    /// Decodes `{"code","error","data"}`. A reply that cannot be decoded becomes code `internal`: the bridge
    /// never produces one, so it means a broken binding, and the adapter must not guess.
    package static func decode(_ text: String) -> BridgeReply<Payload> {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
            return BridgeReply(code: .internalError, error: "bridge reply cannot be decoded", data: nil)
        }
        return BridgeReply(code: BridgeCode(rawValue: envelope.code), error: envelope.error ?? "", data: envelope.data)
    }
}

/// Placeholder payload for replies whose `data` is ignored.
package struct BridgeNoPayload: Decodable {}

/// `engine.Health` of both bridges; the fields the adapters use (the same names in both).
package struct BridgeHealth: Decodable, Equatable {
    package let state: String?
    package let uptimeMs: Int64?
    package let coreRunning: Bool?
    package let lastErrorCode: Int32?
    package let lastError: String?
    package let logDropped: UInt64?
}

/// `npb_version` data. `engine` is reported by the Mihomo bridge only.
package struct BridgeVersion: Decodable, Equatable {
    package let abi: Int32?
    package let engine: String?
    package let core: String?
    package let go: String?
}

/// One record of `npb_log_read` (`engine.LogRecord`, the same in both bridges). Messages of the core may
/// contain destination addresses: hosts must log them as private (ADR-0003 §4).
public struct BridgeLogRecord: Decodable, Hashable, Sendable {
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
