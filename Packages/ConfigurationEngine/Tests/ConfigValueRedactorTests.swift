import Foundation
import XCTest
import DomainModels
@testable import ConfigurationEngine

final class ConfigValueRedactorTests: XCTestCase {
    private let importer = ShareLinkImporter()

    func testDocumentValuesAndPatternsAreRemovedStructureIsKept() {
        let document: JSONValue = .object([
            "tag": .string("proxy-0000"),
            "protocol": .string("vless"),
            "settings": .object([
                "address": .string("vpn.secret-host.example"),
                "id": .string(ProfileFixtures.uuidA),
                "flow": .string("xtls-rprx-vision"),
                "encryption": .string("none"),
            ]),
            "streamSettings": .object([
                "network": .string("xhttp"),
                "security": .string("reality"),
                "realitySettings": .object([
                    "serverName": .string("cdn.front.example"),
                    "fingerprint": .string("chrome"),
                    "password": .string(ProfileFixtures.realityKey),
                    "shortId": .string("0a1b"),
                ]),
                "xhttpSettings": .object(["path": .string("/hidden-path"), "mode": .string("stream-one")]),
            ]),
        ])
        let redactor = ConfigValueRedactor(document: document)
        let text = "dial VPN.SECRET-HOST.EXAMPLE id \(ProfileFixtures.uuidA) sni cdn.front.example key "
            + "\(ProfileFixtures.realityKey) sid 0a1b path /hidden-path other 198.51.100.7, 2001:db8::5, "
            + "2001:0db8:0:0:0:0:0:5, ::1 and \(ProfileFixtures.uuidB) | kept: proxy-0000 vless xhttp reality "
            + "xtls-rprx-vision chrome stream-one none at 12:34:56 port 443"
        let output = redactor.redact(text)
        for secret in ["SECRET-HOST", ProfileFixtures.uuidA, "cdn.front.example", ProfileFixtures.realityKey, " 0a1b ",
                       "hidden-path", "198.51.100.7", "2001:db8::5", "2001:0db8:0:0:0:0:0:5", "::1", ProfileFixtures.uuidB] {
            XCTAssertFalse(output.contains(secret), "\(secret) survived: \(output)")
        }
        for kept in ["proxy-0000", "vless", "xhttp", "reality", "xtls-rprx-vision", "chrome", "stream-one", "none",
                     "12:34:56", "port 443"] {
            XCTAssertTrue(output.contains(kept), "\(kept) was removed: \(output)")
        }
    }

    /// Report messages quote what the profile contains; values a user put in the wrong field must not leak.
    func testCompilerReportsQuoteNoCredentialOrAddress() throws {
        let password = ProfileFixtures.password
        let secrets = [password, ProfileFixtures.uuidB, "203.0.113.77", "vpn.secret-host.example"]
        let method = Data("\(password):\(password)".utf8).base64EncodedString()
        let links = [
            // a password typed into the method field
            "ss://\(method)@192.0.2.1:8388#ss",
            // a UUID in the flow field
            "vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?security=tls&sni=a.example.com&flow=\(ProfileFixtures.uuidB)#f",
            // an address in the fingerprint field
            "vless://\(ProfileFixtures.uuidA)@192.0.2.1:443?security=tls&sni=a.example.com&fp=203.0.113.77#fp",
            // the server's name in the XHTTP mode field
            "vless://\(ProfileFixtures.uuidA)@vpn.secret-host.example:443?type=xhttp&security=tls&mode=vpn.secret-host.example#m",
        ]
        let compiler = XrayConfigCompiler()
        var redactedMessages = 0
        for link in links {
            let outbound = try importer.importLink(link).outbound
            let result = compiler.compileOutbound(outbound, engineTag: "proxy-0000")
            XCTAssertFalse(result.issues.isEmpty, link)
            for issue in result.issues {
                for secret in secrets {
                    XCTAssertNil(issue.detail.range(of: secret, options: .caseInsensitive), "\(issue.path): \(issue.detail)")
                }
                if issue.detail.contains(ConfigValueRedactor.placeholder) {
                    redactedMessages += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(redactedMessages, links.count, "every case quoted a value that had to be removed")
    }

    func testShortAndCommonValuesOfOrdinaryKeysAreKept() {
        let redactor = ConfigValueRedactor(document: .object([
            "headerType": .string("none"), "comment": .string("abc"), "label": .string("visible-label"),
        ]))
        XCTAssertEqual(redactor.redact("none abc"), "none abc")
        XCTAssertEqual(redactor.redact("visible-label"), ConfigValueRedactor.placeholder, "other strings of 6+ characters go")
    }
}
