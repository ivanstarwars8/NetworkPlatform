// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 45966628451 (workflow apple.yml)
//
// Builds the system description of the tunnel interface from the plan sent
// by the control plane. Nothing here touches `packetFlow`: the packet pump of
// the engine adapter moves packets in batches without parsing them
// (ADR-0001 §4.1, Packages/EngineXray/Sources/PacketPump.swift).
// The plan's MTU is also passed to the engine as `CoreStartOptions.mtu`, so
// the interface and the engine's stack agree. Addresses, resolvers and MTU
// of the plan come from `TunnelAddressing` (DomainModels), the same value the
// configuration compiler used (`TunnelNetworkPlan.init(addressing:...)`).

import DomainModels
import Foundation
import NetworkExtension

enum TunnelNetworkSettingsBuilder {
    static func makeSettings(for plan: TunnelNetworkPlan) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: plan.remoteAddress)

        let ipv4 = NEIPv4Settings(addresses: [plan.ipv4Address], subnetMasks: [plan.ipv4SubnetMask])
        if plan.routesAllIPv4 {
            ipv4.includedRoutes = [NEIPv4Route.default()]
        }
        let excludedIPv4 = plan.excludedRoutes.compactMap { route -> NEIPv4Route? in
            guard let mask = route.ipv4SubnetMask else { return nil }
            return NEIPv4Route(destinationAddress: route.address, subnetMask: mask)
        }
        if !excludedIPv4.isEmpty {
            ipv4.excludedRoutes = excludedIPv4
        }
        settings.ipv4Settings = ipv4

        if let address = plan.ipv6Address, let prefixLength = plan.ipv6PrefixLength {
            let ipv6 = NEIPv6Settings(addresses: [address], networkPrefixLengths: [NSNumber(value: prefixLength)])
            if plan.routesAllIPv6 {
                ipv6.includedRoutes = [NEIPv6Route.default()]
            }
            let excludedIPv6 = plan.excludedRoutes.filter(\.isIPv6).map { route in
                NEIPv6Route(destinationAddress: route.address, networkPrefixLength: NSNumber(value: route.prefixLength))
            }
            if !excludedIPv6.isEmpty {
                ipv6.excludedRoutes = excludedIPv6
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
