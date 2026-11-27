// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
// (the Xray part, then XrayBridgeInfo.swift, was compiled on macOS CI in GitHub Actions run 45966628451).
//
// Reads the linked bridge's ABI and version at start, for the log. It proves that the C archive is linked
// into the extension and callable from Swift. One file for both extensions, like BridgeBinding.swift.

#if NP_ENGINE_XRAY || NP_ENGINE_MIHOMO
#if NP_ENGINE_XRAY
import NPXrayBridge
#else
import NPMihomoBridge
#endif

enum BridgeInfo {
    /// The engine of this extension, for log lines.
    #if NP_ENGINE_XRAY
    static let engine = "xray"
    #else
    static let engine = "mihomo"
    #endif

    /// The C ABI version this extension was written against (cabi/main.go of both bridges).
    static let expectedABIVersion: Int32 = 1

    static var abiVersion: Int32 {
        Int32(npb_abi_version())
    }

    /// `{"code":0,"data":{"abi":1,"core":"...","go":"..."}}` from the bridge (Mihomo adds "engine");
    /// contains no configuration data.
    static func versionJSON() -> String {
        guard let pointer = npb_version() else { return "" }
        defer { npb_free(pointer) }
        return String(cString: pointer)
    }
}
#endif
