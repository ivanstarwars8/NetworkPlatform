import Foundation

/// A DNS server used only for some domains (both compilers): Xray writes it as a server object with
/// `domains`, Mihomo as an entry of `nameserver-policy`.
public struct DNSDomainServer: Codable, Hashable, Sendable {
    /// Domain suffixes: each matches the name itself and every subdomain. Lower-case ASCII (punycode),
    /// without a leading or trailing dot.
    public var domains: [String]
    /// Server in Xray notation (`1.1.1.1`, `tcp://…`, `https://…`), the same as `dnsServers`.
    public var server: String

    public init(domains: [String], server: String) {
        self.domains = domains
        self.server = server
    }

    /// `true` when every domain is a plain host name suffix that both engines can carry unescaped.
    var hasValidDomains: Bool {
        !domains.isEmpty && domains.allSatisfy { domain in
            !domain.isEmpty && domain.utf8.count <= 253 && !domain.hasPrefix(".") && !domain.hasSuffix(".")
                && domain.utf8.allSatisfy { byte in
                    (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2E || byte == 0x5F
                }
        }
    }
}
