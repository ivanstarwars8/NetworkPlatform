// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
//
// Tests of Extensions/PacketTunnel/Shared. Those files are compiled into
// this test target through the symbolic link `SharedIPC` next to this file:
// they import only Foundation and DomainModels, and the package manifest has no `TunnelIPC`
// module yet (ADR-0004 §2.3). When that module appears, the link goes away
// and these tests move with the sources.
import Foundation
import DomainModels
import XCTest
@testable import CoreAbstraction

private func assertIPCError(
    _ code: TunnelIPCError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(code.rawValue), but nothing was thrown", file: file, line: line)
    } catch let error as TunnelIPCError {
        XCTAssertEqual(error.code, code, error.message, file: file, line: line)
    } catch {
        XCTFail("expected TunnelIPCError, got \(error)", file: file, line: line)
    }
}

private func assertIPCErrorSync(
    _ code: TunnelIPCError.Code,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> Void
) {
    do {
        try body()
        XCTFail("expected \(code.rawValue), but nothing was thrown", file: file, line: line)
    } catch let error as TunnelIPCError {
        XCTAssertEqual(error.code, code, error.message, file: file, line: line)
    } catch {
        XCTFail("expected TunnelIPCError, got \(error)", file: file, line: line)
    }
}

private let samplePlan = TunnelNetworkPlan(
    remoteAddress: "192.0.2.1",
    ipv4Address: "198.18.0.1",
    ipv4SubnetMask: "255.255.255.252",
    ipv6Address: "fd00::1",
    ipv6PrefixLength: 126,
    dnsServers: ["198.18.0.2"],
    mtu: 1500,
    routesAllIPv4: true,
    routesAllIPv6: true
)

private func sampleRequest(bytes: Int = 2_000) -> TunnelStartRequest {
    var payload = Data(count: bytes)
    for index in 0..<bytes {
        payload[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
    }
    return TunnelStartRequest(coreID: "mock", format: "json", configuration: payload, network: samplePlan)
}

// MARK: - Pending reply

final class TunnelPendingReplyTests: XCTestCase {
    func testReplyBeforeWait() async throws {
        let pending = TunnelPendingReply()
        pending.fulfil(Data([1, 2, 3]))
        XCTAssertTrue(pending.isResolved)
        let reply = try await pending.wait(timeout: 5)
        XCTAssertEqual(reply, Data([1, 2, 3]))
    }

    func testReplyAfterWaitFromAnotherThread() async throws {
        let pending = TunnelPendingReply()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            pending.fulfil(Data([9]))
        }
        let reply = try await pending.wait(timeout: 5)
        XCTAssertEqual(reply, Data([9]))
    }

    func testHandlerThatIsNeverCalledTimesOut() async throws {
        let pending = TunnelPendingReply()
        let began = Date()
        await assertIPCError(.timedOut) {
            _ = try await pending.wait(timeout: 0.1)
        }
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertGreaterThanOrEqual(elapsed, 0.09)
        XCTAssertLessThan(elapsed, 3)
        // A reply that arrives after the deadline is dropped quietly.
        pending.fulfil(Data([1]))
        XCTAssertTrue(pending.isResolved)
    }

    func testNilReplyIsDeliveredAsNil() async throws {
        let pending = TunnelPendingReply()
        pending.fulfil(nil)
        let reply = try await pending.wait(timeout: 5)
        XCTAssertNil(reply)
    }

    func testSendFailure() async throws {
        let pending = TunnelPendingReply()
        pending.fail(TunnelIPCError(.sendFailed, "refused"))
        await assertIPCError(.sendFailed) {
            _ = try await pending.wait(timeout: 5)
        }
    }

    func testOnlyTheFirstOutcomeCounts() async throws {
        let pending = TunnelPendingReply()
        pending.fulfil(Data([1]))
        pending.fulfil(Data([2]))
        pending.fail(TunnelIPCError(.sendFailed, "late"))
        let reply = try await pending.wait(timeout: 5)
        XCTAssertEqual(reply, Data([1]))
    }

    func testCancellationReleasesTheWaiter() async throws {
        let pending = TunnelPendingReply()
        let waiter = Task { () -> TunnelIPCError? in
            do {
                _ = try await pending.wait(timeout: 60)
                return nil
            } catch {
                return error as? TunnelIPCError
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        let began = Date()
        waiter.cancel()
        let error = await waiter.value
        XCTAssertEqual(error?.code, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }

    func testSecondWaitIsRefused() async throws {
        let pending = TunnelPendingReply()
        pending.fulfil(Data([1]))
        _ = try await pending.wait(timeout: 5)
        await assertIPCError(.malformedRequest) {
            _ = try await pending.wait(timeout: 5)
        }
    }

    func testConcurrentHandlersAndDeadlinesResolveEveryWaiterOnce() async throws {
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int: Int].self) { group in
            for number in 0..<300 {
                group.addTask {
                    let pending = TunnelPendingReply()
                    if number % 3 == 0 {
                        // Several racing handler calls.
                        for value in 0..<4 {
                            DispatchQueue.global().async { pending.fulfil(Data([UInt8(value)])) }
                        }
                    } else if number % 3 == 1 {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { pending.fulfil(nil) }
                    }
                    do {
                        let reply = try await pending.wait(timeout: number % 3 == 2 ? 0.05 : 30)
                        return reply == nil ? 1 : 0
                    } catch {
                        return 2
                    }
                }
            }
            var counts: [Int: Int] = [:]
            for await kind in group {
                counts[kind, default: 0] += 1
            }
            return counts
        }
        XCTAssertEqual(outcomes[0], 100, "replies")
        XCTAssertEqual(outcomes[1], 100, "empty replies")
        XCTAssertEqual(outcomes[2], 100, "time-outs")
    }
}

// MARK: - Envelope

final class TunnelExchangeTests: XCTestCase {
    private let request = TunnelRequest(version: TunnelIPC.protocolVersion, id: 7, body: .status)
    private let report = TunnelStatusReport(
        coreID: "mock",
        coreState: "running",
        lastError: nil,
        physicalFootprintBytes: 1_000,
        memoryPressureWarnings: 1,
        memoryPressureCriticals: 0
    )

    private func reply(_ response: TunnelResponse) -> Data? {
        TunnelExchange.encode(response)
    }

    func testRoundTrip() throws {
        let message = try TunnelExchange.encode(request)
        XCTAssertEqual(TunnelExchange.decodeRequest(message), .request(request))

        let response = TunnelResponse(version: TunnelIPC.protocolVersion, id: 7, outcome: .status(report))
        XCTAssertEqual(try TunnelExchange.statusReport(of: reply(response), for: request), report)

        let traffic = TunnelTrafficReport(uplinkBytes: 1, downlinkBytes: .max)
        let statistics = TunnelRequest(version: TunnelIPC.protocolVersion, id: 8, body: .statistics)
        let trafficResponse = TunnelResponse(version: TunnelIPC.protocolVersion, id: 8, outcome: .statistics(traffic))
        XCTAssertEqual(try TunnelExchange.trafficReport(of: reply(trafficResponse), for: statistics), traffic)
    }

    func testMissingAndEmptyReplies() {
        assertIPCErrorSync(.noReply) { _ = try TunnelExchange.outcome(of: nil, for: request) }
        assertIPCErrorSync(.noReply) { _ = try TunnelExchange.outcome(of: Data(), for: request) }
    }

    func testMalformedAndOversizedReplies() {
        assertIPCErrorSync(.malformedReply) { _ = try TunnelExchange.outcome(of: Data("{}".utf8), for: request) }
        assertIPCErrorSync(.malformedReply) { _ = try TunnelExchange.outcome(of: Data([0xFF, 0x00]), for: request) }
        let huge = Data(count: TunnelIPC.maximumMessageBytes + 1)
        assertIPCErrorSync(.messageTooLarge) { _ = try TunnelExchange.outcome(of: huge, for: request) }
    }

    func testVersionAndIdentifierMismatch() {
        let otherVersion = TunnelResponse(version: TunnelIPC.protocolVersion + 1, id: 7, outcome: .status(report))
        assertIPCErrorSync(.unsupportedVersion) { _ = try TunnelExchange.outcome(of: reply(otherVersion), for: request) }
        let otherID = TunnelResponse(version: TunnelIPC.protocolVersion, id: 8, outcome: .status(report))
        assertIPCErrorSync(.mismatchedReply) { _ = try TunnelExchange.outcome(of: reply(otherID), for: request) }
        // A failure addressed to another request is a mismatch, not that failure.
        let foreignFailure = TunnelExchange.failure(id: 8, .notRunning, "x")
        assertIPCErrorSync(.mismatchedReply) { _ = try TunnelExchange.outcome(of: reply(foreignFailure), for: request) }
    }

    func testWrongKindOfReply() {
        let traffic = TunnelResponse(
            version: TunnelIPC.protocolVersion,
            id: 7,
            outcome: .statistics(TunnelTrafficReport(uplinkBytes: 0, downlinkBytes: 0))
        )
        assertIPCErrorSync(.unexpectedReply) { _ = try TunnelExchange.statusReport(of: reply(traffic), for: request) }
    }

    func testFailureOutcomeIsThrownWithItsCode() {
        let failure = TunnelExchange.failure(id: 7, .notRunning, "no engine is running")
        assertIPCErrorSync(.notRunning) { _ = try TunnelExchange.outcome(of: reply(failure), for: request) }
        // id 0: the extension could not decode the request at all.
        let undecodable = TunnelExchange.failure(id: 0, .malformedRequest, "x")
        assertIPCErrorSync(.malformedRequest) { _ = try TunnelExchange.outcome(of: reply(undecodable), for: request) }
    }

    func testUnknownErrorCodeFromANewerPeerSurvives() throws {
        let failure = TunnelExchange.failure(id: 7, TunnelIPCError.Code(rawValue: "code_from_the_future"), "x")
        do {
            _ = try TunnelExchange.outcome(of: reply(failure), for: request)
            XCTFail("expected a failure")
        } catch let error as TunnelIPCError {
            XCTAssertEqual(error.code.rawValue, "code_from_the_future")
        }
    }

    func testErrorCodeIsEncodedAsAPlainString() throws {
        let data = try JSONEncoder().encode(TunnelIPCError(.timedOut, "m"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["code"] as? String, "timed_out")
        XCTAssertEqual(object["message"] as? String, "m")
    }

    func testEngineErrorCodesTravelUnchanged() {
        let code = TunnelIPCError.Code(rawValue: CoreError.timedOut(operation: .statistics, seconds: 2).code)
        XCTAssertEqual(code, .timedOut)
        XCTAssertEqual(TunnelIPCError.Code(rawValue: CoreError.notRunning(state: .idle).code), .notRunning)
        XCTAssertEqual(TunnelIPCError.Code(rawValue: CoreError.cancelled(operation: .start).code), .cancelled)
    }

    func testErrorMessageIsBounded() {
        let error = TunnelIPCError(.sendFailed, String(repeating: "x", count: 10_000))
        XCTAssertEqual(error.message.count, TunnelIPCError.maximumMessageLength + 3)
        XCTAssertEqual(error.summary.hasPrefix("send_failed: xxx"), true)
    }

    func testIncomingMessagesAreRejectedWithAReply() {
        let huge = Data(count: TunnelIPC.maximumMessageBytes + 1)
        XCTAssertEqual(
            TunnelExchange.decodeRequest(huge),
            .rejection(TunnelExchange.failure(id: 0, .messageTooLarge, "message exceeds 65536 bytes"))
        )
        guard case let .rejection(garbage) = TunnelExchange.decodeRequest(Data("not json".utf8)) else {
            return XCTFail("garbage was accepted")
        }
        XCTAssertEqual(garbage.id, 0)
        let old = try? JSONEncoder().encode(TunnelRequest(version: 1, id: 5, body: .status))
        guard case let .rejection(versioned) = TunnelExchange.decodeRequest(old ?? Data()) else {
            return XCTFail("an old version was accepted")
        }
        XCTAssertEqual(versioned.id, 5)
        guard case let .failure(error) = versioned.outcome else { return XCTFail("not a failure") }
        XCTAssertEqual(error.code, .unsupportedVersion)
    }

    func testOversizedReplyIsReplacedByASmallFailure() throws {
        var big = report
        big.lastError = String(repeating: "e", count: TunnelIPC.maximumMessageBytes)
        let response = TunnelResponse(version: TunnelIPC.protocolVersion, id: 7, outcome: .status(big))
        let data = try XCTUnwrap(TunnelExchange.encode(response))
        XCTAssertLessThan(data.count, 1_024)
        assertIPCErrorSync(.messageTooLarge) { _ = try TunnelExchange.outcome(of: data, for: request) }
    }

    /// The whole app-side sequence against a responder that behaves like an
    /// extension, including one that never answers.
    func testRequestSequenceAgainstFakeResponders() async throws {
        func exchange(
            timeout: TimeInterval,
            responder: @escaping @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void
        ) async throws -> TunnelStatusReport {
            let message = try TunnelExchange.encode(request)
            let pending = TunnelPendingReply()
            responder(message) { pending.fulfil($0) }
            return try TunnelExchange.statusReport(of: try await pending.wait(timeout: timeout), for: request)
        }
        let report = self.report

        let answered = try await exchange(timeout: 5) { message, reply in
            DispatchQueue.global().async {
                guard case let .request(incoming) = TunnelExchange.decodeRequest(message) else { return reply(nil) }
                reply(TunnelExchange.encode(
                    TunnelResponse(version: TunnelIPC.protocolVersion, id: incoming.id, outcome: .status(report))
                ))
            }
        }
        XCTAssertEqual(answered, report)

        await assertIPCError(.timedOut) {
            _ = try await exchange(timeout: 0.05) { _, _ in }
        }
        await assertIPCError(.noReply) {
            _ = try await exchange(timeout: 5) { _, reply in reply(nil) }
        }
        await assertIPCError(.notRunning) {
            _ = try await exchange(timeout: 5) { _, reply in
                reply(TunnelExchange.encode(TunnelExchange.failure(id: 7, .notRunning, "no engine")))
            }
        }
    }
}

// MARK: - Network plan

final class TunnelNetworkPlanTests: XCTestCase {
    func testValidPlans() throws {
        try samplePlan.validate()
        var v4Only = samplePlan
        v4Only.ipv6Address = nil
        v4Only.ipv6PrefixLength = nil
        v4Only.routesAllIPv6 = false
        v4Only.dnsServers = []
        v4Only.mtu = 576
        try v4Only.validate()
        var jumbo = samplePlan
        jumbo.mtu = 4064
        try jumbo.validate()
    }

    func testInvalidPlans() {
        func broken(_ change: (inout TunnelNetworkPlan) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var plan = samplePlan
            change(&plan)
            assertIPCErrorSync(.invalidNetworkPlan, file: file, line: line) { try plan.validate() }
        }
        broken { $0.mtu = 575 }
        broken { $0.mtu = 65_536 }
        broken { $0.mtu = 0 }
        broken { $0.mtu = 1_279 }
        broken { $0.remoteAddress = "" }
        broken { $0.ipv4Address = "10.0.0.1 " }
        broken { $0.ipv4SubnetMask = String(repeating: "2", count: 65) }
        broken { $0.ipv6PrefixLength = nil }
        broken { $0.ipv6Address = nil }
        broken { $0.ipv6PrefixLength = 129 }
        broken { $0.ipv6PrefixLength = -1 }
        broken { $0.dnsServers = Array(repeating: "198.18.0.2", count: 17) }
        broken { $0.dnsServers = ["198.18.0.2\n"] }
        broken {
            $0.ipv6Address = nil
            $0.ipv6PrefixLength = nil
        }
        broken { $0.excludedRoutes = [TunnelRoute(address: "10.0.0.0", prefixLength: 33)] }
        broken { $0.excludedRoutes = [TunnelRoute(address: "fe80::", prefixLength: 129)] }
        broken { $0.excludedRoutes = [TunnelRoute(address: "", prefixLength: 8)] }
        broken { $0.excludedRoutes = Array(repeating: TunnelRoute.host("192.0.2.1"), count: 257) }
    }

    /// The interface the extension applies and the configuration the compiler emits share one source of
    /// addresses: `TunnelAddressing`.
    func testPlanFromSharedAddressing() throws {
        let addressing = TunnelAddressing.standard
        let excluded = [TunnelRoute.host("192.0.2.1")] + TunnelAddressing.localRoutes
        let plan = TunnelNetworkPlan(addressing: addressing, excludedRoutes: excluded, remoteAddress: "192.0.2.1")
        try plan.validate()
        XCTAssertEqual(plan.ipv4Address, addressing.ipv4Address)
        XCTAssertEqual(plan.ipv4SubnetMask, "255.255.255.252")
        XCTAssertEqual(plan.ipv6Address, addressing.ipv6Address)
        XCTAssertEqual(plan.ipv6PrefixLength, addressing.ipv6PrefixLength)
        XCTAssertEqual(plan.dnsServers, [addressing.dnsIPv4Address, addressing.dnsIPv6Address].compactMap { $0 })
        XCTAssertEqual(plan.mtu, addressing.mtu)
        XCTAssertTrue(plan.routesAllIPv4)
        XCTAssertTrue(plan.routesAllIPv6)
        XCTAssertEqual(plan.excludedRoutes, excluded)

        var v4Only = addressing
        v4Only.ipv6Address = nil
        v4Only.dnsIPv6Address = nil
        let plan4 = TunnelNetworkPlan(addressing: v4Only, excludedRoutes: [], remoteAddress: "192.0.2.1")
        try plan4.validate()
        XCTAssertNil(plan4.ipv6Address)
        XCTAssertNil(plan4.ipv6PrefixLength)
        XCTAssertFalse(plan4.routesAllIPv6)
        XCTAssertEqual(plan4.dnsServers, [addressing.dnsIPv4Address])
    }

    func testPlanRoundTripAndOlderPlansWithoutExcludedRoutes() throws {
        let plan = TunnelNetworkPlan(addressing: .standard, excludedRoutes: TunnelAddressing.localRoutes, remoteAddress: "192.0.2.1")
        XCTAssertEqual(try JSONDecoder().decode(TunnelNetworkPlan.self, from: JSONEncoder().encode(plan)), plan)
        let older = Data(#"{"remoteAddress":"192.0.2.1","ipv4Address":"198.18.0.1","ipv4SubnetMask":"255.255.255.252","dnsServers":[],"mtu":1500,"routesAllIPv4":true,"routesAllIPv6":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TunnelNetworkPlan.self, from: older)
        XCTAssertEqual(decoded.excludedRoutes, [])
        try decoded.validate()
    }
}

// MARK: - Digest

final class TunnelDigestTests: XCTestCase {
    private func portableHex(_ data: Data) -> String {
        TunnelDigest.hex(TunnelDigest.sha256Portable(data))
    }

    func testStandardVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for (text, expected) in vectors {
            XCTAssertEqual(portableHex(Data(text.utf8)), expected, text)
            XCTAssertEqual(TunnelDigest.sha256Hex(Data(text.utf8)), expected, text)
        }
    }

    func testMillionLetters() {
        let data = Data(repeating: 0x61, count: 1_000_000)
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        XCTAssertEqual(portableHex(data), expected)
        XCTAssertEqual(TunnelDigest.sha256Hex(data), expected)
    }

    func testEveryPaddingBoundaryAndSlices() {
        // Lengths around the 55/56/64-byte padding edges, also as slices of a
        // larger buffer (non-zero start index).
        let backing = Data((0..<400).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var seen = Set<String>()
        for length in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 300] {
            let copy = Data(backing.prefix(length))
            let slice = backing[50..<(50 + length)]
            let moved = Data(backing[50..<(50 + length)])
            XCTAssertEqual(portableHex(slice), portableHex(moved), "slice of length \(length)")
            XCTAssertEqual(TunnelDigest.sha256Hex(copy), portableHex(copy))
            seen.insert(portableHex(copy))
        }
        XCTAssertEqual(seen.count, 15)
    }
}

// MARK: - Container, reference, hand-off

final class ConfigurationHandoffTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-handoff-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func testLimitMatchesTheCoreLimit() {
        XCTAssertEqual(TunnelStartContainer.maximumConfigurationBytes, CoreConfiguration.maximumPayloadBytes)
    }

    func testContainerRoundTrip() throws {
        let request = sampleRequest()
        let container = try TunnelStartContainer.encode(request)
        XCTAssertEqual(try TunnelStartContainer.decode(container), request)
        // The configuration is stored raw, not inflated by an encoding.
        XCTAssertLessThan(container.count, request.configuration.count + 512)
        // Also when handed a slice.
        let padded = Data([0, 0, 0]) + container
        XCTAssertEqual(try TunnelStartContainer.decode(padded[3...]), request)
    }

    func testContainerRejectsDamage() throws {
        let container = try TunnelStartContainer.encode(sampleRequest())
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(Data()) }
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(container.prefix(11)) }
        var badMagic = container
        badMagic[0] = 0x58
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(badMagic) }
        var badVersion = container
        badVersion[7] = 9
        assertIPCErrorSync(.unsupportedVersion) { _ = try TunnelStartContainer.decode(badVersion) }
        var hugeHeader = container
        hugeHeader[8] = 0x7F
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(hugeHeader) }
        var zeroHeader = container
        zeroHeader.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(zeroHeader) }
        var brokenHeader = container
        brokenHeader[12] = 0x21
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(brokenHeader) }
        // Header present, configuration cut off entirely.
        let headerLength = Int(container[10]) << 8 | Int(container[11])
        assertIPCErrorSync(.handoffCorrupt) { _ = try TunnelStartContainer.decode(container.prefix(12 + headerLength)) }
        let oversized = Data(count: TunnelStartContainer.maximumBytes + 1)
        assertIPCErrorSync(.handoffTooLarge) { _ = try TunnelStartContainer.decode(oversized) }
    }

    func testEncodeRejectsBadRequests() {
        var empty = sampleRequest()
        empty.configuration = Data()
        assertIPCErrorSync(.noConfiguration) { _ = try TunnelStartContainer.encode(empty) }
        var badPlan = sampleRequest()
        badPlan.network.mtu = 1
        assertIPCErrorSync(.invalidNetworkPlan) { _ = try TunnelStartContainer.encode(badPlan) }
        var tooLarge = sampleRequest()
        tooLarge.configuration = Data(count: TunnelStartContainer.maximumConfigurationBytes + 1)
        assertIPCErrorSync(.handoffTooLarge) { _ = try TunnelStartContainer.encode(tooLarge) }
        var longName = sampleRequest()
        longName.coreID = String(repeating: "c", count: TunnelStartContainer.maximumHeaderBytes)
        assertIPCErrorSync(.handoffTooLarge) { _ = try TunnelStartContainer.encode(longName) }
    }

    func testLargestAllowedConfigurationPasses() throws {
        var request = sampleRequest(bytes: 16)
        request.configuration = Data(repeating: 0x7B, count: TunnelStartContainer.maximumConfigurationBytes)
        let handoff = ConfigurationHandoff(directory: directory)
        let reference = try handoff.write(request)
        XCTAssertLessThanOrEqual(reference.byteCount, TunnelStartContainer.maximumBytes)
        let received = try handoff.consume(reference)
        XCTAssertEqual(received.configuration.count, TunnelStartContainer.maximumConfigurationBytes)
        XCTAssertEqual(received, request)
    }

    func testStartOptionsStaySmallAndRoundTrip() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let reference = try handoff.write(sampleRequest(bytes: 500_000))
        let options = try reference.startOptions()
        XCTAssertEqual(options.count, 1)
        let boxed = try XCTUnwrap(options[TunnelIPC.startReferenceOptionKey] as? NSData)
        XCTAssertLessThan(boxed.length, 256, "start options must carry a reference, not the configuration")
        XCTAssertEqual(try TunnelStartReference.from(startOptions: options), reference)
        XCTAssertNil(try TunnelStartReference.from(startOptions: nil))
        XCTAssertNil(try TunnelStartReference.from(startOptions: [:]))
        XCTAssertNil(try TunnelStartReference.from(startOptions: ["other": NSNumber(value: 1)]))
    }

    func testMalformedStartOptions() {
        let key = TunnelIPC.startReferenceOptionKey
        assertIPCErrorSync(.malformedStartReference) {
            _ = try TunnelStartReference.from(startOptions: [key: NSNumber(value: 1)])
        }
        assertIPCErrorSync(.malformedStartReference) {
            _ = try TunnelStartReference.from(startOptions: [key: NSData(data: Data("{}".utf8))])
        }
        assertIPCErrorSync(.malformedStartReference) {
            let big = Data(count: TunnelIPC.maximumStartReferenceBytes + 1)
            _ = try TunnelStartReference.from(startOptions: [key: NSData(data: big)])
        }
    }

    func testReferenceValidation() {
        let good = TunnelStartReference(
            version: TunnelIPC.protocolVersion,
            handoffID: UUID().uuidString,
            byteCount: 100,
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertNoThrow(try good.validate())
        func broken(
            _ code: TunnelIPCError.Code,
            _ change: (inout TunnelStartReference) -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            var reference = good
            change(&reference)
            assertIPCErrorSync(code, file: file, line: line) { try reference.validate() }
            assertIPCErrorSync(code, file: file, line: line) { _ = try reference.startOptions() }
        }
        broken(.unsupportedVersion) { $0.version = 1 }
        broken(.malformedStartReference) { $0.handoffID = "../../etc/passwd" }
        broken(.malformedStartReference) { $0.handoffID = "" }
        broken(.malformedStartReference) { $0.handoffID = good.handoffID.lowercased() }
        broken(.malformedStartReference) { $0.handoffID = good.handoffID + "/x" }
        broken(.malformedStartReference) { $0.byteCount = 0 }
        broken(.malformedStartReference) { $0.byteCount = -5 }
        broken(.handoffTooLarge) { $0.byteCount = TunnelStartContainer.maximumBytes + 1 }
        broken(.malformedStartReference) { $0.sha256 = String(repeating: "A", count: 64) }
        broken(.malformedStartReference) { $0.sha256 = String(repeating: "a", count: 63) }
        broken(.malformedStartReference) { $0.sha256 = String(repeating: "g", count: 64) }
    }

    func testWriteConsumeAndSingleUse() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let request = sampleRequest()
        let reference = try handoff.write(request)
        XCTAssertEqual(files(), ["\(reference.handoffID).start"])
        XCTAssertEqual(try handoff.consume(reference), request)
        XCTAssertEqual(files(), [], "a consumed hand-off must be deleted")
        assertIPCErrorSync(.handoffMissing) { _ = try handoff.consume(reference) }
    }

    func testAlteredFileIsRefusedAndDeleted() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let reference = try handoff.write(sampleRequest())
        let url = handoff.fileURL(for: reference.handoffID)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: url)
        assertIPCErrorSync(.handoffCorrupt) { _ = try handoff.consume(reference) }
        XCTAssertEqual(files(), [], "a refused hand-off must not stay on disk")
    }

    func testTruncatedAndExtendedFilesAreRefused() throws {
        let handoff = ConfigurationHandoff(directory: directory)

        let short = try handoff.write(sampleRequest())
        let shortURL = handoff.fileURL(for: short.handoffID)
        try Data(try Data(contentsOf: shortURL).dropLast(10)).write(to: shortURL)
        assertIPCErrorSync(.handoffCorrupt) { _ = try handoff.consume(short) }

        let long = try handoff.write(sampleRequest())
        let longURL = handoff.fileURL(for: long.handoffID)
        try (try Data(contentsOf: longURL) + Data(count: 5_000_000)).write(to: longURL)
        assertIPCErrorSync(.handoffCorrupt) { _ = try handoff.consume(long) }
        XCTAssertEqual(files(), [])
    }

    func testReferenceOfAnotherFileIsRefused() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let first = try handoff.write(sampleRequest(bytes: 1_000))
        let second = try handoff.write(sampleRequest(bytes: 1_000).with(coreID: "other"))
        // Same length class, another digest: the files were swapped.
        var swapped = first
        swapped.handoffID = second.handoffID
        swapped.byteCount = second.byteCount
        assertIPCErrorSync(.handoffCorrupt) { _ = try handoff.consume(swapped) }
        XCTAssertEqual(try handoff.consume(first).coreID, "mock")
    }

    func testMissingDirectoryAndDiscard() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let ghost = TunnelStartReference(
            version: TunnelIPC.protocolVersion,
            handoffID: UUID().uuidString,
            byteCount: 100,
            sha256: String(repeating: "0", count: 64)
        )
        assertIPCErrorSync(.handoffMissing) { _ = try handoff.consume(ghost) }
        handoff.discard(ghost)

        let reference = try handoff.write(sampleRequest())
        handoff.discard(reference)
        XCTAssertEqual(files(), [])
    }

    func testStaleFilesAreSweptOnTheNextWrite() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        let old = try handoff.write(sampleRequest())
        try Data("keep".utf8).write(to: directory.appendingPathComponent("unrelated.txt"))

        // Nothing is stale yet.
        XCTAssertEqual(handoff.removeStale(), 0)
        let later = Date().addingTimeInterval(ConfigurationHandoff.staleAfter + 60)
        let fresh = try handoff.write(sampleRequest(), now: later)
        XCTAssertEqual(files(), ["\(fresh.handoffID).start", "unrelated.txt"].sorted())
        assertIPCErrorSync(.handoffMissing) { _ = try handoff.consume(old) }
    }

    func testUnwritableDirectory() throws {
        // A regular file where the directory should be.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data([1]).write(to: blocker)
        let handoff = ConfigurationHandoff(directory: blocker.appendingPathComponent("inside"))
        assertIPCErrorSync(.handoffWriteFailed) { _ = try handoff.write(sampleRequest()) }
    }

    func testErrorsNeverCarryConfigurationBytes() throws {
        let handoff = ConfigurationHandoff(directory: directory)
        var request = sampleRequest()
        request.configuration = Data("SECRET-PASSWORD-MARKER".utf8)
        let reference = try handoff.write(request)
        let url = handoff.fileURL(for: reference.handoffID)
        var bytes = try Data(contentsOf: url)
        bytes[13] = 0x00
        try bytes.write(to: url)
        do {
            _ = try handoff.consume(reference)
            XCTFail("expected a failure")
        } catch let error as TunnelIPCError {
            XCTAssertFalse(error.summary.contains("SECRET"))
            XCTAssertFalse(error.summary.contains(directory.path))
        }
    }
}

private extension TunnelStartRequest {
    func with(coreID: String) -> TunnelStartRequest {
        var copy = self
        copy.coreID = coreID
        return copy
    }
}
