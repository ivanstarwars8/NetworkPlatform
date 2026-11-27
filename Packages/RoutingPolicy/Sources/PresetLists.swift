import Foundation
import RoutingEngine

/// The built-in lists behind the presets. Short on purpose: they are a starting point, compiled into every
/// configuration; longer lists are added by address (`RemoteRuleSet`). Domain values are suffixes (the name
/// and its subdomains), internationalised zones in punycode.
public enum PresetLists {
    /// One group of a preset: shown in the route simulator as the reason of a decision.
    public struct Group: Hashable, Sendable {
        public var id: String
        public var title: String
        public var target: RuleTarget
        public var suffixes: [String]
        public var cidrs: [String]

        public var conditions: [RuleCondition] {
            suffixes.map { .domainSuffix($0) } + cidrs.compactMap { IPCIDR($0).map { .ipCIDR($0) } }
        }
    }

    public static func groups(of preset: RoutingPreset) -> [Group] {
        switch preset {
        case .everything: return []
        case .russiaDirect: return [russianZones, russianServices]
        case .blockedOnly: return [blockedServices, telegram]
        }
    }

    /// Russian domain zones: .ru, .su, .рф, .рус, .москва, .дети.
    static let russianZones = Group(
        id: "ru-zones", title: "Российские доменные зоны", target: .direct,
        suffixes: ["ru", "su", "xn--p1ai", "xn--p1acf", "xn--80adxhks", "xn--d1acj3b"], cidrs: []
    )

    /// Large Russian services that also live outside the Russian zones.
    static let russianServices = Group(
        id: "ru-services", title: "Крупные российские сервисы", target: .direct,
        suffixes: [
            "yandex.net", "yandex.com", "yastatic.net", "yandexcloud.net",
            "vk.com", "vk.me", "vkuser.net", "userapi.com", "vk-cdn.net", "mycdn.me",
        ],
        cidrs: []
    )

    /// Services blocked in Russia or closed to Russian users.
    static let blockedServices = Group(
        id: "blocked", title: "Заблокированные и недоступные сервисы", target: .tunnel,
        suffixes: [
            // Meta
            "instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net", "fb.com", "fbsbx.com",
            "messenger.com", "threads.net",
            // X
            "x.com", "twitter.com", "twimg.com", "t.co",
            // YouTube
            "youtube.com", "youtu.be", "ytimg.com", "googlevideo.com", "ggpht.com", "youtube-nocookie.com",
            // Others
            "linkedin.com", "licdn.com",
            "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
            "signal.org", "viber.com", "rutracker.org", "torproject.org",
            // Closed to Russian users
            "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
            "claude.ai", "anthropic.com", "gemini.google.com",
        ],
        cidrs: []
    )

    /// Telegram: the apps connect to these addresses directly, without names (Telegram's published ranges).
    static let telegram = Group(
        id: "telegram", title: "Telegram", target: .tunnel,
        suffixes: ["telegram.org", "t.me", "telegram.me", "telesco.pe"],
        cidrs: [
            "91.108.4.0/22", "91.108.8.0/22", "91.108.12.0/22", "91.108.16.0/22", "91.108.56.0/22",
            "95.161.64.0/20", "149.154.160.0/20",
            "2001:67c:4e8::/48", "2001:b28:f23c::/48", "2001:b28:f23d::/48", "2001:b28:f23f::/48",
        ]
    )
}
