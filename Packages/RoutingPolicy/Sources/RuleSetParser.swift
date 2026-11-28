import Foundation
import RoutingEngine

/// Project limits of downloaded lists. Every entry ends up in the engine configuration the Packet Tunnel
/// extension parses inside its memory budget (about 50 MiB on iOS), so lists are kept small and compact;
/// geo databases are never loaded. The numbers are project choices, not measured device limits.
public struct RuleSetLimits: Hashable, Sendable {
    /// Largest body downloaded; the download stops past it.
    public var maximumBytes: Int
    /// Entries of one list after compaction.
    public var maximumEntriesPerSet: Int
    /// Entries of all enabled lists together.
    public var maximumTotalEntries: Int

    public init(maximumBytes: Int = 2 << 20, maximumEntriesPerSet: Int = 10_000, maximumTotalEntries: Int = 20_000) {
        self.maximumBytes = maximumBytes
        self.maximumEntriesPerSet = maximumEntriesPerSet
        self.maximumTotalEntries = maximumTotalEntries
    }

    public static let standard = RuleSetLimits()
}

/// The compact form of a list: what the engines get. Domain suffixes match the name and its subdomains.
public struct CompiledRuleSet: Codable, Hashable, Sendable {
    public var suffixes: [String]
    public var exactDomains: [String]
    public var cidrs: [String]

    public init(suffixes: [String] = [], exactDomains: [String] = [], cidrs: [String] = []) {
        self.suffixes = suffixes
        self.exactDomains = exactDomains
        self.cidrs = cidrs
    }

    public var domainCount: Int { suffixes.count + exactDomains.count }
    public var entryCount: Int { domainCount + cidrs.count }

    /// The routing-model conditions, suffixes first.
    public var conditions: [RuleCondition] {
        suffixes.map { .domainSuffix($0) } + exactDomains.map { .domain($0) } + cidrs.compactMap { IPCIDR($0).map { .ipCIDR($0) } }
    }
}

/// What parsing a list produced.
public struct ParsedRuleSet: Hashable, Sendable {
    public var content: CompiledRuleSet
    /// Lines that held an entry (comments and blank lines excluded).
    public var entryLines: Int
    /// Entries that are not domains or addresses (regular expressions, keywords, process names, malformed).
    public var skipped: Int
    /// Entries removed because another entry already covers them (or repeated).
    public var redundant: Int
}

/// Reads plain domain/address lists in the common text shapes:
///
/// - one domain per line (`example.com`: the name and its subdomains), one address or network per line;
/// - `full:`/`domain:` prefixes (exact name / name and subdomains);
/// - classical rule lines `DOMAIN,…`, `DOMAIN-SUFFIX,…`, `IP-CIDR,…`, `IP-CIDR6,…` (extra fields ignored);
/// - list items of a `payload:` document (`- '+.example.com'`, `- DOMAIN-SUFFIX,example.com`);
/// - hosts-file lines `0.0.0.0 example.com`.
///
/// `+.`, `*.` and `.` prefixes become "name and subdomains" (the last two are slightly broader than written).
/// Keywords, regular expressions and anything else are skipped and counted.
public enum RuleSetParser {
    public static func parse(_ text: String, limits: RuleSetLimits = .standard) -> Result<ParsedRuleSet, PolicyInputError> {
        guard text.utf8.count <= limits.maximumBytes else {
            return .failure(PolicyInputError("Список больше \(limits.maximumBytes / 1024) КБ — такой не загружается."))
        }
        var suffixes = Set<String>()
        var exact = Set<String>()
        var cidrs: [IPCIDR] = []
        var entryLines = 0
        var skipped = 0
        var accepted = 0

        text.enumerateLines { rawLine, stop in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix("!") || line == "payload:" { return }
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            if line.count >= 2, let first = line.first, first == "'" || first == "\"", line.last == first {
                line = String(line.dropFirst().dropLast())
            }
            if line.isEmpty { return }
            entryLines += 1
            switch classify(line) {
            case .suffix(let name): suffixes.insert(name); accepted += 1
            case .exact(let name): exact.insert(name); accepted += 1
            case .cidr(let cidr): cidrs.append(cidr); accepted += 1
            case .skip: skipped += 1
            }
            // Compaction can only shrink; stop reading far past the limit.
            if accepted > limits.maximumEntriesPerSet * 4 { stop = true }
        }

        let compactSuffixes = compactSuffixList(suffixes)
        let suffixSet = Set(compactSuffixes)
        let compactExact = exact.filter { !isCovered($0, by: suffixSet) }.sorted()
        let compactCIDRs = compactCIDRList(cidrs)
        let content = CompiledRuleSet(suffixes: compactSuffixes, exactDomains: compactExact, cidrs: compactCIDRs.map(\.description))
        guard content.entryCount > 0 else {
            return .failure(PolicyInputError("В списке не нашлось ни доменов, ни адресов."))
        }
        guard content.entryCount <= limits.maximumEntriesPerSet else {
            return .failure(PolicyInputError("В списке \(content.entryCount) записей, предел — \(limits.maximumEntriesPerSet). Выберите список поменьше."))
        }
        return .success(ParsedRuleSet(
            content: content, entryLines: entryLines, skipped: skipped,
            redundant: max(0, entryLines - skipped - content.entryCount)
        ))
    }

    enum Entry: Equatable {
        case suffix(String)
        case exact(String)
        case cidr(IPCIDR)
        case skip
    }

    static func classify(_ line: String) -> Entry {
        // Classical rule lines.
        if let comma = line.firstIndex(of: ",") {
            let type = line[..<comma].uppercased()
            let rest = line[line.index(after: comma)...]
            let payload = String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
            switch type {
            case "DOMAIN": return domain(payload, exact: true)
            case "DOMAIN-SUFFIX", "HOST-SUFFIX": return domain(payload, exact: false)
            case "IP-CIDR", "IP-CIDR6", "IP6-CIDR": return IPCIDR(payload).map { .cidr($0) } ?? .skip
            default: return .skip
            }
        }
        let lower = line.lowercased()
        if lower.hasPrefix("full:") { return domain(String(line.dropFirst(5)), exact: true) }
        if lower.hasPrefix("domain:") { return domain(String(line.dropFirst(7)), exact: false) }
        if lower.contains(":") && !lower.contains(" "), let cidr = IPCIDR(line) { return .cidr(cidr) }
        if lower.contains(":") && IPAddress(String(line.prefix { $0 != " " && $0 != "\t" })) == nil { return .skip }
        // Hosts-file lines.
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count == 2, let address = IPAddress(String(fields[0])), address.isUnspecifiedOrLoopback {
            let name = String(fields[1])
            return name == "localhost" ? .skip : domain(name, exact: true)
        }
        guard fields.count == 1 else { return .skip }
        if let cidr = IPCIDR(line) { return .cidr(cidr) }
        var body = line
        for prefix in ["+.", "*.", "."] where body.hasPrefix(prefix) {
            body.removeFirst(prefix.count)
            break
        }
        return domain(body, exact: false)
    }

    private static func domain(_ text: String, exact: Bool) -> Entry {
        guard let name = HostName.ascii(text), name.contains(".") || !exact else { return .skip }
        return exact ? .exact(name) : .suffix(name)
    }

    /// Suffixes without those a shorter suffix in the list already covers, sorted.
    static func compactSuffixList(_ suffixes: Set<String>) -> [String] {
        suffixes.filter { name in
            var rest = Substring(name)
            while let dot = rest.firstIndex(of: ".") {
                rest = rest[rest.index(after: dot)...]
                if suffixes.contains(String(rest)) { return false }
            }
            return true
        }.sorted()
    }

    static func isCovered(_ name: String, by suffixes: Set<String>) -> Bool {
        if suffixes.contains(name) { return true }
        var rest = Substring(name)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if suffixes.contains(String(rest)) { return true }
        }
        return false
    }

    /// Prefixes without duplicates and without those inside another prefix of the list, IPv4 first, in
    /// address order. Prefixes are either nested or disjoint, so after sorting by start address (shorter
    /// first on ties) a prefix is covered exactly when the last kept one covers it.
    static func compactCIDRList(_ cidrs: [IPCIDR]) -> [IPCIDR] {
        let sorted = cidrs.sorted { a, b in
            let ka = a.network.sortKey, kb = b.network.sortKey
            if ka != kb { return ka < kb }
            return a.prefixLength < b.prefixLength
        }
        var kept: [IPCIDR] = []
        for cidr in sorted {
            if let last = kept.last, last.covers(cidr) { continue }
            kept.append(cidr)
        }
        return kept
    }
}

extension IPAddress {
    /// Orders IPv4 before IPv6, then by value.
    var sortKey: SortKey {
        switch self {
        case .v4(let value): return SortKey(family: 0, high: 0, low: UInt64(value))
        case .v6(let high, let low): return SortKey(family: 1, high: high, low: low)
        }
    }

    struct SortKey: Comparable {
        let family: Int
        let high: UInt64
        let low: UInt64

        static func < (a: SortKey, b: SortKey) -> Bool {
            (a.family, a.high, a.low) < (b.family, b.high, b.low)
        }
    }

    var isUnspecifiedOrLoopback: Bool {
        switch self {
        case .v4(let value): return value == 0 || value >> 24 == 127
        case .v6(let high, let low): return high == 0 && (low == 0 || low == 1)
        }
    }
}
