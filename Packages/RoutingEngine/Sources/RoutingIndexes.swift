// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
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
