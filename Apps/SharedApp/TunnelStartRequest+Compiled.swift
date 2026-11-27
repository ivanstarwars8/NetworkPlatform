// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46055850203 (workflow apple.yml)
// (also compiled and unit-tested on Linux and macOS through the symbolic link in Packages/ProfileLibrary/Tests)
//
// The step between the profile library and the hand-off (ADR-0008): a compiled profile becomes the
// `TunnelStartRequest` the extension consumes. The interface plan is built from the same `XrayTunnelPlan`
// the configuration was compiled with, so the system interface and the engine agree on addresses and MTU.

import ConfigurationEngine
import DomainModels
import Foundation
import ProfileLibrary

extension TunnelStartRequest {
    init(compiled: CompiledTunnelStart) {
        self.init(
            coreID: compiled.coreID,
            format: compiled.format,
            configuration: compiled.configuration,
            network: TunnelNetworkPlan(
                addressing: compiled.tunnel.addressing,
                excludedRoutes: compiled.tunnel.excludedRoutes,
                remoteAddress: compiled.tunnel.remoteAddress
            ),
            groupSelection: compiled.initialSelection.map { TunnelGroupSelection(group: $0.group, member: $0.member) }
        )
    }
}
