// What the user chose for automatic connection and for traffic outside the tunnel, as plain values. The app maps
// these onto NEVPNManager / NETunnelProviderManager (Apps/SharedApp/TunnelController.swift); every field below
// corresponds to one real system setting (Documentation/Architecture/automation.md):
//
//   connectOnDemand          NEVPNManager.isOnDemandEnabled (gated by OnDemandState)
//   connectOn*               NEOnDemandRuleConnect / NEOnDemandRuleIgnore per NEOnDemandRuleInterfaceType
//   trustedNetworks          NEOnDemandRule.ssidMatch of a Wi-Fi rule
//   disconnectOnTrusted      that rule is NEOnDemandRuleDisconnect instead of NEOnDemandRuleIgnore
//   includeAllNetworks       NEVPNProtocol.includeAllNetworks
//   excludeLocalNetworks     NEVPNProtocol.excludeLocalNetworks
//
// Foundation only; tested on Linux.

import Foundation

public struct AutomationSettings: Codable, Equatable, Sendable {
    /// Let the system start the tunnel by itself when a connect rule matches.
    public var connectOnDemand: Bool
    /// Connect on Wi-Fi networks that are not in `trustedNetworks`.
    public var connectOnWiFi: Bool
    /// Connect on cellular data (iPhone, iPad with cellular).
    public var connectOnCellular: Bool
    /// Connect on wired Ethernet (Mac).
    public var connectOnWired: Bool
    /// Wi-Fi network names (SSIDs) where the tunnel is not started automatically.
    public var trustedNetworks: [String]
    /// Stop the tunnel when the device joins a trusted network (otherwise the tunnel is left as it is).
    public var disconnectOnTrusted: Bool
    /// Send all traffic through the tunnel; while the tunnel is down, traffic is blocked.
    public var includeAllNetworks: Bool
    /// With `includeAllNetworks`: keep the local network (printers, AirPlay, NAS) reachable outside the tunnel.
    public var excludeLocalNetworks: Bool

    public init(
        connectOnDemand: Bool = false,
        connectOnWiFi: Bool = true,
        connectOnCellular: Bool = true,
        connectOnWired: Bool = true,
        trustedNetworks: [String] = [],
        disconnectOnTrusted: Bool = false,
        includeAllNetworks: Bool = false,
        excludeLocalNetworks: Bool = true
    ) {
        self.connectOnDemand = connectOnDemand
        self.connectOnWiFi = connectOnWiFi
        self.connectOnCellular = connectOnCellular
        self.connectOnWired = connectOnWired
        self.trustedNetworks = trustedNetworks
        self.disconnectOnTrusted = disconnectOnTrusted
        self.includeAllNetworks = includeAllNetworks
        self.excludeLocalNetworks = excludeLocalNetworks
    }

    /// Whether automatic connection is set to connect on any network kind this platform has.
    public func connectsOnAnyNetwork(on platform: AutomationPlatform) -> Bool {
        platform.networkKinds.contains { connects(on: $0) }
    }

    public func connects(on kind: NetworkKind) -> Bool {
        switch kind {
        case .wifi: return connectOnWiFi
        case .cellular: return connectOnCellular
        case .wired: return connectOnWired
        }
    }

    private enum CodingKeys: String, CodingKey {
        case connectOnDemand, connectOnWiFi, connectOnCellular, connectOnWired, trustedNetworks
        case disconnectOnTrusted, includeAllNetworks, excludeLocalNetworks
    }

    /// Missing keys take the defaults, so a record written by an older version still loads.
    public init(from decoder: Decoder) throws {
        let defaults = AutomationSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectOnDemand = try c.decodeIfPresent(Bool.self, forKey: .connectOnDemand) ?? defaults.connectOnDemand
        connectOnWiFi = try c.decodeIfPresent(Bool.self, forKey: .connectOnWiFi) ?? defaults.connectOnWiFi
        connectOnCellular = try c.decodeIfPresent(Bool.self, forKey: .connectOnCellular) ?? defaults.connectOnCellular
        connectOnWired = try c.decodeIfPresent(Bool.self, forKey: .connectOnWired) ?? defaults.connectOnWired
        let names = try c.decodeIfPresent([String].self, forKey: .trustedNetworks) ?? []
        trustedNetworks = TrustedNetworks.sanitized(names)
        disconnectOnTrusted = try c.decodeIfPresent(Bool.self, forKey: .disconnectOnTrusted) ?? defaults.disconnectOnTrusted
        includeAllNetworks = try c.decodeIfPresent(Bool.self, forKey: .includeAllNetworks) ?? defaults.includeAllNetworks
        excludeLocalNetworks = try c.decodeIfPresent(Bool.self, forKey: .excludeLocalNetworks) ?? defaults.excludeLocalNetworks
    }
}

/// Kinds of network an on-demand rule can match (NEOnDemandRuleInterfaceType).
public enum NetworkKind: String, CaseIterable, Codable, Sendable {
    case wifi
    case cellular
    case wired
}

/// What the app offers on each platform. Only what the platform's Network Extension supports is offered;
/// see Documentation/Architecture/automation.md for the API availability behind each flag.
public enum AutomationPlatform: String, CaseIterable, Sendable {
    case iOS
    case macOS
    case tvOS
    case visionOS

    /// Interface types an on-demand rule can match here. `.cellular` exists only on iOS/iPadOS;
    /// `.ethernet` only on macOS (and tvOS, where on-demand is not offered).
    public var networkKinds: [NetworkKind] {
        switch self {
        case .iOS: return [.wifi, .cellular]
        case .macOS: return [.wifi, .wired]
        case .tvOS: return [.wifi, .wired]
        case .visionOS: return [.wifi]
        }
    }

    /// Automatic connection settings are shown. Apple TV has one dashboard and no settings screens.
    public var offersOnDemand: Bool { self != .tvOS }

    /// includeAllNetworks / excludeLocalNetworks are shown.
    public var offersTrafficLock: Bool { self != .tvOS }

    /// Start at login (SMAppService.mainApp) — a Mac concept.
    public var offersLaunchAtLogin: Bool { self == .macOS }

    /// Shortcuts actions (App Intents). Apple TV has no Shortcuts app.
    public var offersShortcuts: Bool { self != .tvOS }

    public static var current: AutomationPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(visionOS)
        return .visionOS
        #else
        return .iOS
        #endif
    }
}
