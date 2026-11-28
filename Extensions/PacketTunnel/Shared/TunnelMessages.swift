// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46022252282 (workflow apple.yml)
//
// Status of that mark for the files in Shared/: they import only Foundation
// (TunnelMessages.swift also DomainModels) and ARE compiled and unit-tested on Linux, through a symbolic link in
// Packages/CoreAbstraction/Tests (Swift 5.10.1, 2026-11-25). They have not
// been compiled for an Apple platform or run inside an app or an extension.
//
// Types shared by the app and the Packet Tunnel extension (ADR-0003 §3).
// This directory is compiled into both targets by Apps/project.yml. It is
// meant to become the `TunnelIPC` package module (ADR-0004 §2.3).
//
// It imports nothing but Foundation and DomainModels (the engine-neutral
// model, which has no engine code) on purpose: the app must not depend on
// engine code (ADR-0001 §3, rule 2).

import DomainModels
import Foundation

enum TunnelIPC {
    /// Version of the message envelope and of the start reference. Both
    /// sides refuse other versions: an extension of a previous app version
    /// may still be running. Version 1 carried the whole start request in
    /// the start options.
    static let protocolVersion: UInt16 = 2

    /// Key of the single entry in `startVPNTunnel(options:)`.
    static let startReferenceOptionKey = "np.start-reference"

    /// Upper bound on the start-options entry. The entry is a reference to a
    /// hand-off file, never the configuration. A limit of this project: the
    /// size the system accepts for start options is not documented.
    static let maximumStartReferenceBytes = 1024

    /// Upper bound on one app message and on one reply. A limit of this
    /// project, not of `sendProviderMessage` (whose limits are not
    /// documented, ADR-0003 §7).
    static let maximumMessageBytes = 64 * 1024

    /// How long the app waits for a reply. A project value, not measured.
    static let defaultRequestTimeout: TimeInterval = 5
}

// MARK: - Errors

/// The only error type that crosses the app/extension boundary, and the only
/// one the IPC helpers in this directory throw.
struct TunnelIPCError: Error, Codable, Equatable, Sendable {
    /// Stable machine-readable code. An open set: a peer of another version
    /// may send codes this build does not know, and engine errors travel with
    /// the codes of `CoreError`.
    struct Code: RawRepresentable, Hashable, Codable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        // Transport, raised on the app side.
        /// The extension did not answer within the deadline.
        static let timedOut = Code(rawValue: "timed_out")
        /// The waiting task was cancelled.
        static let cancelled = Code(rawValue: "cancelled")
        /// The system refused to send the message.
        static let sendFailed = Code(rawValue: "send_failed")
        /// The extension answered without data.
        static let noReply = Code(rawValue: "no_reply")
        static let malformedReply = Code(rawValue: "malformed_reply")
        /// The reply carries another request id.
        static let mismatchedReply = Code(rawValue: "mismatched_reply")
        /// The reply is of another kind than the request.
        static let unexpectedReply = Code(rawValue: "unexpected_reply")
        /// The tunnel is not connected, so nobody would answer.
        static let notConnected = Code(rawValue: "not_connected")

        // Envelope, raised on either side.
        static let messageTooLarge = Code(rawValue: "message_too_large")
        static let malformedRequest = Code(rawValue: "malformed_request")
        static let unsupportedVersion = Code(rawValue: "unsupported_version")

        // Start and hand-off.
        static let noConfiguration = Code(rawValue: "no_configuration")
        static let malformedStartReference = Code(rawValue: "malformed_start_reference")
        static let invalidNetworkPlan = Code(rawValue: "invalid_network_plan")
        static let handoffUnavailable = Code(rawValue: "handoff_unavailable")
        static let handoffMissing = Code(rawValue: "handoff_missing")
        static let handoffTooLarge = Code(rawValue: "handoff_too_large")
        static let handoffCorrupt = Code(rawValue: "handoff_corrupt")
        static let handoffWriteFailed = Code(rawValue: "handoff_write_failed")

        // Extension state.
        static let notRunning = Code(rawValue: "not_running")
        static let alreadyRunning = Code(rawValue: "already_running")
        /// A previous engine call never returned; the process must be
        /// replaced before anything can start.
        static let engineWedged = Code(rawValue: "engine_wedged")
    }

    var code: Code
    /// Bounded, human-readable, never contains configuration data.
    var message: String

    /// Longest message kept. A limit of this project.
    static let maximumMessageLength = 512

    init(_ code: Code, _ message: String) {
        self.code = code
        if message.count > TunnelIPCError.maximumMessageLength {
            self.message = String(message.prefix(TunnelIPCError.maximumMessageLength)) + "..."
        } else {
            self.message = message
        }
    }

    var summary: String {
        "\(code.rawValue): \(message)"
    }
}

// MARK: - Start request

/// What the system tunnel interface should look like. Chosen by the control
/// plane together with the engine configuration; the extension applies it
/// without interpreting the engine document (ADR-0001 §4).
struct TunnelNetworkPlan: Codable, Equatable, Sendable {
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
    /// Destinations that bypass the tunnel (`excludedRoutes`): the proxy servers' addresses and local
    /// networks. Absent in plans written before the field existed.
    var excludedRoutes: [TunnelRoute]

    init(
        remoteAddress: String,
        ipv4Address: String,
        ipv4SubnetMask: String,
        ipv6Address: String?,
        ipv6PrefixLength: Int?,
        dnsServers: [String],
        mtu: Int,
        routesAllIPv4: Bool,
        routesAllIPv6: Bool,
        excludedRoutes: [TunnelRoute] = []
    ) {
        self.remoteAddress = remoteAddress
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.routesAllIPv4 = routesAllIPv4
        self.routesAllIPv6 = routesAllIPv6
        self.excludedRoutes = excludedRoutes
    }

    /// The full-tunnel plan for the addresses a configuration was compiled for
    /// (`XrayTunnelPlan` of ConfigurationEngine carries all three arguments). The interface
    /// addresses, resolvers and MTU come from `TunnelAddressing` only, so the system interface and
    /// the engine's DNS hijack and packet stack cannot disagree.
    init(addressing: TunnelAddressing, excludedRoutes: [TunnelRoute], remoteAddress: String) {
        self.init(
            remoteAddress: remoteAddress,
            ipv4Address: addressing.ipv4Address,
            ipv4SubnetMask: addressing.ipv4SubnetMask,
            ipv6Address: addressing.ipv6Address,
            ipv6PrefixLength: addressing.ipv6Address == nil ? nil : addressing.ipv6PrefixLength,
            dnsServers: addressing.dnsServers,
            mtu: addressing.mtu,
            routesAllIPv4: true,
            routesAllIPv6: addressing.ipv6Address != nil && addressing.ipv6PrefixLength != nil,
            excludedRoutes: excludedRoutes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case remoteAddress, ipv4Address, ipv4SubnetMask, ipv6Address, ipv6PrefixLength, dnsServers, mtu
        case routesAllIPv4, routesAllIPv6, excludedRoutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteAddress = try container.decode(String.self, forKey: .remoteAddress)
        ipv4Address = try container.decode(String.self, forKey: .ipv4Address)
        ipv4SubnetMask = try container.decode(String.self, forKey: .ipv4SubnetMask)
        ipv6Address = try container.decodeIfPresent(String.self, forKey: .ipv6Address)
        ipv6PrefixLength = try container.decodeIfPresent(Int.self, forKey: .ipv6PrefixLength)
        dnsServers = try container.decode([String].self, forKey: .dnsServers)
        mtu = try container.decode(Int.self, forKey: .mtu)
        routesAllIPv4 = try container.decode(Bool.self, forKey: .routesAllIPv4)
        routesAllIPv6 = try container.decode(Bool.self, forKey: .routesAllIPv6)
        excludedRoutes = try container.decodeIfPresent([TunnelRoute].self, forKey: .excludedRoutes) ?? []
    }

    /// Bounds of this project, wide enough for both engines (ADR-0001 §4:
    /// 1500 and 4064) and narrow enough to stop nonsense before it reaches
    /// the system.
    static let mtuRange = 576...65_535
    static let minimumIPv6MTU = 1_280
    static let maximumDNSServers = 16
    static let maximumAddressLength = 64
    static let maximumExcludedRoutes = 256

    /// Rejects plans that are structurally impossible. This is not address
    /// parsing: the system does that when the settings are applied.
    func validate() throws {
        func invalid(_ text: String) -> TunnelIPCError {
            TunnelIPCError(.invalidNetworkPlan, text)
        }
        func checkAddress(_ value: String, _ name: String) throws {
            guard !value.isEmpty, value.utf8.count <= TunnelNetworkPlan.maximumAddressLength else {
                throw invalid("\(name) is empty or too long")
            }
            guard !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else {
                throw invalid("\(name) contains white space or control characters")
            }
        }
        try checkAddress(remoteAddress, "remote address")
        try checkAddress(ipv4Address, "IPv4 address")
        try checkAddress(ipv4SubnetMask, "IPv4 subnet mask")
        guard TunnelNetworkPlan.mtuRange.contains(mtu) else {
            throw invalid("MTU \(mtu) is outside \(TunnelNetworkPlan.mtuRange)")
        }
        switch (ipv6Address, ipv6PrefixLength) {
        case (nil, nil):
            guard !routesAllIPv6 else {
                throw invalid("IPv6 routing requested without an IPv6 address")
            }
        case let (address?, prefix?):
            try checkAddress(address, "IPv6 address")
            guard (0...128).contains(prefix) else {
                throw invalid("IPv6 prefix length \(prefix) is outside 0...128")
            }
            guard mtu >= TunnelNetworkPlan.minimumIPv6MTU else {
                throw invalid("MTU \(mtu) is below the IPv6 minimum of \(TunnelNetworkPlan.minimumIPv6MTU)")
            }
        default:
            throw invalid("IPv6 address and prefix length must be given together")
        }
        guard dnsServers.count <= TunnelNetworkPlan.maximumDNSServers else {
            throw invalid("more than \(TunnelNetworkPlan.maximumDNSServers) DNS servers")
        }
        for server in dnsServers {
            try checkAddress(server, "DNS server")
        }
        guard excludedRoutes.count <= TunnelNetworkPlan.maximumExcludedRoutes else {
            throw invalid("more than \(TunnelNetworkPlan.maximumExcludedRoutes) excluded routes")
        }
        for route in excludedRoutes {
            try checkAddress(route.address, "excluded route")
            guard (0...(route.isIPv6 ? 128 : 32)).contains(route.prefixLength) else {
                throw invalid("excluded route prefix length \(route.prefixLength) is out of range")
            }
        }
    }
}

/// Everything the extension needs to start: a compiled engine document, the
/// engine it was compiled for, and the interface plan (ADR-0003 §3.3).
/// The configuration contains secrets in clear text; it must never be logged.
///
/// It does not travel in the start options: see `ConfigurationHandoff`.
struct TunnelStartRequest: Equatable, Sendable {
    var coreID: String
    var format: String
    var configuration: Data
    var network: TunnelNetworkPlan
    /// The member a group starts with when it is not the group's own choice: the extension pins it right
    /// after the engine starts, before the start is reported as done. `nil`: the group chooses.
    var groupSelection: TunnelGroupSelection?

    init(coreID: String, format: String, configuration: Data, network: TunnelNetworkPlan, groupSelection: TunnelGroupSelection? = nil) {
        self.coreID = coreID
        self.format = format
        self.configuration = configuration
        self.network = network
        self.groupSelection = groupSelection
    }
}

// MARK: - Message envelope

struct TunnelRequest: Codable, Equatable, Sendable {
    enum Body: String, Codable, Sendable {
        /// State of the engine inside the tunnel process.
        case status
        /// Traffic counters of the running engine.
        case statistics
        /// The engine's outbound groups with its own health measurements of their members.
        case groups
        /// Pin a member of a group (or give the choice back to it) without restarting the tunnel;
        /// `selection` says which.
        case selectMember
        /// The newest connections the engine tracks (engines with `CoreFeature.connectionList`).
        case connections
        /// Engine diagnostics: versions, Go runtime memory, goroutines, uptime, recent errors
        /// (`TunnelEngineDiagnostics`). An extension of an older build answers `malformed_request`.
        case diagnostics
    }

    var version: UInt16
    var id: UInt64
    var body: Body
    /// The argument of `selectMember`; absent otherwise.
    var selection: TunnelGroupSelection?

    init(version: UInt16, id: UInt64, body: Body, selection: TunnelGroupSelection? = nil) {
        self.version = version
        self.id = id
        self.body = body
        self.selection = selection
    }
}

/// Which member of which engine group new connections go to. Tags are those of the engine configuration
/// (the compiler's report maps profile tags to them); `member == nil` gives the choice back to the group.
struct TunnelGroupSelection: Codable, Equatable, Sendable {
    /// Longest tag accepted. A limit of this project (the bridges refuse more than 256 bytes).
    static let maximumTagBytes = 128

    var group: String
    var member: String?

    func validate() throws {
        for tag in [group, member ?? ""] where tag.utf8.count > TunnelGroupSelection.maximumTagBytes {
            throw TunnelIPCError(.malformedRequest, "tag exceeds \(TunnelGroupSelection.maximumTagBytes) bytes")
        }
        guard !group.isEmpty else {
            throw TunnelIPCError(.malformedRequest, "selection names no group")
        }
    }
}

struct TunnelResponse: Codable, Equatable, Sendable {
    enum Outcome: Codable, Equatable, Sendable {
        case status(TunnelStatusReport)
        case statistics(TunnelTrafficReport)
        case groups(TunnelGroupReport)
        /// The request was carried out and has nothing to report.
        case done
        case connections(TunnelConnectionReport)
        case diagnostics(TunnelEngineDiagnostics)
        case failure(TunnelIPCError)
    }

    var version: UInt16
    /// The `id` of the request, or 0 when the request could not be decoded.
    var id: UInt64
    var outcome: Outcome
}

/// The engine half of the two independent states (ADR-0003 §2). The tunnel
/// half is `NEVPNStatus` and never travels over this channel.
struct TunnelStatusReport: Codable, Equatable, Sendable {
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

struct TunnelTrafficReport: Codable, Equatable, Sendable {
    struct Outbound: Codable, Equatable, Sendable {
        /// Engine tag of the outbound (as compiled), not a user-facing name.
        var tag: String
        var uplinkBytes: UInt64
        var downlinkBytes: UInt64
    }

    var uplinkBytes: UInt64
    var downlinkBytes: UInt64
    /// Per-outbound counters, when the engine counts per outbound; at most `maximumOutbounds`, sorted by tag.
    /// Absent in replies of extensions built before the field existed.
    var outbounds: [Outbound]? = nil
    /// Connections the engine tracks right now, when it can say.
    var activeConnections: Int? = nil
    /// Seconds since the engine started.
    var uptimeSeconds: Double? = nil

    /// A limit of this project, keeping the reply far below `TunnelIPC.maximumMessageBytes`.
    static let maximumOutbounds = 64
}

/// The newest connections the engine tracks, newest first. Destinations are the user's data: shown in the
/// app, never logged by either side.
struct TunnelConnectionReport: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: String
        var network: String
        var destination: String
        var rule: String?
        var chain: [String]
        var uploadBytes: UInt64
        var downloadBytes: UInt64
        var startedAt: Date?
    }

    /// Every connection the engine tracks; `items` may hold fewer.
    var total: Int
    var items: [Item]

    /// Limits of this project: the largest possible reply (every field at its bound) stays below
    /// `TunnelIPC.maximumMessageBytes` (64 KiB); checked by a test.
    static let maximumItems = 50
    static let maximumTextBytes = 200
    static let maximumTagBytes = 64
    static let maximumChainLength = 4

    /// Shortens an over-long string to `limit` UTF-8 bytes (on a character boundary, "..." appended).
    static func bounded(_ text: String, limit: Int = maximumTextBytes) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        for character in text {
            if result.utf8.count + String(character).utf8.count > limit - 3 { break }
            result.append(character)
        }
        return result + "..."
    }
}

/// The engine's groups as the engine measures them. Numbers are the engine's own (Xray observatory, Mihomo
/// health checks); the extension does not probe anything to answer.
struct TunnelGroupReport: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        var tag: String
        var alive: Bool
        var delayMilliseconds: Int?
        var lastTry: Date?
        var lastSeen: Date?
    }

    struct Group: Codable, Equatable, Sendable {
        var tag: String
        var kind: String
        /// The member new connections go to, when the engine can say.
        var current: String?
        /// The member pinned by the app, `nil` when the group chooses.
        var pinned: String?
        var members: [Member]
    }

    var groups: [Group]
}

/// What the engine diagnostics screen shows. Numbers come from the bridge (`npb_version`, `npb_health`,
/// `npb_memory`) and from the Swift host (`phys_footprint`); a value the extension could not read is `nil`,
/// never estimated. Texts are bounded and carry no configuration (the bridge redacts its errors; the app
/// passes them through `ConfigValueRedactor` again before showing them).
struct TunnelEngineDiagnostics: Codable, Equatable, Sendable {
    struct ErrorRecord: Codable, Equatable, Sendable {
        var timeUnixMilliseconds: Int64
        var kind: String
        var message: String
    }

    var coreID: String?
    /// Version of the core the bridge links (Xray-core, Mihomo).
    var coreVersion: String?
    var goVersion: String?
    var bridgeABI: Int32?
    /// Engine lifecycle state of the Swift adapter, or "absent".
    var coreState: String
    /// Seconds since the engine started, from the bridge.
    var uptimeSeconds: Double?
    var goHeapLiveBytes: UInt64?
    var goHeapObjectsBytes: UInt64?
    var goMappedBytes: UInt64?
    var goStacksBytes: UInt64?
    var goroutines: UInt64?
    var gcCycles: UInt64?
    var goMemoryLimitBytes: Int64?
    /// `phys_footprint` of the extension process (what iOS enforces), measured by the Swift host.
    var physicalFootprintBytes: UInt64?
    var memoryPressureWarnings: Int
    var memoryPressureCriticals: Int
    /// Last error of the Swift engine lifecycle.
    var lifecycleError: String?
    /// Last start/stop error the bridge recorded (code and message).
    var bridgeError: String?
    /// Error-level engine log records, newest last, bounded.
    var recentErrors: [ErrorRecord]
    var logRecordsDropped: UInt64?

    /// Longest text kept per error; a limit of this project.
    static let maximumErrorLength = 240
    /// Most error records sent; a limit of this project.
    static let maximumRecentErrors = 8

    /// Applies the limits (the reply must stay far below `TunnelIPC.maximumMessageBytes`).
    func bounded() -> TunnelEngineDiagnostics {
        func cut(_ text: String?) -> String? {
            guard let text = text else { return nil }
            return text.count > Self.maximumErrorLength ? String(text.prefix(Self.maximumErrorLength)) + "…" : text
        }
        var copy = self
        copy.lifecycleError = cut(lifecycleError)
        copy.bridgeError = cut(bridgeError)
        copy.recentErrors = recentErrors.suffix(Self.maximumRecentErrors).map {
            ErrorRecord(timeUnixMilliseconds: $0.timeUnixMilliseconds, kind: String($0.kind.prefix(32)), message: cut($0.message) ?? "")
        }
        return copy
    }
}

// MARK: - Encoding and checking, both directions

/// The rules of one request/reply exchange, independent of the transport so
/// that they can be tested without `NETunnelProviderSession`.
enum TunnelExchange {
    // MARK: App side

    /// Encodes a request for `sendProviderMessage`.
    static func encode(_ request: TunnelRequest) throws -> Data {
        guard let data = try? JSONEncoder().encode(request) else {
            throw TunnelIPCError(.malformedRequest, "request could not be encoded")
        }
        guard data.count <= TunnelIPC.maximumMessageBytes else {
            throw TunnelIPCError(.messageTooLarge, "request exceeds \(TunnelIPC.maximumMessageBytes) bytes")
        }
        return data
    }

    /// Checks a reply against the request it should answer and returns its
    /// outcome. A `.failure` outcome is thrown, so the caller never sees it.
    static func outcome(of reply: Data?, for request: TunnelRequest) throws -> TunnelResponse.Outcome {
        guard let reply = reply, !reply.isEmpty else {
            throw TunnelIPCError(.noReply, "the extension answered without data")
        }
        guard reply.count <= TunnelIPC.maximumMessageBytes else {
            throw TunnelIPCError(.messageTooLarge, "reply exceeds \(TunnelIPC.maximumMessageBytes) bytes")
        }
        guard let response = try? JSONDecoder().decode(TunnelResponse.self, from: reply) else {
            throw TunnelIPCError(.malformedReply, "reply is not a tunnel response")
        }
        guard response.version == TunnelIPC.protocolVersion else {
            throw TunnelIPCError(.unsupportedVersion, "the extension speaks version \(response.version)")
        }
        if case let .failure(error) = response.outcome, response.id == 0 || response.id == request.id {
            // id 0: the extension could not even decode the request.
            throw error
        }
        guard response.id == request.id else {
            throw TunnelIPCError(.mismatchedReply, "reply \(response.id) does not answer request \(request.id)")
        }
        return response.outcome
    }

    static func statusReport(of reply: Data?, for request: TunnelRequest) throws -> TunnelStatusReport {
        guard case let .status(report) = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected a status report")
        }
        return report
    }

    static func groupReport(of reply: Data?, for request: TunnelRequest) throws -> TunnelGroupReport {
        guard case let .groups(report) = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected a group report")
        }
        return report
    }

    static func connectionReport(of reply: Data?, for request: TunnelRequest) throws -> TunnelConnectionReport {
        guard case let .connections(report) = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected a connection report")
        }
        return report
    }

    static func confirmation(of reply: Data?, for request: TunnelRequest) throws {
        guard case .done = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected a confirmation")
        }
    }

    static func trafficReport(of reply: Data?, for request: TunnelRequest) throws -> TunnelTrafficReport {
        guard case let .statistics(report) = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected a traffic report")
        }
        return report
    }

    static func diagnostics(of reply: Data?, for request: TunnelRequest) throws -> TunnelEngineDiagnostics {
        guard case let .diagnostics(report) = try outcome(of: reply, for: request) else {
            throw TunnelIPCError(.unexpectedReply, "expected engine diagnostics")
        }
        return report
    }

    // MARK: Extension side

    enum Incoming: Equatable {
        case request(TunnelRequest)
        /// The message cannot be served; this is the reply to send.
        case rejection(TunnelResponse)
    }

    static func decodeRequest(_ messageData: Data) -> Incoming {
        guard messageData.count <= TunnelIPC.maximumMessageBytes else {
            return .rejection(failure(id: 0, .messageTooLarge, "message exceeds \(TunnelIPC.maximumMessageBytes) bytes"))
        }
        guard let request = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            return .rejection(failure(id: 0, .malformedRequest, "message is not a tunnel request"))
        }
        guard request.version == TunnelIPC.protocolVersion else {
            return .rejection(
                failure(id: request.id, .unsupportedVersion, "the extension speaks version \(TunnelIPC.protocolVersion)")
            )
        }
        if request.body == .selectMember {
            guard let selection = request.selection else {
                return .rejection(failure(id: request.id, .malformedRequest, "selectMember without a selection"))
            }
            do {
                try selection.validate()
            } catch let error as TunnelIPCError {
                return .rejection(TunnelResponse(version: TunnelIPC.protocolVersion, id: request.id, outcome: .failure(error)))
            } catch {
                return .rejection(failure(id: request.id, .malformedRequest, "invalid selection"))
            }
        }
        return .request(request)
    }

    static func failure(id: UInt64, _ code: TunnelIPCError.Code, _ message: String) -> TunnelResponse {
        TunnelResponse(version: TunnelIPC.protocolVersion, id: id, outcome: .failure(TunnelIPCError(code, message)))
    }

    /// Encodes a reply. An oversized or unencodable reply is replaced by a
    /// small failure, so the app always gets an answer it can decode.
    static func encode(_ response: TunnelResponse) -> Data? {
        if let data = try? JSONEncoder().encode(response), data.count <= TunnelIPC.maximumMessageBytes {
            return data
        }
        let fallback = failure(id: response.id, .messageTooLarge, "reply exceeds \(TunnelIPC.maximumMessageBytes) bytes")
        return try? JSONEncoder().encode(fallback)
    }
}
