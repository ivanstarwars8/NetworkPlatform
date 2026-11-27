import XCTest
@testable import ConfigurationEngine

final class YAMLEmitterTests: XCTestCase {
    func testPlainScalars() {
        for text in ["vless", "proxy-0001", "a.b/c", "xtls-rprx-vision", "DOMAIN-SUFFIX", "abc=", "path/to+x", "Host"] {
            XCTAssertEqual(YAMLEmitter.scalar(text), text, text)
        }
    }

    func testReservedWordsAreQuoted() {
        for text in ["true", "False", "YES", "no", "On", "off", "y", "N", "null", "Null", "~"] {
            XCTAssertEqual(YAMLEmitter.scalar(text), "\"\(text)\"", text)
        }
    }

    func testNumberLikeAndIndicatorStringsAreQuoted() {
        for text in ["", "0", "123", "1.5", "0x1F", "0o17", "017", "1e3", ".inf", ".NaN", "-", "-1", "+1", "1:20",
                     "127.0.0.1", "=", "2001:db8::1", "::", "1_000"] {
            XCTAssertTrue(YAMLEmitter.scalar(text).hasPrefix("\""), "'\(text)' must be quoted")
        }
        for text in ["a: b", "a #b", "#x", "a,b", "[x]", "{x}", "&a", "*a", "!t", "|", ">", "'q'", "%x", "@x", "`x`",
                     " lead", "trail ", "two words", "?x", "a:b", "x\u{0}"] {
            XCTAssertTrue(YAMLEmitter.scalar(text).hasPrefix("\""), "'\(text)' must be quoted")
        }
    }

    func testDoubleQuotedEscapes() {
        XCTAssertEqual(YAMLEmitter.scalar("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(YAMLEmitter.scalar("l1\nl2\r\tx"), "\"l1\\nl2\\r\\tx\"")
        XCTAssertEqual(YAMLEmitter.scalar("\u{1}\u{7F}\u{85}"), "\"\\x01\\x7F\\x85\"")
        XCTAssertEqual(YAMLEmitter.scalar("\u{FEFF}\u{2028}"), "\"\\uFEFF\\u2028\"")
        XCTAssertEqual(YAMLEmitter.scalar("\u{0}"), "\"\\0\"")
        // Printable non-ASCII stays as UTF-8 inside quotes.
        XCTAssertEqual(YAMLEmitter.scalar("пароль😀"), "\"пароль😀\"")
    }

    func testBlockLayout() {
        let document = YAMLNode.mapping([
            YAMLPair("mode", .string("rule")),
            YAMLPair("ipv6", .bool(true)),
            YAMLPair("port", .integer(-7)),
            YAMLPair("none", .null),
            YAMLPair("empty-list", .sequence([])),
            YAMLPair("empty-map", .mapping([])),
            YAMLPair("proxies", .sequence([
                .mapping([
                    YAMLPair("name", .string("p")),
                    YAMLPair("reality-opts", .mapping([YAMLPair("short-id", .string("0123"))])),
                    YAMLPair("alpn", .sequence([.string("h2"), .string("http/1.1")])),
                ]),
                .string("x"),
                .sequence([.integer(1), .integer(2)]),
                .mapping([]),
            ])),
        ])
        let expected = """
        mode: rule
        ipv6: true
        port: -7
        none: null
        empty-list: []
        empty-map: {}
        proxies:
          - name: p
            reality-opts:
              short-id: "0123"
            alpn:
              - h2
              - http/1.1
          - x
          -
            - 1
            - 2
          - {}

        """
        XCTAssertEqual(YAMLEmitter.emit(document), expected)
    }

    func testTopLevelScalarAndEmptyDocuments() {
        XCTAssertEqual(YAMLEmitter.emit(.string("x")), "x\n")
        XCTAssertEqual(YAMLEmitter.emit(.mapping([])), "{}\n")
        XCTAssertEqual(YAMLEmitter.emit(.sequence([.string("a")])), "- a\n")
    }

    func testSubscriptAndBuilder() {
        var builder = YAMLMappingBuilder()
        builder.set("a", "1")
        builder.set("b", nil as String?)
        builder.set("a", 2)
        builder.set("c", strings: ["x"])
        XCTAssertEqual(builder.pairs.map { $0.key }, ["a", "c"])
        XCTAssertEqual(builder.node["a"], .integer(2))
        XCTAssertEqual(builder.node["c"]?.sequenceValue, [.string("x")])
        XCTAssertNil(YAMLNode.string("s")["a"])
    }
}
