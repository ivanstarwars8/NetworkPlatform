// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import RoutingEngine

final class IPAddressTests: XCTestCase {
    // MARK: IPv4

    func testParsesIPv4() {
        XCTAssertEqual(IPAddress("192.168.1.1"), .v4(0xC0A8_0101))
        XCTAssertEqual(IPAddress("0.0.0.0"), .v4(0))
        XCTAssertEqual(IPAddress("255.255.255.255"), .v4(0xFFFF_FFFF))
        XCTAssertEqual(IPAddress("10.0.0.1"), IPAddress(v4Octets: 10, 0, 0, 1))
    }

    func testFormatsIPv4() {
        XCTAssertEqual(IPAddress.v4(0xC0A8_0101).description, "192.168.1.1")
        XCTAssertEqual(IPAddress.v4(0).description, "0.0.0.0")
    }

    func testRejectsInvalidIPv4() {
        let invalid = [
            "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.256", "01.2.3.4", "1.2.3.04",
            "1.2.3.4 ", " 1.2.3.4", "1..3.4", "1.2.3.", ".1.2.3", "a.b.c.d", "1.2.3.-4",
            "1.2.3.4/24", "0x7f.0.0.1", "1234.1.1.1", "1,2,3,4", "1.2.3.4.", "1.2.3.4\n",
            "127.1", "2130706433",
        ]
        for text in invalid {
            XCTAssertNil(IPAddress(text), "'\(text)' must be rejected")
        }
    }

    // MARK: IPv6

    func testParsesFullAndCompressedIPv6() {
        XCTAssertEqual(IPAddress("::"), .v6(high: 0, low: 0))
        XCTAssertEqual(IPAddress("::1"), .v6(high: 0, low: 1))
        XCTAssertEqual(IPAddress("1::"), .v6(high: 0x0001_0000_0000_0000, low: 0))
        XCTAssertEqual(IPAddress("2001:db8::1"), .v6(high: 0x2001_0DB8_0000_0000, low: 1))
        XCTAssertEqual(
            IPAddress("2001:0DB8:0000:0000:0000:0000:0000:0001"),
            .v6(high: 0x2001_0DB8_0000_0000, low: 1)
        )
        XCTAssertEqual(
            IPAddress("fe80::1:2:3:4"),
            .v6(high: 0xFE80_0000_0000_0000, low: 0x0001_0002_0003_0004)
        )
        XCTAssertEqual(
            IPAddress("1:2:3:4:5:6:7:8"),
            .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0007_0008)
        )
        XCTAssertEqual(
            IPAddress("1:2:3:4:5:6:7::"),
            .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0007_0000)
        )
        XCTAssertEqual(
            IPAddress("::2:3:4:5:6:7:8"),
            .v6(high: 0x0000_0002_0003_0004, low: 0x0005_0006_0007_0008)
        )
        XCTAssertEqual(IPAddress("1::8"), .v6(high: 0x0001_0000_0000_0000, low: 8))
        XCTAssertEqual(IPAddress("FFFF::ffff"), .v6(high: 0xFFFF_0000_0000_0000, low: 0xFFFF))
    }

    func testParsesEmbeddedIPv4() {
        XCTAssertEqual(
            IPAddress("::ffff:192.168.1.1"),
            .v6(high: 0, low: 0x0000_FFFF_C0A8_0101)
        )
        XCTAssertEqual(IPAddress("::ffff:c0a8:101"), IPAddress("::ffff:192.168.1.1"))
        XCTAssertEqual(
            IPAddress("64:ff9b::192.0.2.33"),
            .v6(high: 0x0064_FF9B_0000_0000, low: 0x0000_0000_C000_0221)
        )
        XCTAssertEqual(
            IPAddress("1:2:3:4:5:6:1.2.3.4"),
            .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0102_0304)
        )
        XCTAssertEqual(IPAddress("::1.2.3.4"), .v6(high: 0, low: 0x0102_0304))
    }

    func testIPv4MappedHandling() throws {
        let mapped = try XCTUnwrap(IPAddress("::ffff:10.1.2.3"))
        XCTAssertTrue(mapped.isIPv4Mapped)
        XCTAssertTrue(mapped.isIPv6)
        XCTAssertEqual(mapped.unmapped, IPAddress("10.1.2.3"))
        XCTAssertEqual(mapped.description, "::ffff:10.1.2.3")

        let plain = try XCTUnwrap(IPAddress("10.1.2.3"))
        XCTAssertFalse(plain.isIPv4Mapped)
        XCTAssertEqual(plain.unmapped, plain)

        // ::1.2.3.4 is IPv4-compatible, not IPv4-mapped.
        let compatible = try XCTUnwrap(IPAddress("::1.2.3.4"))
        XCTAssertFalse(compatible.isIPv4Mapped)
        XCTAssertEqual(compatible.unmapped, compatible)
    }

    func testFormatsIPv6Canonically() {
        let cases: [(String, String)] = [
            ("::", "::"),
            ("::1", "::1"),
            ("1::", "1::"),
            ("2001:0DB8:0000:0000:0000:0000:0000:0001", "2001:db8::1"),
            ("1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8"),
            ("1:2:3:4:5:6:7::", "1:2:3:4:5:6:7:0"),
            ("::2:3:4:5:6:7:8", "0:2:3:4:5:6:7:8"),
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),
            ("2001:0:0:1:0:0:0:1", "2001:0:0:1::1"),
            ("fe80:0:0:0:1:2:3:4", "fe80::1:2:3:4"),
            ("64:ff9b::192.0.2.33", "64:ff9b::c000:221"),
            ("0:0:1:0:0:0:0:0", "0:0:1::"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(IPAddress(input)?.description, expected, "formatting \(input)")
        }
    }

    func testDescriptionRoundTrips() {
        let samples = [
            "0.0.0.0", "8.8.8.8", "::", "::1", "2001:db8::1", "1:2:3:4:5:6:7:8",
            "::ffff:1.2.3.4", "fe80::1", "2001:db8:0:0:1::", "ff02::1:ff00:42",
        ]
        for text in samples {
            guard let parsed = IPAddress(text) else {
                XCTFail("'\(text)' must parse")
                continue
            }
            XCTAssertEqual(IPAddress(parsed.description), parsed, "round trip of \(text)")
        }
    }

    func testRejectsInvalidIPv6() {
        let invalid = [
            ":", ":::", "1:::2", "1::2::3", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9",
            "1:2:3:4:5:6:7:8::", "::1:2:3:4:5:6:7:8", "12345::1", "g::1", "1:", ":1",
            "fe80::1%eth0", "[::1]", "::1.2.3", "1.2.3.4::", "::1.2.3.4:5",
            "1:2:3:4:5:6:7:1.2.3.4", "::ffff:256.1.1.1", "::ffff:01.2.3.4", ":: ", " ::",
            "1:2:3:4:5:6:7:8:", ":1:2:3:4:5:6:7:8", "::g", "1::2:", "::/0",
            "1111:2222:3333:4444:5555:6666:7777:8888:9999:aaaa",
        ]
        for text in invalid {
            XCTAssertNil(IPAddress(text), "'\(text)' must be rejected")
        }
    }

    func testRejectsOverlongInput() {
        let long = String(repeating: "1", count: 200)
        XCTAssertNil(IPAddress(long))
        XCTAssertNil(IPAddress("::" + String(repeating: "0:", count: 100) + "1"))
    }

    // MARK: CIDR

    func testCIDRParsingAndNormalisation() throws {
        let net = try XCTUnwrap(IPCIDR("10.1.2.3/8"))
        XCTAssertEqual(net.network, IPAddress("10.0.0.0"))
        XCTAssertEqual(net.prefixLength, 8)
        XCTAssertEqual(net.description, "10.0.0.0/8")
        XCTAssertEqual(net, IPCIDR("10.0.0.0/8"))

        let host = try XCTUnwrap(IPCIDR("192.168.1.1"))
        XCTAssertEqual(host.prefixLength, 32)

        let host6 = try XCTUnwrap(IPCIDR("2001:db8::1"))
        XCTAssertEqual(host6.prefixLength, 128)

        let net6 = try XCTUnwrap(IPCIDR("2001:db8:ffff::1/32"))
        XCTAssertEqual(net6.description, "2001:db8::/32")
    }

    func testCIDRContainsIPv4() throws {
        let net = try XCTUnwrap(IPCIDR("10.0.0.0/8"))
        XCTAssertTrue(net.contains(try XCTUnwrap(IPAddress("10.255.1.2"))))
        XCTAssertFalse(net.contains(try XCTUnwrap(IPAddress("11.0.0.0"))))
        XCTAssertFalse(net.contains(try XCTUnwrap(IPAddress("::1"))))

        let all = try XCTUnwrap(IPCIDR("0.0.0.0/0"))
        XCTAssertTrue(all.contains(try XCTUnwrap(IPAddress("203.0.113.9"))))
        XCTAssertFalse(all.contains(try XCTUnwrap(IPAddress("2001:db8::1"))))

        let single = try XCTUnwrap(IPCIDR("192.0.2.7/32"))
        XCTAssertTrue(single.contains(try XCTUnwrap(IPAddress("192.0.2.7"))))
        XCTAssertFalse(single.contains(try XCTUnwrap(IPAddress("192.0.2.6"))))

        let odd = try XCTUnwrap(IPCIDR("172.16.0.0/12"))
        XCTAssertTrue(odd.contains(try XCTUnwrap(IPAddress("172.31.255.255"))))
        XCTAssertFalse(odd.contains(try XCTUnwrap(IPAddress("172.32.0.0"))))
    }

    func testCIDRContainsIPv6AcrossWordBoundary() throws {
        let net = try XCTUnwrap(IPCIDR("2001:db8::/32"))
        XCTAssertTrue(net.contains(try XCTUnwrap(IPAddress("2001:db8:ffff::1"))))
        XCTAssertFalse(net.contains(try XCTUnwrap(IPAddress("2001:db9::"))))

        let p64 = try XCTUnwrap(IPCIDR("2001:db8:0:1::/64"))
        XCTAssertTrue(p64.contains(try XCTUnwrap(IPAddress("2001:db8:0:1:ffff:ffff:ffff:ffff"))))
        XCTAssertFalse(p64.contains(try XCTUnwrap(IPAddress("2001:db8:0:2::"))))

        let p65 = try XCTUnwrap(IPCIDR("2001:db8:0:1:8000::/65"))
        XCTAssertTrue(p65.contains(try XCTUnwrap(IPAddress("2001:db8:0:1:ffff::1"))))
        XCTAssertFalse(p65.contains(try XCTUnwrap(IPAddress("2001:db8:0:1:7fff::1"))))

        let p128 = try XCTUnwrap(IPCIDR("2001:db8::5/128"))
        XCTAssertTrue(p128.contains(try XCTUnwrap(IPAddress("2001:db8::5"))))
        XCTAssertFalse(p128.contains(try XCTUnwrap(IPAddress("2001:db8::4"))))

        let all = try XCTUnwrap(IPCIDR("::/0"))
        XCTAssertTrue(all.contains(try XCTUnwrap(IPAddress("ff02::1"))))
        // Families never match each other, and mapped addresses count as IPv4.
        XCTAssertFalse(all.contains(try XCTUnwrap(IPAddress("10.0.0.1"))))
        XCTAssertFalse(all.contains(try XCTUnwrap(IPAddress("::ffff:10.0.0.1"))))
    }

    func testMappedCIDRBecomesIPv4() throws {
        XCTAssertEqual(IPCIDR("::ffff:10.0.0.0/104"), IPCIDR("10.0.0.0/8"))
        XCTAssertEqual(IPCIDR("::ffff:0:0/96"), IPCIDR("0.0.0.0/0"))
        XCTAssertEqual(IPCIDR("::ffff:1.2.3.4"), IPCIDR("1.2.3.4/32"))
        let net = try XCTUnwrap(IPCIDR("10.0.0.0/8"))
        XCTAssertTrue(net.contains(try XCTUnwrap(IPAddress("::ffff:10.9.9.9"))))
        // A shorter prefix reaches outside the mapped block and stays IPv6.
        let wide = try XCTUnwrap(IPCIDR("::ffff:0:0/95"))
        XCTAssertTrue(wide.network.isIPv6)
    }

    func testCIDRCovers() throws {
        let wide = try XCTUnwrap(IPCIDR("10.0.0.0/8"))
        let narrow = try XCTUnwrap(IPCIDR("10.1.0.0/16"))
        XCTAssertTrue(wide.covers(narrow))
        XCTAssertFalse(narrow.covers(wide))
        XCTAssertTrue(wide.covers(wide))
        XCTAssertFalse(wide.covers(try XCTUnwrap(IPCIDR("11.0.0.0/16"))))
        XCTAssertFalse(try XCTUnwrap(IPCIDR("::/0")).covers(wide))
    }

    func testRejectsInvalidCIDR() {
        let invalid = [
            "", "/8", "10.0.0.0/", "10.0.0.0/33", "10.0.0.0/08", "10.0.0.0/00", "10.0.0.0/-1",
            "10.0.0.0/8/8", "10.0.0.0/ 8", "10.0.0.0/1234", "10.0.0.0/a", "::/129", "2001:db8::/200",
            "10.0.0/8", "example.com/8",
        ]
        for text in invalid {
            XCTAssertNil(IPCIDR(text), "'\(text)' must be rejected")
        }
        XCTAssertNotNil(IPCIDR("0.0.0.0/0"))
        XCTAssertNotNil(IPCIDR("::/128"))
        XCTAssertNil(IPCIDR(address: .v4(0), prefixLength: 33))
        XCTAssertNil(IPCIDR(address: .v4(0), prefixLength: -1))
        XCTAssertNil(IPCIDR(address: .v6(high: 0, low: 0), prefixLength: 129))
    }

    func testCodableRoundTrip() throws {
        let addresses = [try XCTUnwrap(IPAddress("10.0.0.1")), try XCTUnwrap(IPAddress("2001:db8::1"))]
        let addressData = try JSONEncoder().encode(addresses)
        XCTAssertEqual(try JSONDecoder().decode([IPAddress].self, from: addressData), addresses)

        let prefixes = [try XCTUnwrap(IPCIDR("10.0.0.0/8")), try XCTUnwrap(IPCIDR("2001:db8::/32"))]
        let prefixData = try JSONEncoder().encode(prefixes)
        XCTAssertEqual(try JSONDecoder().decode([IPCIDR].self, from: prefixData), prefixes)

        let bad = Data("[\"10.0.0.0/99\"]".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([IPCIDR].self, from: bad))
    }

    // MARK: Bit helpers

    func testIPBits() {
        let bits = IPBits(high: 0x8000_0000_0000_0001, low: 0x8000_0000_0000_0001)
        XCTAssertEqual(bits.bit(at: 0), 1)
        XCTAssertEqual(bits.bit(at: 1), 0)
        XCTAssertEqual(bits.bit(at: 63), 1)
        XCTAssertEqual(bits.bit(at: 64), 1)
        XCTAssertEqual(bits.bit(at: 65), 0)
        XCTAssertEqual(bits.bit(at: 127), 1)

        XCTAssertEqual(bits.masked(to: 0), IPBits(high: 0, low: 0))
        XCTAssertEqual(bits.masked(to: 1), IPBits(high: 0x8000_0000_0000_0000, low: 0))
        XCTAssertEqual(bits.masked(to: 64), IPBits(high: 0x8000_0000_0000_0001, low: 0))
        XCTAssertEqual(bits.masked(to: 65), IPBits(high: 0x8000_0000_0000_0001, low: 0x8000_0000_0000_0000))
        XCTAssertEqual(bits.masked(to: 128), bits)

        XCTAssertEqual(bits.commonPrefixLength(with: bits), 128)
        XCTAssertEqual(bits.commonPrefixLength(with: IPBits(high: 0, low: 0)), 0)
        XCTAssertEqual(bits.commonPrefixLength(with: IPBits(high: 0x8000_0000_0000_0000, low: 0)), 63)
        XCTAssertEqual(bits.commonPrefixLength(with: IPBits(high: 0x8000_0000_0000_0001, low: 0)), 64)
        XCTAssertEqual(
            bits.commonPrefixLength(with: IPBits(high: 0x8000_0000_0000_0001, low: 0x8000_0000_0000_0000)),
            127
        )
    }
}
