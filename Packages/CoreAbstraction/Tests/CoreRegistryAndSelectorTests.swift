// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import CoreAbstraction

private func descriptor(
    _ id: CoreIdentifier,
    version: String = "1.0",
    protocols: Set<CoreProtocol> = [],
    transports: Set<CoreTransport> = [],
    features: Set<CoreFeature> = []
) -> CoreDescriptor {
    CoreDescriptor(
        id: id,
        displayName: "Core \(id)",
        version: version,
        capabilities: CoreCapabilities(protocols: protocols, transports: transports, features: features)
    )
}

final class CoreCapabilitiesTests: XCTestCase {
    func testSatisfiesAndMissing() {
        let have = CoreCapabilities(
            protocols: [.vless, .trojan],
            transports: [.tcp, .grpc],
            features: [.trafficStatistics]
        )
        XCTAssertTrue(have.satisfies(.none))
        XCTAssertTrue(have.satisfies(CoreCapabilities(protocols: [.vless], transports: [.tcp])))
        XCTAssertTrue(have.satisfies(have))
        XCTAssertFalse(have.satisfies(CoreCapabilities(protocols: [.hysteria2])))
        XCTAssertFalse(have.satisfies(CoreCapabilities(protocols: [.vless], features: [.hotReload])))

        let required = CoreCapabilities(
            protocols: [.vless, .hysteria2],
            transports: [.xhttp],
            features: [.trafficStatistics, .hotReload]
        )
        let missing = have.missing(from: required)
        XCTAssertEqual(missing, CoreCapabilities(protocols: [.hysteria2], transports: [.xhttp], features: [.hotReload]))
        XCTAssertEqual(missing.count, 3)
        XCTAssertFalse(missing.isEmpty)
        XCTAssertTrue(have.missing(from: have).isEmpty)
        XCTAssertTrue(CoreCapabilities.none.isEmpty)
    }

    func testSetAlgebra() {
        let a = CoreCapabilities(protocols: [.vless], transports: [.tcp], features: [.hotReload])
        let b = CoreCapabilities(protocols: [.vless, .trojan], transports: [.grpc], features: [])
        XCTAssertEqual(
            a.union(b),
            CoreCapabilities(protocols: [.vless, .trojan], transports: [.tcp, .grpc], features: [.hotReload])
        )
        XCTAssertEqual(a.intersection(b), CoreCapabilities(protocols: [.vless]))
    }

    func testDescriptionIsSortedAndStable() {
        let capabilities = CoreCapabilities(
            protocols: [.vmess, .trojan, .vless],
            transports: [.websocket, .grpc],
            features: []
        )
        XCTAssertEqual(capabilities.description, "protocols [trojan, vless, vmess]; transports [grpc, websocket]")
        XCTAssertEqual(CoreCapabilities.none.description, "nothing")
        XCTAssertEqual(
            CoreCapabilities(features: [.hotReload]).description,
            "features [hot-reload]"
        )
    }

    func testOpenSetsAcceptUnknownNames() {
        let exotic: CoreProtocol = "some-future-protocol"
        let capabilities = CoreCapabilities(protocols: [exotic])
        XCTAssertTrue(capabilities.satisfies(CoreCapabilities(protocols: ["some-future-protocol"])))
        XCTAssertEqual(exotic.rawValue, "some-future-protocol")
        XCTAssertEqual(CoreIdentifier("xray"), "xray")
        XCTAssertLessThan(CoreIdentifier("a"), CoreIdentifier("b"))
    }

    func testCodableRoundTrip() throws {
        let original = descriptor(
            "engine",
            version: "25.1.0",
            protocols: [.vless, .shadowsocks],
            transports: [.tcp, .httpUpgrade],
            features: [.memoryReporting]
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([CoreDescriptor].self, from: data)
        XCTAssertEqual(decoded, [original])
        // Identifiers are encoded as plain strings.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"engine\""), text)
        XCTAssertTrue(text.contains("\"vless\""), text)
    }
}

final class CoreErrorTests: XCTestCase {
    private struct Foreign: Error, CustomStringConvertible {
        let description: String
    }

    func testNormalise() {
        let known = CoreError.unsupportedFeature(.hotReload)
        XCTAssertEqual(CoreError.normalise(known, during: .start), known)
        XCTAssertEqual(CoreError.normalise(CancellationError(), during: .stop), .cancelled(operation: .stop))
        XCTAssertEqual(
            CoreError.normalise(Foreign(description: "dial tcp: timeout"), during: .reload),
            .operationFailed(operation: .reload, message: "dial tcp: timeout")
        )
    }

    func testForeignMessagesAreBounded() {
        let long = String(repeating: "e", count: 5_000)
        guard case let .operationFailed(_, message) = CoreError.normalise(Foreign(description: long), during: .start) else {
            XCTFail("expected operationFailed")
            return
        }
        XCTAssertEqual(message.count, CoreError.maximumMessageLength + 3)
        XCTAssertTrue(message.hasSuffix("..."))

        let exact = String(repeating: "e", count: CoreError.maximumMessageLength)
        XCTAssertEqual(
            CoreError.normalise(Foreign(description: exact), during: .start),
            .operationFailed(operation: .start, message: exact)
        )
    }

    func testCodesAreStableAndDistinct() {
        let samples: [CoreError] = [
            .invalidConfiguration(issues: []),
            .configurationMismatch(expected: "a", actual: "b"),
            .unsupportedFeature(.hotReload),
            .illegalTransition(from: .idle, event: .stop),
            .notRunning(state: .idle),
            .coreNotRegistered("a"),
            .coreAlreadyRegistered("a"),
            .noCompatibleCore(reasons: ["r"]),
            .operationFailed(operation: .start, message: "m"),
            .unexpectedExit(message: "m"),
            .cancelled(operation: .start),
        ]
        let codes = samples.map { $0.code }
        XCTAssertEqual(codes, [
            "invalid_configuration", "configuration_mismatch", "unsupported_feature", "illegal_transition",
            "not_running", "core_not_registered", "core_already_registered", "no_compatible_core",
            "operation_failed", "unexpected_exit", "cancelled",
        ])
        XCTAssertEqual(Set(codes).count, samples.count)
        for sample in samples {
            XCTAssertFalse(sample.description.isEmpty)
        }
    }

    func testDescriptions() {
        let issues = [
            CoreValidationIssue(severity: .error, path: "dns", message: "no servers"),
            CoreValidationIssue(severity: .error, message: "bad tag"),
            CoreValidationIssue(severity: .error, message: "three"),
            CoreValidationIssue(severity: .error, message: "four"),
        ]
        XCTAssertEqual(
            CoreError.invalidConfiguration(issues: issues).description,
            "invalid configuration: dns: no servers; bad tag; three; and 1 more"
        )
        XCTAssertEqual(
            CoreError.illegalTransition(from: .idle, event: .stop).description,
            "'stop' is not allowed in state 'idle'"
        )
        XCTAssertEqual(
            CoreError.operationFailed(operation: .start, message: "boom").description,
            "start failed: boom"
        )
    }

    func testValueTypes() {
        XCTAssertTrue(CoreValidationReport.valid.isValid)
        let warningOnly = CoreValidationReport(issues: [CoreValidationIssue(severity: .warning, message: "w")])
        XCTAssertTrue(warningOnly.isValid)
        XCTAssertEqual(warningOnly.warnings.count, 1)
        XCTAssertTrue(warningOnly.errors.isEmpty)

        XCTAssertEqual(TrafficCounters(uplinkBytes: 1, downlinkBytes: 2).totalBytes, 3)
        XCTAssertEqual(TrafficCounters(uplinkBytes: UInt64.max, downlinkBytes: 2).totalBytes, UInt64.max)
        XCTAssertEqual(CoreStartOptions.none, CoreStartOptions())
    }
}

final class CoreSelectorTests: XCTestCase {
    private let alpha = descriptor("alpha", protocols: [.vless, .trojan], transports: [.tcp, .xhttp], features: [.trafficStatistics])
    private let beta = descriptor("beta", protocols: [.vless, .hysteria2], transports: [.tcp], features: [.hotReload, .selectorGroups])
    private let gamma = descriptor("gamma", protocols: [.vless], transports: [.tcp])

    func testPicksTheOnlyEligibleCore() {
        let required = CoreCapabilities(protocols: [.hysteria2], transports: [.tcp])
        let selection = CoreSelector().select(from: [alpha, beta, gamma], required: required)
        XCTAssertEqual(selection.selected, beta)
        XCTAssertEqual(selection.candidates.map { $0.descriptor.id }, ["alpha", "beta", "gamma"])
        XCTAssertEqual(selection.candidates.map { $0.isEligible }, [false, true, false])
        XCTAssertEqual(selection.candidates[0].missing, CoreCapabilities(protocols: [.hysteria2]))
        XCTAssertEqual(selection.reasons, [
            "required: protocols [hysteria2]; transports [tcp]",
            "'alpha' 1.0: rejected, missing protocols [hysteria2]",
            "'beta' 1.0: eligible",
            "'gamma' 1.0: rejected, missing protocols [hysteria2]",
            "selected 'beta': the only eligible core",
        ])
    }

    func testPreferenceOrderWinsAmongEligible() {
        let required = CoreCapabilities(protocols: [.vless], transports: [.tcp])
        let selector = CoreSelector(preference: ["gamma", "alpha"])
        let selection = selector.select(from: [alpha, beta, gamma], required: required)
        XCTAssertEqual(selection.selected, gamma)
        XCTAssertEqual(selection.reasons.last, "selected 'gamma': eligible and number 1 in the preference order")
    }

    func testIneligiblePreferredCoreIsSkippedWithAReason() {
        let required = CoreCapabilities(protocols: [.trojan])
        let selector = CoreSelector(preference: ["beta", "missing", "alpha"])
        let selection = selector.select(from: [alpha, beta, gamma], required: required)
        XCTAssertEqual(selection.selected, alpha)
        XCTAssertEqual(Array(selection.reasons.suffix(3)), [
            "preferred 'beta' is not eligible",
            "preferred 'missing' is not available",
            "selected 'alpha': eligible and number 3 in the preference order",
        ])
    }

    func testFallsBackToLowestIdentifier() {
        let required = CoreCapabilities(protocols: [.vless])
        let selection = CoreSelector().select(from: [gamma, beta, alpha], required: required)
        XCTAssertEqual(selection.selected, alpha)
        XCTAssertEqual(selection.reasons.last, "selected 'alpha': lowest identifier among 3 eligible cores")

        // A preference that names no eligible core does not change that.
        let preferring = CoreSelector(preference: ["nope"]).select(from: [gamma, beta, alpha], required: required)
        XCTAssertEqual(preferring.selected, alpha)
    }

    func testResultDoesNotDependOnInputOrder() {
        let required = CoreCapabilities(protocols: [.vless], transports: [.tcp])
        let orders: [[CoreDescriptor]] = [
            [alpha, beta, gamma], [alpha, gamma, beta], [beta, alpha, gamma],
            [beta, gamma, alpha], [gamma, alpha, beta], [gamma, beta, alpha],
        ]
        let selector = CoreSelector(preference: ["beta"])
        let reference = selector.select(from: orders[0], required: required)
        XCTAssertEqual(reference.selected, beta)
        for order in orders {
            XCTAssertEqual(selector.select(from: order, required: required), reference)
        }
    }

    func testNothingEligible() {
        let required = CoreCapabilities(protocols: [.wireguard], features: [.memoryReporting])
        let selection = CoreSelector(preference: ["alpha"]).select(from: [alpha, beta], required: required)
        XCTAssertNil(selection.selected)
        XCTAssertEqual(selection.reasons, [
            "required: protocols [wireguard]; features [memory-reporting]",
            "'alpha' 1.0: rejected, missing protocols [wireguard]; features [memory-reporting]",
            "'beta' 1.0: rejected, missing protocols [wireguard]; features [memory-reporting]",
            "no core selected: none of 2 available cores has every required capability",
        ])

        XCTAssertThrowsError(try CoreSelector().requireSelection(from: [alpha, beta], required: required)) { error in
            guard case let .noCompatibleCore(reasons)? = error as? CoreError else {
                XCTFail("expected noCompatibleCore, got \(error)")
                return
            }
            XCTAssertEqual(reasons.count, 4)
        }
    }

    func testNoCores() {
        let selection = CoreSelector().select(from: [], required: .none)
        XCTAssertNil(selection.selected)
        XCTAssertTrue(selection.candidates.isEmpty)
        XCTAssertEqual(selection.reasons, ["required: nothing", "no core selected: no cores are available"])
    }

    func testEmptyRequirementAcceptsAnyCore() throws {
        let selected = try CoreSelector().requireSelection(from: [gamma, beta], required: .none)
        XCTAssertEqual(selected, beta)
    }

    func testDuplicateIdentifiersAreIgnoredDeterministically() {
        let older = descriptor("alpha", version: "1.0", protocols: [.vless])
        let newer = descriptor("alpha", version: "2.0", protocols: [.vless, .trojan])
        let required = CoreCapabilities(protocols: [.vless])
        let first = CoreSelector().select(from: [older, newer], required: required)
        let second = CoreSelector().select(from: [newer, older], required: required)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(first.selected, older)
        XCTAssertTrue(first.reasons.contains("'alpha' 2.0: ignored, duplicate identifier"))
    }
}

final class CoreRegistryTests: XCTestCase {
    func testRegisterLookupAndCreate() throws {
        let registry = CoreRegistry()
        XCTAssertTrue(registry.isEmpty)
        let zeta = MockCore(id: "zeta")
        let alpha = MockCore(id: "alpha", version: "2.0")
        try registry.register(zeta.descriptor) { zeta }
        try registry.register(alpha.descriptor) { alpha }

        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.descriptors.map { $0.id }, ["alpha", "zeta"])
        XCTAssertEqual(registry.descriptor(for: "alpha"), alpha.descriptor)
        XCTAssertNil(registry.descriptor(for: "nope"))

        let made = try registry.makeCore("zeta")
        XCTAssertEqual(made.descriptor, zeta.descriptor)
        XCTAssertEqual(made.capabilities, MockCore.fullCapabilities)
    }

    func testDuplicateAndUnknown() throws {
        let registry = CoreRegistry()
        let core = MockCore(id: "one")
        try registry.register(core.descriptor) { core }
        XCTAssertThrowsError(try registry.register(core.descriptor) { core }) { error in
            XCTAssertEqual(error as? CoreError, .coreAlreadyRegistered("one"))
        }
        XCTAssertThrowsError(try registry.makeCore("two")) { error in
            XCTAssertEqual(error as? CoreError, .coreNotRegistered("two"))
        }
        XCTAssertTrue(registry.unregister("one"))
        XCTAssertFalse(registry.unregister("one"))
        XCTAssertTrue(registry.isEmpty)
        // After removal the identifier is free again.
        XCTAssertNoThrow(try registry.register(core.descriptor) { core })
    }

    func testFactoryIsCalledPerRequest() throws {
        let registry = CoreRegistry()
        let template = MockCore(id: "fresh")
        try registry.register(template.descriptor) { MockCore(id: "fresh") }
        let first = try registry.makeCore("fresh")
        let second = try registry.makeCore("fresh")
        XCTAssertFalse((first as AnyObject) === (second as AnyObject))
    }

    func testSelectionThroughRegistry() throws {
        let registry = CoreRegistry()
        let plain = MockCore(id: "plain", capabilities: CoreCapabilities(protocols: [.vless], transports: [.tcp]))
        let rich = MockCore(id: "rich")
        try registry.register(rich.descriptor) { rich }
        try registry.register(plain.descriptor) { plain }

        let needsReload = registry.select(required: CoreCapabilities(features: [.hotReload]))
        XCTAssertEqual(needsReload.selected?.id, "rich")

        let anything = registry.select(required: CoreCapabilities(protocols: [.vless]))
        XCTAssertEqual(anything.selected?.id, "plain")

        let preferred = registry.select(
            required: CoreCapabilities(protocols: [.vless]),
            using: CoreSelector(preference: ["rich"])
        )
        XCTAssertEqual(preferred.selected?.id, "rich")

        let impossible = registry.select(required: CoreCapabilities(protocols: [.wireguard]))
        XCTAssertNil(impossible.selected)
    }

    func testConcurrentRegistration() {
        let registry = CoreRegistry()
        let count = 200
        DispatchQueue.concurrentPerform(iterations: count) { number in
            let core = MockCore(id: CoreIdentifier("core-\(number % 100)"))
            // Half of the registrations collide on purpose.
            _ = try? registry.register(core.descriptor) { core }
            _ = registry.descriptors
            _ = registry.descriptor(for: core.descriptor.id)
        }
        XCTAssertEqual(registry.descriptors.count, 100)
        let ids = registry.descriptors.map { $0.id }
        XCTAssertEqual(ids, ids.sorted())
    }

    func testSelectedCoreCanBeDrivenThroughLifecycle() async throws {
        let registry = CoreRegistry()
        let mock = MockCore(id: "engine")
        try registry.register(mock.descriptor) { mock }

        let required = CoreCapabilities(protocols: [.vless], transports: [.websocket], features: [.hotReload])
        let chosen = try CoreSelector().requireSelection(from: registry.descriptors, required: required)
        let lifecycle = CoreLifecycle(core: try registry.makeCore(chosen.id))
        try await lifecycle.start(MockCore.configuration(for: "engine"))
        let state = await lifecycle.state
        XCTAssertEqual(state, .running)
        try await lifecycle.stop()
        XCTAssertEqual(mock.commandCalls, [.start, .stop])
    }
}
