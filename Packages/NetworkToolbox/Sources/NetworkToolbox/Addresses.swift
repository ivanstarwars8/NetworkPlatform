// What the device knows about its own addresses without asking anyone (interface addresses), and the parser
// for the one public echo service the toolbox can use when the user turns it on (Cloudflare's trace page).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum AddressScope: String, Hashable, Sendable {
    case loopback
    case linkLocal
    case privateNetwork
    /// RFC 2544 benchmarking range and the ULA prefix the tunnel itself uses.
    case tunnel
    case carrierNAT
    case global

    public var title: String {
        switch self {
        case .loopback: return "петля"
        case .linkLocal: return "локальный канала"
        case .privateNetwork: return "частная сеть"
        case .tunnel: return "служебный диапазон"
        case .carrierNAT: return "NAT оператора"
        case .global: return "глобальный"
        }
    }
}

public struct InterfaceAddress: Hashable, Sendable {
    public let interface: String
    public let address: String
    public let isIPv6: Bool
    public let scope: AddressScope
}

public enum AddressClassifier {
    public static func scope(of address: String) -> AddressScope {
        guard let endpoint = SocketEndpoint(address: address, port: 0) else { return .global }
        let text = endpoint.address.lowercased()
        if !endpoint.isIPv6 {
            let octets = text.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return .global }
            switch (octets[0], octets[1]) {
            case (127, _): return .loopback
            case (169, 254): return .linkLocal
            case (10, _), (192, 168): return .privateNetwork
            case (172, 16...31): return .privateNetwork
            case (198, 18...19): return .tunnel
            case (100, 64...127): return .carrierNAT
            default: return .global
            }
        }
        if text == "::1" { return .loopback }
        if text.hasPrefix("fe8") || text.hasPrefix("fe9") || text.hasPrefix("fea") || text.hasPrefix("feb") { return .linkLocal }
        if text.hasPrefix("fc") || text.hasPrefix("fd") { return .privateNetwork }
        if text.hasPrefix("2") || text.hasPrefix("3") { return .global }
        return .privateNetwork
    }

    /// Addresses of the device's interfaces (getifaddrs). Nothing is sent on the network.
    public static func interfaceAddresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [InterfaceAddress] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let raw = entry.pointee.ifa_addr else { continue }
            let family = Int32(raw.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard let text = SocketEndpoint.numericHost(raw, length: length) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let item = InterfaceAddress(interface: name, address: text, isIPv6: family == AF_INET6, scope: scope(of: text))
            if !result.contains(item) { result.append(item) }
        }
        return result
    }
}

/// The opt-in public address check. The service is named in the interface because it sees the request.
public enum PublicAddressService {
    public static let name = "Cloudflare"
    public static let ipv4URL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
    public static let ipv6URL = URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace")!
    public static let maximumBytes = 4096

    public struct Trace: Equatable, Sendable {
        public let address: String
        /// Two-letter country code the service derived from the address, when given.
        public let location: String?
    }

    /// Parses the `key=value` lines of the trace page.
    public static func parse(_ data: Data) -> Trace? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard let ip = values["ip"], let endpoint = SocketEndpoint(address: ip, port: 0) else { return nil }
        let location = values["loc"].flatMap { $0.count == 2 ? $0 : nil }
        return Trace(address: endpoint.address, location: location)
    }
}

public enum HostName {
    /// ASCII form of a host name for resolvers that do not do IDNA themselves: non-ASCII labels become
    /// "xn--" Punycode labels. IP literals and ASCII names are returned unchanged.
    public static func ascii(_ host: String) -> String? {
        if host.unicodeScalars.allSatisfy({ $0.isASCII }) { return host }
        var labels: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
                labels.append(String(label))
            } else {
                guard let encoded = Punycode.encode(String(label).lowercased()) else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        return labels.joined(separator: ".")
    }
}
