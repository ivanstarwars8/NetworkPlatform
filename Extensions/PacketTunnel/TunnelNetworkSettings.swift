// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/45966628451
//
// Builds the system description of the tunnel interface from the plan sent
// by the control plane. Packets never pass through Swift: the engine reads
// and writes the utun device itself (ADR-0003 §2), so nothing here touches
// `packetFlow`.

import Foundation
import NetworkExtension

enum TunnelNetworkSettingsBuilder {
    static func makeSettings(for plan: TunnelNetworkPlan) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: plan.remoteAddress)

        let ipv4 = NEIPv4Settings(addresses: [plan.ipv4Address], subnetMasks: [plan.ipv4SubnetMask])
        if plan.routesAllIPv4 {
            ipv4.includedRoutes = [NEIPv4Route.default()]
        }
        settings.ipv4Settings = ipv4

        if let address = plan.ipv6Address, let prefixLength = plan.ipv6PrefixLength {
            let ipv6 = NEIPv6Settings(addresses: [address], networkPrefixLengths: [NSNumber(value: prefixLength)])
            if plan.routesAllIPv6 {
                ipv6.includedRoutes = [NEIPv6Route.default()]
            }
            settings.ipv6Settings = ipv6
        }

        if !plan.dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: plan.dnsServers)
        }

        settings.mtu = NSNumber(value: plan.mtu)
        return settings
    }
}
