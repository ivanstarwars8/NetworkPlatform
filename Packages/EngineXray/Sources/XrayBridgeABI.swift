// Verified on Linux only (Swift 5.10.1, swift test, against a fake bridge). Never compiled against the real
// C archive on Linux; the binding to it lives in the extension (Extensions/PacketTunnel/XrayBridgeBinding.swift).
import Foundation

/// The C ABI v1 of the Go bridge (`Cores/Bridge/cabi/main.go`), one Swift method per `npb_*` function.
///
/// The adapter talks to the bridge only through this protocol. The real implementation is a thin binding in
/// the Packet Tunnel extension, the only target that links the C archive; tests use a fake. Keeping the
/// adapter on this side of the protocol is what lets it be compiled and tested on Linux without Go.
///
/// Rules of the ABI the binding must keep:
/// - control-plane calls return the JSON object `{"code","error","data"}` the bridge produced, already
///   copied into a Swift string and released with `npb_free`;
/// - data-plane calls take caller-owned buffers and return a non-negative count or a negated bridge code;
/// - every function is safe to call from any thread; `start`, `stop`, `validate`, `tunRead` and `readLog`
///   may block (the adapter calls them only from its own threads, never from the Swift cooperative pool).
public protocol XrayBridgeABI: Sendable {
    /// `npb_abi_version`.
    func abiVersion() -> Int32
    /// `npb_version`: `{"code":0,"data":{"abi":1,"core":"...","go":"..."}}`.
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

/// The ABI version this adapter was written against.
public enum XrayBridgeContract {
    public static let abiVersion: Int32 = 1
}

/// Result codes of the bridge (`Cores/Bridge/engine/errors.go`; the numbers are part of the ABI).
public struct XrayBridgeCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let ok = XrayBridgeCode(rawValue: 0)
    public static let invalidArgument = XrayBridgeCode(rawValue: 1)
    public static let invalidState = XrayBridgeCode(rawValue: 2)
    public static let configParse = XrayBridgeCode(rawValue: 3)
    public static let configBuild = XrayBridgeCode(rawValue: 4)
    public static let configUnsupported = XrayBridgeCode(rawValue: 5)
    public static let startFailed = XrayBridgeCode(rawValue: 6)
    public static let timeout = XrayBridgeCode(rawValue: 7)
    public static let cancelled = XrayBridgeCode(rawValue: 8)
    public static let stopFailed = XrayBridgeCode(rawValue: 9)
    public static let internalError = XrayBridgeCode(rawValue: 10)
    public static let notRunning = XrayBridgeCode(rawValue: 11)
    public static let bufferTooSmall = XrayBridgeCode(rawValue: 12)
    public static let closed = XrayBridgeCode(rawValue: 13)

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
    public static func fromDataPlane(_ result: Int32) -> XrayBridgeCode {
        XrayBridgeCode(rawValue: result == Int32.min ? Int32.max : -result)
    }
}

/// A decoded control-plane reply.
struct XrayBridgeReply<Payload: Decodable> {
    let code: XrayBridgeCode
    let error: String
    let data: Payload?

    private struct Envelope: Decodable {
        let code: Int32
        let error: String?
        let data: Payload?
    }

    /// Decodes `{"code","error","data"}`. A reply that cannot be decoded becomes code `internal`: the bridge
    /// never produces one, so it means a broken binding, and the adapter must not guess.
    static func decode(_ text: String) -> XrayBridgeReply<Payload> {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
            return XrayBridgeReply(code: .internalError, error: "bridge reply cannot be decoded", data: nil)
        }
        return XrayBridgeReply(code: XrayBridgeCode(rawValue: envelope.code), error: envelope.error ?? "", data: envelope.data)
    }
}

/// Placeholder payload for replies whose `data` is ignored.
struct XrayNoPayload: Decodable {}
