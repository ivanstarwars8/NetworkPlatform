// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/45966628451
//
// The one place where this extension calls the Go bridge today: it reads the
// bridge's ABI and version at start and logs them. It proves that the C
// archive is linked into the extension and callable from Swift; it is not an
// engine adapter (there is none, the registry stays empty, see
// PacketTunnelProvider.swift). Only in flavours that contain Xray.

#if NP_ENGINE_XRAY
import NPXrayBridge

enum XrayBridgeInfo {
    /// The C ABI version this extension was written against (Cores/Bridge/cabi/main.go).
    static let expectedABIVersion: Int32 = 1

    static var abiVersion: Int32 {
        Int32(npb_abi_version())
    }

    /// `{"code":0,"data":{"abi":1,"core":"...","go":"..."}}` from the bridge;
    /// contains no configuration data.
    static func versionJSON() -> String {
        guard let pointer = npb_version() else { return "" }
        defer { npb_free(pointer) }
        return String(cString: pointer)
    }
}
#endif
