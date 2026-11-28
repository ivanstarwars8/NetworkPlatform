// The on-demand rules for a set of settings, as an ordered list the app turns into NEOnDemandRule objects one to
// one. The system evaluates the rules top to bottom and applies the first that matches the current network.
//
//   1. trusted Wi-Fi names (if any)   Disconnect or Ignore, ssidMatch = names, interface Wi-Fi
//   2. each network kind of the platform: Connect when chosen, Ignore otherwise
//   3. anything else                  Ignore (a manually started or stopped tunnel is left alone)
//
// Ignore never changes the tunnel: a tunnel started by hand stays up, a stopped one stays down.

import Foundation

public enum PlannedAction: String, Equatable, Sendable {
    case connect
    case disconnect
    case ignore
}

public struct PlannedRule: Equatable, Sendable {
    public let action: PlannedAction
    /// nil = any interface (NEOnDemandRuleInterfaceType.any).
    public let interface: NetworkKind?
    /// SSIDs to match; empty = any Wi-Fi network. Only used with `.wifi`.
    public let ssids: [String]

    public init(_ action: PlannedAction, interface: NetworkKind?, ssids: [String] = []) {
        self.action = action
        self.interface = interface
        self.ssids = ssids
    }
}

public enum OnDemandPlanner {
    public static func rules(for settings: AutomationSettings, on platform: AutomationPlatform) -> [PlannedRule] {
        var rules: [PlannedRule] = []
        let kinds = platform.networkKinds
        if kinds.contains(.wifi), !settings.trustedNetworks.isEmpty {
            rules.append(PlannedRule(settings.disconnectOnTrusted ? .disconnect : .ignore, interface: .wifi, ssids: settings.trustedNetworks))
        }
        for kind in kinds {
            rules.append(PlannedRule(settings.connects(on: kind) ? .connect : .ignore, interface: kind))
        }
        rules.append(PlannedRule(.ignore, interface: nil))
        return rules
    }
}
