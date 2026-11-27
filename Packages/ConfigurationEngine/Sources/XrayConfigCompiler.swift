import Foundation
import DomainModels

/// Memory-related shape of the compiled configuration.
public enum XrayMemoryProfile: String, Codable, Hashable, Sendable {
    /// Xray's own defaults: no policy section, default QUIC windows.
    case standard
    /// For a process with a memory budget of about 50 MiB (an iOS packet tunnel provider):
    /// short idle timeouts and small per-connection buffers in policy level 0, and capped QUIC
    /// receive windows for Hysteria2. The bridge's runtime side of the same profile (memory limit,
    /// GC, flow cap, no geodata files) is the bridge option `memory.profile = "mobile"`.
    /// Values: `Documentation/Performance/memory-budget.md`; they are project choices, not platform limits.
    case mobile
}

/// Inputs of a compilation that are not part of `Profile`.
/// The model has no routing or DNS section yet; what the compiler can take is listed here.
public struct XrayCompileOptions: Codable, Hashable, Sendable {
    /// `debug`, `info`, `warning`, `error` or `none`.
    public var logLevel: String
    /// Loopback SOCKS5 inbound for tests and desktop use; `nil` emits no inbound
    /// (the tunnel adapter adds its own).
    public var localSOCKSPort: UInt16?
    /// DNS servers in Xray notation (`1.1.1.1`, `https://dns.example/dns-query`); empty emits no DNS section.
    public var dnsServers: [String]
    /// `.standard` unless the configuration is for a memory-limited process.
    public var memoryProfile: XrayMemoryProfile
    /// Addresses of the packet tunnel. When set, the output has the `tun` inbound the bridge's packet
    /// path needs (`tun.mode = "flow"`), DNS hijacking into the core's resolver, and routing that keeps
    /// the proxy servers and local networks out of the proxy. `nil` emits no tunnel.
    public var tunnel: TunnelAddressing?

    public init(
        logLevel: String = "warning",
        localSOCKSPort: UInt16? = nil,
        dnsServers: [String] = [],
        memoryProfile: XrayMemoryProfile = .standard,
        tunnel: TunnelAddressing? = nil
    ) {
        self.logLevel = logLevel
        self.localSOCKSPort = localSOCKSPort
        self.dnsServers = dnsServers
        self.memoryProfile = memoryProfile
        self.tunnel = tunnel
    }

    /// Options for the Packet Tunnel extension: the tunnel with the shared addresses and the mobile
    /// memory profile (the extension runs the bridge with `memory.profile = "mobile"`).
    public static func packetTunnel(
        dnsServers: [String] = [],
        addressing: TunnelAddressing = .standard,
        logLevel: String = "warning"
    ) -> XrayCompileOptions {
        XrayCompileOptions(logLevel: logLevel, dnsServers: dnsServers, memoryProfile: .mobile, tunnel: addressing)
    }

    private enum CodingKeys: String, CodingKey {
        case logLevel, localSOCKSPort, dnsServers, memoryProfile, tunnel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logLevel = try container.decode(String.self, forKey: .logLevel)
        localSOCKSPort = try container.decodeIfPresent(UInt16.self, forKey: .localSOCKSPort)
        dnsServers = try container.decode([String].self, forKey: .dnsServers)
        // absent in options encoded before the field existed
        memoryProfile = try container.decodeIfPresent(XrayMemoryProfile.self, forKey: .memoryProfile) ?? .standard
        tunnel = try container.decodeIfPresent(TunnelAddressing.self, forKey: .tunnel)
    }
}

/// What the tunnel host needs next to a configuration compiled with `XrayCompileOptions.tunnel`.
/// Built from the same values as the configuration, so the interface and the engine agree.
public struct XrayTunnelPlan: Codable, Hashable, Sendable {
    /// The addresses the configuration was compiled for.
    public var addressing: TunnelAddressing
    /// Destinations that must bypass the tunnel at the system level: the IP literals of the proxy
    /// servers, then `TunnelAddressing.localRoutes`. The configuration sends the same destinations
    /// to the direct outbound.
    public var excludedRoutes: [TunnelRoute]
    /// `tunnelRemoteAddress` for the system: the first proxy server given as an IP literal, otherwise
    /// the tunnel's own IPv4 address (the system shows it; it does not route by it).
    public var remoteAddress: String

    public init(addressing: TunnelAddressing, excludedRoutes: [TunnelRoute], remoteAddress: String) {
        self.addressing = addressing
        self.excludedRoutes = excludedRoutes
        self.remoteAddress = remoteAddress
    }
}

public struct XrayCompilation: Sendable {
    /// `nil` when the verdict is `.blocked`.
    public var config: JSONValue?
    public var report: ConversionReport
    /// Set when the configuration was compiled with a tunnel and is not blocked.
    public var tunnel: XrayTunnelPlan?

    public init(config: JSONValue?, report: ConversionReport, tunnel: XrayTunnelPlan? = nil) {
        self.config = config
        self.report = report
        self.tunnel = tunnel
    }

    /// Deterministic JSON text (sorted keys). Contains credentials: never log it.
    public func jsonText() throws -> String? {
        return try config?.jsonText()
    }
}

/// Compiles the engine-neutral model into an Xray JSON configuration (ADR-0002).
///
/// Every difference between the profile and the output is listed in the report;
/// an outbound with an `.error` issue is left out and named in `excludedOutbounds`.
/// Pure function of its inputs: no I/O, no global state.
public struct XrayConfigCompiler: Sendable {
    /// Version of Xray-core whose `infra/conf` the rules below were read from and
    /// whose binary accepts the fixture corpus.
    public static let engineVersion = "26.11.9"

    public static let directTag = "direct"
    public static let blockTag = "block"
    public static let socksInboundTag = "socks-in"
    /// Tag of the `tun` inbound. In flow mode the bridge replaces the inbound by its own packet
    /// inbound with the same tag, MTU and user level (`Cores/Bridge/engine/config.go` `resolveTun`).
    public static let tunInboundTag = "tun-in"
    /// Outbound that answers hijacked DNS queries with the core's resolver.
    public static let dnsOutboundTag = "dns-out"
    /// Inbound tag of the core resolver's own queries, routed like the user's traffic.
    public static let dnsInternalTag = "dns-internal"
    /// Resolvers used inside the tunnel when the options name none (queried through the proxy).
    /// A project choice.
    public static let defaultTunnelDNSServers = ["1.1.1.1", "8.8.8.8"]

    /// Policy level 0 of `XrayMemoryProfile.mobile` (`infra/conf/policy.go` keys; seconds, `bufferSize` in KiB).
    /// The tunnel inbound runs at level 0. Xray's defaults: connIdle 300, handshake 60, uplinkOnly 1,
    /// downlinkOnly 1, bufferSize 512 KiB on amd64 and 4 KiB on arm64 (`features/policy/policy.go`).
    /// `Cores/BuildScripts/bridge-tunlab.sh` (MOBILE=1) uses the same numbers.
    public static let mobilePolicy: [String: Int64] = [
        "connIdle": 30, "handshake": 10, "uplinkOnly": 1, "downlinkOnly": 1, "bufferSize": 4,
    ]

    /// QUIC receive windows of `XrayMemoryProfile.mobile` for Hysteria2, in bytes (`finalmask.quicParams`).
    /// Xray's Hysteria2 defaults are 8 MiB per stream and 20 MiB per connection
    /// (`transport/internet/hysteria/dialer.go`).
    public static let mobileQUICWindows: [String: Int64] = [
        "initStreamReceiveWindow": 512 << 10, "maxStreamReceiveWindow": 2 << 20,
        "initConnectionReceiveWindow": 1 << 20, "maxConnectionReceiveWindow": 4 << 20,
    ]

    public typealias SecretResolver = @Sendable (SecretReference) -> String?

    public var options: XrayCompileOptions
    private let resolver: SecretResolver?

    public init(options: XrayCompileOptions = XrayCompileOptions(), resolveSecret: SecretResolver? = nil) {
        self.options = options
        self.resolver = resolveSecret
    }

    // MARK: - Profile

    public func compile(_ profile: Profile) -> XrayCompilation {
        var report = ConversionReport(engine: .xray, engineVersion: XrayConfigCompiler.engineVersion)

        for issue in profile.validate() {
            report.add("profile", .invalid, .error, "Profile is inconsistent (\(issue.kind.rawValue)) at tag '\(issue.tag)'")
        }
        let structurallyValid = report.issues.isEmpty

        let width = max(4, String(profile.outbounds.count).count)
        var compiled: [JSONValue] = []
        var emittedTags: [String: String] = [:]
        for (index, outbound) in profile.outbounds.enumerated() {
            let engineTag = "proxy-" + XrayConfigCompiler.padded(index, width: width)
            let result = compileOutbound(outbound, engineTag: engineTag, path: "outbounds[\(index)]")
            report.issues.append(contentsOf: result.issues)
            if let json = result.json, !outbound.tag.isEmpty, emittedTags[outbound.tag] == nil {
                compiled.append(json)
                emittedTags[outbound.tag] = engineTag
            } else {
                report.excludedOutbounds.append(outbound.tag)
            }
        }
        report.engineTags = emittedTags

        var route: Route?
        if structurallyValid {
            route = resolveRoute(profile, emittedTags: emittedTags, report: &report)
        }

        guard let route = route else {
            report.verdict = .blocked
            return XrayCompilation(config: nil, report: report)
        }

        var root: [String: JSONValue] = [:]
        if ["debug", "info", "warning", "error", "none"].contains(options.logLevel) {
            root["log"] = .object(["loglevel": .string(options.logLevel)])
        } else {
            report.add("options.logLevel", .invalid, .warning, "Unknown log level; 'warning' is used")
            root["log"] = .object(["loglevel": .string("warning")])
        }
        var inbounds: [JSONValue] = []
        if let port = options.localSOCKSPort {
            inbounds.append(.object([
                "tag": .string(XrayConfigCompiler.socksInboundTag),
                "protocol": .string("socks"),
                "listen": .string("127.0.0.1"),
                "port": .integer(Int64(port)),
                "settings": .object(["auth": .string("noauth"), "udp": .bool(true)]),
            ]))
        }
        var dnsServers = options.dnsServers
        var tunnelPlan: XrayTunnelPlan?
        if let addressing = options.tunnel {
            if dnsServers.isEmpty {
                dnsServers = XrayConfigCompiler.defaultTunnelDNSServers
                report.add(
                    "options.dnsServers", .migrated, .info,
                    "No DNS servers given; the tunnel resolves through \(dnsServers.count) default public resolvers, queried through the proxy"
                )
            }
            for (index, server) in dnsServers.enumerated() where XrayConfigCompiler.bypassesRouting(dnsServer: server) {
                report.add(
                    "options.dnsServers[\(index)]", .unsupported, .error,
                    "This DNS server would be queried outside the tunnel (system resolver or a '+local' scheme)"
                )
            }
            guard (576...65_535).contains(addressing.mtu) else {
                report.add("options.tunnel.mtu", .invalid, .error, "Tunnel MTU is outside 576...65535")
                report.verdict = .blocked
                return XrayCompilation(config: nil, report: report)
            }
            if report.issues.contains(where: { $0.severity == .error && $0.path.hasPrefix("options.dnsServers") }) {
                report.verdict = .blocked
                return XrayCompilation(config: nil, report: report)
            }
            inbounds.append(.object([
                "tag": .string(XrayConfigCompiler.tunInboundTag),
                "protocol": .string("tun"),
                "settings": .object(["mtu": .integer(Int64(addressing.mtu))]),
            ]))
            tunnelPlan = tunnelExclusions(profile, emittedTags: emittedTags, addressing: addressing, report: &report)
        }
        if !inbounds.isEmpty {
            root["inbounds"] = .array(inbounds)
        }
        if !dnsServers.isEmpty {
            var dns: [String: JSONValue] = ["servers": .array(dnsServers.map { .string($0) })]
            if tunnelPlan != nil {
                dns["tag"] = .string(XrayConfigCompiler.dnsInternalTag)
            }
            root["dns"] = .object(dns)
        }
        if options.memoryProfile == .mobile {
            root["policy"] = .object(["levels": .object([
                "0": .object(XrayConfigCompiler.mobilePolicy.mapValues { .integer($0) }),
            ])])
            report.add(
                "options.memoryProfile", .migrated, .info,
                "Mobile memory profile: connections idle for \(XrayConfigCompiler.mobilePolicy["connIdle"] ?? 0) s are closed and per-connection buffers are \(XrayConfigCompiler.mobilePolicy["bufferSize"] ?? 0) KiB"
            )
        }
        compiled.append(.object(["tag": .string(XrayConfigCompiler.directTag), "protocol": .string("freedom")]))
        compiled.append(.object(["tag": .string(XrayConfigCompiler.blockTag), "protocol": .string("blackhole")]))
        if tunnelPlan != nil {
            compiled.append(.object(["tag": .string(XrayConfigCompiler.dnsOutboundTag), "protocol": .string("dns")]))
        }
        root["outbounds"] = .array(compiled)

        var routing: [String: JSONValue] = [:]
        var target: [String: JSONValue] = [:]
        switch route {
        case .outbound(let tag):
            target["outboundTag"] = .string(tag)
        case .balancer(let balancer):
            target["balancerTag"] = .string(balancer.tag)
            var object: [String: JSONValue] = [
                "tag": .string(balancer.tag),
                "selector": .array(balancer.members.map { .string($0) }),
                "strategy": .object(["type": .string(balancer.strategy)]),
            ]
            if let fallback = balancer.members.first {
                object["fallbackTag"] = .string(fallback)
            }
            routing["balancers"] = .array([.object(object)])
            if let observatory = balancer.observatory {
                root[observatory.key] = observatory.value
            }
        }
        var rules: [JSONValue] = []
        if let plan = tunnelPlan {
            // Every DNS query the system or an app sends into the tunnel, to any address, is answered by
            // the core's resolver; nothing reaches a resolver outside the tunnel.
            rules.append(.object([
                "type": .string("field"),
                "inboundTag": .array([.string(XrayConfigCompiler.tunInboundTag)]),
                "network": .string("udp"),
                "port": .string("53"),
                "outboundTag": .string(XrayConfigCompiler.dnsOutboundTag),
            ]))
            // The resolver's own queries go where the user's traffic goes.
            rules.append(.object(target.merging([
                "type": .string("field"),
                "inboundTag": .array([.string(XrayConfigCompiler.dnsInternalTag)]),
            ]) { current, _ in current }))
            rules.append(.object([
                "type": .string("field"),
                "ip": .array(plan.excludedRoutes.map { .string($0.cidr) }),
                "outboundTag": .string(XrayConfigCompiler.directTag),
            ]))
        }
        rules.append(.object(target.merging(["type": .string("field"), "network": .string("tcp,udp")]) { current, _ in current }))
        routing["rules"] = .array(rules)
        root["routing"] = .object(routing)

        report.verdict = report.issues.contains { $0.severity != .info } ? .degraded : .exact
        return XrayCompilation(config: .object(root), report: report, tunnel: tunnelPlan)
    }

    /// Server addresses and local ranges that bypass the tunnel.
    private func tunnelExclusions(
        _ profile: Profile,
        emittedTags: [String: String],
        addressing: TunnelAddressing,
        report: inout ConversionReport
    ) -> XrayTunnelPlan {
        var servers: [TunnelRoute] = []
        var named = 0
        for outbound in profile.outbounds where emittedTags[outbound.tag] != nil {
            let host = outbound.server.host
            if XrayStreamCompiler.isIPLiteral(host) {
                let route = TunnelRoute.host(host)
                if !servers.contains(route) {
                    servers.append(route)
                }
            } else {
                named += 1
            }
        }
        if named > 0 {
            report.add(
                "options.tunnel", .untested, .info,
                "\(named) server(s) are named by a domain: their addresses are not known before the tunnel starts and cannot be excluded from it; the system is expected to keep the extension's own connections out of its tunnel"
            )
        }
        let remote = servers.first?.address ?? addressing.ipv4Address
        return XrayTunnelPlan(addressing: addressing, excludedRoutes: servers + TunnelAddressing.localRoutes, remoteAddress: remote)
    }

    /// DNS server notations that the core queries without routing, i.e. outside the tunnel
    /// (`app/dns/nameserver.go`: `localhost` is the system resolver, `+local` schemes dial directly).
    static func bypassesRouting(dnsServer: String) -> Bool {
        let lowered = dnsServer.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered == "localhost" || lowered.contains("+local")
    }

    private static func padded(_ index: Int, width: Int) -> String {
        let text = String(index)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    // MARK: - Route

    private struct Balancer {
        var tag: String
        var members: [String]
        var strategy: String
        var observatory: (key: String, value: JSONValue)?
    }

    private enum Route {
        case outbound(String)
        case balancer(Balancer)
    }

    private func resolveRoute(
        _ profile: Profile,
        emittedTags: [String: String],
        report: inout ConversionReport
    ) -> Route? {
        var selected = profile.selectedTag
        if selected == nil {
            guard let first = profile.outbounds.first else {
                report.add("profile.outbounds", .invalid, .error, "Profile has no outbounds")
                return nil
            }
            selected = first.tag
            report.add("profile.selectedTag", .migrated, .info, "Nothing is selected; the first outbound is used")
        }
        guard var tag = selected else { return nil }

        // Selector groups are resolved statically, possibly through several levels.
        var hops = 0
        while let group = profile.group(tagged: tag), group.kind == .selector {
            let path = "groups[\(group.tag)]"
            guard let next = group.defaultMemberTag ?? group.members.first?.tag else {
                report.add(path, .invalid, .error, "Selector group has no members")
                return nil
            }
            report.add(
                path, .approximated, .warning,
                "A selector group is compiled to its current member; switching requires a new compilation"
            )
            tag = next
            hops += 1
            if hops > Profile.maximumGroupNestingDepth {
                report.add(path, .invalid, .error, "Selector groups are nested too deep")
                return nil
            }
        }

        if profile.outbound(tagged: tag) != nil {
            guard let engineTag = emittedTags[tag] else {
                report.add("profile.selectedTag", .unsupported, .error, "The selected outbound could not be compiled")
                return nil
            }
            return .outbound(engineTag)
        }
        guard let group = profile.group(tagged: tag) else {
            report.add("profile.selectedTag", .invalid, .error, "Selected tag does not exist")
            return nil
        }
        let path = "groups[\(group.tag)]"
        guard let flattened = profile.flattenedOutboundTags(ofGroup: group.tag), !flattened.isEmpty else {
            report.add(path, .invalid, .error, "Group members cannot be resolved")
            return nil
        }
        if group.members.contains(where: { if case .group = $0 { return true } else { return false } }) {
            report.add(
                path, .approximated, .warning,
                "Nested groups are flattened into one balancer; inner strategies are not preserved"
            )
        }
        let members = flattened.compactMap { emittedTags[$0] }
        if members.count < flattened.count {
            report.add(path, .dropped, .warning, "\(flattened.count - members.count) member(s) could not be compiled and are left out")
        }
        guard !members.isEmpty else {
            report.add(path, .unsupported, .error, "No member of the selected group could be compiled")
            return nil
        }

        var strategy: String
        switch group.kind {
        case .selector:
            return nil
        case .urlTest:
            strategy = "leastPing"
        case .fallback:
            strategy = "leastPing"
            report.add(
                path, .approximated, .warning,
                "Xray has no ordered fallback; the fastest healthy member is used instead of the first healthy one"
            )
        case .loadBalance:
            switch group.strategy ?? .random {
            case .random: strategy = "random"
            case .roundRobin: strategy = "roundRobin"
            case .leastPing: strategy = "leastPing"
            case .leastLoad: strategy = "leastLoad"
            case .consistentHashing:
                strategy = "random"
                report.add(path, .approximated, .warning, "Xray has no consistent-hashing balancer; 'random' is used")
            }
        }

        let balancerTag = "group-" + XrayConfigCompiler.padded(
            profile.groups.firstIndex { $0.tag == group.tag } ?? 0, width: 4
        )
        report.engineTags[group.tag] = balancerTag
        var balancer = Balancer(tag: balancerTag, members: members, strategy: strategy, observatory: nil)
        let selector: JSONValue = .array(members.map { .string($0) })
        let check = group.healthCheck
        if check?.toleranceMilliseconds != nil {
            report.add(path + ".healthCheck.toleranceMilliseconds", .dropped, .warning, "Xray has no latency tolerance setting")
        }
        switch strategy {
        case "leastPing":
            var object: [String: JSONValue] = ["subjectSelector": selector]
            if let check = check {
                object["probeURL"] = .string(check.url)
                object["probeInterval"] = .string("\(max(1, check.intervalSeconds))s")
                if check.timeoutMilliseconds != nil {
                    report.add(path + ".healthCheck.timeoutMilliseconds", .dropped, .warning, "The Xray observatory has no probe timeout setting")
                }
            } else {
                report.add(path + ".healthCheck", .migrated, .info, "No health check is configured; Xray observatory defaults are used")
            }
            balancer.observatory = (key: "observatory", value: .object(object))
        case "leastLoad":
            var ping: [String: JSONValue] = [:]
            if let check = check {
                ping["destination"] = .string(check.url)
                ping["interval"] = .string("\(max(1, check.intervalSeconds))s")
                if let timeout = check.timeoutMilliseconds {
                    ping["timeout"] = .string("\(max(1, timeout))ms")
                }
            } else {
                report.add(path + ".healthCheck", .migrated, .info, "No health check is configured; Xray burst observatory defaults are used")
            }
            balancer.observatory = (
                key: "burstObservatory",
                value: .object(["subjectSelector": selector, "pingConfig": .object(ping)])
            )
        default:
            if check != nil {
                report.add(path + ".healthCheck", .dropped, .warning, "This balancing strategy does not use a health check in Xray")
            }
        }
        return .balancer(balancer)
    }

    // MARK: - Outbound

    /// Compiles one outbound. `json` is `nil` when any issue has severity `.error`.
    public func compileOutbound(
        _ outbound: Outbound,
        engineTag: String,
        path: String = "outbound"
    ) -> (json: JSONValue?, issues: [ConversionIssue]) {
        var context = XrayOutboundContext(path: path)
        let json = build(outbound, engineTag: engineTag, context: &context)
        // Messages may quote what the profile contains; no credential or address leaves in them.
        var redactor = ConfigValueRedactor(document: json)
        redactor.add(outbound.server.host)
        let credentials = outbound.credentials
        for secret in [credentials.userID, credentials.password, credentials.privateKey, credentials.preSharedKey] {
            if case .inline(let text)? = secret {
                redactor.add(text)
            }
        }
        if let username = credentials.username {
            redactor.add(username)
        }
        return (context.failed ? nil : json, redactor.redact(context.issues))
    }

    private func resolve(_ value: SecretValue?, _ subpath: String, _ context: inout XrayOutboundContext) -> String? {
        guard let value = value else {
            context.note(subpath, .invalid, .error, "Required credential is missing")
            return nil
        }
        let text: String?
        switch value {
        case .inline(let inline):
            text = inline
        case .reference(let reference):
            text = resolver?(reference)
            if text == nil {
                context.note(subpath, .invalid, .error, "Secret reference could not be resolved")
                return nil
            }
        }
        guard let result = text, !result.isEmpty else {
            context.note(subpath, .invalid, .error, "Credential is empty")
            return nil
        }
        return result
    }

    private func build(_ outbound: Outbound, engineTag: String, context: inout XrayOutboundContext) -> JSONValue? {
        let server = outbound.server
        if server.host.isEmpty {
            context.note("server.host", .invalid, .error, "Server host is empty")
        }
        if server.port == 0 {
            context.note("server.port", .invalid, .error, "Server port is zero")
        }
        reportLeftovers(outbound, context: &context)

        var settings: [String: JSONValue] = [
            "address": .string(server.host),
            "port": .integer(Int64(server.port)),
        ]
        var stream: [String: JSONValue]?
        let protocolName: String
        let resolveSecret: (SecretValue?, String, inout XrayOutboundContext) -> String? = { value, subpath, context in
            self.resolve(value, subpath, &context)
        }
        func ordinaryStream(sniFromHost: Bool, _ context: inout XrayOutboundContext) -> [String: JSONValue] {
            return XrayStreamCompiler.compile(
                outbound.stream, server: server, extras: outbound.extras,
                sniDefaultFromHost: sniFromHost, subpath: "stream",
                resolve: resolveSecret, context: &context
            )
        }

        switch outbound.settings {
        case .vless(let vless):
            protocolName = "vless"
            if let id = resolve(outbound.credentials.userID, "credentials.userID", &context) {
                checkUserID(id, context: &context)
                settings["id"] = .string(id)
            }
            let encryption = vless.encryption.isEmpty ? "none" : vless.encryption
            if encryption != "none" && !encryption.hasPrefix("mlkem768x25519plus.") {
                context.note("settings.encryption", .unsupported, .error, "Xray does not support this VLESS encryption value")
            }
            settings["encryption"] = .string(encryption)
            if let flow = vless.flow, !flow.isEmpty {
                if flow == "xtls-rprx-vision" || flow == "xtls-rprx-vision-udp443" {
                    settings["flow"] = .string(flow)
                    if outbound.stream.transport.kind != .tcp {
                        context.note("settings.flow", .untested, .warning, "Vision flow is meant for the RAW transport; this combination is not tested")
                    }
                } else {
                    context.note("settings.flow", .unsupported, .error, "Xray does not support the VLESS flow '\(flow)'")
                }
            }
            if let encoding = vless.packetEncoding, !encoding.isEmpty, encoding.lowercased() != "xudp" {
                context.note("settings.packetEncoding", .unsupported, .warning, "Xray always uses XUDP for VLESS; '\(encoding)' is not applied")
            }
            if outbound.stream.security.kind == .none && encryption == "none" && XrayConfigCompiler.isPublicAddress(server.host) {
                context.note("stream.security", .unsupported, .error, "Xray refuses VLESS without TLS, REALITY or VLESS Encryption to a public address")
            }
            stream = ordinaryStream(sniFromHost: true, &context)

        case .vmess(let vmess):
            protocolName = "vmess"
            if let id = resolve(outbound.credentials.userID, "credentials.userID", &context) {
                checkUserID(id, context: &context)
                settings["id"] = .string(id)
            }
            let cipher = vmess.cipher.lowercased()
            switch cipher {
            case "", "auto":
                settings["security"] = .string("auto")
            case "aes-128-gcm", "chacha20-poly1305":
                settings["security"] = .string(cipher)
            default:
                settings["security"] = .string("auto")
                context.note("settings.cipher", .approximated, .warning, "Xray has no VMess cipher '\(cipher)'; 'auto' is used")
            }
            if vmess.alterID > 0 {
                context.note("settings.alterID", .unsupported, .warning, "Xray speaks only VMess AEAD; a non-zero alterId is ignored and a legacy server will not answer")
            }
            stream = ordinaryStream(sniFromHost: true, &context)

        case .trojan:
            protocolName = "trojan"
            if let password = resolve(outbound.credentials.password, "credentials.password", &context) {
                settings["password"] = .string(password)
            }
            if outbound.stream.security.kind == .none && XrayConfigCompiler.isPublicAddress(server.host) {
                context.note("stream.security", .unsupported, .error, "Xray refuses Trojan without TLS to a public address")
            }
            stream = ordinaryStream(sniFromHost: false, &context)

        case .shadowsocks(let shadowsocks):
            protocolName = "shadowsocks"
            let method = shadowsocks.method.lowercased()
            let password = resolve(outbound.credentials.password, "credentials.password", &context)
            if let keyLength = XrayConfigCompiler.shadowsocks2022KeyLengths[method] {
                if let password = password {
                    let keys = password.split(separator: ":", omittingEmptySubsequences: false)
                    let valid = keys.allSatisfy { Data(base64Encoded: String($0))?.count == keyLength }
                    if !valid {
                        context.note("credentials.password", .invalid, .error, "Shadowsocks 2022 key must be standard base64 of \(keyLength) bytes (identity keys separated by ':')")
                    } else if keys.count > 1 && method.contains("chacha") {
                        context.note("credentials.password", .unsupported, .error, "Xray does not support identity keys with the ChaCha 2022 method")
                    }
                }
            } else if !XrayConfigCompiler.shadowsocksMethods.contains(method) {
                context.note("settings.method", .unsupported, .error, "Xray does not support the Shadowsocks method '\(method)'")
            }
            settings["method"] = .string(method)
            if let password = password {
                settings["password"] = .string(password)
            }
            if shadowsocks.plugin != nil {
                context.note("settings.plugin", .unsupported, .error, "Xray cannot run SIP003 plugins")
            }
            stream = ordinaryStream(sniFromHost: false, &context)

        case .socks(let socks):
            protocolName = "socks"
            if socks.version != .v5 {
                context.note("settings.version", .unsupported, .error, "The Xray SOCKS outbound speaks SOCKS5 only")
            }
            addUserPass(outbound, to: &settings, context: &context)
            stream = ordinaryStream(sniFromHost: false, &context)

        case .http:
            protocolName = "http"
            addUserPass(outbound, to: &settings, context: &context)
            stream = ordinaryStream(sniFromHost: false, &context)

        case .wireGuard(let wireGuard):
            protocolName = "wireguard"
            settings = buildWireGuard(wireGuard, outbound: outbound, context: &context)
            if outbound.stream.transport.kind != .native || outbound.stream.security.kind != .none {
                context.note("stream", .invalid, .error, "WireGuard carries its own transport; stream settings do not apply")
            }
            if !outbound.extras.isEmpty {
                noteUnusedExtras(outbound, usedXrayKeys: [], context: &context)
            }

        case .hysteria2(let hysteria):
            protocolName = "hysteria"
            settings["version"] = .integer(2)
            stream = buildHysteria2Stream(hysteria, outbound: outbound, resolve: resolveSecret, context: &context)

        case .tuic:
            context.note("settings", .unsupported, .error, "Xray \(XrayConfigCompiler.engineVersion) has no TUIC outbound")
            return nil

        case .other(let kind):
            context.note("settings", .unsupported, .error, "Xray compiler has no support for the protocol '\(kind.rawValue)'")
            return nil
        }

        if stream != nil {
            var used: Set<String> = [EngineExtras.xrayFinalMaskKey]
            if outbound.stream.transport.kind == .xhttp {
                used.insert(EngineExtras.xrayXHTTPExtraKey)
            }
            noteUnusedExtras(outbound, usedXrayKeys: used, context: &context)
        }

        var object: [String: JSONValue] = [
            "tag": .string(engineTag),
            "protocol": .string(protocolName),
            "settings": .object(settings),
        ]
        if let stream = stream {
            object["streamSettings"] = .object(stream)
        }
        return .object(object)
    }

    // MARK: - Protocol pieces

    static let shadowsocksMethods: Set<String> = [
        "aes-128-gcm", "aead_aes_128_gcm", "aes-256-gcm", "aead_aes_256_gcm",
        "chacha20-poly1305", "aead_chacha20_poly1305", "chacha20-ietf-poly1305",
        "xchacha20-poly1305", "aead_xchacha20_poly1305", "xchacha20-ietf-poly1305",
    ]

    /// Method → key length in bytes (`proxy/shadowsocks_2022/cipher.go`).
    static let shadowsocks2022KeyLengths: [String: Int] = [
        "2022-blake3-aes-128-gcm": 16,
        "2022-blake3-aes-256-gcm": 32,
        "2022-blake3-chacha20-poly1305": 32,
    ]

    private func checkUserID(_ id: String, context: inout XrayOutboundContext) {
        if UUID(uuidString: id) != nil { return }
        let length = id.utf8.count
        if length >= 1 && length <= 30 {
            context.note("credentials.userID", .approximated, .info, "The id is not a UUID; Xray derives a UUID from the text, as its server does")
        } else {
            context.note("credentials.userID", .invalid, .error, "The id is neither a UUID nor a text of 1...30 bytes")
        }
    }

    private func addUserPass(_ outbound: Outbound, to settings: inout [String: JSONValue], context: inout XrayOutboundContext) {
        let username = outbound.credentials.username ?? ""
        if !username.isEmpty {
            settings["user"] = .string(username)
            if outbound.credentials.password != nil {
                if let password = resolve(outbound.credentials.password, "credentials.password", &context) {
                    settings["pass"] = .string(password)
                }
            }
        } else if outbound.credentials.password != nil {
            context.note("credentials.password", .dropped, .warning, "Xray sends no authentication when the user name is empty; the password is not used")
        }
    }

    private func buildWireGuard(
        _ wireGuard: WireGuardSettings,
        outbound: Outbound,
        context: inout XrayOutboundContext
    ) -> [String: JSONValue] {
        // Apple platforms have no kernel TUN path in Xray (`proxy/wireguard/tun_default.go`);
        // pinning the userspace stack makes Linux validation exercise the same code and keeps
        // a root-run test from creating an interface and policy routes on the host.
        var settings: [String: JSONValue] = ["noKernelTun": .bool(true)]
        if let key = resolve(outbound.credentials.privateKey, "credentials.privateKey", &context) {
            if XrayConfigCompiler.isWireGuardKey(key) {
                settings["secretKey"] = .string(key)
            } else {
                context.note("credentials.privateKey", .invalid, .error, "WireGuard private key is not 32 bytes of base64 or hex")
            }
        }
        var peer: [String: JSONValue] = ["endpoint": .string(outbound.server.authority)]
        if XrayConfigCompiler.isWireGuardKey(wireGuard.peerPublicKey) {
            peer["publicKey"] = .string(wireGuard.peerPublicKey)
        } else {
            context.note("settings.peerPublicKey", .invalid, .error, "WireGuard public key is not 32 bytes of base64 or hex")
        }
        if outbound.credentials.preSharedKey != nil,
           let key = resolve(outbound.credentials.preSharedKey, "credentials.preSharedKey", &context) {
            if XrayConfigCompiler.isWireGuardKey(key) {
                peer["preSharedKey"] = .string(key)
            } else {
                context.note("credentials.preSharedKey", .invalid, .error, "WireGuard pre-shared key is not 32 bytes of base64 or hex")
            }
        }
        if let keepalive = wireGuard.persistentKeepaliveSeconds, keepalive > 0 {
            peer["keepAlive"] = .integer(Int64(keepalive))
        }
        if !wireGuard.allowedIPs.isEmpty {
            peer["allowedIPs"] = .array(wireGuard.allowedIPs.map { .string($0) })
        }
        settings["peers"] = .array([.object(peer)])
        if wireGuard.localAddresses.isEmpty {
            context.note("settings.localAddresses", .approximated, .warning, "No interface address is set; Xray substitutes placeholder addresses")
        } else {
            settings["address"] = .array(wireGuard.localAddresses.map { .string($0) })
        }
        if let mtu = wireGuard.mtu, mtu > 0 {
            settings["mtu"] = .integer(Int64(mtu))
        }
        if !wireGuard.reserved.isEmpty {
            if wireGuard.reserved.count == 3 {
                settings["reserved"] = .array(wireGuard.reserved.map { .integer(Int64($0)) })
            } else {
                context.note("settings.reserved", .invalid, .error, "WireGuard 'reserved' must be empty or exactly 3 bytes")
            }
        }
        return settings
    }

    private func buildHysteria2Stream(
        _ hysteria: Hysteria2Settings,
        outbound: Outbound,
        resolve: (SecretValue?, String, inout XrayOutboundContext) -> String?,
        context: inout XrayOutboundContext
    ) -> [String: JSONValue] {
        var preset = XrayStreamCompiler.Parts()
        preset.fields["network"] = .string("hysteria")
        var hysteriaSettings: [String: JSONValue] = ["version": .integer(2)]
        if outbound.credentials.password != nil {
            if let auth = resolve(outbound.credentials.password, "credentials.password", &context) {
                hysteriaSettings["auth"] = .string(auth)
            }
        }
        preset.fields["hysteriaSettings"] = .object(hysteriaSettings)

        if outbound.stream.transport.kind != .native {
            context.note("stream.transport", .invalid, .error, "Hysteria2 carries its own transport")
        }
        var stream = outbound.stream
        switch stream.security {
        case .tls(let tls):
            if tls.pinnedPeerCertificateSHA256 != nil {
                context.note(
                    "stream.security.pinnedPeerCertificateSHA256", .approximated, .warning,
                    "Hysteria checks a pin in addition to the certificate chain; Xray accepts a matching leaf pin without checking the chain"
                )
            }
        case .none:
            stream.security = .tls(TLSSettings())
            context.note("stream.security", .migrated, .info, "Hysteria2 always uses TLS")
        case .reality:
            context.note("stream.security", .unsupported, .error, "Hysteria2 cannot use REALITY")
        }

        if let obfuscation = hysteria.obfuscation {
            switch obfuscation.type.lowercased() {
            case "salamander":
                if let password = resolve(obfuscation.password, "settings.obfuscation.password", &context) {
                    if password.utf8.count < 4 {
                        context.note("settings.obfuscation.password", .invalid, .error, "Salamander password must be at least 4 bytes")
                    }
                    preset.udpMasks.append(.object([
                        "type": .string("salamander"),
                        "settings": .object(["password": .string(password)]),
                    ]))
                }
            case "gecko":
                context.note(
                    "settings.obfuscation", .unsupported, .error,
                    "Gecko obfuscation needs a packet size range that the model does not carry"
                )
            default:
                context.note("settings.obfuscation", .unsupported, .error, "Unknown Hysteria2 obfuscation '\(obfuscation.type)'")
            }
        }

        if !hysteria.serverPorts.isEmpty {
            let ports = hysteria.serverPorts
                .map { $0.isSinglePort ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }
                .joined(separator: ",")
            var hop: [String: JSONValue] = [
                "mode": .string("intervalLocal,intervalRemote"),
                "remotePorts": .string(ports),
            ]
            if let interval = hysteria.hopIntervalSeconds {
                if interval < 5 {
                    context.note("settings.hopIntervalSeconds", .invalid, .error, "Port hopping interval must be at least 5 seconds")
                }
                hop["interval"] = .integer(Int64(interval))
            }
            // Masks wrap the socket in reverse order; hopping must be the last one (libXray does the same).
            preset.udpMasks.append(.object(["type": .string("udphop"), "settings": .object(hop)]))
        } else if hysteria.hopIntervalSeconds != nil {
            context.note("settings.hopIntervalSeconds", .dropped, .warning, "A hop interval without a port list has no effect")
        }

        var quic: [String: JSONValue] = [:]
        for (name, key, value) in [
            ("uploadBandwidth", "brutalUp", hysteria.uploadBandwidth),
            ("downloadBandwidth", "brutalDown", hysteria.downloadBandwidth),
        ] {
            guard let value = value, !value.isEmpty else { continue }
            switch XrayConfigCompiler.bandwidthBytesPerSecond(value) {
            case .some(let rate) where rate >= 65_536:
                quic[key] = .string(value)
            case .some:
                context.note("settings.\(name)", .dropped, .warning, "Bandwidth is below the Xray minimum of 65536 bytes per second and is not applied")
            case .none:
                context.note("settings.\(name)", .dropped, .warning, "Bandwidth has no unit Xray understands (a bare number is ambiguous between clients) and is not applied")
            }
        }
        if !quic.isEmpty {
            quic["congestion"] = .string("brutal")
        }
        if options.memoryProfile == .mobile {
            for (key, value) in XrayConfigCompiler.mobileQUICWindows {
                quic[key] = .integer(value)
            }
            context.note(
                "stream.quic", .migrated, .info,
                "Mobile memory profile: QUIC receive windows are capped at \((XrayConfigCompiler.mobileQUICWindows["maxConnectionReceiveWindow"] ?? 0) >> 20) MiB per connection"
            )
        }
        if !quic.isEmpty {
            preset.quicParams = quic
        }

        return XrayStreamCompiler.compile(
            stream, server: outbound.server, extras: outbound.extras,
            sniDefaultFromHost: false, subpath: "stream", preset: preset,
            resolve: resolve, context: &context
        )
    }

    /// Bytes per second as `conf.Bandwidth.Bps` computes it; `nil` for a bare number or an unknown unit.
    static func bandwidthBytesPerSecond(_ text: String) -> UInt64? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = lowered.prefix { ($0 >= "0" && $0 <= "9") || $0 == "." }
        let unit = lowered.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits), value >= 0, value < 1e12 else { return nil }
        let multiplier: Double
        switch unit {
        case "b", "bps": multiplier = 1
        case "k", "kb", "kbps": multiplier = 1e3
        case "m", "mb", "mbps": multiplier = 1e6
        case "g", "gb", "gbps": multiplier = 1e9
        case "t", "tb", "tbps": multiplier = 1e12
        default: return nil
        }
        return UInt64(value * multiplier) / 8
    }

    /// Mirrors `conf.ParseWireGuardKey`: 64 hex digits or base64 (either alphabet); 32 bytes expected.
    static func isWireGuardKey(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        if bytes.count == 64 && bytes.allSatisfy({ PercentCoding.hexValue($0) != nil }) {
            return true
        }
        return LenientBase64.decode(text)?.count == 32
    }

    /// Mirrors `requiresTransportSecurity` in `infra/conf/xray.go`.
    static func isPublicAddress(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if XrayStreamCompiler.isIPLiteral(lowered) {
            if lowered.utf8.contains(0x3A) {
                if lowered == "::1" { return false }
                let head = lowered.prefix(4)
                if head.hasPrefix("fc") || head.hasPrefix("fd") { return false }
                if head.hasPrefix("fe8") || head.hasPrefix("fe9") || head.hasPrefix("fea") || head.hasPrefix("feb") {
                    return false
                }
                return true
            }
            let octets = lowered.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return true }
            if octets[0] == 10 || octets[0] == 127 { return false }
            if octets[0] == 172 && (16...31).contains(octets[1]) { return false }
            if octets[0] == 192 && octets[1] == 168 { return false }
            if octets[0] == 169 && octets[1] == 254 { return false }
            return true
        }
        var domain = lowered
        if domain.hasSuffix(".") { domain.removeLast() }
        if !domain.contains(".") { return false }
        for suffix in ["lan", "localdomain", "example", "invalid", "localhost", "test", "local", "home.arpa", "internal"] {
            if domain == suffix || domain.hasSuffix("." + suffix) { return false }
        }
        return true
    }

    // MARK: - Leftovers

    /// Parameters the importer recorded but could not apply are not in the output either.
    private func reportLeftovers(_ outbound: Outbound, context: inout XrayOutboundContext) {
        for parameter in outbound.unsupported where parameter.disposition == .recorded {
            if parameter.reason == .duplicate { continue }
            context.note(
                "unsupported[\(parameter.name)]", .dropped, .warning,
                "Imported parameter '\(parameter.name)' (\(parameter.reason.rawValue)) is not part of the configuration"
            )
        }
    }

    private func noteUnusedExtras(_ outbound: Outbound, usedXrayKeys: Set<String>, context: inout XrayOutboundContext) {
        for engine in outbound.extras.storage.keys.sorted() {
            guard let bucket = outbound.extras.storage[engine] else { continue }
            for key in bucket.keys.sorted() {
                if engine == EngineID.xray.rawValue {
                    if usedXrayKeys.contains(key) { continue }
                    context.note("extras.\(engine).\(key)", .dropped, .warning, "This Xray extra has no place in the compiled outbound")
                } else {
                    context.note("extras.\(engine).\(key)", .dropped, .info, "Extra bound to another engine is not used by Xray")
                }
            }
        }
    }
}
