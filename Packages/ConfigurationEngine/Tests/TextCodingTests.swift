import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

final class TextCodingTests: XCTestCase {

    // MARK: - Percent-encoding

    func testPercentDecode() {
        XCTAssertEqual(PercentCoding.decode("plain"), "plain")
        XCTAssertEqual(PercentCoding.decode(""), "")
        XCTAssertEqual(PercentCoding.decode("a%20b%2Fc%3f"), "a b/c?")
        XCTAssertEqual(PercentCoding.decode("a+b"), "a+b")
        XCTAssertEqual(PercentCoding.decode("%D0%9F%D1%80%D0%B8"), "\u{41F}\u{440}\u{438}")
        XCTAssertEqual(PercentCoding.decode("%F0%9F%9A%80"), "\u{1F680}")
        XCTAssertEqual(PercentCoding.decode("line%0Abreak%09tab"), "line\nbreak\ttab")
    }

    func testPercentDecodeRejectsMalformedInput() {
        XCTAssertNil(PercentCoding.decode("%"))
        XCTAssertNil(PercentCoding.decode("%2"))
        XCTAssertNil(PercentCoding.decode("abc%2"))
        XCTAssertNil(PercentCoding.decode("%zz"))
        XCTAssertNil(PercentCoding.decode("%G0"))
        // Not UTF-8 after decoding.
        XCTAssertNil(PercentCoding.decode("%FF%FE"))
        XCTAssertNil(PercentCoding.decode("%C3"))
        // Control characters.
        XCTAssertNil(PercentCoding.decode("%00"))
        XCTAssertNil(PercentCoding.decode("a%1Bb"))
        XCTAssertNil(PercentCoding.decode("%7F"))
    }

    func testPercentEncode() {
        XCTAssertEqual(PercentCoding.encode("AZaz09-._~", as: .strict), "AZaz09-._~")
        XCTAssertEqual(PercentCoding.encode("a b/c:d,e@f", as: .strict), "a%20b%2Fc%3Ad%2Ce%40f")
        XCTAssertEqual(PercentCoding.encode("a b/c:d,e@f", as: .queryValue), "a%20b/c:d,e@f")
        XCTAssertEqual(PercentCoding.encode("a+b&c=d#e?f%g", as: .queryValue), "a%2Bb%26c%3Dd%23e%3Ff%25g")
        XCTAssertEqual(PercentCoding.encode("\u{41F}", as: .strict), "%D0%9F")
        XCTAssertEqual(PercentCoding.encode("", as: .strict), "")
    }

    func testPercentRoundTrip() {
        let samples = ["", "simple", "sp ace", "sl/ash", "q?u&e=r#y", "100%", "\u{1F680} \u{43C}\u{438}\u{440}", "+-_.~", "a\tb"]
        for sample in samples {
            XCTAssertEqual(PercentCoding.decode(PercentCoding.encode(sample, as: .strict)), sample)
            XCTAssertEqual(PercentCoding.decode(PercentCoding.encode(sample, as: .queryValue)), sample)
        }
    }

    // MARK: - Base64

    func testLenientBase64AcceptsAllCommonSpellings() {
        // "hello?>" exercises both alphabet-specific symbols.
        let standard = Data("hello?>~~".utf8).base64EncodedString()
        XCTAssertEqual(LenientBase64.decodeToString(standard), "hello?>~~")
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(LenientBase64.decodeToString(urlSafe), "hello?>~~")

        XCTAssertEqual(LenientBase64.decodeToString("YQ=="), "a")
        XCTAssertEqual(LenientBase64.decodeToString("YQ"), "a")
        XCTAssertEqual(LenientBase64.decodeToString("YWI="), "ab")
        XCTAssertEqual(LenientBase64.decodeToString("YWI"), "ab")
        XCTAssertEqual(LenientBase64.decodeToString("YWJj"), "abc")
        XCTAssertEqual(LenientBase64.decodeToString(" YW\r\nJj \n"), "abc")
        XCTAssertEqual(LenientBase64.decode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")?.count, 32)
    }

    func testLenientBase64RejectsGarbage() {
        XCTAssertNil(LenientBase64.decode(""))
        XCTAssertNil(LenientBase64.decode("   "))
        XCTAssertNil(LenientBase64.decode("="))
        XCTAssertNil(LenientBase64.decode("a"))
        XCTAssertNil(LenientBase64.decode("abcde"))
        XCTAssertNil(LenientBase64.decode("YQ==YQ=="))
        XCTAssertNil(LenientBase64.decode("YW@j"))
        XCTAssertNil(LenientBase64.decode("vless://x"))
        // Valid base64, invalid UTF-8.
        XCTAssertNotNil(LenientBase64.decode("//79/A=="))
        XCTAssertNil(LenientBase64.decodeToString("//79/A=="))
    }

    func testBase64URLSafeEncoding() {
        XCTAssertEqual(LenientBase64.encodeURLSafe("a"), "YQ")
        XCTAssertEqual(LenientBase64.encodeURLSafe("aes-256-gcm:secret"), "YWVzLTI1Ni1nY206c2VjcmV0")
        let tricky = "hello?>~~"
        let encoded = LenientBase64.encodeURLSafe(tricky)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(LenientBase64.decodeToString(encoded), tricky)
    }

    // MARK: - Small parsers

    func testPortAndIntegerParsing() {
        XCTAssertEqual(Text.parsePort("1"), 1)
        XCTAssertEqual(Text.parsePort("443"), 443)
        XCTAssertEqual(Text.parsePort("65535"), 65535)
        XCTAssertNil(Text.parsePort("0"))
        XCTAssertNil(Text.parsePort("65536"))
        XCTAssertNil(Text.parsePort("999999"))
        XCTAssertNil(Text.parsePort(""))
        XCTAssertNil(Text.parsePort("-1"))
        XCTAssertNil(Text.parsePort("+80"))
        XCTAssertNil(Text.parsePort(" 80"))
        XCTAssertNil(Text.parsePort("8o"))
        XCTAssertNil(Text.parsePort("\u{0664}\u{0664}\u{0663}"))

        XCTAssertEqual(Text.parseNonNegativeInt("0"), 0)
        XCTAssertEqual(Text.parseNonNegativeInt("999999999"), 999_999_999)
        XCTAssertNil(Text.parseNonNegativeInt("1000000000"))
        XCTAssertNil(Text.parseNonNegativeInt("99999999999999999999999999"))
        XCTAssertNil(Text.parseNonNegativeInt("-5"))
        XCTAssertNil(Text.parseNonNegativeInt("1.5"))
    }

    func testBoolAndListParsing() {
        XCTAssertEqual(Text.parseBool("1"), true)
        XCTAssertEqual(Text.parseBool("TRUE"), true)
        XCTAssertEqual(Text.parseBool("0"), false)
        XCTAssertEqual(Text.parseBool("False"), false)
        XCTAssertNil(Text.parseBool(""))
        XCTAssertNil(Text.parseBool("2"))

        XCTAssertEqual(Text.commaList("h2,http/1.1"), ["h2", "http/1.1"])
        XCTAssertEqual(Text.commaList(" a , ,b,, "), ["a", "b"])
        XCTAssertEqual(Text.commaList(""), [])

        XCTAssertEqual(LinkSupport.parsePortList("443"), [PortRange(lower: 443, upper: 443)])
        XCTAssertEqual(LinkSupport.parsePortList("443,5000-6000"), [
            PortRange(lower: 443, upper: 443), PortRange(lower: 5000, upper: 6000),
        ])
        XCTAssertNil(LinkSupport.parsePortList(""))
        XCTAssertNil(LinkSupport.parsePortList("443,"))
        XCTAssertNil(LinkSupport.parsePortList("1-2-3"))
        XCTAssertNil(LinkSupport.parsePortList(Array(repeating: "1", count: 65).joined(separator: ",")))
    }

    // MARK: - URI splitting

    func testParsedURIComponents() throws {
        let uri = try ParsedURI.parse("VLess://user%40x:pa%3Ass@Example.com:8443/some/path?a=1&b=%20#frag%20ment")
        XCTAssertEqual(uri.scheme, "vless")
        XCTAssertEqual(uri.rawUserInfo, "user%40x:pa%3Ass")
        XCTAssertEqual(uri.host, "Example.com")
        XCTAssertFalse(uri.isIPv6Literal)
        XCTAssertEqual(uri.rawPort, "8443")
        XCTAssertEqual(uri.rawPath, "/some/path")
        XCTAssertEqual(uri.rawQuery, "a=1&b=%20")
        XCTAssertEqual(uri.rawFragment, "frag%20ment")

        let bare = try ParsedURI.parse("socks://192.0.2.1")
        XCTAssertNil(bare.rawUserInfo)
        XCTAssertNil(bare.rawPort)
        XCTAssertNil(bare.rawQuery)
        XCTAssertNil(bare.rawFragment)
        XCTAssertEqual(bare.rawPath, "")

        let v6 = try ParsedURI.parse("trojan://pw@[2001:db8::1%25eth0]:443/")
        XCTAssertEqual(v6.host, "2001:db8::1%25eth0")
        XCTAssertTrue(v6.isIPv6Literal)
        XCTAssertEqual(v6.rawPort, "443")
        XCTAssertEqual(v6.rawPath, "/")

        let mapped = try ParsedURI.parse("trojan://pw@[::ffff:192.0.2.1]")
        XCTAssertEqual(mapped.host, "::ffff:192.0.2.1")
        XCTAssertNil(mapped.rawPort)
    }

    func testParsedURIUserInfoEdgeCases() throws {
        // '@' inside the password: the last '@' of the authority separates the host.
        let at = try ParsedURI.parse("trojan://p@ss@w0rd@example.com:443")
        XCTAssertEqual(at.rawUserInfo, "p@ss@w0rd")
        XCTAssertEqual(at.host, "example.com")

        // '/' inside the user information (standard-alphabet base64).
        let slash = try ParsedURI.parse("wireguard://ab/cd+ef==@wg.example.com:51820?publickey=x")
        XCTAssertEqual(slash.rawUserInfo, "ab/cd+ef==")
        XCTAssertEqual(slash.host, "wg.example.com")
        XCTAssertEqual(slash.rawPort, "51820")
        XCTAssertEqual(slash.rawPath, "")

        // '@' in the path does not create user information when the authority has its own.
        let path = try ParsedURI.parse("vless://id@example.com:443/p@th")
        XCTAssertEqual(path.rawUserInfo, "id")
        XCTAssertEqual(path.rawPath, "/p@th")

        // '?' and '#' after the fragment start belong to the fragment.
        let fragment = try ParsedURI.parse("vless://id@example.com:443?x=1#name?with#marks")
        XCTAssertEqual(fragment.rawQuery, "x=1")
        XCTAssertEqual(fragment.rawFragment, "name?with#marks")
    }

    func testHostValidation() {
        XCTAssertTrue(ParsedURI.isValidHostName("example.com"))
        XCTAssertTrue(ParsedURI.isValidHostName("xn--e1afmkfd.xn--p1ai"))
        XCTAssertTrue(ParsedURI.isValidHostName("\u{43F}\u{440}\u{438}\u{43C}\u{435}\u{440}.\u{440}\u{444}"))
        XCTAssertTrue(ParsedURI.isValidHostName("192.0.2.1"))
        XCTAssertFalse(ParsedURI.isValidHostName(""))
        XCTAssertFalse(ParsedURI.isValidHostName("a b"))
        XCTAssertFalse(ParsedURI.isValidHostName("a/b"))
        XCTAssertFalse(ParsedURI.isValidHostName("a:b"))
        XCTAssertFalse(ParsedURI.isValidHostName("a@b"))
        XCTAssertFalse(ParsedURI.isValidHostName(String(repeating: "a", count: 2000)))

        XCTAssertTrue(ParsedURI.isValidIPv6Literal("::1"))
        XCTAssertTrue(ParsedURI.isValidIPv6Literal("2001:db8::1"))
        XCTAssertTrue(ParsedURI.isValidIPv6Literal("fe80::1%25en0"))
        XCTAssertTrue(ParsedURI.isValidIPv6Literal("::ffff:192.0.2.1"))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal(""))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal("1"))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal("example.com"))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal("2001:db8::g"))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal("fe80::1%"))
        XCTAssertFalse(ParsedURI.isValidIPv6Literal(String(repeating: "1:", count: 40)))
    }

    func testSchemeSplitting() {
        XCTAssertEqual(ParsedURI.splitScheme("VLESS://x")?.scheme, "vless")
        XCTAssertEqual(ParsedURI.splitScheme("VLESS://x")?.rest, "x")
        XCTAssertEqual(ParsedURI.splitScheme("a://")?.rest, "")
        XCTAssertNil(ParsedURI.splitScheme("://x"))
        XCTAssertNil(ParsedURI.splitScheme("no scheme://x"))
        XCTAssertNil(ParsedURI.splitScheme("a:/x"))
        XCTAssertNil(ParsedURI.splitScheme("a:"))
        XCTAssertNil(ParsedURI.splitScheme(""))
        XCTAssertNil(ParsedURI.splitScheme(String(repeating: "a", count: 40) + "://x"))
    }

    // MARK: - Parameter bag

    func testParameterBagAccountsForEveryParameter() throws {
        var report = ImportReport(scheme: "test")
        var bag = try ParameterBag(
            rawQuery: "a=1&b=&c=%20x&a=2&novalue&d=4&&e=5",
            limits: .standard, report: &report
        )
        XCTAssertEqual(report.unsupported.map { $0.reason }, [.duplicate])
        XCTAssertEqual(bag.take("a"), "1")
        XCTAssertNil(bag.take("a"))
        XCTAssertNil(bag.takeNonEmpty("b"))
        XCTAssertEqual(bag.takeNonEmpty("c"), " x")
        XCTAssertTrue(bag.contains("novalue"))
        XCTAssertEqual(bag.take("novalue"), "")
        XCTAssertNil(bag.take("missing"))
        bag.finish(knownElsewhere: ["e"], report: &report)
        XCTAssertEqual(report.unsupported.map { $0.name }, ["a", "d", "e"])
        XCTAssertEqual(report.unsupported.map { $0.reason }, [.duplicate, .unknown, .notApplicable])
        XCTAssertEqual(report.unsupported.map { $0.value }, ["2", "4", "5"])
        // Finishing twice records nothing new.
        bag.finish(knownElsewhere: [], report: &report)
        XCTAssertEqual(report.unsupported.count, 3)
    }

    func testParameterBagAliases() throws {
        var report = ImportReport(scheme: "test")
        var bag = try ParameterBag(rawQuery: "insecure=1&allowInsecure=0&sni=a&peer=a", limits: .standard, report: &report)
        XCTAssertEqual(bag.takeFirst(of: ["allowInsecure", "insecure"], report: &report), "0")
        XCTAssertEqual(bag.takeFirst(of: ["sni", "peer"], report: &report), "a")
        XCTAssertNil(bag.takeFirst(of: ["nope", "nada"], report: &report))
        // Only the conflicting alias is recorded; the identical one is not a loss.
        XCTAssertEqual(report.unsupported.map { $0.name }, ["insecure"])
        XCTAssertEqual(report.unsupported.first?.reason, .duplicate)
        bag.finish(knownElsewhere: [], report: &report)
        XCTAssertEqual(report.unsupported.count, 1)
    }

    func testImportLimitsDefaults() {
        let limits = ImportLimits.standard
        XCTAssertEqual(limits, ImportLimits())
        XCTAssertGreaterThan(limits.maximumLinkBytes, 0)
        XCTAssertGreaterThan(limits.maximumSubscriptionBytes, limits.maximumLinkBytes)
        XCTAssertGreaterThan(limits.maximumSubscriptionLines, 0)
        XCTAssertGreaterThan(limits.maximumParameters, 0)
        XCTAssertGreaterThan(limits.maximumJSONDepth, 0)
    }
}
