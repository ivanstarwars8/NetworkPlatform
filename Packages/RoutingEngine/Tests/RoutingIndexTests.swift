// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

/// Deterministic pseudo-random generator (64-bit LCG, Knuth's MMIX
/// constants). Tests must not depend on the system generator.
struct LCG {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        // The low bits of an LCG are weak; use the high ones.
        return state >> 33
    }

    /// Uniform-ish value in `0..<bound`; `bound` must be positive.
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }

    /// 64 pseudo-random bits.
    mutating func bits64() -> UInt64 {
        (next() << 33) ^ (next() << 11) ^ next()
    }
}

private func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
}

final class DomainTrieTests: XCTestCase {
    func testExactAndSuffixLookup() {
        var trie = DomainTrie()
        trie.insertSuffix(bytes("example.com"), strict: false, ruleIndex: 5)
        trie.insertExact(bytes("www.example.com"), ruleIndex: 2)
        trie.insertSuffix(bytes("com"), strict: true, ruleIndex: 9)
        trie.insertSuffix(bytes("example.com"), strict: false, ruleIndex: 7) // keeps 5

        XCTAssertEqual(trie.lookup(bytes("example.com")), 5)
        XCTAssertEqual(trie.lookup(bytes("www.example.com")), 2)
        XCTAssertEqual(trie.lookup(bytes("a.example.com")), 5)
        XCTAssertEqual(trie.lookup(bytes("deep.a.example.com")), 5)
        XCTAssertEqual(trie.lookup(bytes("other.com")), 9)
        XCTAssertEqual(trie.lookup(bytes("badexample.com")), 9)
        // A strict suffix does not match the name itself.
        XCTAssertEqual(trie.lookup(bytes("com")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("org")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("example.org")), noRuleIndex)
    }

    func testSuffixRespectsLabelBoundary() {
        var trie = DomainTrie()
        trie.insertSuffix(bytes("example.com"), strict: false, ruleIndex: 1)
        XCTAssertEqual(trie.lookup(bytes("badexample.com")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("example.com.evil")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("xexample.com")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("x.example.com")), 1)
    }

    func testExactDoesNotMatchSubdomains() {
        var trie = DomainTrie()
        trie.insertExact(bytes("example.com"), ruleIndex: 3)
        XCTAssertEqual(trie.lookup(bytes("example.com")), 3)
        XCTAssertEqual(trie.lookup(bytes("www.example.com")), noRuleIndex)
        XCTAssertEqual(trie.lookup(bytes("com")), noRuleIndex)
    }

    func testLowestIndexWinsAlongThePath() {
        var trie = DomainTrie()
        trie.insertSuffix(bytes("a.b.c"), strict: false, ruleIndex: 4)
        trie.insertSuffix(bytes("b.c"), strict: false, ruleIndex: 8)
        trie.insertSuffix(bytes("c"), strict: false, ruleIndex: 1)
        XCTAssertEqual(trie.lookup(bytes("x.a.b.c")), 1)

        var other = DomainTrie()
        other.insertSuffix(bytes("a.b.c"), strict: false, ruleIndex: 4)
        other.insertSuffix(bytes("b.c"), strict: false, ruleIndex: 8)
        XCTAssertEqual(other.lookup(bytes("x.a.b.c")), 4)
        XCTAssertEqual(other.lookup(bytes("y.b.c")), 8)
    }

    func testCoveringSuffixIndex() {
        var trie = DomainTrie()
        trie.insertSuffix(bytes("example.com"), strict: false, ruleIndex: 5)
        trie.insertSuffix(bytes("com"), strict: true, ruleIndex: 9)
        trie.insertExact(bytes("exact.org"), ruleIndex: 1)

        XCTAssertEqual(trie.coveringSuffixIndex(bytes("sub.example.com"), strict: false), 5)
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("example.com"), strict: false), 5)
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("other.com"), strict: false), 9)
        // ".com" covers subdomains of com but not com itself.
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("com"), strict: false), noRuleIndex)
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("com"), strict: true), 9)
        // An exact entry never covers a suffix.
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("exact.org"), strict: false), noRuleIndex)
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("exact.org"), strict: true), noRuleIndex)
        XCTAssertEqual(trie.coveringSuffixIndex(bytes("net"), strict: false), noRuleIndex)
    }

    func testNodeCountSharesCommonParents() {
        var trie = DomainTrie()
        XCTAssertEqual(trie.nodeCount, 1)
        trie.insertSuffix(bytes("a.example.com"), strict: false, ruleIndex: 0)
        XCTAssertEqual(trie.nodeCount, 4)
        trie.insertSuffix(bytes("b.example.com"), strict: false, ruleIndex: 1)
        XCTAssertEqual(trie.nodeCount, 5)
        trie.insertExact(bytes("a.example.com"), ruleIndex: 2)
        XCTAssertEqual(trie.nodeCount, 5)
    }
}

final class CIDRTrieTests: XCTestCase {
    private func cidr(_ text: String) throws -> IPCIDR {
        try XCTUnwrap(IPCIDR(text), "bad test CIDR \(text)")
    }

    private func address(_ text: String) throws -> IPAddress {
        try XCTUnwrap(IPAddress(text), "bad test address \(text)")
    }

    func testMinimumAndLongestPrefix() throws {
        var index = CIDRIndex()
        index.insert(try cidr("10.0.0.0/8"), ruleIndex: 3)
        index.insert(try cidr("10.1.0.0/16"), ruleIndex: 1)
        index.insert(try cidr("10.1.2.0/24"), ruleIndex: 7)
        index.insert(try cidr("0.0.0.0/0"), ruleIndex: 9)

        let inner = index.search(try address("10.1.2.3"))
        XCTAssertEqual(inner.minimumIndex, 1)
        XCTAssertEqual(inner.longestPrefixLength, 24)
        XCTAssertEqual(inner.longestPrefixIndex, 7)

        let middle = index.search(try address("10.2.0.1"))
        XCTAssertEqual(middle.minimumIndex, 3)
        XCTAssertEqual(middle.longestPrefixLength, 8)
        XCTAssertEqual(middle.longestPrefixIndex, 3)

        let outer = index.search(try address("11.0.0.1"))
        XCTAssertEqual(outer.minimumIndex, 9)
        XCTAssertEqual(outer.longestPrefixLength, 0)

        let v6 = index.search(try address("::1"))
        XCTAssertEqual(v6.minimumIndex, noRuleIndex)
        XCTAssertEqual(v6.longestPrefixLength, -1)

        // IPv4-mapped addresses are looked up as IPv4.
        XCTAssertEqual(index.search(try address("::ffff:10.1.2.3")).minimumIndex, 1)
        XCTAssertEqual(index.entryCount, 4)
    }

    func testInsertionOrderDoesNotMatter() throws {
        // Longest first forces "insert between" and "branch" node splits.
        let entries: [(String, Int)] = [
            ("10.1.2.0/24", 7), ("10.0.0.0/8", 3), ("10.1.3.0/24", 4), ("10.1.0.0/16", 1),
            ("10.128.0.0/9", 6), ("0.0.0.0/0", 9), ("10.1.2.128/25", 2), ("10.1.2.129/32", 0),
        ]
        var forward = CIDRIndex()
        for (text, ruleIndex) in entries {
            forward.insert(try cidr(text), ruleIndex: ruleIndex)
        }
        var backward = CIDRIndex()
        for (text, ruleIndex) in entries.reversed() {
            backward.insert(try cidr(text), ruleIndex: ruleIndex)
        }
        let probes = [
            "10.1.2.129", "10.1.2.130", "10.1.2.1", "10.1.3.9", "10.1.4.1", "10.200.0.1",
            "10.0.0.1", "9.9.9.9", "255.255.255.255", "0.0.0.0",
        ]
        let expectedMinimum = [0, 1, 1, 1, 1, 3, 3, 9, 9, 9]
        let expectedLongest = [32, 25, 24, 24, 16, 9, 8, 0, 0, 0]
        for (position, probe) in probes.enumerated() {
            let a = forward.search(try address(probe))
            let b = backward.search(try address(probe))
            XCTAssertEqual(a, b, "order dependence for \(probe)")
            XCTAssertEqual(a.minimumIndex, expectedMinimum[position], "minimum for \(probe)")
            XCTAssertEqual(a.longestPrefixLength, expectedLongest[position], "longest prefix for \(probe)")
        }
    }

    func testIPv6Prefixes() throws {
        var index = CIDRIndex()
        index.insert(try cidr("2001:db8::/32"), ruleIndex: 5)
        index.insert(try cidr("2001:db8:0:1::/64"), ruleIndex: 2)
        index.insert(try cidr("2001:db8:0:1:8000::/65"), ruleIndex: 8)
        index.insert(try cidr("2001:db8::1/128"), ruleIndex: 1)
        index.insert(try cidr("::/0"), ruleIndex: 20)

        XCTAssertEqual(index.search(try address("2001:db8::1")).minimumIndex, 1)
        XCTAssertEqual(index.search(try address("2001:db8::1")).longestPrefixLength, 128)
        XCTAssertEqual(index.search(try address("2001:db8::2")).minimumIndex, 5)
        XCTAssertEqual(index.search(try address("2001:db8:0:1::9")).minimumIndex, 2)
        let deep = index.search(try address("2001:db8:0:1:8000::9"))
        XCTAssertEqual(deep.minimumIndex, 2)
        XCTAssertEqual(deep.longestPrefixLength, 65)
        XCTAssertEqual(deep.longestPrefixIndex, 8)
        XCTAssertEqual(index.search(try address("2001:db9::1")).minimumIndex, 20)
        // IPv4 is a separate trie.
        XCTAssertEqual(index.search(try address("10.0.0.1")).minimumIndex, noRuleIndex)
    }

    func testCoveringIndex() throws {
        var index = CIDRIndex()
        index.insert(try cidr("10.0.0.0/8"), ruleIndex: 4)
        index.insert(try cidr("10.1.2.0/24"), ruleIndex: 1)
        XCTAssertEqual(index.coveringIndex(try cidr("10.1.0.0/16")), 4)
        // The /24 is narrower than the queried /16 and must not count.
        XCTAssertEqual(index.coveringIndex(try cidr("10.1.2.0/23")), 4)
        XCTAssertEqual(index.coveringIndex(try cidr("10.1.2.0/24")), 1)
        XCTAssertEqual(index.coveringIndex(try cidr("10.1.2.7/32")), 1)
        XCTAssertEqual(index.coveringIndex(try cidr("10.0.0.0/7")), noRuleIndex)
        XCTAssertEqual(index.coveringIndex(try cidr("11.0.0.0/8")), noRuleIndex)
        XCTAssertEqual(index.coveringIndex(try cidr("::/0")), noRuleIndex)
    }

    func testDuplicatePrefixKeepsLowestIndex() throws {
        var index = CIDRIndex()
        index.insert(try cidr("192.168.0.0/16"), ruleIndex: 9)
        index.insert(try cidr("192.168.0.0/16"), ruleIndex: 3)
        index.insert(try cidr("192.168.0.0/16"), ruleIndex: 6)
        XCTAssertEqual(index.search(try address("192.168.5.5")).minimumIndex, 3)
    }

    /// Compares the trie with a brute-force scan on pseudo-random prefixes.
    func testAgainstBruteForce() throws {
        var rng = LCG(seed: 0xC1D8_0001)
        for round in 0..<6 {
            var index = CIDRIndex()
            var stored: [(cidr: IPCIDR, ruleIndex: Int)] = []
            let v4Lengths = [0, 4, 8, 9, 12, 16, 17, 20, 24, 25, 30, 31, 32]
            let v6Lengths = [0, 16, 32, 33, 48, 56, 63, 64, 65, 96, 127, 128]
            for ruleIndex in 0..<400 {
                let made: IPCIDR?
                if rng.chance(60) {
                    let value = (UInt32(10) << 24) | UInt32(rng.below(4)) << 16
                        | UInt32(rng.below(4)) << 8 | UInt32(rng.below(256))
                    made = IPCIDR(address: .v4(value), prefixLength: rng.pick(v4Lengths))
                } else {
                    let high = UInt64(0x2001_0DB8_0000_0000) | UInt64(rng.below(4)) << 16 | UInt64(rng.below(4))
                    let low = rng.chance(50) ? rng.bits64() : UInt64(rng.below(4)) << 62
                    made = IPCIDR(address: .v6(high: high, low: low), prefixLength: rng.pick(v6Lengths))
                }
                guard let prefix = made else {
                    XCTFail("generator produced an invalid prefix")
                    return
                }
                // Skip the catch-all prefixes in some rounds to exercise misses.
                if round % 2 == 1 && prefix.prefixLength == 0 { continue }
                index.insert(prefix, ruleIndex: ruleIndex)
                stored.append((cidr: prefix, ruleIndex: ruleIndex))
            }

            for _ in 0..<1500 {
                let probe: IPAddress
                if rng.chance(60) {
                    let top: UInt32 = rng.chance(90) ? 10 : 11
                    probe = .v4((top << 24) | UInt32(rng.below(4)) << 16
                        | UInt32(rng.below(4)) << 8 | UInt32(rng.below(256)))
                } else {
                    let high = UInt64(0x2001_0DB8_0000_0000) | UInt64(rng.below(5)) << 16 | UInt64(rng.below(4))
                    let low = rng.chance(50) ? rng.bits64() : UInt64(rng.below(4)) << 62
                    probe = .v6(high: high, low: low)
                }

                var expectedMinimum = noRuleIndex
                var expectedLength = -1
                var expectedLongestIndex = noRuleIndex
                for entry in stored where entry.cidr.contains(probe) {
                    expectedMinimum = min(expectedMinimum, entry.ruleIndex)
                    if entry.cidr.prefixLength > expectedLength {
                        expectedLength = entry.cidr.prefixLength
                        expectedLongestIndex = entry.ruleIndex
                    } else if entry.cidr.prefixLength == expectedLength {
                        expectedLongestIndex = min(expectedLongestIndex, entry.ruleIndex)
                    }
                }

                let found = index.search(probe)
                if found.minimumIndex != expectedMinimum
                    || found.longestPrefixLength != expectedLength
                    || found.longestPrefixIndex != expectedLongestIndex {
                    XCTFail("round \(round): mismatch for \(probe): trie \(found), "
                        + "expected min \(expectedMinimum) longest /\(expectedLength) #\(expectedLongestIndex)")
                    return
                }
            }

            // Covering queries against brute force.
            for entry in stored.prefix(200) {
                var expected = noRuleIndex
                for other in stored where other.cidr.covers(entry.cidr) {
                    expected = min(expected, other.ruleIndex)
                }
                XCTAssertEqual(index.coveringIndex(entry.cidr), expected, "covering \(entry.cidr)")
            }
        }
    }
}

final class PortIndexTests: XCTestCase {
    private func range(_ lower: UInt16, _ upper: UInt16) -> PortRange {
        PortRange(lower: lower, upper: upper) ?? PortRange(lower)
    }

    func testEmptyIndex() {
        let index = PortIndex(entries: [])
        XCTAssertEqual(index.lookup(0), noRuleIndex)
        XCTAssertEqual(index.lookup(443), noRuleIndex)
        XCTAssertEqual(index.lookup(65535), noRuleIndex)
        XCTAssertEqual(index.segmentCount, 1)
    }

    func testOverlappingRangesKeepLowestIndex() {
        let index = PortIndex(entries: [
            (range: range(80, 80), ruleIndex: 5),
            (range: range(1, 1000), ruleIndex: 9),
            (range: range(443, 443), ruleIndex: 2),
            (range: range(400, 500), ruleIndex: 7),
        ])
        XCTAssertEqual(index.lookup(0), noRuleIndex)
        XCTAssertEqual(index.lookup(1), 9)
        XCTAssertEqual(index.lookup(79), 9)
        XCTAssertEqual(index.lookup(80), 5)
        XCTAssertEqual(index.lookup(81), 9)
        XCTAssertEqual(index.lookup(400), 7)
        XCTAssertEqual(index.lookup(443), 2)
        XCTAssertEqual(index.lookup(444), 7)
        XCTAssertEqual(index.lookup(500), 7)
        XCTAssertEqual(index.lookup(501), 9)
        XCTAssertEqual(index.lookup(1000), 9)
        XCTAssertEqual(index.lookup(1001), noRuleIndex)
        XCTAssertEqual(index.lookup(65535), noRuleIndex)
    }

    func testFullRangeAndEdges() {
        let index = PortIndex(entries: [
            (range: range(0, 65535), ruleIndex: 20),
            (range: range(65535, 65535), ruleIndex: 3),
            (range: range(0, 0), ruleIndex: 4),
        ])
        XCTAssertEqual(index.lookup(0), 4)
        XCTAssertEqual(index.lookup(1), 20)
        XCTAssertEqual(index.lookup(65534), 20)
        XCTAssertEqual(index.lookup(65535), 3)
        XCTAssertEqual(index.segmentCount, 3)
    }

    func testAgainstBruteForce() {
        var rng = LCG(seed: 0x9087_0002)
        for _ in 0..<5 {
            var entries: [(range: PortRange, ruleIndex: Int)] = []
            for ruleIndex in 0..<300 {
                let lower = rng.below(65536)
                let width = rng.chance(70) ? rng.below(50) : rng.below(20000)
                let upper = min(65535, lower + width)
                entries.append((range: range(UInt16(lower), UInt16(upper)), ruleIndex: ruleIndex))
            }
            // Shuffle so that the index cannot rely on the input order.
            var shuffled = entries
            var position = shuffled.count - 1
            while position > 0 {
                shuffled.swapAt(position, rng.below(position + 1))
                position -= 1
            }
            let index = PortIndex(entries: shuffled)
            for _ in 0..<3000 {
                let port = UInt16(rng.below(65536))
                var expected = noRuleIndex
                for entry in entries where entry.range.contains(port) {
                    expected = min(expected, entry.ruleIndex)
                }
                XCTAssertEqual(index.lookup(port), expected, "port \(port)")
            }
        }
    }
}

final class PortRangeTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(PortRange("443"), PortRange(443))
        XCTAssertEqual(PortRange("1000-2000"), PortRange(lower: 1000, upper: 2000))
        XCTAssertEqual(PortRange("1000:2000"), PortRange(lower: 1000, upper: 2000))
        XCTAssertEqual(PortRange("0"), PortRange(0))
        XCTAssertEqual(PortRange("65535"), PortRange(65535))
        XCTAssertEqual(PortRange("0-65535")?.description, "0-65535")
        XCTAssertEqual(PortRange("80")?.description, "80")
    }

    func testRejectsInvalid() {
        for text in ["", "-", "80-", "-80", "65536", "2000-1000", "1-2-3", "80a", " 80", "1:2:3", "999999", "1--2"] {
            XCTAssertNil(PortRange(text), "'\(text)' must be rejected")
        }
        XCTAssertNil(PortRange(lower: 2, upper: 1))
    }

    func testCodableRejectsReversedBounds() throws {
        let good = Data("[{\"lower\":1,\"upper\":2}]".utf8)
        XCTAssertEqual(try JSONDecoder().decode([PortRange].self, from: good).map { $0.description }, ["1-2"])
        let bad = Data("[{\"lower\":3,\"upper\":2}]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([PortRange].self, from: bad))
    }
}
