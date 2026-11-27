import Foundation
import DomainModels
import RoutingEngine

/// Memory-related shape of a compiled Mihomo configuration.
public enum MihomoMemoryProfile: String, Codable, Hashable, Sendable {
    /// The core's own defaults.
    case standard
    /// For a process with a memory budget of about 50 MiB (an iOS packet tunnel provider): capped QUIC
    /// receive windows for Hysteria2 and TUIC, lazy health checks with a long interval, no TCP concurrent
    /// dialing, no geodata. The bridge's runtime side of the same profile (memory limit, GC, queues, flow cap,
    /// idle timeouts) is the bridge option `memory.profile = "mobile"`; those numbers live only in the bridge.
    case mobile
}

/// Inputs of a Mihomo compilation that are not part of `Profile`.
public struct MihomoCompileOptions: Codable, Hashable, Sendable {
    /// `debug`, `info`, `warning`, `error` or `none` (written as Mihomo's `silent`).
    public var logLevel: String
    /// Loopback SOCKS5 inbound (`socks-port`) for the lab and desktop use; `nil` emits none. The Packet Tunnel
    /// extension never opens a port (ADR-0003).
    public var localSOCKSPort: UInt16?
    /// DNS servers in Xray notation (`1.1.1.1`, `tcp://1.1.1.1`, `https://dns.example/dns-query`); queried
    /// through the selected route. With a tunnel and no servers, `XrayConfigCompiler.defaultTunnelDNSServers`.
    public var dnsServers: [String]
    /// `false` (default): the resolver answers with real addresses and remembers address → domain for
    /// the rules (`enhanced-mode: redir-host`). `true`: fake addresses (`fake-ip`).
    public var fakeIP: Bool
    public var memoryProfile: MihomoMemoryProfile
    /// Addresses of the packet tunnel; `nil` emits no `tun` section.
    public var tunnel: TunnelAddressing?
    /// Routing rules (RoutingEngine). `nil`: everything goes to the selected route.
    public var routing: RoutingTable?

    public init(
        logLevel: String = "warning",
        localSOCKSPort: UInt16? = nil,
        dnsServers: [String] = [],
        fakeIP: Bool = false,
        memoryProfile: MihomoMemoryProfile = .standard,
        tunnel: TunnelAddressing? = nil,
        routing: RoutingTable? = nil
    ) {
        self.logLevel = logLevel
        self.localSOCKSPort = localSOCKSPort
        self.dnsServers = dnsServers
        self.fakeIP = fakeIP
        self.memoryProfile = memoryProfile
        self.tunnel = tunnel
        self.routing = routing
    }

    /// Options for the Packet Tunnel extension: the tunnel with the shared addresses and the mobile profile
    /// (the extension runs the bridge with `memory.profile = "mobile"`).
    public static func packetTunnel(
        dnsServers: [String] = [],
        addressing: TunnelAddressing = .standard,
        routing: RoutingTable? = nil,
        logLevel: String = "warning"
    ) -> MihomoCompileOptions {
        MihomoCompileOptions(
            logLevel: logLevel, dnsServers: dnsServers, memoryProfile: .mobile, tunnel: addressing, routing: routing
        )
    }
}

public struct MihomoCompilation: Sendable {
    /// `nil` when the verdict is `.blocked`.
    public var document: YAMLNode?
    public var report: ConversionReport
    /// Set when compiled with a tunnel and not blocked. Same shape as for Xray: the interface settings do
    /// not depend on the engine.
    public var tunnel: XrayTunnelPlan?

    public init(document: YAMLNode?, report: ConversionReport, tunnel: XrayTunnelPlan? = nil) {
        self.document = document
        self.report = report
        self.tunnel = tunnel
    }

    /// Deterministic YAML text. Contains credentials: never log it.
    public func yamlText() -> String? {
        return document.map { YAMLEmitter.emit($0) }
    }
}

/// Compiles the engine-neutral model into a Mihomo (Clash) YAML configuration for `Cores/MihomoBridge`
/// (ADR-0002, ADR-0007; `Documentation/Architecture/mihomo-config.md`).
///
/// Every difference between the model and the output is in the report. An outbound with an `.error` issue is
/// left out and named in `excludedOutbounds`; routing that cannot be written exactly blocks the compilation,
/// because a partial rule list routes differently from what the simulator shows (`RuleLowering`).
/// Pure function of its inputs.
public struct MihomoConfigCompiler: Sendable {
    /// Mihomo release whose sources the keys below were read from (`Cores/MihomoBridge/go.mod`).
    public static let engineVersion = "1.19.34"

    /// Built-in targets of the core.
    public static let directTarget = "DIRECT"
    public static let rejectTarget = "REJECT"
    /// `tun.dns-hijack`: every DNS query sent into the tunnel, to any address, over UDP or TCP, is answered by
    /// the core's resolver (`listener/sing_tun/dns.go`: an unspecified address matches any destination on 53).
    public static let dnsHijack = ["any:53", "tcp://any:53"]
    /// Health-check interval of groups in the mobile profile, when the model names none (seconds). Project choice.
    public static let mobileHealthCheckIntervalSeconds = 600
    /// Default health check URL of the core (`constant/adapters.go` DefaultTestURL).
    public static let defaultHealthCheckURL = "https://www.gstatic.com/generate_204"

    public typealias SecretResolver = @Sendable (SecretReference) -> String?

    public var options: MihomoCompileOptions
    let resolver: SecretResolver?

    public init(options: MihomoCompileOptions = MihomoCompileOptions(), resolveSecret: SecretResolver? = nil) {
        self.options = options
        self.resolver = resolveSecret
    }

    static func padded(_ index: Int, width: Int = 4) -> String {
        let text = String(index)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    // MARK: - Profile

    public func compile(_ profile: Profile) -> MihomoCompilation {
        var report = ConversionReport(engine: .mihomo, engineVersion: MihomoConfigCompiler.engineVersion)
        for issue in profile.validate() {
            report.add("profile", .invalid, .error, "Profile is inconsistent (\(issue.kind.rawValue)) at tag '\(issue.tag)'")
        }
        let structurallyValid = report.issues.isEmpty
        func blocked() -> MihomoCompilation {
            report.verdict = .blocked
            return MihomoCompilation(document: nil, report: report)
        }

        // Proxies.
        let width = max(4, String(profile.outbounds.count).count)
        var proxies: [YAMLNode] = []
        var proxyByTag: [String: [YAMLPair]] = [:]
        var names: [String: String] = [:]
        for (index, outbound) in profile.outbounds.enumerated() {
            let name = "proxy-" + MihomoConfigCompiler.padded(index, width: width)
            let result = compileOutbound(outbound, name: name, path: "outbounds[\(index)]")
            report.issues.append(contentsOf: result.issues)
            if let pairs = result.pairs, !outbound.tag.isEmpty, names[outbound.tag] == nil {
                proxies.append(.mapping(pairs))
                proxyByTag[outbound.tag] = pairs
                names[outbound.tag] = name
            } else {
                report.excludedOutbounds.append(outbound.tag)
            }
        }
        guard structurallyValid else { return blocked() }

        // Groups.
        let groups = compileGroups(profile, names: &names, report: &report)

        // Main route: what the resolver's own queries and, without routing rules, all traffic use.
        var selected = profile.selectedTag
        if selected == nil {
            guard let first = profile.outbounds.first else {
                report.add("profile.outbounds", .invalid, .error, "Profile has no outbounds")
                return blocked()
            }
            selected = first.tag
            report.add("profile.selectedTag", .migrated, .info, "Nothing is selected; the first outbound is used")
        }
        guard let selectedTag = selected, let mainTarget = names[selectedTag] else {
            report.add("profile.selectedTag", .unsupported, .error, "The selected outbound or group could not be compiled")
            return blocked()
        }
        report.engineTags = names

        var root = YAMLMappingBuilder()
        root.set("mode", "rule")
        root.set("log-level", logLevel(&report))
        root.set("ipv6", options.tunnel.map { $0.ipv6Address != nil } ?? true)
        root.set("allow-lan", false)
        if let port = options.localSOCKSPort {
            root.set("bind-address", "127.0.0.1")
            root.set("socks-port", Int(port))
        }
        // The bridge forces these; the compiler writes them so that its output and the bridge agree
        // (`ConfigSummary.overridden` stays empty).
        root.set("find-process-mode", "off")
        root.set("profile", YAMLNode.mapping([
            YAMLPair("store-selected", .bool(false)), YAMLPair("store-fake-ip", .bool(false)),
        ]))
        root.set("unified-delay", true)
        root.set("tcp-concurrent", false)
        root.set("geo-auto-update", false)
        if options.memoryProfile == .mobile {
            report.add(
                "options.memoryProfile", .migrated, .info,
                "Mobile memory profile: QUIC receive windows capped, group health checks lazy every \(MihomoConfigCompiler.mobileHealthCheckIntervalSeconds) s unless the model sets an interval"
            )
        }

        // Tunnel and DNS.
        var tunnelPlan: XrayTunnelPlan?
        var dnsServers = options.dnsServers
        if let addressing = options.tunnel {
            guard (576...65_535).contains(addressing.mtu) else {
                report.add("options.tunnel.mtu", .invalid, .error, "Tunnel MTU is outside 576...65535")
                return blocked()
            }
            if dnsServers.isEmpty {
                dnsServers = XrayConfigCompiler.defaultTunnelDNSServers
                report.add(
                    "options.dnsServers", .migrated, .info,
                    "No DNS servers given; the tunnel resolves through \(dnsServers.count) default public resolvers, queried through the proxy"
                )
            }
            tunnelPlan = tunnelExclusions(profile, names: names, addressing: addressing, report: &report)
        }
        var dnsSection: YAMLNode?
        if !dnsServers.isEmpty {
            guard let dns = compileDNS(dnsServers, mainTarget: mainTarget, profile: profile, names: names, report: &report) else {
                return blocked()
            }
            dnsSection = dns
        }
        if let addressing = options.tunnel {
            var tun = YAMLMappingBuilder()
            tun.set("enable", true)
            tun.set("stack", "mips")
            tun.set("mtu", addressing.mtu)
            tun.set("dns-hijack", strings: MihomoConfigCompiler.dnsHijack)
            // The core derives the tun's IPv4 address from dns.fake-ip-range (config.go parseTun); IPv6 is set here.
            if let v6 = addressing.ipv6Address, let length = addressing.ipv6PrefixLength {
                tun.set("inet6-address", strings: ["\(v6)/\(length)"])
            } else {
                tun.set("inet6-address", YAMLNode.sequence([]))
            }
            tun.set("auto-route", false)
            tun.set("auto-detect-interface", false)
            root.set("tun", tun.node)
            if addressing.dnsIPv4Address != MihomoConfigCompiler.nextAddress(addressing.ipv4Address)
                || (addressing.dnsIPv6Address != nil && addressing.dnsIPv6Address != addressing.ipv6Address.flatMap(MihomoConfigCompiler.nextAddress)) {
                report.add(
                    "options.tunnel.dnsIPv4Address", .approximated, .info,
                    "The resolver address is not the one after the tunnel address; it is still answered, through the port-53 hijack of any address"
                )
            }
        }
        if let dns = dnsSection {
            root.set("dns", dns)
        }

        root.set("proxies", YAMLNode.sequence(proxies))

        // Rules (chains may add proxies).
        var chainProxies: [YAMLNode] = []
        var rules: [String] = []
        if let plan = tunnelPlan {
            for route in plan.excludedRoutes {
                rules.append("\(route.isIPv6 ? "IP-CIDR6" : "IP-CIDR"),\(route.cidr),\(MihomoConfigCompiler.directTarget),no-resolve")
            }
        }
        if let table = options.routing {
            var compiler = MihomoRuleCompiler(profile: profile, names: names, proxyByTag: proxyByTag)
            guard let lowered = compiler.compile(table, report: &report) else { return blocked() }
            rules += lowered
            chainProxies = compiler.chainProxies
        } else {
            rules.append("MATCH,\(mainTarget)")
        }
        if !chainProxies.isEmpty {
            root.set("proxies", YAMLNode.sequence(proxies + chainProxies))
        }
        if !groups.isEmpty {
            root.set("proxy-groups", YAMLNode.sequence(groups))
        }
        root.set("rules", strings: rules)

        report.verdict = report.issues.contains { $0.severity != .info } ? .degraded : .exact
        return MihomoCompilation(document: root.node, report: report, tunnel: tunnelPlan)
    }

    private func logLevel(_ report: inout ConversionReport) -> String {
        switch options.logLevel {
        case "debug", "info", "warning", "error": return options.logLevel
        case "none": return "silent"
        default:
            report.add("options.logLevel", .invalid, .warning, "Unknown log level; 'warning' is used")
            return "warning"
        }
    }

    /// The address after `text` (IPv4 or IPv6), as the bridge computes the hijacked resolver address.
    static func nextAddress(_ text: String) -> String? {
        guard let address = IPAddress(text) else { return nil }
        switch address {
        case .v4(let value):
            return value == UInt32.max ? nil : IPAddress.v4(value + 1).description
        case .v6(let high, let low):
            let (newLow, overflow) = low.addingReportingOverflow(1)
            return IPAddress.v6(high: overflow ? high &+ 1 : high, low: newLow).description
        }
    }

    // MARK: - Tunnel exclusions

    private func tunnelExclusions(
        _ profile: Profile,
        names: [String: String],
        addressing: TunnelAddressing,
        report: inout ConversionReport
    ) -> XrayTunnelPlan {
        var servers: [TunnelRoute] = []
        var named = 0
        for outbound in profile.outbounds where names[outbound.tag] != nil {
            var hosts = [outbound.server.host]
            if case .xhttp(let xhttp) = outbound.stream.transport, let download = xhttp.download {
                hosts.append(download.server.host)
            }
            for host in hosts {
                if XrayStreamCompiler.isIPLiteral(host) {
                    let route = TunnelRoute.host(host)
                    if !servers.contains(route) { servers.append(route) }
                } else {
                    named += 1
                }
            }
        }
        if named > 0 {
            report.add(
                "options.tunnel", .untested, .info,
                "\(named) server address(es) are domains: their addresses are not known before the tunnel starts and cannot be excluded from it; the system is expected to keep the extension's own connections out of its tunnel"
            )
        }
        let remote = servers.first?.address ?? addressing.ipv4Address
        return XrayTunnelPlan(addressing: addressing, excludedRoutes: servers + TunnelAddressing.localRoutes, remoteAddress: remote)
    }

    // MARK: - DNS

    /// Default resolvers used to resolve DoH/DoT host names and proxy server names when the options name no
    /// resolver given as an address. A project choice (the same as the tunnel's defaults).
    static let fallbackResolverAddresses = XrayConfigCompiler.defaultTunnelDNSServers

    private func compileDNS(
        _ servers: [String],
        mainTarget: String,
        profile: Profile,
        names: [String: String],
        report: inout ConversionReport
    ) -> YAMLNode? {
        var nameservers: [String] = []
        var addressServers: [String] = []
        var failed = false
        for (index, server) in servers.enumerated() {
            let path = "options.dnsServers[\(index)]"
            guard let converted = MihomoConfigCompiler.mihomoDNSServer(server) else {
                if XrayConfigCompiler.bypassesRouting(dnsServer: server) {
                    report.add(path, .unsupported, .error, "This DNS server would be queried outside the tunnel (system resolver or a '+local' scheme)")
                } else {
                    report.add(path, .unsupported, .error, "Mihomo has no equivalent of this DNS server notation")
                }
                failed = true
                continue
            }
            nameservers.append(converted.server + "#" + mainTarget)
            if converted.isAddress { addressServers.append(converted.server) }
        }
        guard !failed else { return nil }
        let bootstrap = addressServers.isEmpty
            ? MihomoConfigCompiler.fallbackResolverAddresses : addressServers
        var dns = YAMLMappingBuilder()
        dns.set("enable", true)
        dns.set("ipv6", options.tunnel.map { $0.ipv6Address != nil } ?? true)
        dns.set("use-system-hosts", false)
        if options.fakeIP {
            dns.set("enhanced-mode", "fake-ip")
            report.add(
                "options.fakeIP", .untested, .info,
                "Fake-IP: apps get addresses from a private pool and the domain is restored by the core; not covered by the end-to-end lab run"
            )
        } else {
            dns.set("enhanced-mode", "redir-host")
        }
        if let addressing = options.tunnel {
            // Also the tun's IPv4 address (the prefix's own address, length /30) — see config.go parseTun.
            dns.set("fake-ip-range", "\(addressing.ipv4Address)/\(options.fakeIP ? 16 : addressing.ipv4PrefixLength)")
            if options.fakeIP && addressing.ipv4PrefixLength != 30 {
                report.add("options.tunnel.ipv4PrefixLength", .approximated, .warning, "Mihomo gives the tun a /30 regardless of the configured prefix")
            }
        } else if options.fakeIP {
            dns.set("fake-ip-range", "198.18.0.1/16")
        }
        // Every query, including those that resolve DoH host names, goes through the selected route.
        dns.set("default-nameserver", strings: bootstrap.map { $0 + "#" + mainTarget })
        dns.set("nameserver", strings: nameservers)
        let namedServers = profile.outbounds.filter {
            names[$0.tag] != nil && !XrayStreamCompiler.isIPLiteral($0.server.host)
        }.count
        if namedServers > 0 {
            // Resolving a proxy server's name through the proxy itself would never complete.
            dns.set("proxy-server-nameserver", strings: bootstrap)
            report.add(
                "options.dnsServers", .approximated, .info,
                "\(namedServers) server(s) are named by a domain: their names are resolved directly (proxy-server-nameserver), not through the tunnel"
            )
        }
        return dns.node
    }

    /// A DNS server in Mihomo notation, or `nil` when it has none or would bypass routing.
    static func mihomoDNSServer(_ text: String) -> (server: String, isAddress: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !XrayConfigCompiler.bypassesRouting(dnsServer: trimmed), !trimmed.contains("#") else { return nil }
        if IPAddress(trimmed) != nil {
            return (trimmed.contains(":") ? "[\(trimmed)]" : trimmed, true)
        }
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard ["udp", "tcp", "tls", "https", "quic"].contains(scheme) else { return nil }
        let rest = trimmed[schemeEnd.upperBound...]
        var host = String(rest.prefix { $0 != "/" && $0 != "?" })
        if host.hasPrefix("[") {
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { return nil }
        return (scheme + "://" + rest, IPAddress(host) != nil)
    }

    // MARK: - Groups

    private func compileGroups(_ profile: Profile, names: inout [String: String], report: inout ConversionReport) -> [YAMLNode] {
        // A group can be emitted when at least one member can: emitted outbounds, then groups to a fixpoint.
        var emittable = Set<String>()
        var changed = true
        while changed {
            changed = false
            for group in profile.groups where !emittable.contains(group.tag) {
                let ok = group.members.contains { member in
                    switch member {
                    case .outbound(let tag): return names[tag] != nil
                    case .group(let tag): return emittable.contains(tag)
                    }
                }
                if ok {
                    emittable.insert(group.tag)
                    changed = true
                }
            }
        }
        for (index, group) in profile.groups.enumerated() where emittable.contains(group.tag) {
            names[group.tag] = "group-" + MihomoConfigCompiler.padded(index)
        }

        var result: [YAMLNode] = []
        for group in profile.groups {
            let path = "groups[\(group.tag)]"
            guard let name = names[group.tag] else {
                report.add(path, .dropped, .warning, "No member of the group could be compiled; the group is left out")
                continue
            }
            var members: [String] = []
            var lost = 0
            for member in group.members {
                if let memberName = names[member.tag] {
                    if !members.contains(memberName) { members.append(memberName) }
                } else {
                    lost += 1
                }
            }
            if lost > 0 {
                report.add(path, .dropped, .warning, "\(lost) member(s) could not be compiled and are left out")
            }
            var builder = YAMLMappingBuilder()
            builder.set("name", name)
            var usesHealthCheck = true
            switch group.kind {
            case .selector:
                builder.set("type", "select")
                usesHealthCheck = false
                if let defaultTag = group.defaultMemberTag, let defaultName = names[defaultTag],
                   let position = members.firstIndex(of: defaultName), position > 0 {
                    members.remove(at: position)
                    members.insert(defaultName, at: 0)
                    report.add(path, .migrated, .info, "The default member is listed first: a Mihomo selector starts on its first member")
                }
            case .urlTest:
                builder.set("type", "url-test")
            case .fallback:
                builder.set("type", "fallback")
            case .loadBalance:
                switch group.strategy ?? .random {
                case .roundRobin:
                    builder.set("type", "load-balance")
                    builder.set("strategy", "round-robin")
                case .consistentHashing:
                    builder.set("type", "load-balance")
                    builder.set("strategy", "consistent-hashing")
                case .random:
                    builder.set("type", "load-balance")
                    builder.set("strategy", "round-robin")
                    report.add(path, .approximated, .warning, "Mihomo has no random balancer; 'round-robin' is used")
                case .leastPing:
                    builder.set("type", "url-test")
                    report.add(path, .approximated, .warning, "Least-ping balancing is compiled to a Mihomo url-test group (lowest latency member)")
                case .leastLoad:
                    builder.set("type", "url-test")
                    report.add(path, .approximated, .warning, "Mihomo has no least-load balancer; a url-test group (lowest latency member) is used")
                }
            }
            builder.set("proxies", strings: members)
            if usesHealthCheck {
                if let check = group.healthCheck {
                    builder.set("url", check.url)
                    builder.set("interval", max(1, check.intervalSeconds))
                    builder.set("timeout", check.timeoutMilliseconds.map { max(1, $0) })
                    if let tolerance = check.toleranceMilliseconds {
                        if group.kind == .urlTest || (group.kind == .loadBalance && [.leastPing, .leastLoad].contains(group.strategy ?? .random)) {
                            builder.set("tolerance", max(0, tolerance))
                        } else {
                            report.add(path + ".healthCheck.toleranceMilliseconds", .dropped, .warning, "Only url-test groups have a latency tolerance in Mihomo")
                        }
                    }
                } else {
                    builder.set("url", MihomoConfigCompiler.defaultHealthCheckURL)
                    builder.set("interval", options.memoryProfile == .mobile ? MihomoConfigCompiler.mobileHealthCheckIntervalSeconds : 300)
                    report.add(path + ".healthCheck", .migrated, .info, "No health check is configured; the core's default URL is used")
                }
                builder.set("lazy", true)
            } else if group.healthCheck != nil {
                report.add(path + ".healthCheck", .dropped, .info, "A selector group does not probe its members")
            }
            result.append(builder.node)
        }
        return result
    }
}
