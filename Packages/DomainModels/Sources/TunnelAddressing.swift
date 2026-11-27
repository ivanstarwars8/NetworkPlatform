import Foundation

/// One destination prefix of the tunnel's routing, e.g. `10.0.0.0/8` or `fe80::/10`.
public struct TunnelRoute: Codable, Hashable, Sendable {
    /// Network address in textual form (IPv4 dotted quad or IPv6).
    public var address: String
    public var prefixLength: Int

    public init(address: String, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    /// A host route (`/32` or `/128`) for one address.
    public static func host(_ address: String) -> TunnelRoute {
        TunnelRoute(address: address, prefixLength: address.utf8.contains(0x3A) ? 128 : 32)
    }

    public var isIPv6: Bool { address.utf8.contains(0x3A) }

    /// `address/prefixLength`.
    public var cidr: String { "\(address)/\(prefixLength)" }

    /// Dotted-quad subnet mask of an IPv4 route (`NEIPv4Route` takes a mask, not a prefix length);
    /// `nil` for IPv6 or an out-of-range prefix.
    public var ipv4SubnetMask: String? {
        guard !isIPv6 else { return nil }
        return TunnelRoute.ipv4SubnetMask(prefixLength: prefixLength)
    }

    public static func ipv4SubnetMask(prefixLength: Int) -> String? {
        guard (0...32).contains(prefixLength) else { return nil }
        let bits: UInt32 = prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
        return [24, 16, 8, 0].map { String((bits >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}

/// Addresses of the tunnel interface, shared by everything that has to agree on them: the engine
/// configuration compiler (DNS hijack, private-range rules) and the Packet Tunnel host
/// (`NEPacketTunnelNetworkSettings`). There is one source of these values: this type.
///
/// The defaults are project choices. IPv4 uses 198.18.0.0/30 out of the benchmarking range
/// (RFC 2544), which is neither private nor publicly routed, so it does not collide with the
/// private ranges that bypass the tunnel. IPv6 uses a /126 out of a unique-local prefix.
public struct TunnelAddressing: Codable, Hashable, Sendable {
    public var ipv4Address: String
    public var ipv4PrefixLength: Int
    public var ipv6Address: String?
    public var ipv6PrefixLength: Int?
    /// Resolver addresses given to the system. They lie inside the tunnel's own prefixes, so queries
    /// sent to them enter the tunnel; the engine answers them itself (DNS hijack).
    public var dnsIPv4Address: String
    public var dnsIPv6Address: String?
    /// MTU of the interface and of the engine's packet stack; both must be equal.
    public var mtu: Int

    public init(
        ipv4Address: String,
        ipv4PrefixLength: Int,
        ipv6Address: String?,
        ipv6PrefixLength: Int?,
        dnsIPv4Address: String,
        dnsIPv6Address: String?,
        mtu: Int
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4PrefixLength = ipv4PrefixLength
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.dnsIPv4Address = dnsIPv4Address
        self.dnsIPv6Address = dnsIPv6Address
        self.mtu = mtu
    }

    public static let standard = TunnelAddressing(
        ipv4Address: "198.18.0.1",
        ipv4PrefixLength: 30,
        ipv6Address: "fd66:6e70::1",
        ipv6PrefixLength: 126,
        dnsIPv4Address: "198.18.0.2",
        dnsIPv6Address: "fd66:6e70::2",
        mtu: 1500
    )

    public var ipv4SubnetMask: String {
        TunnelRoute.ipv4SubnetMask(prefixLength: ipv4PrefixLength) ?? "255.255.255.255"
    }

    /// The resolver addresses, IPv4 first.
    public var dnsServers: [String] {
        [dnsIPv4Address] + (dnsIPv6Address.map { [$0] } ?? [])
    }

    /// Destinations that never go through the proxy: local networks, link-local and multicast.
    /// They bypass the tunnel at the system level and go to the direct outbound inside the engine;
    /// the two lists must be the same, otherwise a direct connection would re-enter the tunnel.
    /// Unique-local IPv6 (fc00::/7) is not in the list because the tunnel's own IPv6 prefix is
    /// unique-local.
    public static let localIPv4Routes: [TunnelRoute] = [
        TunnelRoute(address: "10.0.0.0", prefixLength: 8),
        TunnelRoute(address: "172.16.0.0", prefixLength: 12),
        TunnelRoute(address: "192.168.0.0", prefixLength: 16),
        TunnelRoute(address: "169.254.0.0", prefixLength: 16),
        TunnelRoute(address: "224.0.0.0", prefixLength: 4),
        TunnelRoute(address: "255.255.255.255", prefixLength: 32),
    ]

    public static let localIPv6Routes: [TunnelRoute] = [
        TunnelRoute(address: "fe80::", prefixLength: 10),
        TunnelRoute(address: "ff00::", prefixLength: 8),
    ]

    public static var localRoutes: [TunnelRoute] { localIPv4Routes + localIPv6Routes }
}
