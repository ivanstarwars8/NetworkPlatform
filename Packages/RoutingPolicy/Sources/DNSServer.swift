import ConfigurationEngine
import Foundation
import RoutingEngine

/// A resolver address as the user types it, checked and classified. The stored notation is the one both
/// compilers take (`XrayCompileOptions.dnsServers`): a bare address for UDP, `tcp://`, `https://`, `tls://`.
public struct DNSServer: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case udp
        case tcp
        case https
        case tls

        public var title: String {
            switch self {
            case .udp: return "UDP"
            case .tcp: return "TCP"
            case .https: return "DoH"
            case .tls: return "DoT"
            }
        }
    }

    public var kind: Kind
    /// Normalised notation.
    public var text: String

    /// DNS over TLS has no Xray form (`app/dns/nameserver.go` knows udp, tcp, https, h2c, quic+local):
    /// a `tls://` server compiles for Mihomo only.
    public var engineNote: String? {
        kind == .tls ? "DoT работает только с движком Mihomo; с Xray подключение не запустится." : nil
    }

    public static func parse(_ raw: String) -> Result<DNSServer, PolicyInputError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(PolicyInputError("Введите адрес сервера.")) }
        if let address = IPAddress(text) {
            return .success(DNSServer(kind: .udp, text: address.description))
        }
        guard let schemeEnd = text.range(of: "://") else {
            return .failure(PolicyInputError("Нужен адрес 1.1.1.1, tcp://1.1.1.1, tls://1.1.1.1 или https://dns.example/dns-query."))
        }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        let rest = String(text[schemeEnd.upperBound...])
        if scheme.hasSuffix("+local") || text.lowercased() == "localhost" {
            return .failure(PolicyInputError("Такой сервер опрашивается мимо туннеля — это утечка DNS. Выберите другой."))
        }
        let kind: Kind
        switch scheme {
        case "udp": kind = .udp
        case "tcp": kind = .tcp
        case "https": kind = .https
        case "tls": kind = .tls
        default:
            return .failure(PolicyInputError("Поддерживаются UDP, tcp://, tls:// и https://."))
        }
        guard !rest.contains("#"), !rest.contains(" ") else {
            return .failure(PolicyInputError("В адресе сервера не должно быть пробелов и символа #."))
        }
        var host = String(rest.prefix { $0 != "/" && $0 != "?" })
        var port: String?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return .failure(PolicyInputError("Не закрыта скобка в адресе IPv6.")) }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { port = String(after.dropFirst()) }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            port = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
        }
        if let port = port {
            guard let number = UInt16(port), number > 0 else { return .failure(PolicyInputError("Порт сервера — число 1–65535.")) }
        }
        guard IPAddress(host) != nil || HostName.ascii(host) == host.lowercased() else {
            return .failure(PolicyInputError("Не удалось разобрать имя или адрес сервера."))
        }
        if kind == .https && !rest.contains("/") {
            return .failure(PolicyInputError("Для DoH нужен путь, например https://dns.example/dns-query."))
        }
        if kind != .https && kind != .udp && IPAddress(host) == nil {
            // Xray resolves a tcp:// host name through the same resolver it serves; keep to addresses.
            return .failure(PolicyInputError("Для TCP и DoT укажите IP-адрес сервера, а не имя."))
        }
        if kind == .udp && IPAddress(host) == nil {
            return .failure(PolicyInputError("Для UDP укажите IP-адрес сервера."))
        }
        return .success(DNSServer(kind: kind, text: scheme + "://" + rest))
    }

    /// Resolvers the compilers use when the list is empty (`XrayConfigCompiler.defaultTunnelDNSServers`).
    public static var defaultServers: [String] { XrayConfigCompiler.defaultTunnelDNSServers }
}
