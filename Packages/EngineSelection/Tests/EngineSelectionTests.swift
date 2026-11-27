import AdaptiveBalancer
import ConfigurationEngine
import DomainModels
@testable import EngineSelection
import Foundation
import ProfileLibrary
import XCTest

/// Engine support read from the real compilers' reports, the automatic choice and its explanation.
final class EngineChoiceTests: XCTestCase {
    // Documentation addresses and test keys, as in Tests/Fixtures/ShareLinks.
    static let reality = "vless://1cc9207f-5dda-4274-bb0d-9d105c95c6e8@192.0.2.1:443?type=tcp&security=reality"
        + "&sni=www.example.org&fp=chrome&pbk=VZhM7y7_-UFCl2zNHcAGmpbH_cJyhFV3yXneqhjbwC4&sid=0a1b&flow=xtls-rprx-vision#lab"

    static func fixtureLink(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Tests/Fixtures/ShareLinks/\(name).link").standardizedFileURL
        return try String(contentsOf: root, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func profile(_ link: String) throws -> Profile {
        try ProfileImporter().importShareLink(link).profile
    }

    static func supports(_ profile: Profile) -> [EngineSupport] {
        TunnelEngine.allCases.map { EngineSupport.assess(profile, engine: $0, resolveSecret: { _ in nil }) }
    }

    let dual = EngineChooser(available: [.xray, .mihomo])

    func testBothCompleteUsesTheBuildDefaultThenSticksToTheWorkingEngine() throws {
        let supports = Self.supports(try Self.profile(Self.reality))
        XCTAssertEqual(supports.map(\.level), [.complete, .complete], "\(supports)")

        let fresh = dual.decide(preference: .automatic, supports: supports, lastWorkingEngine: nil)
        XCTAssertEqual(fresh.engine, .xray)
        XCTAssertEqual(fresh.reason, .defaultEngine)
        XCTAssertTrue(fresh.losses.isEmpty)
        XCTAssertTrue(fresh.explanation.contains("первый движок"), fresh.explanation)

        let sticky = dual.decide(preference: .automatic, supports: supports, lastWorkingEngine: .mihomo)
        XCTAssertEqual(sticky.engine, .mihomo, "a working engine is kept, no switch without need")
        XCTAssertEqual(sticky.reason, .keepsWorkingEngine)
    }

    func testTUICGoesToMihomoBecauseXrayCannotRunIt() throws {
        let supports = Self.supports(try Self.profile(try Self.fixtureLink("tuic-v5")))
        XCTAssertEqual(supports[0].level, .unsupported)
        XCTAssertFalse(supports[0].blockers.isEmpty)
        XCTAssertEqual(supports[1].level, .complete, "\(supports[1])")

        let auto = dual.decide(preference: .automatic, supports: supports, lastWorkingEngine: .xray)
        XCTAssertEqual(auto.engine, .mihomo)
        XCTAssertEqual(auto.reason, .onlyCompleteEngine)
        XCTAssertTrue(auto.explanation.contains("Xray не может запустить"), auto.explanation)

        let manual = dual.decide(preference: .xray, supports: supports, lastWorkingEngine: nil)
        XCTAssertNil(manual.engine)
        XCTAssertEqual(manual.reason, .chosenEngineCannotRun)
        XCTAssertEqual(manual.betterAlternative, .mihomo)
        XCTAssertFalse(manual.canStart)
    }

    func testPartialEngineIsNeverPickedSilently() throws {
        // Mihomo drops the XHTTP download split; Xray carries it.
        let supports = Self.supports(try Self.profile(try Self.fixtureLink("vless-xhttp-reality-download")))
        XCTAssertEqual(supports[0].level, .complete, "\(supports[0])")
        XCTAssertEqual(supports[1].level, .partial, "\(supports[1])")

        let auto = dual.decide(preference: .automatic, supports: supports, lastWorkingEngine: .mihomo)
        XCTAssertEqual(auto.engine, .xray, "auto prefers the engine that carries everything over the sticky one")
        XCTAssertEqual(auto.reason, .onlyCompleteEngine)

        let manual = dual.decide(preference: .mihomo, supports: supports, lastWorkingEngine: nil)
        XCTAssertEqual(manual.engine, .mihomo)
        XCTAssertEqual(manual.reason, .chosenByUser)
        XCTAssertFalse(manual.losses.isEmpty, "the losses travel with the decision")
        XCTAssertEqual(manual.betterAlternative, .xray)
        XCTAssertTrue(manual.explanation.contains("список ниже"), manual.explanation)
        XCTAssertTrue(manual.losses[0].russianText.hasPrefix("Будет пропущено"), manual.losses[0].russianText)
    }

    func testFewestLossesWhenNothingIsComplete() {
        let loss = FeatureLoss(kind: .dropped, path: "p", detail: "d")
        let supports = [
            EngineSupport(engine: .xray, level: .partial, losses: [loss, loss]),
            EngineSupport(engine: .mihomo, level: .partial, losses: [loss]),
        ]
        let decision = dual.decide(preference: .automatic, supports: supports, lastWorkingEngine: .xray)
        XCTAssertEqual(decision.engine, .mihomo)
        XCTAssertEqual(decision.reason, .fewestLosses)
        XCTAssertEqual(decision.losses.count, 1)
        XCTAssertTrue(decision.explanation.contains("1 возможность профиля"), decision.explanation)
    }

    func testSingleEngineBuildAndNothingRunnable() {
        let xrayOnly = EngineChooser(available: [.xray])
        let supports = [EngineSupport(engine: .xray, level: .complete), EngineSupport(engine: .mihomo, level: .complete)]
        let decision = xrayOnly.decide(preference: .automatic, supports: supports, lastWorkingEngine: .mihomo)
        XCTAssertEqual(decision.engine, .xray, "an engine the build lacks is never chosen")
        XCTAssertEqual(decision.reason, .onlyEngineInBuild)
        XCTAssertEqual(decision.supports.map(\.engine), [.xray])

        let none = dual.decide(
            preference: .automatic,
            supports: [EngineSupport(engine: .xray, level: .unsupported), EngineSupport(engine: .mihomo, level: .unsupported)],
            lastWorkingEngine: nil
        )
        XCTAssertNil(none.engine)
        XCTAssertEqual(none.reason, .noEngineCanRun)

        let missing = xrayOnly.decide(preference: .mihomo, supports: supports, lastWorkingEngine: nil)
        XCTAssertNil(missing.engine, "a preference for an engine outside the build cannot start")
    }

    func testReportReadingIgnoresNonLosses() {
        let report = ConversionReport(
            engine: .xray, engineVersion: "1",
            issues: [
                ConversionIssue(path: "a", kind: .untested, severity: .warning, detail: "x"),
                ConversionIssue(path: "b", kind: .migrated, severity: .warning, detail: "x"),
                ConversionIssue(path: "c", kind: .dropped, severity: .info, detail: "x"),
                ConversionIssue(path: "d", kind: .approximated, severity: .warning, detail: "x"),
            ],
            verdict: .degraded, engineTags: [:], excludedOutbounds: ["srv"]
        )
        let support = EngineSupport(engine: .xray, report: report)
        XCTAssertEqual(support.level, .partial)
        XCTAssertEqual(support.losses.map(\.kind), [.approximated, .excludedServer])
    }

    func testRussianPlural() {
        XCTAssertEqual(RussianCount.phrase(1, one: "a", few: "b", many: "c"), "1 a")
        XCTAssertEqual(RussianCount.phrase(3, one: "a", few: "b", many: "c"), "3 b")
        XCTAssertEqual(RussianCount.phrase(11, one: "a", few: "b", many: "c"), "11 c")
        XCTAssertEqual(RussianCount.phrase(22, one: "a", few: "b", many: "c"), "22 b")
    }
}

/// Rollback and engine fallback after failed starts.
final class StartSupervisorTests: XCTestCase {
    let profileID = UUID()
    let otherProfile = UUID()

    func attempt(_ engine: TunnelEngine, _ digest: String, _ origin: StartAttempt.Origin = .user) -> StartAttempt {
        StartAttempt(profileID: profileID, engine: engine, configurationDigest: digest, origin: origin)
    }

    func good(_ engine: TunnelEngine, _ digest: String) throws -> EngineSelection.LastKnownGood {
        let profile = try EngineChoiceTests.profile(EngineChoiceTests.reality)
        return EngineSelection.LastKnownGood(profileID: profileID, engine: engine, configurationDigest: digest, profile: profile, recordedAt: Date(timeIntervalSince1970: 0))
    }

    func testConfirmedOnlyAfterProbation() {
        var supervisor = StartSupervisor.standard
        XCTAssertEqual(supervisor.probationWindow, 20)
        let a = attempt(.xray, "A")
        supervisor.began(a, at: 0)
        let none = FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: nil)
        XCTAssertEqual(supervisor.observe(.connecting, at: 1) { none }, .none)
        XCTAssertEqual(supervisor.observe(.connected, at: 2) { none }, .none)
        XCTAssertEqual(supervisor.tick(at: 10), .none)
        XCTAssertEqual(supervisor.tick(at: 22), .confirmed(a))
        XCTAssertEqual(supervisor.tick(at: 30), .none, "confirmed once")
        XCTAssertEqual(supervisor.observe(.disconnected, at: 40) { none }, .none, "a later drop is not a start failure")
    }

    func testFailureRollsBackToLastKnownGoodOnce() throws {
        var supervisor = StartSupervisor.standard
        let lkg = try good(.mihomo, "OLD")
        let context = FailureContext(lastKnownGood: lkg, preference: .automatic, completeAlternative: .mihomo)
        let a = attempt(.xray, "NEW")
        supervisor.began(a, at: 0)
        _ = supervisor.observe(.connecting, at: 1) { context }
        let action = supervisor.observe(.disconnected, at: 3) { context }
        XCTAssertEqual(action, .retry(.rollback(lkg), after: a))
        XCTAssertNotNil(action.russianNotice)

        // The rollback fails too: stop, never loop.
        let r = attempt(.mihomo, "OLD", .rollback)
        supervisor.began(r, at: 4)
        _ = supervisor.observe(.connecting, at: 5) { context }
        XCTAssertEqual(supervisor.observe(.disconnected, at: 6) { context }, .gaveUp(.retryFailed, after: r))
    }

    func testDropDuringProbationIsAStartFailure() throws {
        var supervisor = StartSupervisor.standard
        let lkg = try good(.xray, "OLD")
        let context = FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil)
        let a = attempt(.xray, "NEW")
        supervisor.began(a, at: 0)
        _ = supervisor.observe(.connected, at: 1) { context }
        XCTAssertEqual(supervisor.observe(.disconnected, at: 8) { context }, .retry(.rollback(lkg), after: a))
    }

    func testNoRollbackToTheSameConfigurationOrAnotherProfile() throws {
        var supervisor = StartSupervisor.standard
        var lkg = try good(.xray, "SAME")
        let a = attempt(.xray, "SAME")
        supervisor.began(a, at: 0)
        XCTAssertEqual(
            supervisor.observe(.disconnected, at: 0.5) { FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil) },
            .none, "a disconnect before any progress is a stale notification"
        )
        _ = supervisor.observe(.connecting, at: 0.6) { FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil) }
        XCTAssertEqual(
            supervisor.observe(.disconnected, at: 1) { FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil) },
            .gaveUp(.nothingToRetry, after: a)
        )
        lkg.profileID = otherProfile
        lkg.configurationDigest = "OTHER"
        supervisor.began(a, at: 2)
        _ = supervisor.observe(.connecting, at: 2.5) { FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil) }
        XCTAssertEqual(
            supervisor.observe(.disconnected, at: 3) { FailureContext(lastKnownGood: lkg, preference: .xray, completeAlternative: nil) },
            .gaveUp(.nothingToRetry, after: a)
        )
    }

    func testEngineFallbackOnlyInAutoAndWithinTheSwitchLimits() {
        var supervisor = StartSupervisor.standard
        let auto = FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: .mihomo)
        let a = attempt(.xray, "A")
        supervisor.began(a, at: 0)
        _ = supervisor.observe(.connecting, at: 1) { auto }
        XCTAssertEqual(supervisor.observe(.disconnected, at: 2) { auto }, .retry(.switchEngine(to: .mihomo), after: a))

        // The fallback counts as an engine switch (cellular policy: 1 per hour, 600 s apart).
        supervisor.began(attempt(.mihomo, "B", .engineFallback), at: 3)
        _ = supervisor.observe(.connected, at: 4) { auto }
        XCTAssertEqual(supervisor.tick(at: 30), .confirmed(attempt(.mihomo, "B", .engineFallback)))

        supervisor.began(a, at: 100)
        _ = supervisor.observe(.connecting, at: 100.5) { auto }
        guard case .gaveUp(.engineSwitchLimited, after: a) = supervisor.observe(.disconnected, at: 101, context: { auto }) else {
            return XCTFail("a second engine switch within the window must be refused")
        }

        // A manual preference never switches engines.
        var manual = StartSupervisor.standard
        manual.began(a, at: 0)
        _ = manual.observe(.connecting, at: 0.5) { auto }
        XCTAssertEqual(
            manual.observe(.disconnected, at: 1) { FailureContext(lastKnownGood: nil, preference: .xray, completeAlternative: .mihomo) },
            .gaveUp(.nothingToRetry, after: a)
        )
    }

    func testFallbackTargetMustBeComplete() {
        var supervisor = StartSupervisor.standard
        let a = attempt(.xray, "A")
        supervisor.began(a, at: 0)
        _ = supervisor.observe(.connecting, at: 0.5) { FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: nil) }
        XCTAssertEqual(
            supervisor.observe(.disconnected, at: 1) { FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: nil) },
            .gaveUp(.nothingToRetry, after: a)
        )
    }

    func testUserStopIsNotAFailure() {
        var supervisor = StartSupervisor.standard
        supervisor.began(attempt(.xray, "A"), at: 0)
        supervisor.userStopped()
        XCTAssertEqual(
            supervisor.observe(.disconnected, at: 1) { FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: .mihomo) },
            .none
        )
    }

    func testDisabledEngineSwitching() {
        var policy = SelectionPolicy.cellularDefault().engineSwitch
        policy.isEnabled = false
        var supervisor = StartSupervisor(probationWindow: 5, engineSwitch: policy)
        let a = attempt(.xray, "A")
        supervisor.began(a, at: 0)
        _ = supervisor.observe(.connecting, at: 0.5) { FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: .mihomo) }
        guard case .gaveUp(.engineSwitchLimited, after: a) = supervisor.observe(.disconnected, at: 1, context: {
            FailureContext(lastKnownGood: nil, preference: .automatic, completeAlternative: .mihomo)
        }) else { return XCTFail() }
    }
}

final class EngineChoiceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("np-engine-choice-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripAndForget() throws {
        let id = UUID()
        let gone = UUID()
        let profile = try EngineChoiceTests.profile(EngineChoiceTests.reality)
        let store = try EngineChoiceStore(directory: directory)
        XCTAssertEqual(store.preference(for: id), .automatic)
        try store.setPreference(.mihomo, for: id)
        try store.setPreference(.xray, for: gone)
        let record = EngineSelection.LastKnownGood(profileID: id, engine: .mihomo, configurationDigest: "abc", profile: profile, recordedAt: Date(timeIntervalSince1970: 1_000))
        try store.recordGood(record)

        let reopened = try EngineChoiceStore(directory: directory)
        XCTAssertEqual(reopened.preference(for: id), .mihomo)
        XCTAssertEqual(reopened.lastKnownGood(for: id), record)
        try reopened.retain(only: [id])
        XCTAssertEqual(reopened.preference(for: gone), .automatic)

        let text = try String(contentsOf: reopened.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("abc"))

        try reopened.setPreference(.automatic, for: id)
        try reopened.forget(id)
        let empty = try EngineChoiceStore(directory: directory)
        XCTAssertNil(empty.lastKnownGood(for: id))
        XCTAssertEqual(empty.preference(for: id), .automatic)
    }

    func testCorruptFileIsReported() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent(EngineChoiceStore.fileName))
        XCTAssertThrowsError(try EngineChoiceStore(directory: directory))
    }
}
