// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Types shared by the app and the Packet Tunnel extension (ADR-0003 §3).
// This file is compiled into both targets by Apps/project.yml. It is meant to
// become the `TunnelIPC` package module (ADR-0004 §2.3) once it can be built
// and tested; until then it lives next to its only consumer.
//
// It imports nothing but Foundation on purpose: the app must not depend on
// engine code (ADR-0001 §3, rule 2).

import Foundation

enum TunnelIPC {
    /// Version of the message envelope. Both sides refuse other versions:
    /// an extension of a previous app version may still be running.
    static let protocolVersion: UInt16 = 1

    /// Key of the single entry in `startVPNTunnel(options:)`.
    static let startRequestOptionKey = "np.start-request"

    /// Upper bound on one app message accepted by the extension. A limit of
    /// this project, not of `sendProviderMessage` (whose limits are not
    /// documented, ADR-0003 §7).
    static let maximumMessageBytes = 64 * 1024
}

// MARK: - Start request

/// What the system tunnel interface should look like. Chosen by the control
/// plane together with the engine configuration; the extension applies it
/// without interpreting the engine document (ADR-0001 §4).
struct TunnelNetworkPlan: Codable, Equatable {
    /// `tunnelRemoteAddress` of `NEPacketTunnelNetworkSettings`.
    var remoteAddress: String
    var ipv4Address: String
    var ipv4SubnetMask: String
    var ipv6Address: String?
    var ipv6PrefixLength: Int?
    var dnsServers: [String]
    /// A property of the engine adapter, not a constant (ADR-0001 §4).
    var mtu: Int
    var routesAllIPv4: Bool
    var routesAllIPv6: Bool
}

/// Everything the extension needs to start: a compiled engine document, the
/// engine it was compiled for, and the interface plan (ADR-0003 §3.3).
/// The configuration contains secrets in clear text; it must never be logged.
struct TunnelStartRequest: Codable, Equatable {
    var coreID: String
    var format: String
    var configuration: Data
    var network: TunnelNetworkPlan

    /// Encodes the request for `startVPNTunnel(options:)`.
    func startOptions() throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(self)
        return [TunnelIPC.startRequestOptionKey: data as NSData]
    }

    /// Decodes the request from start options. Returns `nil` when the options
    /// carry no request (On-Demand start, the switch in Settings).
    static func from(startOptions: [String: NSObject]?) throws -> TunnelStartRequest? {
        guard let value = startOptions?[TunnelIPC.startRequestOptionKey] else {
            return nil
        }
        guard let data = value as? NSData else {
            throw TunnelIPCError(code: "malformed_start_request", message: "start request is not a data value")
        }
        return try JSONDecoder().decode(TunnelStartRequest.self, from: data as Data)
    }
}

// MARK: - Message envelope

struct TunnelRequest: Codable {
    enum Body: String, Codable {
        /// State of the engine inside the tunnel process.
        case status
        /// Traffic counters of the running engine.
        case statistics
    }

    var version: UInt16
    var id: UInt64
    var body: Body
}

struct TunnelResponse: Codable {
    enum Outcome: Codable {
        case status(TunnelStatusReport)
        case statistics(TunnelTrafficReport)
        case failure(TunnelIPCError)
    }

    var version: UInt16
    /// The `id` of the request, or 0 when the request could not be decoded.
    var id: UInt64
    var outcome: Outcome
}

/// The engine half of the two independent states (ADR-0003 §2). The tunnel
/// half is `NEVPNStatus` and never travels over this channel.
struct TunnelStatusReport: Codable, Equatable {
    /// Identifier of the engine in use, `nil` when none was started.
    var coreID: String?
    /// Raw value of the engine lifecycle state, or "absent".
    var coreState: String
    var lastError: String?
    /// `phys_footprint` of the extension process, measured by the Swift host.
    var physicalFootprintBytes: UInt64?
    var memoryPressureWarnings: Int
    var memoryPressureCriticals: Int
}

struct TunnelTrafficReport: Codable, Equatable {
    var uplinkBytes: UInt64
    var downlinkBytes: UInt64
}

struct TunnelIPCError: Error, Codable, Equatable {
    /// Stable machine-readable code.
    var code: String
    var message: String
}
