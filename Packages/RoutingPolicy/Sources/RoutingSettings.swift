import Foundation
import RoutingEngine

/// Where matching traffic goes. The tunnel is the profile's selected server or group.
public enum RuleTarget: String, Codable, Hashable, Sendable, CaseIterable {
    case tunnel
    case direct
    case block

    public var title: String {
        switch self {
        case .tunnel: return "Через VPN"
        case .direct: return "Напрямую"
        case .block: return "Блокировать"
        }
    }
}

/// The starting point of the routing: what happens to traffic no own rule or list decided.
public enum RoutingPreset: String, Codable, Hashable, Sendable, CaseIterable {
    /// Everything through the tunnel.
    case everything
    /// Russian domain zones and large Russian services directly, everything else through the tunnel.
    case russiaDirect
    /// Only the built-in list of blocked services (and own rules and lists) through the tunnel.
    case blockedOnly

    public var title: String {
        switch self {
        case .everything: return "Всё через VPN"
        case .russiaDirect: return "Российские сайты напрямую"
        case .blockedOnly: return "Только заблокированное"
        }
    }

    public var summary: String {
        switch self {
        case .everything:
            return "Весь трафик идёт через сервер профиля."
        case .russiaDirect:
            return "Сайты в зонах .ru, .рф, .su и крупные российские сервисы — напрямую, остальное — через VPN."
        case .blockedOnly:
            return "Через VPN — встроенный список заблокированных и недоступных из России сервисов и ваши правила, остальное — напрямую."
        }
    }

    /// What traffic that matched nothing does.
    public var finalTarget: RuleTarget {
        switch self {
        case .everything, .russiaDirect: return .tunnel
        case .blockedOnly: return .direct
        }
    }
}

/// What an own rule compares.
public enum RuleMatchKind: String, Codable, Hashable, Sendable, CaseIterable {
    case domain
    case domainSuffix
    case domainKeyword
    case ipCIDR
    case port
    case network

    public var title: String {
        switch self {
        case .domain: return "Домен целиком"
        case .domainSuffix: return "Домен и поддомены"
        case .domainKeyword: return "Слово в домене"
        case .ipCIDR: return "Адрес или сеть"
        case .port: return "Порт"
        case .network: return "Протокол"
        }
    }

    public var placeholder: String {
        switch self {
        case .domain: return "example.com"
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "example"
        case .ipCIDR: return "203.0.113.0/24"
        case .port: return "443 или 1000-2000"
        case .network: return "tcp или udp"
        }
    }

    /// `true` for values shown in the monospaced face (addresses, ports).
    public var isTechnical: Bool {
        switch self {
        case .ipCIDR, .port, .network: return true
        case .domain, .domainSuffix, .domainKeyword: return false
        }
    }
}

/// A rule the user wrote. `value` is stored normalised (see `CustomRule.make`).
public struct CustomRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: RuleMatchKind
    public var value: String
    public var target: RuleTarget
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: RuleMatchKind, value: String, target: RuleTarget, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.value = value
        self.target = target
        self.isEnabled = isEnabled
    }

    /// Validates and normalises typed input. The error text says what is wrong and what is expected.
    public static func make(id: UUID = UUID(), kind: RuleMatchKind, text: String, target: RuleTarget, isEnabled: Bool = true) -> Result<CustomRule, PolicyInputError> {
        switch normalise(kind: kind, text: text) {
        case .success(let value):
            return .success(CustomRule(id: id, kind: kind, value: value, target: target, isEnabled: isEnabled))
        case .failure(let error):
            return .failure(error)
        }
    }

    static func normalise(kind: RuleMatchKind, text: String) -> Result<String, PolicyInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(PolicyInputError("Введите значение.")) }
        switch kind {
        case .domain, .domainSuffix:
            var body = trimmed
            if kind == .domainSuffix {
                if body.hasPrefix("*.") { body.removeFirst(2) } else if body.hasPrefix(".") { body.removeFirst() }
            }
            guard let name = HostName.ascii(body) else {
                return .failure(PolicyInputError("Это не похоже на домен. Пример: example.com или пример.рф."))
            }
            return .success(name)
        case .domainKeyword:
            let keyword = trimmed.lowercased()
            guard keyword.utf8.count <= 64,
                  keyword.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F })
            else {
                return .failure(PolicyInputError("Слово — до 64 латинских букв, цифр, точек или дефисов."))
            }
            return .success(keyword)
        case .ipCIDR:
            guard let cidr = IPCIDR(trimmed) else {
                return .failure(PolicyInputError("Нужен адрес или сеть: 203.0.113.7, 203.0.113.0/24 или 2001:db8::/32."))
            }
            return .success(cidr.description)
        case .port:
            guard let range = RoutingEngine.PortRange(trimmed) else {
                return .failure(PolicyInputError("Нужен порт 0–65535 или диапазон, например 1000-2000."))
            }
            return .success(range.lower == range.upper ? "\(range.lower)" : "\(range.lower)-\(range.upper)")
        case .network:
            guard let network = NetworkKind(rawValue: trimmed.lowercased()) else {
                return .failure(PolicyInputError("Протокол — tcp или udp."))
            }
            return .success(network.rawValue)
        }
    }

    /// The condition in the routing model. `nil` only for a stored value that no longer parses.
    public var condition: RuleCondition? {
        switch kind {
        case .domain: return .domain(value)
        case .domainSuffix: return .domainSuffix(value)
        case .domainKeyword: return .domainKeyword(value)
        case .ipCIDR: return IPCIDR(value).map { .ipCIDR($0) }
        case .port: return RoutingEngine.PortRange(value).map { .port($0) }
        case .network: return NetworkKind(rawValue: value).map { .network($0) }
        }
    }
}

/// A list of domains and addresses downloaded from an address. Its compiled entries live in the store's
/// cache, not here.
public struct RemoteRuleSet: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: String
    public var target: RuleTarget
    public var isEnabled: Bool
    /// When the cached entries were downloaded; `nil` before the first successful download.
    public var updatedAt: Date?
    public var domainCount: Int
    public var addressCount: Int
    /// What went wrong on the last download, or `nil`. The cached entries (if any) stay in use.
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, url: String, target: RuleTarget, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.target = target
        self.isEnabled = isEnabled
        self.updatedAt = nil
        self.domainCount = 0
        self.addressCount = 0
        self.lastError = nil
    }

    /// Validates a typed address: `https` (or `http`) with a host.
    public static func validateURL(_ text: String) -> Result<URL, PolicyInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return .failure(PolicyInputError("Нужен адрес вида https://example.com/list.txt."))
        }
        return .success(url)
    }
}

/// A DNS server used for one domain and its subdomains.
public struct DomainDNSRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// ASCII form, without leading or trailing dots.
    public var domain: String
    /// Server in the notation of `DNSServer`.
    public var server: String

    public init(id: UUID = UUID(), domain: String, server: String) {
        self.id = id
        self.domain = domain
        self.server = server
    }
}

/// Resolver settings of the tunnel.
public struct DNSSettings: Codable, Hashable, Sendable {
    /// Servers in order; empty means the compiler's defaults (`DNSSettings.defaultServers`).
    public var servers: [String]
    public var domainServers: [DomainDNSRule]
    /// `false`: ask for IPv4 addresses only.
    public var ipv6: Bool
    /// `true` (default): every resolver query goes through the tunnel, whatever the rules say.
    public var leakProtection: Bool

    public init(servers: [String] = [], domainServers: [DomainDNSRule] = [], ipv6: Bool = true, leakProtection: Bool = true) {
        self.servers = servers
        self.domainServers = domainServers
        self.ipv6 = ipv6
        self.leakProtection = leakProtection
    }
}

/// Everything the user decides about routing and DNS. Stored by `RoutingSettingsStore`.
public struct RoutingSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var preset: RoutingPreset
    /// In priority order: the first matching rule wins.
    public var customRules: [CustomRule]
    /// In priority order, after the own rules.
    public var remoteRuleSets: [RemoteRuleSet]
    public var dns: DNSSettings

    public init(
        preset: RoutingPreset = .everything,
        customRules: [CustomRule] = [],
        remoteRuleSets: [RemoteRuleSet] = [],
        dns: DNSSettings = DNSSettings()
    ) {
        self.schemaVersion = RoutingSettings.currentSchemaVersion
        self.preset = preset
        self.customRules = customRules
        self.remoteRuleSets = remoteRuleSets
        self.dns = dns
    }
}

/// A rejected input, with a message for the user (Russian, says what is expected).
public struct PolicyInputError: Error, Hashable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}
