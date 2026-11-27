// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46045764184 (workflow apple.yml)
//
// The binding of `BridgeABI` (Packages/EngineBridge) to the C archive of this extension's Go bridge. Both
// bridges export the same `npb_*` functions with the same signatures (Cores/MihomoBridge/cabi/shape_test.go),
// so one file serves both extensions: each extension target compiles with exactly one engine condition
// (Apps/project.yml, NP_ENGINE_CONDITIONS) and imports exactly one bridge module (ADR-0001: one engine per
// process; linking both archives would fail on duplicate symbols anyway). The only file that calls `npb_*`
// functions apart from BridgeInfo.swift; the adapters never import a bridge module.
//
// Signatures as cgo generates them for Cores/{Bridge,MihomoBridge}/cabi/main.go: `char *` for strings and byte buffers
// of the control plane, `uint8_t *` for packet batches, `int32_t` for lengths and results. The bridge
// copies every input buffer before it returns (README, ABI notes), so pointers into Swift values that
// live only for the call are sufficient.

#if NP_ENGINE_XRAY || NP_ENGINE_MIHOMO
import EngineBridge
import Foundation
#if NP_ENGINE_XRAY
import NPXrayBridge
#else
import NPMihomoBridge
#endif

struct CBridgeBinding: BridgeABI {
    func abiVersion() -> Int32 {
        Int32(npb_abi_version())
    }

    func version() -> String {
        Self.take(npb_version())
    }

    func validate(configuration: Data, options: Data) -> String {
        Self.withCBuffers(configuration, options) { config, configLength, opts, optsLength in
            Self.take(npb_validate(config, configLength, opts, optsLength))
        }
    }

    func start(configuration: Data, options: Data) -> String {
        Self.withCBuffers(configuration, options) { config, configLength, opts, optsLength in
            Self.take(npb_start(config, configLength, opts, optsLength))
        }
    }

    func stop(timeoutMilliseconds: Int32) -> String {
        Self.take(npb_stop(timeoutMilliseconds))
    }

    func stats() -> String {
        Self.take(npb_stats())
    }

    func health() -> String {
        Self.take(npb_health())
    }

    func memory() -> String {
        Self.take(npb_memory())
    }

    func observe() -> String {
        Self.take(npb_observe())
    }

    func select(group: String, member: String) -> String {
        Self.withCBuffers(Data(group.utf8), Data(member.utf8)) { groupPointer, groupLength, memberPointer, memberLength in
            Self.take(npb_select(groupPointer, groupLength, memberPointer, memberLength))
        }
    }

    func state() -> Int32 {
        Int32(npb_state())
    }

    func readLog(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        guard let base = buffer.baseAddress else { return -1 }
        return Int32(npb_log_read(base.assumingMemoryBound(to: CChar.self), Int32(clamping: buffer.count), timeoutMilliseconds))
    }

    func tunWrite(_ batch: UnsafeMutableRawBufferPointer) -> Int32 {
        guard let base = batch.baseAddress else { return -1 }
        return Int32(npb_tun_write(base.assumingMemoryBound(to: UInt8.self), Int32(clamping: batch.count)))
    }

    func tunRead(into buffer: UnsafeMutableRawBufferPointer, timeoutMilliseconds: Int32) -> Int32 {
        guard let base = buffer.baseAddress else { return -1 }
        return Int32(npb_tun_read(base.assumingMemoryBound(to: UInt8.self), Int32(clamping: buffer.count), timeoutMilliseconds))
    }

    // MARK: Helpers

    /// Copies a reply into a Swift string and releases it with `npb_free`.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer = pointer else { return #"{"code":10,"error":"bridge returned no reply"}"# }
        defer { npb_free(pointer) }
        return String(cString: pointer)
    }

    /// Passes two byte buffers as `char *` + length. An empty buffer becomes NULL/0, which the bridge
    /// treats as "absent" (defaults for options, an error for a configuration).
    private static func withCBuffers<R>(
        _ first: Data,
        _ second: Data,
        _ body: (UnsafeMutablePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32) -> R
    ) -> R {
        first.withUnsafeBytes { a in
            second.withUnsafeBytes { b in
                body(
                    a.count == 0 ? nil : UnsafeMutablePointer(mutating: a.bindMemory(to: CChar.self).baseAddress),
                    Int32(clamping: a.count),
                    b.count == 0 ? nil : UnsafeMutablePointer(mutating: b.bindMemory(to: CChar.self).baseAddress),
                    Int32(clamping: b.count)
                )
            }
        }
    }
}
#endif
