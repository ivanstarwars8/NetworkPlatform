import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

final class SubscriptionDecoderTests: XCTestCase {

    private let decoder = SubscriptionDecoder()

    private let lineOne = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?security=tls&sni=example.com#one"
    private let lineTwo = "trojan://pw@example.org:443#two"

    /// base64 (standard alphabet, padded) of `lineOne CRLF lineTwo CRLF`.
    private let paddedBase64 =
        "dmxlc3M6Ly9iODMxMzgxZC02MzI0LTRkNTMtYWQ0Zi04Y2RhNDhiMzA4MTFAZXhhbXBsZS5jb206NDQzP3NlY3VyaXR5PXRscyZz"
        + "bmk9ZXhhbXBsZS5jb20jb25lDQp0cm9qYW46Ly9wd0BleGFtcGxlLm9yZzo0NDMjdHdvDQo="

    private func assertTwoEntries(
        _ result: SubscriptionImport,
        encoding: SubscriptionImport.Encoding,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.encoding, encoding, file: file, line: line)
        XCTAssertEqual(result.entries.map { $0.outbound.name }, ["one", "two"], file: file, line: line)
        XCTAssertEqual(result.entries.map { $0.outbound.kind }, [.vless, .trojan], file: file, line: line)
        XCTAssertEqual(result.entries.map { $0.lineNumber }, [1, 2], file: file, line: line)
        XCTAssertEqual(result.failures, [], file: file, line: line)
        XCTAssertEqual(result.warnings, [], file: file, line: line)
        XCTAssertEqual(result.truncatedLineCount, 0, file: file, line: line)
    }

    // MARK: - Encodings

    func testFixtureMatchesItsDescription() {
        let expected = Data((lineOne + "\r\n" + lineTwo + "\r\n").utf8).base64EncodedString()
        XCTAssertEqual(paddedBase64, expected)
    }

    func testBase64WithPadding() throws {
        assertTwoEntries(try decoder.decode(text: paddedBase64), encoding: .base64)
        assertTwoEntries(try decoder.decode(Data(paddedBase64.utf8)), encoding: .base64)
    }

    func testBase64WithoutPadding() throws {
        let unpadded = paddedBase64.replacingOccurrences(of: "=", with: "")
        XCTAssertNotEqual(unpadded, paddedBase64)
        assertTwoEntries(try decoder.decode(text: unpadded), encoding: .base64)
    }

    func testBase64URLAlphabetWithAndWithoutPadding() throws {
        // '>' and '?' in the payload force the '+' and '/' symbols of the standard alphabet.
        let body = "trojan://p>>>w@example.org:443?sni=a>>?b#one\n" + lineTwo.replacingOccurrences(of: "two", with: "t??") + "\n"
        let standard = Data(body.utf8).base64EncodedString()
        XCTAssertTrue(standard.contains("+") || standard.contains("/"))
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let urlSafeUnpadded = urlSafe.replacingOccurrences(of: "=", with: "")

        for variant in [standard, urlSafe, urlSafeUnpadded] {
            let result = try decoder.decode(text: variant)
            XCTAssertEqual(result.encoding, .base64)
            XCTAssertEqual(result.entries.count, 2)
            XCTAssertEqual(result.failures, [])
            XCTAssertEqual(result.entries.first?.outbound.credentials.password, .inline("p>>>w"))
        }
    }

    func testBase64WrappedAcrossLinesAndSurroundedByWhitespace() throws {
        var wrapped = "\n  "
        var count = 0
        for character in paddedBase64 {
            wrapped.append(character)
            count += 1
            if count % 76 == 0 {
                wrapped += "\r\n"
            }
        }
        wrapped += "\n\n"
        assertTwoEntries(try decoder.decode(text: wrapped), encoding: .base64)
    }

    func testPlainListWithLFAndCRLFAndCR() throws {
        assertTwoEntries(try decoder.decode(text: lineOne + "\n" + lineTwo), encoding: .plain)
        assertTwoEntries(try decoder.decode(text: lineOne + "\r\n" + lineTwo + "\r\n"), encoding: .plain)
        assertTwoEntries(try decoder.decode(text: lineOne + "\r" + lineTwo), encoding: .plain)
    }

    func testByteOrderMark() throws {
        var plain: [UInt8] = [0xEF, 0xBB, 0xBF]
        plain.append(contentsOf: Array((lineOne + "\r\n" + lineTwo).utf8))
        assertTwoEntries(try decoder.decode(Data(plain)), encoding: .plain)

        var encoded: [UInt8] = [0xEF, 0xBB, 0xBF]
        encoded.append(contentsOf: Array(paddedBase64.utf8))
        assertTwoEntries(try decoder.decode(Data(encoded)), encoding: .base64)

        assertTwoEntries(try decoder.decode(text: "\u{FEFF}" + lineOne + "\n" + lineTwo), encoding: .plain)

        // A BOM inside the base64 payload is removed as well.
        var inner: [UInt8] = [0xEF, 0xBB, 0xBF]
        inner.append(contentsOf: Array((lineOne + "\n" + lineTwo).utf8))
        assertTwoEntries(try decoder.decode(text: Data(inner).base64EncodedString()), encoding: .base64)
    }

    // MARK: - Per-line accounting

    func testBlankLinesCommentsAndLineNumbers() throws {
        let body = [
            "# provider header",
            "",
            lineOne,
            "   ",
            "// another comment",
            "\t" + lineTwo + "  ",
        ].joined(separator: "\r\n")
        let result = try decoder.decode(text: body)
        XCTAssertEqual(result.entries.map { $0.lineNumber }, [3, 6])
        XCTAssertEqual(result.entries.map { $0.outbound.name }, ["one", "two"])
        XCTAssertEqual(result.commentLineCount, 2)
        XCTAssertEqual(result.failures, [])
    }

    func testPerLineErrorsAreCollectedAndGoodLinesSurvive() throws {
        let body = [
            lineOne,
            "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com?security=tls#no-port",
            "https://example.com/not-a-proxy",
            "garbage without scheme",
            "vmess://!!!!",
            lineTwo,
            "ss://bm9jb2xvbg@example.com:8388#bad-ss",
        ].joined(separator: "\n")
        let result = try decoder.decode(text: body)
        XCTAssertEqual(result.encoding, .plain)
        XCTAssertEqual(result.entries.map { $0.lineNumber }, [1, 6])
        XCTAssertEqual(result.outbounds.map { $0.name }, ["one", "two"])
        XCTAssertEqual(result.failures, [
            SubscriptionImport.Failure(lineNumber: 2, scheme: "vless", error: .missingField("port")),
            SubscriptionImport.Failure(lineNumber: 3, scheme: "https", error: .unsupportedScheme("https")),
            SubscriptionImport.Failure(lineNumber: 4, scheme: nil, error: .malformedLink(reason: "missing scheme")),
            SubscriptionImport.Failure(lineNumber: 5, scheme: "vmess", error: .invalidBase64(context: "vmess")),
            SubscriptionImport.Failure(lineNumber: 7, scheme: "ss", error: .missingField("password")),
        ])
    }

    func testEntryReportsAreKept() throws {
        let body = lineOne + "&mystery=1\n" + lineTwo
        let result = try decoder.decode(text: body.replacingOccurrences(of: "#one&mystery=1", with: "&mystery=1#one"))
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].report.unsupportedParameter(named: "mystery")?.value, "1")
        XCTAssertEqual(result.entries[0].outbound.unsupported.count, 1)
        XCTAssertTrue(result.entries[1].report.isLossless)
    }

    func testDuplicateNamesGetUniqueTags() throws {
        let body = [lineTwo, lineTwo, lineOne, lineTwo].joined(separator: "\n")
        let result = try decoder.decode(text: body)
        XCTAssertEqual(result.outbounds.map { $0.tag }, ["two", "two (2)", "one", "two (3)"])
        XCTAssertEqual(result.outbounds.map { $0.name }, ["two", "two", "one", "two"])
        XCTAssertEqual(Set(result.outbounds.map { $0.tag }).count, 4)
        XCTAssertEqual(result.warnings.map { $0.code }, [.suspiciousValue])

        let profile = Profile(name: "sub", source: .subscription(url: "https://example.com/s"), outbounds: result.outbounds)
        XCTAssertEqual(profile.validate(), [])
    }

    // MARK: - Limits and rejection

    func testOversizedBodyIsRejectedBeforeDecoding() {
        let small = SubscriptionDecoder(limits: ImportLimits(maximumSubscriptionBytes: 64))
        let body = lineOne + "\n" + lineTwo
        XCTAssertThrowsError(try small.decode(text: body)) { error in
            XCTAssertEqual(error as? ImportError, .inputTooLarge(limit: 64, actual: body.utf8.count))
        }
        XCTAssertThrowsError(try small.decode(Data(body.utf8))) { error in
            XCTAssertEqual(error as? ImportError, .inputTooLarge(limit: 64, actual: body.utf8.count))
        }

        let limit = ImportLimits.standard.maximumSubscriptionBytes
        let huge = Data(repeating: 0x41, count: limit + 1)
        XCTAssertThrowsError(try decoder.decode(huge)) { error in
            XCTAssertEqual(error as? ImportError, .inputTooLarge(limit: limit, actual: limit + 1))
        }
    }

    func testLineLimitTruncatesAndReports() throws {
        let limited = SubscriptionDecoder(limits: ImportLimits(maximumSubscriptionLines: 2))
        let body = ["# c", lineOne, "", "broken://x", lineTwo, lineOne].joined(separator: "\n")
        let result = try limited.decode(text: body)
        XCTAssertEqual(result.entries.map { $0.lineNumber }, [2])
        XCTAssertEqual(result.failures.map { $0.lineNumber }, [4])
        XCTAssertEqual(result.truncatedLineCount, 2)
        XCTAssertEqual(result.commentLineCount, 1)
        XCTAssertEqual(result.warnings.map { $0.code }, [.truncated])
    }

    func testOversizedLineFailsAloneWithoutStoppingTheRest() throws {
        let limits = ImportLimits(maximumLinkBytes: 128)
        let long = "trojan://pw@example.org:443#" + String(repeating: "x", count: 200)
        let result = try SubscriptionDecoder(limits: limits).decode(text: lineTwo + "\n" + long + "\n" + lineTwo)
        XCTAssertEqual(result.entries.map { $0.lineNumber }, [1, 3])
        XCTAssertEqual(result.failures, [
            SubscriptionImport.Failure(
                lineNumber: 2, scheme: "trojan",
                error: .inputTooLarge(limit: 128, actual: long.utf8.count)
            ),
        ])
    }

    func testRejectsWhatIsNotASubscription() {
        func assertError(_ text: String, _ expected: ImportError, line: UInt = #line) {
            XCTAssertThrowsError(try decoder.decode(text: text), line: line) { error in
                XCTAssertEqual(error as? ImportError, expected, line: line)
            }
        }
        assertError("", .emptyInput)
        assertError(" \r\n\t\n", .emptyInput)
        assertError("\u{FEFF}", .emptyInput)
        assertError("<html><body>502 Bad Gateway</body></html>", .notASubscription)
        assertError("{\"error\":\"expired\"}", .notASubscription)
        assertError("proxies:\n  - name: a\n    type: ss", .notASubscription)
        // Valid base64, but of text that contains no links.
        assertError("aGVsbG8gd29ybGQsIHRoaXMgaXMgbm90IGEgc3Vic2NyaXB0aW9u", .notASubscription)
        // Valid base64 of bytes that are not UTF-8.
        assertError(Data([0xFF, 0xFE, 0xFD, 0xFC]).base64EncodedString(), .notASubscription)
        assertError("a", .notASubscription)

        XCTAssertThrowsError(try decoder.decode(Data([0xFF, 0xFE, 0x00, 0x41]))) { error in
            XCTAssertEqual(error as? ImportError, .invalidUTF8)
        }
    }

    func testMixedSchemesFromFixtures() throws {
        let links = [
            Fixtures.vlessRealityVision, Fixtures.vlessXHTTP, Fixtures.vlessWebSocketTLS, Fixtures.trojanGRPC,
            Fixtures.vmessWebSocketJSON, Fixtures.vmessGRPCJSON, Fixtures.vmessURL,
            Fixtures.shadowsocksSIP002, Fixtures.shadowsocks2022, Fixtures.shadowsocksLegacy,
            Fixtures.hysteria2, Fixtures.hy2Short, Fixtures.tuic,
            Fixtures.socksBase64, Fixtures.socksPlain, Fixtures.wireGuard,
        ]
        let body = Data(links.joined(separator: "\r\n").utf8).base64EncodedString()
        let result = try decoder.decode(text: body)
        XCTAssertEqual(result.encoding, .base64)
        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.entries.count, links.count)
        XCTAssertEqual(result.outbounds.map { $0.kind }, [
            .vless, .vless, .vless, .trojan, .vmess, .vmess, .vmess,
            .shadowsocks, .shadowsocks, .shadowsocks, .hysteria2, .hysteria2, .tuic,
            .socks, .socks, .wireGuard,
        ])
        XCTAssertEqual(Set(result.outbounds.map { $0.tag }).count, links.count)

        // Each entry equals a direct import of its line.
        let importer = ShareLinkImporter()
        for (index, link) in links.enumerated() {
            let direct = try importer.importLink(link)
            XCTAssertEqual(result.entries[index].outbound, direct.outbound)
            XCTAssertEqual(result.entries[index].report, direct.report)
        }
    }
}
