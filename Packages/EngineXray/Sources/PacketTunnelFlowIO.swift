// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 45987643793 (workflow apple.yml)
// and as part of the Swift package on macOS (workflow swift-package.yml, run 45987648310)
//
// `TunnelPacketIO` over `NEPacketTunnelFlow`. Only where Network Extension exists; the pure pump logic it
// feeds is tested on Linux with a fake.

#if canImport(NetworkExtension)
import Foundation
import NetworkExtension

/// Wraps the provider's `packetFlow`. `NEPacketTunnelFlow` is not marked Sendable; the pump calls
/// `readPackets` from the completion queue or its writer thread and `writePackets` only from its reader
/// thread, never concurrently with itself. Network Extension documents neither call as main-thread-only.
public final class PacketTunnelFlowIO: TunnelPacketIO, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow
    private static let inet = NSNumber(value: AF_INET)
    private static let inet6 = NSNumber(value: AF_INET6)

    public init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    public func readPackets(_ handler: @escaping @Sendable ([Data]) -> Void) {
        // The protocol numbers of the read are ignored: the bridge takes raw IP packets.
        flow.readPackets { packets, _ in
            handler(packets)
        }
    }

    public func writePackets(_ packets: [Data], families: [PacketAddressFamily]) -> Bool {
        let protocols = families.map { $0 == .ipv4 ? PacketTunnelFlowIO.inet : PacketTunnelFlowIO.inet6 }
        return flow.writePackets(packets, withProtocols: protocols)
    }
}
#endif
