import XCTest
@testable import NetworkToolbox

final class SHA256Tests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testKnownVectors() {
        XCTAssertEqual(hex(SHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }
}

final class CertificateTests: XCTestCase {
    // Self-signed test certificates made with openssl for these tests only (no real host).
    static let ecCertificate = "MIIB1zCCAX2gAwIBAgIDEjSrMAoGCCqGSM49BAMCMCkxFDASBgNVBAMMC2J5ay5leGFtcGxlMREwDwYDVQQKDAhCeWsgVGVzdDAeFw0yNjExMjcyMzAzMTVaFw0zNjExMjQyMzAzMTVaMCkxFDASBgNVBAMMC2J5ay5leGFtcGxlMREwDwYDVQQKDAhCeWsgVGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABF5VBorgF1aADo3YzOo9iQEEAyweBui3G20S0KIBCZQ0SWGbgEpRuJ73Q1FEbGPlzUeWa/BeSMjFrXAnvl+6azKjgZMwgZAwHQYDVR0OBBYEFESXwqtUs4yRdbdpqWRJR1GWPXfWMB8GA1UdIwQYMBaAFESXwqtUs4yRdbdpqWRJR1GWPXfWMA8GA1UdEwEB/wQFMAMBAf8wPQYDVR0RBDYwNIILYnlrLmV4YW1wbGWCDSouYnlrLmV4YW1wbGWHBMAAAgeHECABDbgAAAAAAAAAAAAAAAcwCgYIKoZIzj0EAwIDSAAwRQIgN0ttglGl+cwuS5eH4vMsommQi6PiAf2zbO1McRrpHDUCIQDRZW+KcqxXbT7POCSroyDQhJPHos33DbFQ4XnyAV5pEA=="
    static let rsaCertificate = "MIIDDTCCAfWgAwIBAgIUYQ8mkUVQMYa8X/Om8uHTrioxJJ0wDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcnNhLmV4YW1wbGUwHhcNMjYxMTI3MjMwMzE2WhcNMjYxMjI3MjMwMzE2WjAWMRQwEgYDVQQDDAtyc2EuZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANRxLs/h/FO4AKS2vK/tIjpzXCjg+913I/MY65LvYdfHbIu42FIvKo2bJNH7jUTu2ofuheP8SSuNy/W0dHDXxDK6nImXgWZCAZsdgEL4iNRzk+uJmDoQVcgGW4Nu3rivK50HQg4TybTS4N8IvcA8jvjU4F36dQcR4z3NBGzkMsEfYOkZ3WSJFpJwEKOrMXCxJTicOGQSPjrEw+hvjQAciLXuM8SZoYiEGs+R31bwa/PDiisJWnLWtG3rZshCTwfQKYJ5yENs2K7krs3q8jjsWjYs75prTyZqxMFXF202RQj0vwyyJgQlGJVrm4Fi5vuLkBNV1+y2clHsfFkW4dVpygcCAwEAAaNTMFEwHQYDVR0OBBYEFNoiww34Tn78qE2sWORKCxpudL1xMB8GA1UdIwQYMBaAFNoiww34Tn78qE2sWORKCxpudL1xMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBALXeA8Q9pZYDFH27P4MwxhDiyyCIUZL5/Oytyhcmrn1ri/L+teR1a82fs3n1vmgGSGq6pVhhBt//Q50xcYDf+zAdTEuw4isSMFmrXdyOhL8N9ahxYE5jzeCSrg6a+ea2eQtHLtAV/CtSSmifds3pRbRENnoETnDUE6S7k36hTF+arjfg/riGZDRYlAr6w4zVTSGjK0LgvGDNudiuBnxGOkS0C8TbnND+XRFnv0A3z0ENnvZbNDLOleoWRPmP8D7Cvjg9yd/Cz9f7Qy/KLsIOZniL+FhsgDSywH5xMKMM4ZL5F9V6+/e+cSH60gHV4huU6FglBpcQozM2y4g7XPYEWDo="

    private func der(_ base64: String) -> [UInt8] { Array(Data(base64Encoded: base64)!) }

    func testECCertificateSummary() throws {
        let summary = try XCTUnwrap(CertificateParser.summary(der: der(Self.ecCertificate)))
        XCTAssertEqual(summary.subjectCommonName, "byk.example")
        XCTAssertEqual(summary.subjectOrganization, "Byk Test")
        XCTAssertEqual(summary.issuerCommonName, "byk.example")
        XCTAssertEqual(summary.serialNumberHex, "1234AB")
        XCTAssertEqual(summary.dnsNames, ["byk.example", "*.byk.example"])
        XCTAssertEqual(summary.ipAddresses, ["192.0.2.7", "2001:db8::7"])
        XCTAssertEqual(summary.publicKey, "ECDSA P-256")
        XCTAssertEqual(summary.signatureAlgorithm, "ECDSA с SHA-256")
        XCTAssertEqual(
            summary.sha256Fingerprint.replacingOccurrences(of: ":", with: "").lowercased(),
            "8aac3ade8196475bbfbbaa13eab140927c8404e16683f52492ef3357402e1490"
        )
        // notBefore=Nov 27 23:03:15 2026 GMT, notAfter=Nov 24 23:03:15 2036 GMT
        XCTAssertEqual(summary.notBefore, Date(timeIntervalSince1970: 1_795_820_595))
        XCTAssertEqual(summary.notAfter, Date(timeIntervalSince1970: 2_111_180_595))
    }

    func testRSACertificateSummary() throws {
        let summary = try XCTUnwrap(CertificateParser.summary(der: der(Self.rsaCertificate)))
        XCTAssertEqual(summary.subjectTitle, "rsa.example")
        XCTAssertEqual(summary.publicKey, "RSA 2048 бит")
        XCTAssertEqual(summary.signatureAlgorithm, "RSA с SHA-256")
        XCTAssertTrue(summary.dnsNames.isEmpty)
        XCTAssertTrue(summary.covers(host: "rsa.example"), "falls back to the common name without SANs")
    }

    func testHostCoverage() throws {
        let summary = try XCTUnwrap(CertificateParser.summary(der: der(Self.ecCertificate)))
        XCTAssertTrue(summary.covers(host: "byk.example"))
        XCTAssertTrue(summary.covers(host: "WWW.byk.example"))
        XCTAssertFalse(summary.covers(host: "a.b.byk.example"), "a wildcard covers one label")
        XCTAssertFalse(summary.covers(host: "otherbyk.example"))
        XCTAssertTrue(summary.covers(host: "192.0.2.7"))
        XCTAssertTrue(summary.covers(host: "[2001:db8:0::7]"))
        XCTAssertFalse(summary.covers(host: "192.0.2.8"))
    }

    func testValidity() throws {
        let summary = try XCTUnwrap(CertificateParser.summary(der: der(Self.ecCertificate)))
        XCTAssertEqual(summary.validity(at: Date(timeIntervalSince1970: 1_700_000_000)), .notYetValid)
        XCTAssertEqual(summary.validity(at: Date(timeIntervalSince1970: 2_200_000_000)), .expired)
        XCTAssertEqual(summary.validity(at: Date(timeIntervalSince1970: 2_111_180_595 - 86_400 * 10 - 5)), .valid(daysLeft: 10))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(CertificateParser.summary(der: []))
        XCTAssertNil(CertificateParser.summary(der: [0x30, 0x82, 0xFF, 0xFF]))
        let full = der(Self.ecCertificate)
        for cut in stride(from: 1, to: full.count, by: 7) {
            XCTAssertNil(CertificateParser.summary(der: Array(full.prefix(cut))), "truncated at \(cut)")
        }
    }
}

final class DNSMessageTests: XCTestCase {
    private let typeAClassIN: [UInt8] = [0x00, 0x01, 0x00, 0x01]
    private let typeAAAAClassIN: [UInt8] = [0x00, 0x1C, 0x00, 0x01]

    /// Length-prefixed labels and the root byte.
    private func labels(_ parts: String...) -> [UInt8] {
        var bytes: [UInt8] = []
        for part in parts {
            let utf8 = Array(part.utf8)
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        return bytes
    }

    func testQueryEncoding() throws {
        let query = try DNSMessage.query(id: 0xBEEF, name: "example.com.", type: .aaaa)
        XCTAssertEqual(Array(query.prefix(12)), [0xBE, 0xEF, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(query.dropFirst(12)), labels("example", "com") + typeAAAAClassIN)
    }

    func testPunycode() throws {
        XCTAssertEqual(Punycode.encode("пример"), "e1afmkfd")
        XCTAssertEqual(Punycode.encode("рф"), "p1ai")
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        let name = try DNSMessage.encodeName("пример.рф")
        XCTAssertEqual(name, labels("xn--e1afmkfd", "xn--p1ai"))
        XCTAssertEqual(HostName.ascii("сайт.пример.рф"), "xn--80aswg.xn--e1afmkfd.xn--p1ai")
        XCTAssertEqual(HostName.ascii("example.com"), "example.com")
    }

    func testInvalidNames() {
        XCTAssertThrowsError(try DNSMessage.encodeName(""))
        XCTAssertThrowsError(try DNSMessage.encodeName("a..b"))
        XCTAssertThrowsError(try DNSMessage.encodeName(String(repeating: "a", count: 64) + ".com"))
        XCTAssertThrowsError(try DNSMessage.encodeName("with space.com"))
    }

    /// A response with a CNAME (compressed) and an A and AAAA record.
    func testResponseParsing() throws {
        var message: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00]
        message += labels("www", "example", "com")
        message += typeAClassIN
        // CNAME www.example.com -> example.com (pointer to offset 16)
        let cname: [UInt8] = [0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x0E, 0x10, 0x00, 0x02, 0xC0, 0x10]
        message += cname
        // A example.com 93.184.216.34
        let a: [UInt8] = [0xC0, 0x10, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 93, 184, 216, 34]
        message += a
        // AAAA example.com 2001:db8::1
        let aaaa: [UInt8] = [0xC0, 0x10, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x10,
                             0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        message += aaaa
        let response = try DNSMessage.parse(message)
        XCTAssertEqual(response.id, 0x1234)
        XCTAssertEqual(response.responseCodeName, "NOERROR")
        XCTAssertTrue(response.recursionAvailable)
        XCTAssertEqual(response.answers.count, 3)
        XCTAssertEqual(response.answers[0].value, .name("example.com"))
        XCTAssertEqual(response.answers[0].ttl, 3600)
        XCTAssertEqual(response.answers[0].name, "www.example.com")
        XCTAssertEqual(response.addresses, ["93.184.216.34", "2001:db8::1"])

        for cut in 0..<message.count {
            XCTAssertThrowsError(try DNSMessage.parse(Array(message.prefix(cut))), "truncated at \(cut)")
        }
    }

    func testPointerLoopIsRejected() {
        var message: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
        let looping: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1] // name points at itself
        message += looping
        XCTAssertThrowsError(try DNSMessage.parse(message))
    }

    func testNXDomainAndQueryBit() throws {
        let nx: [UInt8] = [0, 9, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(try DNSMessage.parse(nx).responseCodeName, "NXDOMAIN")
        let query: [UInt8] = [0, 9, 0x01, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try DNSMessage.parse(query))
    }

    func testIPv6Formatting() {
        func bytes(_ groups: [UInt16]) -> [UInt8] {
            var result: [UInt8] = []
            for group in groups {
                result.append(UInt8(group >> 8))
                result.append(UInt8(group & 0xFF))
            }
            return result
        }
        XCTAssertEqual(IPv6Text.format(bytes([0, 0, 0, 0, 0, 0, 0, 1])), "::1")
        XCTAssertEqual(IPv6Text.format(bytes([0, 0, 0, 0, 0, 0, 0, 0])), "::")
        XCTAssertEqual(IPv6Text.format(bytes([0xfe80, 0, 0, 0, 0, 0, 0, 0])), "fe80::")
        XCTAssertEqual(IPv6Text.format(bytes([0x2001, 0xdb8, 0, 1, 0, 0, 0, 1])), "2001:db8:0:1::1")
        XCTAssertEqual(IPv6Text.format(bytes([0x2001, 0xdb8, 1, 2, 3, 4, 5, 6])), "2001:db8:1:2:3:4:5:6")
    }
}

final class SocketTests: XCTestCase {
    func testEndpointParsing() throws {
        let v4 = try XCTUnwrap(SocketEndpoint(address: " 192.0.2.1 ", port: 443))
        XCTAssertFalse(v4.isIPv6)
        XCTAssertEqual(v4.displayText, "192.0.2.1:443")
        let v6 = try XCTUnwrap(SocketEndpoint(address: "[2001:DB8::0:1]", port: 53))
        XCTAssertTrue(v6.isIPv6)
        XCTAssertEqual(v6.address, "2001:db8::1")
        XCTAssertEqual(v6.displayText, "[2001:db8::1]:53")
        XCTAssertNil(SocketEndpoint(address: "example.com", port: 80), "names are not resolved here")
        XCTAssertNil(SocketEndpoint(address: "", port: 80))
    }

    /// A closed loopback port answers with a reset: refused, quickly. No listener is opened by the test.
    func testRefusedOnClosedLoopbackPort() throws {
        let endpoint = try XCTUnwrap(SocketEndpoint(address: "127.0.0.1", port: 1))
        let outcome = TCPProbe.connect(to: endpoint, timeout: 2)
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(PortState(outcome), .closed)
    }

    func testPingIsBoundedAndCancellable() throws {
        let endpoint = try XCTUnwrap(SocketEndpoint(address: "127.0.0.1", port: 1))
        let outcomes = TCPProbe.ping(endpoint, count: 500, timeout: 1, interval: 0)
        XCTAssertEqual(outcomes.count, ProbeLimits.pingCountRange.upperBound)
        var calls = 0
        let cancelled = TCPProbe.ping(endpoint, count: 5, timeout: 1, interval: 0) { calls += 1; return calls > 2 }
        XCTAssertEqual(cancelled.count, 2)
    }

    func testLatencySummary() {
        let summary = LatencySummary(samples: [0.010, nil, 0.030, 0.020])
        XCTAssertEqual(summary.sent, 4)
        XCTAssertEqual(summary.received, 3)
        XCTAssertEqual(summary.minimum, 0.010)
        XCTAssertEqual(summary.maximum, 0.030)
        XCTAssertEqual(summary.average!, 0.020, accuracy: 1e-9)
        XCTAssertEqual(summary.jitter!, 0.015, accuracy: 1e-9)
        XCTAssertEqual(summary.lossPercent, 25)
        let empty = LatencySummary(samples: [])
        XCTAssertNil(empty.average)
        XCTAssertEqual(empty.lossPercent, 0)
    }

    func testResolverReturnsLiteralsWithoutLookup() {
        guard case let .success(resolution) = SystemResolver.resolve("2001:db8::1", timeout: 1) else {
            return XCTFail("literal not accepted")
        }
        XCTAssertEqual(resolution.addresses, ["2001:db8::1"])
        guard case let .success(local) = SystemResolver.resolve("localhost", timeout: 3) else {
            return XCTFail("localhost did not resolve")
        }
        XCTAssertTrue(local.addresses.contains { $0 == "127.0.0.1" || $0 == "::1" })
    }

    /// No network in the test container: a UDP query to a closed loopback port fails or times out within
    /// the bound, it never hangs.
    func testDNSLookupIsBounded() throws {
        let resolver = try XCTUnwrap(SocketEndpoint(address: "127.0.0.1", port: 9))
        let start = Date()
        let result = DNSClient.lookup("example.com", type: .a, resolver: resolver, timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        if case .success = result { XCTFail("nobody listens on port 9") }
    }

    func testInterfaceAddressesIncludeLoopback() {
        let addresses = AddressClassifier.interfaceAddresses()
        XCTAssertTrue(addresses.contains { $0.scope == .loopback })
    }

    func testSystemResolverConfigurationIsReadable() {
        // The container may have no resolvers; the call must still answer.
        XCTAssertNotNil(SystemDNSConfiguration.resolvers())
        XCTAssertEqual(SystemDNSConfiguration.split(Array("1.1.1.1\0::1\0\0".utf8CString), count: 2), ["1.1.1.1", "::1"])
        XCTAssertEqual(SystemDNSConfiguration.split(Array("8.8.8.8\08.8.8.8\0".utf8CString), count: 2), ["8.8.8.8"])
    }
}

final class AddressTests: XCTestCase {
    func testScopes() {
        XCTAssertEqual(AddressClassifier.scope(of: "127.0.0.1"), .loopback)
        XCTAssertEqual(AddressClassifier.scope(of: "192.168.1.5"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(of: "172.20.0.1"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(of: "172.32.0.1"), .global)
        XCTAssertEqual(AddressClassifier.scope(of: "100.70.1.1"), .carrierNAT)
        XCTAssertEqual(AddressClassifier.scope(of: "198.18.0.1"), .tunnel)
        XCTAssertEqual(AddressClassifier.scope(of: "fe80::1"), .linkLocal)
        XCTAssertEqual(AddressClassifier.scope(of: "fd66:6e70::1"), .privateNetwork)
        XCTAssertEqual(AddressClassifier.scope(of: "2a00:1450::1"), .global)
        XCTAssertEqual(AddressClassifier.scope(of: "::1"), .loopback)
    }

    func testTraceParsing() {
        let body = Data("fl=1\nh=1.1.1.1\nip=203.0.113.9\nts=1\nloc=DE\nwarp=off\n".utf8)
        XCTAssertEqual(PublicAddressService.parse(body), PublicAddressService.Trace(address: "203.0.113.9", location: "DE"))
        let v6 = Data("ip=2001:DB8::5\nloc=XYZ\n".utf8)
        XCTAssertEqual(PublicAddressService.parse(v6), PublicAddressService.Trace(address: "2001:db8::5", location: nil))
        XCTAssertNil(PublicAddressService.parse(Data("ip=not-an-ip\n".utf8)))
        XCTAssertNil(PublicAddressService.parse(Data(repeating: 0x41, count: 5000)))
    }

    func testInputs() {
        XCTAssertEqual(try URLInput.httpsURL("example.com/path").get().absoluteString, "https://example.com/path")
        XCTAssertEqual(URLInput.httpsURL("http://example.com").failureValue, .notHTTPS)
        XCTAssertEqual(URLInput.httpsURL("https://u:p@example.com").failureValue, .credentials)
        XCTAssertEqual(URLInput.httpsURL("   ").failureValue, .empty)
        XCTAssertEqual(HostInput.host(" [2001:db8::1] "), "2001:db8::1")
        XCTAssertNil(HostInput.host("a b"))
        XCTAssertNil(HostInput.host("example.com/x"))
        XCTAssertEqual(HostInput.port("443"), 443)
        XCTAssertNil(HostInput.port("0"))
        XCTAssertNil(HostInput.port("70000"))
    }
}

final class HTTPTimingTests: XCTestCase {
    func testPhasesWithTLS() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let stamps = HTTPTimestamps(
            fetchStart: t0,
            domainLookupStart: t0.addingTimeInterval(0.001), domainLookupEnd: t0.addingTimeInterval(0.021),
            connectStart: t0.addingTimeInterval(0.021), secureConnectionStart: t0.addingTimeInterval(0.051),
            secureConnectionEnd: t0.addingTimeInterval(0.111), connectEnd: t0.addingTimeInterval(0.111),
            requestStart: t0.addingTimeInterval(0.112), responseStart: t0.addingTimeInterval(0.212),
            responseEnd: t0.addingTimeInterval(0.250)
        )
        let phases = HTTPPhases(stamps)
        XCTAssertEqual(phases.dns!, 0.020, accuracy: 1e-6)
        XCTAssertEqual(phases.connect!, 0.030, accuracy: 1e-6)
        XCTAssertEqual(phases.tls!, 0.060, accuracy: 1e-6)
        XCTAssertEqual(phases.firstByte!, 0.100, accuracy: 1e-6)
        XCTAssertEqual(phases.total!, 0.250, accuracy: 1e-6)
    }

    func testReusedConnectionHasNoHandshakePhases() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let phases = HTTPPhases(HTTPTimestamps(fetchStart: t0, requestStart: t0, responseStart: t0.addingTimeInterval(0.05), reusedConnection: true))
        XCTAssertNil(phases.dns)
        XCTAssertNil(phases.connect)
        XCTAssertNil(phases.tls)
        XCTAssertEqual(phases.firstByte!, 0.05, accuracy: 1e-6)
        XCTAssertNil(HTTPPhases.interval(t0.addingTimeInterval(1), t0), "out-of-order stamps are not a phase")
    }
}

final class DNSPathCheckTests: XCTestCase {
    let tunnel = ["198.18.0.2", "fd66:6e70::2"]

    func testVerdicts() {
        XCTAssertEqual(DNSPathCheck(tunnelConnected: false, tunnelResolvers: tunnel, systemResolvers: ["192.168.1.1"], probe: .notRun).verdict, .tunnelOff)
        XCTAssertEqual(DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: ["198.18.0.2"], probe: .answered(seconds: 0.01)).verdict, .protected)
        XCTAssertEqual(DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: ["FD66:6E70:0::2"], probe: .answered(seconds: 0.01)).verdict, .protected)
        XCTAssertEqual(
            DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: ["198.18.0.2", "192.168.1.1"], probe: .answered(seconds: 0.01)).verdict,
            .leaking(outside: ["192.168.1.1"])
        )
        XCTAssertEqual(DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: ["198.18.0.2"], probe: .failed("timeout")).verdict, .tunnelResolverSilent)
        XCTAssertEqual(DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: nil, probe: .notRun).verdict, .unknown)
        XCTAssertEqual(DNSPathCheck(tunnelConnected: true, tunnelResolvers: tunnel, systemResolvers: [], probe: .notRun).verdict, .unknown)
    }
}

final class AnalyzerTests: XCTestCase {
    func testRateSampler() {
        var sampler = RateSampler()
        let now = Date()
        XCTAssertNil(sampler.add(up: 0, down: 0, monotonicTime: 10, wallTime: now))
        let point = sampler.add(up: 1000, down: 125_000, monotonicTime: 11, wallTime: now)
        XCTAssertEqual(point?.downBitsPerSecond, 1_000_000)
        XCTAssertEqual(point?.upBitsPerSecond, 8000)
        XCTAssertNil(sampler.add(up: 10, down: 10, monotonicTime: 12, wallTime: now), "counters went back: engine restarted")
        XCTAssertNil(sampler.add(up: 20, down: 20, monotonicTime: 30, wallTime: now), "gap too long")
        XCTAssertNotNil(sampler.add(up: 30, down: 30, monotonicTime: 31, wallTime: now))
    }

    func testBoundedHistory() {
        var history = BoundedHistory<Int>(capacity: 3)
        XCTAssertNil(history.last)
        (1...5).forEach { history.append($0) }
        XCTAssertEqual(history.elements, [3, 4, 5])
        XCTAssertEqual(history.last, 5)
        history.removeAll()
        XCTAssertTrue(history.isEmpty)
        history.append(9)
        XCTAssertEqual(history.elements, [9])
    }

    func testAxisMaximum() {
        XCTAssertEqual(TrafficGraph.axisMaximum([]), 10_000)
        let point = RatePoint(time: Date(), downBitsPerSecond: 3_400_000, upBitsPerSecond: 100)
        XCTAssertEqual(TrafficGraph.axisMaximum([point]), 5_000_000)
        let exact = RatePoint(time: Date(), downBitsPerSecond: 2_000_000, upBitsPerSecond: 0)
        XCTAssertEqual(TrafficGraph.axisMaximum([exact]), 2_000_000)
    }

    func testTimelineCollapsesRepeatsAndIsBounded() {
        var timeline = EventTimeline()
        timeline.record(.error, "A")
        timeline.record(.error, "A")
        timeline.record(.network, "Wi-Fi")
        XCTAssertEqual(timeline.events.count, 2)
        XCTAssertEqual(timeline.events[0].repeats, 2)
        XCTAssertEqual(timeline.events(of: .network).map(\.text), ["Wi-Fi"])
        for index in 0..<500 { timeline.record(.tunnel, "e\(index)") }
        XCTAssertEqual(timeline.events.count, EventTimeline.capacity)
        XCTAssertEqual(timeline.events.last?.text, "e499")
        timeline.clear()
        XCTAssertTrue(timeline.events.isEmpty)
    }

    func testConnectionTracker() {
        func record(_ id: String) -> ConnectionRecord {
            ConnectionRecord(id: id, network: "tcp", destination: "example.com:443", rule: nil, chain: [], uploadBytes: 0, downloadBytes: 0, started: nil)
        }
        var tracker = ConnectionTracker()
        tracker.update([record("1"), record("2")])
        tracker.update([record("2"), record("3")])
        XCTAssertEqual(tracker.active.map(\.id), ["2", "3"])
        XCTAssertEqual(tracker.recentlyClosed.map(\.id), ["1"])
        tracker.update([])
        XCTAssertEqual(tracker.recentlyClosed.map(\.id), ["3", "2", "1"])
        tracker.clear()
        XCTAssertTrue(tracker.recentlyClosed.isEmpty)
    }
}

final class RedactionTests: XCTestCase {
    let redactor = DiagnosticsRedactor()

    func testSecretsAndAddressesAreRemoved() {
        let samples = [
            "vless://3f1c2a4e-1111-4222-8333-944455556666@edge.example.org:443?sni=cdn.example.org",
            "uuid 3f1c2a4e-1111-4222-8333-944455556666 failed",
            "dial tcp 203.0.113.10:8443: connection refused",
            "dial tcp [2001:db8::10]:443: timeout",
            "server edge.example.org did not answer",
            "сервер сайт.пример.рф недоступен",
            "public key ZlZ0dGhpc2lzYWtleWJhc2U2NDEyMzQ1Njc4OTA",
            "password=hunter2",
            "user me@example.com",
        ]
        let secrets = ["3f1c2a4e", "edge.example.org", "cdn.example.org", "203.0.113.10", "2001:db8::10", "сайт.пример.рф",
                       "ZlZ0dGhpc2lzYWtleWJhc2U2NDEyMzQ1Njc4OTA", "hunter2", "me@example.com"]
        for sample in samples {
            let output = redactor.redact(sample)
            for secret in secrets {
                XCTAssertFalse(output.contains(secret), "\(secret) left in \(output)")
            }
        }
    }

    func testReadableTextIsKept() {
        XCTAssertEqual(redactor.redact("Туннель подключён в 22:51:09"), "Туннель подключён в 22:51:09")
        XCTAssertEqual(redactor.redact("Состояние движка: running"), "Состояние движка: running")
        XCTAssertEqual(redactor.redact("Отправлено: 12,5 МБ"), "Отправлено: 12,5 МБ")
        XCTAssertEqual(redactor.redact("2026-11-27T22:51:09Z туннель"), "2026-11-27T22:51:09Z туннель")
        XCTAssertEqual(redactor.redact("Версия: 0.1.0 (410), iOS/iPadOS 26.1.0"), "Версия: 0.1.0 (410), iOS/iPadOS 26.1.0")
    }

    func testBundleText() {
        let tags = ["proxy-my-home-server", "direct"]
        let names = DiagnosticsBundle.neutralNames(for: tags)
        XCTAssertEqual(names["direct"], "выход 1")
        XCTAssertEqual(names["proxy-my-home-server"], "выход 2")
        let bundle = DiagnosticsBundle(sections: [
            .init(title: "Туннель", lines: [("Состояние", "Подключено"), ("Ошибка", "dial 198.51.100.4:443 refused")]),
        ])
        let text = bundle.text()
        XCTAssertTrue(text.contains("## Туннель"))
        XCTAssertTrue(text.contains("Состояние: Подключено"))
        XCTAssertFalse(text.contains("198.51.100.4"))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
