// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly, MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46087955935 (workflow apple.yml)
//
// The connect/disconnect action shared by the connection screen, the macOS menu bar item and the tvOS
// dashboard, so that all three behave the same. Starts go through the supervisor (rollback, engine fallback).

import DesignSystem
import Foundation

extension TunnelController {
    /// The phase the UI shows for the current `NEVPNStatus`.
    var phase: ConnectionPhase { ConnectionPhase(vpnStatusRawValue: status.rawValue) }

    /// Runs the action of the current phase: connect with the selected profile, or stop the tunnel.
    func performPrimaryAction(library: ProfileLibraryModel) async {
        switch phase.action {
        case .connect: await connect(using: library)
        case .disconnect: await disconnect()
        case .none: break
        }
    }

    /// Compiles the selected profile first: a profile that cannot be compiled never touches the VPN
    /// configuration. Installs the configuration on first use (the system asks for permission).
    func connect(using library: ProfileLibraryModel) async {
        guard let prepared = library.makeStartRequest() else { return }
        if !isInstalled {
            await install()
        }
        guard isInstalled else { return }
        await start(prepared, library: library)
    }
}

extension ProfileLibraryModel {
    /// Why the connect action cannot run, or nil when it can.
    var connectBlocker: String? {
        if profiles.isEmpty { return "Сначала добавьте профиль." }
        if selectedProfileID == nil { return "Выберите профиль." }
        return nil
    }
}
