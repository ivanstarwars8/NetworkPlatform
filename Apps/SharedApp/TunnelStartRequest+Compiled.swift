// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
// (compiled and unit-tested on Linux through the symbolic link in Packages/ProfileLibrary/Tests; not yet
// compiled into the app)
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
            )
        )
    }
}
