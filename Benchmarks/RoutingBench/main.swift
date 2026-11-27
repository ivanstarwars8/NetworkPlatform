// RoutingBench: release benchmark of RoutingEngine's compiled router.
//
// Usage:
//   swift run -c release RoutingBench --rules 100000 [--queries 200000]
//       [--seed 1] [--threads N] [--json out.json] [--skip-rebuild]
//       [--without-regex]
//
// --without-regex replaces the regular-expression rules of the mix with
// keyword rules. It exists to attribute lookup cost: patterns are the only
// rules that are still scanned in order on every lookup.
//
// One process measures one table size, so that resident-memory readings of
// different sizes do not contaminate each other. Methodology and results:
// Documentation/Performance/routing-benchmarks.md.
import Dispatch
import Foundation
import RoutingEngine

// MARK: - Helpers

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
}

func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }

/// Resident set size in bytes, or -1 when it cannot be read.
func residentBytes() -> Int {
    #if os(Linux)
    guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return -1 }
    let fields = text.split(separator: " ")
    guard fields.count > 1, let pages = Int(fields[1]) else { return -1 }
    return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    #else
    // Not implemented for other systems: the benchmark is run on Linux.
    return -1
    #endif
}

/// Peak resident set size of the process (VmHWM) in bytes, or -1.
func peakResidentBytes() -> Int {
    #if os(Linux)
    guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return -1 }
    for line in text.split(separator: "\n") where line.hasPrefix("VmHWM:") {
        let digits = line.filter { $0.isNumber }
        if let kilobytes = Int(digits) { return kilobytes * 1024 }
    }
    return -1
    #else
    return -1
    #endif
}

/// The memory limit of the control group, if any (cgroup v2, then v1).
func memoryLimitBytes() -> Int? {
    for path in ["/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"] {
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value < Int.max / 2 {
            return value
        }
    }
    return nil
}

func megabytes(_ bytes: Int) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

func progress(_ message: String) {
    FileHandle.standardError.write(Data(("[bench] " + message + "\n").utf8))
}

// MARK: - Workload

/// Generates a table with the mix of rule kinds found in real profiles:
/// mostly domain suffixes and exact names (block and direct lists), address
/// prefixes, and a minority of keywords, patterns, port rules and compound
/// rules. Values are spread widely, so that no early rule shadows the rest
/// of the table and a lookup has to consult every structure.
struct Workload {
    var rng: SplitMix64
    var withoutRegex = false
    static let topLevel = ["com", "net", "org", "io", "ru", "de", "cn", "co.uk", "app", "dev", "info", "xyz"]
    static let subs = ["www", "api", "cdn", "static", "img", "mail", "m", "edge", "login", "video"]

    /// Shares in parts per thousand, in the order of `kind(for:)`.
    static let mix: [(name: String, share: Int)] = [
        ("domainSuffix", 520), ("domainFull", 150), ("ipv4Prefix", 150), ("ipv6Prefix", 50),
        ("domainKeyword", 30), ("domainRegex", 5), ("strictSuffix", 5), ("port", 15),
        ("domainList", 20), ("domainAndPort", 20), ("prefixAndNetwork", 15), ("inboundAndDomain", 5),
        ("ipNotIn", 5), ("sourcePrefix", 5), ("userOrProtocol", 5),
    ]

    mutating func word(_ minimum: Int, _ maximum: Int) -> String {
        let length = minimum + rng.below(maximum - minimum + 1)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for _ in 0..<length { bytes.append(UInt8(97 + rng.below(26))) }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func registrable() -> String {
        word(5, 14) + (rng.below(8) == 0 ? "-" + word(2, 5) : "") + "." + rng.pick(Workload.topLevel)
    }

    mutating func v4Prefix() -> IPCIDR {
        let length = rng.pick([8, 12, 14, 16, 16, 18, 20, 22, 24, 24, 24, 28, 32])
        let address = UInt32(truncatingIfNeeded: rng.next())
        return IPCIDR(address: .v4(address), prefixLength: length)!
    }

    mutating func v6Prefix() -> IPCIDR {
        let length = rng.pick([29, 32, 32, 40, 48, 48, 56, 64, 64, 128])
        let high = (UInt64(0x2000) << 48) | (rng.next() >> 4)
        return IPCIDR(address: .v6(high: high, low: rng.next()), prefixLength: length)!
    }

    mutating func unusualPort() -> PortRange {
        let lower = 10000 + rng.below(50000)
        if rng.below(2) == 0 { return PortRange(UInt16(lower)) }
        return PortRange(lower: UInt16(lower), upper: UInt16(min(65535, lower + rng.below(20))))!
    }

    mutating func action() -> RouteAction {
        switch rng.below(10) {
        case 0, 1, 2: return .direct
        case 3, 4: return .reject
        case 5: return .group("auto")
        default: return .proxy("node-\(rng.below(8))")
        }
    }

    mutating func condition(kind: String) -> RuleCondition {
        switch kind {
        case "domainSuffix": return .domainSuffix(registrable())
        case "domainFull": return .domain(rng.pick(Workload.subs) + "." + registrable())
        case "ipv4Prefix": return .ipCIDR(v4Prefix())
        case "ipv6Prefix": return .ipCIDR(v6Prefix())
        case "domainKeyword": return .domainKeyword(word(7, 10))
        case "domainRegex":
            return .domainRegex(rng.pick([
                "^" + word(6, 8) + "[0-9]+\\.", "\\." + word(6, 8) + "-[a-z]{2,4}\\.(com|net)$",
                "^(ads?|track)[0-9]*\\." + word(6, 9) + "\\.", word(7, 9) + "\\d{2,}",
            ]))
        case "strictSuffix": return .domainSuffix("." + registrable())
        case "port": return .port(unusualPort())
        case "domainList":
            var items: [RuleCondition] = []
            for _ in 0..<(5 + rng.below(16)) { items.append(.domainSuffix(registrable())) }
            return .or(items)
        case "domainAndPort": return .and([.domainSuffix(registrable()), .port(PortRange(UInt16(rng.pick([80, 443, 8443]))))])
        case "prefixAndNetwork": return .and([.ipCIDR(v4Prefix()), .network(rng.below(2) == 0 ? .udp : .tcp)])
        case "inboundAndDomain": return .and([.inboundTag("in-\(rng.below(4))"), .domainSuffix(registrable())])
        case "ipNotIn": return .and([.ipNotIn([v4Prefix(), v4Prefix()]), .port(unusualPort())])
        case "sourcePrefix": return .and([.sourceCIDR(v4Prefix()), .port(unusualPort())])
        default:
            return rng.below(2) == 0 ? .user(word(5, 9) + "@" + registrable()) : .and([.sniffedProtocol("bittorrent"), .port(unusualPort())])
        }
    }

    mutating func table(ruleCount: Int) -> (table: RoutingTable, kinds: [String: Int]) {
        var wheel: [String] = []
        for entry in Workload.mix {
            for _ in 0..<entry.share { wheel.append(entry.name) }
        }
        precondition(wheel.count == 1000)
        var rules: [RoutingRule] = []
        rules.reserveCapacity(ruleCount)
        var kinds: [String: Int] = [:]
        for _ in 0..<ruleCount {
            var kind = rng.pick(wheel)
            if withoutRegex && kind == "domainRegex" { kind = "domainKeyword" }
            kinds[kind, default: 0] += 1
            rules.append(RoutingRule(condition: condition(kind: kind), action: action()))
        }
        return (RoutingTable(rules: rules, finalAction: .proxy("final")), kinds)
    }

    /// Queries: about half are built from a rule (and normally hit it or an
    /// earlier one), half are unrelated names and addresses that fall
    /// through to the final action - the worst case for an ordered list.
    mutating func queries(count: Int, table: RoutingTable) -> [RouteRequest] {
        var result: [RouteRequest] = []
        result.reserveCapacity(count)
        let rules = table.rules
        while result.count < count {
            let port = UInt16(rng.pick([443, 443, 443, 80, 8080, 53, 5222]))
            let network: NetworkKind = rng.below(5) == 0 ? .udp : .tcp
            var domain: String?
            var ip: IPAddress?
            if rng.below(2) == 0, !rules.isEmpty {
                var condition = rules[rng.below(rules.count)].condition
                if case let .or(items) = condition, let first = items.first { condition = first }
                if case let .and(items) = condition, let first = items.first { condition = first }
                switch condition {
                case let .domainSuffix(name):
                    let bare = name.hasPrefix(".") ? String(name.dropFirst()) : name
                    domain = rng.below(3) == 0 ? bare : rng.pick(Workload.subs) + "." + bare
                case let .domain(name): domain = name
                case let .ipCIDR(prefix): ip = prefix.network
                default: break
                }
            }
            if domain == nil && ip == nil {
                if rng.below(4) == 0 {
                    ip = .v4(UInt32(truncatingIfNeeded: rng.next()))
                } else {
                    domain = rng.pick(Workload.subs) + "." + registrable()
                }
            }
            result.append(RouteRequest(domain: domain, ip: ip, port: port, network: network, inboundTag: "in-\(rng.below(4))"))
        }
        return result
    }
}

// MARK: - Measurement

struct Percentiles: Codable {
    var samples: Int
    var meanNs: Double
    var medianNs: UInt64
    var p95Ns: UInt64
    var p99Ns: UInt64
    var maxNs: UInt64

    init(_ values: [UInt64]) {
        let sorted = values.sorted()
        samples = sorted.count
        func at(_ fraction: Double) -> UInt64 {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        meanNs = sorted.isEmpty ? 0 : Double(sorted.reduce(0, +)) / Double(sorted.count)
        medianNs = at(0.50)
        p95Ns = at(0.95)
        p99Ns = at(0.99)
        maxNs = sorted.last ?? 0
    }
}

struct Report: Codable {
    var ruleCount: Int
    var seed: UInt64
    var queryCount: Int
    var buildConfiguration: String
    var withoutRegex: Bool
    var cpuCount: Int
    var memoryLimitMB: Double?
    var ruleKinds: [String: Int]
    var tableGenerationMs: Double
    var indexBuildMs: Double
    var coldFirstQueryNs: UInt64
    var clockOverheadNs: UInt64
    var perQueryAll: Percentiles
    var perQueryMatched: Percentiles
    var perQueryFinal: Percentiles
    var matchedShare: Double
    var singleThreadQueriesPerSecond: Double
    var threads: Int
    var concurrentQueriesPerSecond: Double
    var rssBaselineMB: Double
    var rssAfterTableMB: Double
    var rssAfterIndexMB: Double
    var indexRssDeltaMB: Double
    var totalRssDeltaMB: Double
    var fullRebuildMs: Double?
    var rssPeakDuringRebuildMB: Double?
    /// VmHWM before the rebuild: table, index and query set.
    var rssPeakBeforeRebuildMB: Double
    /// VmHWM at exit; with a rebuild it includes the moment when the old
    /// and the new router coexist.
    var rssPeakMB: Double
    var incrementalUpdate: String
    var domainTrieNodes: Int
    var cidrTrieNodes: Int
    var portSegments: Int
    var fallbackRules: Int
    var anchoredFallbackEntries: Int
    var unanchoredFallbackEntries: Int
    var checksum: Int
}

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let position = arguments.firstIndex(of: name), position + 1 < arguments.count else { return nil }
    return arguments[position + 1]
}

func run() throws {
    guard let ruleCount = argument("--rules").flatMap({ Int($0) }), ruleCount > 0 else {
        print("usage: RoutingBench --rules N [--queries Q] [--seed S] [--threads T] [--json path] [--skip-rebuild] [--without-regex]")
        exit(2)
    }
    let queryCount = argument("--queries").flatMap { Int($0) } ?? 200_000
    let seed = argument("--seed").flatMap { UInt64($0) } ?? 1
    let threads = argument("--threads").flatMap { Int($0) } ?? ProcessInfo.processInfo.activeProcessorCount
    let skipRebuild = CommandLine.arguments.contains("--skip-rebuild")
    #if DEBUG
    let configuration = "debug"
    #else
    let configuration = "release"
    #endif

    // The default rule limit of the module is a project limit for imported
    // profiles; the benchmark raises it explicitly to measure beyond it.
    let limits = RoutingLimits(maximumRules: max(ruleCount, 500_000), maximumConditionNodes: max(2_000_000, ruleCount * 8))

    let rssBaseline = residentBytes()
    var workload = Workload(rng: SplitMix64(state: seed), withoutRegex: CommandLine.arguments.contains("--without-regex"))
    var started = nowNanoseconds()
    var generated = workload.table(ruleCount: ruleCount)
    let generationNs = nowNanoseconds() - started
    let rssTable = residentBytes()
    progress("table: \(ruleCount) rules in \(milliseconds(generationNs)) ms, rss \(megabytes(rssTable)) MB")

    started = nowNanoseconds()
    var router = try CompiledRouter(table: generated.table, limits: limits)
    let buildNs = nowNanoseconds() - started
    let rssIndex = residentBytes()
    progress("index: \(milliseconds(buildNs)) ms, rss \(megabytes(rssIndex)) MB, fallback \(router.statistics.fallbackRules)")

    let queries = workload.queries(count: queryCount, table: generated.table)

    // Cold start: the very first lookup after construction.
    started = nowNanoseconds()
    let first = router.match(queries[0])
    let coldNs = nowNanoseconds() - started
    var checksum = first.ruleIndex ?? -1

    var clockSamples: [UInt64] = []
    for _ in 0..<10_000 {
        let before = nowNanoseconds()
        clockSamples.append(nowNanoseconds() - before)
    }
    let clockOverhead = Percentiles(clockSamples).medianNs

    for query in queries.prefix(min(20_000, queries.count)) { _ = router.match(query) } // warm-up

    var all: [UInt64] = []
    var matched: [UInt64] = []
    var final: [UInt64] = []
    all.reserveCapacity(queryCount)
    for query in queries {
        let before = nowNanoseconds()
        let decision = router.match(query)
        let elapsed = nowNanoseconds() - before
        all.append(elapsed)
        if let index = decision.ruleIndex {
            matched.append(elapsed)
            checksum = checksum &+ index
        } else {
            final.append(elapsed)
        }
    }

    started = nowNanoseconds()
    for query in queries { _ = router.match(query) }
    let singleNs = nowNanoseconds() - started
    let singleRate = Double(queryCount) / (Double(singleNs) / 1e9)

    let shared = router
    started = nowNanoseconds()
    DispatchQueue.concurrentPerform(iterations: threads) { worker in
        var local = 0
        var position = worker * 7919 % queries.count
        for _ in 0..<queries.count {
            if shared.match(queries[position]).ruleIndex != nil { local += 1 }
            position += 1
            if position == queries.count { position = 0 }
        }
        precondition(local >= 0)
    }
    let concurrentNs = nowNanoseconds() - started
    let concurrentRate = Double(queryCount * threads) / (Double(concurrentNs) / 1e9)
    progress("queries: median \(Percentiles(all).medianNs) ns, single \(Int(singleRate)) q/s, \(threads) threads \(Int(concurrentRate)) q/s")

    // Rule update. There is no incremental update: the router is immutable
    // and a changed table is compiled again. The old router stays alive
    // until the new one is ready, as it would while serving lookups.
    let peakBeforeRebuild = peakResidentBytes()
    var rebuildMs: Double?
    var rssPeak: Double?
    if !skipRebuild {
        generated.table.rules[ruleCount / 2] = RoutingRule(condition: .domainSuffix("updated-rule.example"), action: .reject)
        started = nowNanoseconds()
        let rebuilt = try CompiledRouter(table: generated.table, limits: limits)
        rebuildMs = milliseconds(nowNanoseconds() - started)
        rssPeak = megabytes(residentBytes())
        precondition(rebuilt.match(RouteRequest(domain: "x.updated-rule.example", port: 1, network: .tcp)).ruleIndex != nil)
        router = rebuilt
        progress("rebuild: \(rebuildMs ?? 0) ms, rss \(rssPeak ?? 0) MB")
    }

    let report = Report(
        ruleCount: ruleCount,
        seed: seed,
        queryCount: queryCount,
        buildConfiguration: configuration,
        withoutRegex: workload.withoutRegex,
        cpuCount: ProcessInfo.processInfo.activeProcessorCount,
        memoryLimitMB: memoryLimitBytes().map { megabytes($0) },
        ruleKinds: generated.kinds,
        tableGenerationMs: milliseconds(generationNs),
        indexBuildMs: milliseconds(buildNs),
        coldFirstQueryNs: coldNs,
        clockOverheadNs: clockOverhead,
        perQueryAll: Percentiles(all),
        perQueryMatched: Percentiles(matched),
        perQueryFinal: Percentiles(final),
        matchedShare: Double(matched.count) / Double(max(1, all.count)),
        singleThreadQueriesPerSecond: singleRate.rounded(),
        threads: threads,
        concurrentQueriesPerSecond: concurrentRate.rounded(),
        rssBaselineMB: megabytes(rssBaseline),
        rssAfterTableMB: megabytes(rssTable),
        rssAfterIndexMB: megabytes(rssIndex),
        indexRssDeltaMB: megabytes(rssIndex - rssTable),
        totalRssDeltaMB: megabytes(rssIndex - rssBaseline),
        fullRebuildMs: rebuildMs,
        rssPeakDuringRebuildMB: rssPeak,
        rssPeakBeforeRebuildMB: megabytes(peakBeforeRebuild),
        rssPeakMB: megabytes(peakResidentBytes()),
        incrementalUpdate: "unsupported",
        domainTrieNodes: router.statistics.domainTrieNodes,
        cidrTrieNodes: router.statistics.cidrTrieNodes,
        portSegments: router.statistics.portSegments,
        fallbackRules: router.statistics.fallbackRules,
        anchoredFallbackEntries: router.statistics.anchoredFallbackEntries,
        unanchoredFallbackEntries: router.statistics.unanchoredFallbackEntries,
        checksum: checksum
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if let path = argument("--json") {
        try data.write(to: URL(fileURLWithPath: path))
    }
    print(String(decoding: data, as: UTF8.self))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("RoutingBench failed: \(error)\n".utf8))
    exit(1)
}
