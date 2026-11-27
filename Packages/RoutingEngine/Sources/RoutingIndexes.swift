// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-27). Not yet built or run on Apple platforms.
import Foundation

/// Sentinel used by every index for "no rule".
let noRuleIndex = Int.max

// MARK: - Domain trie

/// A trie over host-name labels in reversed order (`www.example.com` is the
/// path `com` -> `example` -> `www`). Each node keeps the lowest rule index
/// for three kinds of entries, so a lookup walks at most one node per label
/// regardless of how many rules are stored.
struct DomainTrie: Sendable {
    private struct Edge: Hashable, Sendable {
        let parent: Int
        let label: String
    }

    // All edges live in one hash table instead of one dictionary per node:
    // far fewer allocations for tables with hundreds of thousands of rules.
    private var edges: [Edge: Int] = [:]
    /// Lowest rule index of an exact-name entry ending at the node.
    private var exact: [Int] = [noRuleIndex]
    /// Lowest rule index of a suffix entry that matches the name itself and
    /// its subdomains.
    private var suffix: [Int] = [noRuleIndex]
    /// Lowest rule index of a suffix entry that matches subdomains only.
    private var strictSuffix: [Int] = [noRuleIndex]

    var nodeCount: Int { exact.count }

    /// Splits a name into label byte ranges, last label first.
    private static func reversedLabelRanges(_ name: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var end = name.count
        while true {
            var start = end
            while start > 0 && name[start - 1] != 0x2E {
                start -= 1
            }
            ranges.append(start..<end)
            if start == 0 { break }
            end = start - 1
        }
        return ranges
    }

    private static func label(_ name: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: name[range], as: UTF8.self)
    }

    /// Returns the node for `name`, creating the path when needed.
    private mutating func makeNode(for name: [UInt8]) -> Int {
        var node = 0
        for range in DomainTrie.reversedLabelRanges(name) {
            let edge = Edge(parent: node, label: DomainTrie.label(name, range))
            if let existing = edges[edge] {
                node = existing
            } else {
                let created = exact.count
                exact.append(noRuleIndex)
                suffix.append(noRuleIndex)
                strictSuffix.append(noRuleIndex)
                edges[edge] = created
                node = created
            }
        }
        return node
    }

    mutating func insertExact(_ name: [UInt8], ruleIndex: Int) {
        let node = makeNode(for: name)
        exact[node] = min(exact[node], ruleIndex)
    }

    mutating func insertSuffix(_ name: [UInt8], strict: Bool, ruleIndex: Int) {
        let node = makeNode(for: name)
        if strict {
            strictSuffix[node] = min(strictSuffix[node], ruleIndex)
        } else {
            suffix[node] = min(suffix[node], ruleIndex)
        }
    }

    /// Lowest rule index among all entries that match `name`, or
    /// `noRuleIndex`.
    func lookup(_ name: [UInt8]) -> Int {
        var best = noRuleIndex
        var node = 0
        var end = name.count
        while true {
            var start = end
            while start > 0 && name[start - 1] != 0x2E {
                start -= 1
            }
            let edge = Edge(parent: node, label: String(decoding: name[start..<end], as: UTF8.self))
            guard let child = edges[edge] else { break }
            node = child
            if start == 0 {
                // The whole name is consumed: exact and inclusive suffix apply.
                best = min(best, min(exact[node], suffix[node]))
                break
            }
            // More labels remain: the name is a strict subdomain of this node.
            best = min(best, min(suffix[node], strictSuffix[node]))
            end = start - 1
        }
        return best
    }

    /// Lowest rule index among stored suffix entries that match everything a
    /// new suffix entry (`name`, `strict`) would match, or `noRuleIndex`.
    func coveringSuffixIndex(_ name: [UInt8], strict: Bool) -> Int {
        var best = noRuleIndex
        var node = 0
        let ranges = DomainTrie.reversedLabelRanges(name)
        for (position, range) in ranges.enumerated() {
            let edge = Edge(parent: node, label: DomainTrie.label(name, range))
            guard let child = edges[edge] else { break }
            node = child
            let isLast = position == ranges.count - 1
            if isLast {
                // Same name: an inclusive suffix covers both kinds; a strict
                // one covers only another strict one.
                best = min(best, suffix[node])
                if strict {
                    best = min(best, strictSuffix[node])
                }
            } else {
                // Proper ancestor: both kinds cover the whole subtree below.
                best = min(best, min(suffix[node], strictSuffix[node]))
            }
        }
        return best
    }
}

// MARK: - CIDR trie

/// A path-compressed binary (radix-2) trie keyed by address bits.
///
/// Routing needs "lowest rule index among all stored prefixes that contain
/// the address", which is not always the longest prefix, so `search` returns
/// both: the minimum over the whole path and the longest (most specific)
/// stored prefix.
struct CIDRTrie: Sendable {
    struct SearchResult: Equatable, Sendable {
        /// Lowest rule index on the path, or `noRuleIndex`.
        var minimumIndex: Int
        /// Length of the most specific stored prefix, or -1.
        var longestPrefixLength: Int
        /// Rule index stored at the most specific prefix, or `noRuleIndex`.
        var longestPrefixIndex: Int
    }

    let maximumBits: Int

    // Node 0 is the root (prefix length 0). Parallel arrays keep the node
    // storage flat.
    private var keys: [IPBits] = [IPBits(high: 0, low: 0)]
    private var lengths: [Int] = [0]
    private var zeroChild: [Int] = [-1]
    private var oneChild: [Int] = [-1]
    private var values: [Int] = [noRuleIndex]

    init(maximumBits: Int) {
        self.maximumBits = maximumBits
    }

    var nodeCount: Int { keys.count }

    private func child(of node: Int, bit: Int) -> Int {
        bit == 0 ? zeroChild[node] : oneChild[node]
    }

    private mutating func setChild(of node: Int, bit: Int, to child: Int) {
        if bit == 0 {
            zeroChild[node] = child
        } else {
            oneChild[node] = child
        }
    }

    private mutating func addNode(key: IPBits, length: Int, value: Int) -> Int {
        keys.append(key)
        lengths.append(length)
        zeroChild.append(-1)
        oneChild.append(-1)
        values.append(value)
        return keys.count - 1
    }

    /// Stores `ruleIndex` for the prefix; an existing entry keeps the lower
    /// index. Lengths outside `0...maximumBits` are ignored.
    mutating func insert(key rawKey: IPBits, length: Int, ruleIndex: Int) {
        guard length >= 0, length <= maximumBits else { return }
        let key = rawKey.masked(to: length)
        var current = 0
        while true {
            // Invariant: keys[current] is a prefix of key and
            // lengths[current] <= length.
            if lengths[current] == length {
                values[current] = min(values[current], ruleIndex)
                return
            }
            let bit = key.bit(at: lengths[current])
            let next = child(of: current, bit: bit)
            if next < 0 {
                let leaf = addNode(key: key, length: length, value: ruleIndex)
                setChild(of: current, bit: bit, to: leaf)
                return
            }
            let nextLength = lengths[next]
            let shared = min(key.commonPrefixLength(with: keys[next]), min(length, nextLength))
            if shared == nextLength {
                // The child's prefix is a prefix of the new key: descend.
                current = next
                continue
            }
            if shared == length {
                // The new prefix sits between `current` and `next`.
                let middle = addNode(key: key, length: length, value: ruleIndex)
                setChild(of: middle, bit: keys[next].bit(at: length), to: next)
                setChild(of: current, bit: bit, to: middle)
                return
            }
            // The two prefixes diverge at `shared`: add a branch node.
            let branch = addNode(key: key.masked(to: shared), length: shared, value: noRuleIndex)
            let leaf = addNode(key: key, length: length, value: ruleIndex)
            setChild(of: branch, bit: key.bit(at: shared), to: leaf)
            setChild(of: branch, bit: keys[next].bit(at: shared), to: next)
            setChild(of: current, bit: bit, to: branch)
            return
        }
    }

    /// Walks the stored prefixes of length `<= maximumLength` that contain
    /// `key`.
    func search(key: IPBits, maximumLength: Int) -> SearchResult {
        let limit = min(maximumLength, maximumBits)
        var result = SearchResult(minimumIndex: noRuleIndex, longestPrefixLength: -1, longestPrefixIndex: noRuleIndex)
        var current = 0
        while true {
            let value = values[current]
            let length = lengths[current]
            if value != noRuleIndex {
                result.minimumIndex = min(result.minimumIndex, value)
                result.longestPrefixLength = length
                result.longestPrefixIndex = value
            }
            if length >= limit { break }
            let next = child(of: current, bit: key.bit(at: length))
            if next < 0 { break }
            let nextLength = lengths[next]
            if nextLength > limit { break }
            if key.commonPrefixLength(with: keys[next]) < nextLength { break }
            current = next
        }
        return result
    }

    /// Calls `body` with the value of every stored prefix that contains
    /// `key`, shortest prefix first.
    func forEachContaining(key: IPBits, _ body: (Int) -> Void) {
        var current = 0
        while true {
            let value = values[current]
            let length = lengths[current]
            if value != noRuleIndex { body(value) }
            if length >= maximumBits { break }
            let next = child(of: current, bit: key.bit(at: length))
            if next < 0 { break }
            if key.commonPrefixLength(with: keys[next]) < lengths[next] { break }
            current = next
        }
    }
}

/// IPv4 and IPv6 tries behind one interface.
struct CIDRIndex: Sendable {
    private var v4 = CIDRTrie(maximumBits: 32)
    private var v6 = CIDRTrie(maximumBits: 128)
    private(set) var entryCount = 0

    var nodeCount: Int { v4.nodeCount + v6.nodeCount }

    mutating func insert(_ cidr: IPCIDR, ruleIndex: Int) {
        let key = IPBits.key(for: cidr.network)
        if cidr.network.isIPv4 {
            v4.insert(key: key, length: cidr.prefixLength, ruleIndex: ruleIndex)
        } else {
            v6.insert(key: key, length: cidr.prefixLength, ruleIndex: ruleIndex)
        }
        entryCount += 1
    }

    /// Search over every stored prefix containing the address.
    func search(_ address: IPAddress) -> CIDRTrie.SearchResult {
        let plain = address.unmapped
        let key = IPBits.key(for: plain)
        if plain.isIPv4 {
            return v4.search(key: key, maximumLength: 32)
        }
        return v6.search(key: key, maximumLength: 128)
    }

    /// Lowest rule index among stored prefixes that contain the whole
    /// `cidr`, or `noRuleIndex`.
    func coveringIndex(_ cidr: IPCIDR) -> Int {
        let key = IPBits.key(for: cidr.network)
        if cidr.network.isIPv4 {
            return v4.search(key: key, maximumLength: cidr.prefixLength).minimumIndex
        }
        return v6.search(key: key, maximumLength: cidr.prefixLength).minimumIndex
    }
}

// MARK: - Port index

/// Disjoint port segments, each with the lowest rule index of the ranges
/// covering it. Lookup is a binary search over segment starts.
struct PortIndex: Sendable {
    private var starts: [Int] = [0]
    private var values: [Int] = [noRuleIndex]

    var segmentCount: Int { starts.count }

    init() {}

    init(entries: [(range: PortRange, ruleIndex: Int)]) {
        guard !entries.isEmpty else { return }
        let ordered = entries.sorted { $0.ruleIndex < $1.ruleIndex }
        var table = [Int](repeating: noRuleIndex, count: 65536)
        // next[p] points towards the first unpainted port >= p
        // (union-find with path halving); 65536 is the end sentinel.
        var next = Array(0...65536)
        for entry in ordered {
            let upper = Int(entry.range.upper)
            var port = Int(entry.range.lower)
            while true {
                var root = port
                while next[root] != root {
                    next[root] = next[next[root]]
                    root = next[root]
                }
                port = root
                if port > upper { break }
                // Lowest index paints first; later ranges skip painted ports.
                table[port] = entry.ruleIndex
                next[port] = port + 1
                port += 1
            }
        }
        var segmentStarts: [Int] = [0]
        var segmentValues: [Int] = [table[0]]
        var port = 1
        while port < 65536 {
            if table[port] != table[port - 1] {
                segmentStarts.append(port)
                segmentValues.append(table[port])
            }
            port += 1
        }
        starts = segmentStarts
        values = segmentValues
    }

    /// Lowest rule index among ranges containing `port`, or `noRuleIndex`.
    func lookup(_ port: UInt16) -> Int {
        let target = Int(port)
        var low = 0
        var high = starts.count - 1
        // Find the last segment whose start is <= target. starts[0] == 0.
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= target {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return values[low]
    }
}

// MARK: - Keyword automaton

/// An Aho-Corasick automaton over keyword bytes. One pass over a host name
/// reports every stored keyword that occurs in it, however many keywords
/// there are.
struct KeywordAutomaton: Sendable {
    /// Transitions, keyed by `node << 8 | byte`.
    private var edges: [UInt64: Int32] = [:]
    /// Longest proper suffix of the node's string that is also a node.
    private var failure: [Int32] = [0]
    /// Nearest node on the failure chain that ends a keyword, or -1.
    private var outputLink: [Int32] = [-1]
    /// Identifiers of the keywords that end exactly at the node.
    private var outputs: [[Int32]] = [[]]
    private(set) var keywordCount = 0

    var isEmpty: Bool { keywordCount == 0 }
    var nodeCount: Int { failure.count }

    private static func key(_ node: Int32, _ byte: UInt8) -> UInt64 {
        (UInt64(UInt32(bitPattern: node)) << 8) | UInt64(byte)
    }

    init() {}

    /// `keywords` must not contain empty byte strings.
    init(keywords: [(bytes: [UInt8], id: Int32)]) {
        guard !keywords.isEmpty else { return }
        var children: [[(byte: UInt8, node: Int32)]] = [[]]
        for keyword in keywords where !keyword.bytes.isEmpty {
            var node: Int32 = 0
            for byte in keyword.bytes {
                let edge = KeywordAutomaton.key(node, byte)
                if let next = edges[edge] {
                    node = next
                } else {
                    let created = Int32(failure.count)
                    failure.append(0)
                    outputLink.append(-1)
                    outputs.append([])
                    children.append([])
                    edges[edge] = created
                    children[Int(node)].append((byte, created))
                    node = created
                }
            }
            outputs[Int(node)].append(keyword.id)
            keywordCount += 1
        }
        // Breadth-first: a node's failure link only depends on shallower nodes.
        var queue: [Int32] = children[0].map { $0.node }
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for child in children[Int(node)] {
                var fallback = failure[Int(node)]
                var target: Int32 = 0
                while true {
                    if let next = edges[KeywordAutomaton.key(fallback, child.byte)] {
                        target = next
                        break
                    }
                    if fallback == 0 { break }
                    fallback = failure[Int(fallback)]
                }
                failure[Int(child.node)] = target
                outputLink[Int(child.node)] = outputs[Int(target)].isEmpty ? outputLink[Int(target)] : target
                queue.append(child.node)
            }
        }
    }

    /// Appends the identifiers of all keywords occurring in `text`.
    func collect(_ text: [UInt8], into found: inout [Int32]) {
        guard keywordCount > 0 else { return }
        var node: Int32 = 0
        for byte in text {
            while true {
                if let next = edges[KeywordAutomaton.key(node, byte)] {
                    node = next
                    break
                }
                if node == 0 { break }
                node = failure[Int(node)]
            }
            var output = outputs[Int(node)].isEmpty ? outputLink[Int(node)] : node
            while output > 0 {
                found.append(contentsOf: outputs[Int(output)])
                output = outputLink[Int(output)]
            }
        }
    }
}

// MARK: - Fallback anchors

/// Buckets for fallback rules. A fallback rule (keyword, AND, ...) cannot be
/// answered by an index alone, but most of them have a necessary condition
/// an index can test - their anchor: a domain name, a keyword, an address
/// prefix, a user, a narrow port range, or the literal every match of a
/// pattern contains. Only the rules whose anchor fits
/// the request are evaluated; a rule without an anchor stays in the ordered
/// list that is scanned linearly.
struct FallbackAnchors: Sendable {
    enum Anchor {
        case domain([UInt8])
        case keyword([UInt8])
        case prefix(IPCIDR)
        case user(String)
        case port(PortRange)

        /// Lower is more selective.
        var rank: Int {
            switch self {
            case .domain: return 0
            case .prefix: return 1
            case .user: return 2
            case .keyword: return 3
            case .port: return 4
            }
        }
    }

    /// Port ranges wider than this are not used as anchors.
    static let maximumAnchorPorts = 32

    /// Patterns whose required literal is shorter than this stay in the
    /// ordered list.
    static let minimumRegexLiteral = 3

    /// Keyed by a name: the request name must equal it or end with
    /// `"." + name` for any rule in the bucket to match.
    private var byDomain: [String: [Int32]] = [:]
    private var byUser: [String: [Int32]] = [:]
    private var byPort: [UInt16: [Int32]] = [:]
    private var v4 = CIDRTrie(maximumBits: 32)
    private var v6 = CIDRTrie(maximumBits: 128)
    private var prefixSlots: [IPCIDR: Int] = [:]
    private var prefixBuckets: [[Int32]] = []
    private var pendingKeywords: [(bytes: [UInt8], id: Int32)] = []
    private var keywords = KeywordAutomaton()
    private(set) var entryCount = 0

    /// A necessary condition of `condition` that a bucket can test, or
    /// `nil`.
    static func anchor(of condition: ResolvedCondition) -> Anchor? {
        switch condition {
        case let .domainExact(name): return .domain(name)
        case let .domainSuffix(name, _): return .domain(name)
        case let .domainKeyword(keyword): return .keyword(keyword)
        case let .ipCIDR(cidr): return .prefix(cidr)
        case let .user(name): return .user(name)
        case let .port(range):
            return Int(range.upper) - Int(range.lower) < maximumAnchorPorts ? .port(range) : nil
        case let .allOf(items):
            var best: Anchor?
            for item in items {
                if let candidate = anchor(of: item), candidate.rank < (best?.rank ?? Int.max) {
                    best = candidate
                }
            }
            return best
        case let .domainRegex(regex):
            // Every match contains the pattern's required literal, so the
            // pattern only needs evaluating when the literal occurs. Short
            // literals ("." and the like) would fit almost every name.
            let literal = regex.requiredLiteral
            return literal.count >= minimumRegexLiteral ? .keyword(literal) : nil
        case .ipNotIn, .network, .sourceCIDR, .sourcePort, .inboundTag, .sniffedProtocol,
             .anyOf, .not:
            return nil
        }
    }

    mutating func insert(_ anchor: Anchor, id: Int32) {
        entryCount += 1
        switch anchor {
        case let .domain(name):
            byDomain[ByteText.string(name), default: []].append(id)
        case let .keyword(keyword):
            pendingKeywords.append((keyword, id))
        case let .prefix(cidr):
            let slot: Int
            if let existing = prefixSlots[cidr] {
                slot = existing
            } else {
                slot = prefixBuckets.count
                prefixSlots[cidr] = slot
                prefixBuckets.append([])
                let key = IPBits.key(for: cidr.network)
                if cidr.network.isIPv4 {
                    v4.insert(key: key, length: cidr.prefixLength, ruleIndex: slot)
                } else {
                    v6.insert(key: key, length: cidr.prefixLength, ruleIndex: slot)
                }
            }
            prefixBuckets[slot].append(id)
        case let .user(name):
            byUser[name, default: []].append(id)
        case let .port(range):
            for port in range.lower...range.upper {
                byPort[port, default: []].append(id)
            }
        }
    }

    /// Call once after the last `insert`.
    mutating func finish() {
        keywords = KeywordAutomaton(keywords: pendingKeywords)
        pendingKeywords = []
        prefixSlots = [:]
    }

    /// Appends the identifiers of every entry whose anchor fits the request.
    /// An identifier may appear more than once.
    func collect(_ input: EvaluationInput, into found: inout [Int32]) {
        if let domain = input.domain {
            if !byDomain.isEmpty {
                var start = 0
                while true {
                    if let bucket = byDomain[String(decoding: domain[start...], as: UTF8.self)] {
                        found.append(contentsOf: bucket)
                    }
                    guard let dot = domain[start...].firstIndex(of: 0x2E) else { break }
                    start = dot + 1
                    if start >= domain.count { break }
                }
            }
            keywords.collect(domain, into: &found)
        }
        if !prefixBuckets.isEmpty {
            for ip in input.targetIPs {
                let key = IPBits.key(for: ip)
                if ip.isIPv4 {
                    v4.forEachContaining(key: key) { found.append(contentsOf: prefixBuckets[$0]) }
                } else {
                    v6.forEachContaining(key: key) { found.append(contentsOf: prefixBuckets[$0]) }
                }
            }
        }
        if let user = input.user, let bucket = byUser[user] {
            found.append(contentsOf: bucket)
        }
        if let bucket = byPort[input.port] {
            found.append(contentsOf: bucket)
        }
    }
}
