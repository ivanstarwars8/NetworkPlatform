import ConfigurationEngine
import DomainModels
import Foundation
@testable import ProfileLibrary
import XCTest

/// A subscription server in memory: answers from a queue and records the request headers.
final class FakeFetcher: SubscriptionFetching, @unchecked Sendable {
    var answers: [Result<SubscriptionHTTP.Result, SubscriptionHTTP.Failure>] = []
    private(set) var requests: [(url: URL, headers: [String: String])] = []

    func fetch(_ url: URL, headers: [String: String]) async throws -> SubscriptionHTTP.Result {
        requests.append((url, headers))
        guard !answers.isEmpty else { throw SubscriptionHTTP.Failure("no answer queued") }
        return try answers.removeFirst().get()
    }
}

final class SubscriptionAndSelectionTests: XCTestCase {
    static let uuid = ProfileFlowTests.uuid
    static func vless(_ host: String, _ name: String) -> String {
        "vless://\(uuid)@\(host):443?type=tcp&security=reality&sni=www.example.org&fp=chrome"
            + "&pbk=\(ProfileFlowTests.realityKey)&sid=0a1b&flow=xtls-rprx-vision#\(name)"
    }
    static func trojan(_ host: String, _ name: String, password: String = "s3cret-pass-1") -> String {
        "trojan://\(password)@\(host):443?security=tls&sni=example.org#\(name)"
    }

    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let url = URL(string: "https://sub.example.org/s/token-abcdef")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-subscription-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeManager(_ fetcher: FakeFetcher, secrets: MemorySecretStore = MemorySecretStore()) throws -> (SubscriptionManager, ProfileStore) {
        let store = try ProfileStore(directory: directory, secrets: secrets)
        let manager = SubscriptionManager(
            profiles: store, records: SubscriptionRecordStore(directory: directory), fetcher: fetcher,
            clock: { [unowned self] in self.now }
        )
        return (manager, store)
    }

    private func body(_ lines: String...) -> SubscriptionHTTP.Result {
        .body(lines.joined(separator: "\n"), entityTag: "\"v1\"", lastModified: "Tue, 01 Dec 2026 10:00:00 GMT")
    }

    // MARK: HTTP rules

    func testHTTPInterpretation() throws {
        XCTAssertEqual(try SubscriptionHTTP.interpret(status: 304, headers: [:], body: Data()), .notModified)
        XCTAssertEqual(
            try SubscriptionHTTP.interpret(status: 200, headers: ["etag": "\"a\"", "LAST-MODIFIED": "x"], body: Data("abc".utf8)),
            .body("abc", entityTag: "\"a\"", lastModified: "x")
        )
        XCTAssertThrowsError(try SubscriptionHTTP.interpret(status: 404, headers: [:], body: Data("x".utf8))) {
            XCTAssertEqual(($0 as? SubscriptionHTTP.Failure)?.message, "сервер ответил HTTP 404")
        }
        XCTAssertThrowsError(try SubscriptionHTTP.interpret(status: 200, headers: [:], body: Data()))
        XCTAssertThrowsError(try SubscriptionHTTP.interpret(status: 200, headers: [:], body: Data([0xFF, 0xFE])))
        XCTAssertThrowsError(try SubscriptionHTTP.interpret(
            status: 200, headers: [:], body: Data("x".utf8), declaredLength: Int64(SubscriptionHTTP.maximumBodyBytes) + 1
        ))
        XCTAssertThrowsError(try SubscriptionHTTP.interpret(
            status: 200, headers: [:], body: Data(count: SubscriptionHTTP.maximumBodyBytes + 1)
        ))
        var record = SubscriptionRecord(profileID: UUID())
        XCTAssertEqual(SubscriptionHTTP.requestHeaders(for: record), [:])
        record.entityTag = "\"v1\""
        record.lastModified = "date"
        XCTAssertEqual(SubscriptionHTTP.requestHeaders(for: record), ["If-None-Match": "\"v1\"", "If-Modified-Since": "date"])
    }

    func testStalenessAndNextRefresh() {
        var record = SubscriptionRecord(profileID: UUID(), interval: .sixHours)
        XCTAssertTrue(record.isStale(at: now), "never refreshed")
        record.lastSuccess = now
        XCTAssertFalse(record.isStale(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(record.isStale(at: now.addingTimeInterval(6 * 3600)))
        XCTAssertEqual(record.nextRefresh(after: now.addingTimeInterval(60)), now.addingTimeInterval(6 * 3600))
        record.interval = .manual
        XCTAssertFalse(record.isStale(at: now.addingTimeInterval(1e6)))
        XCTAssertNil(record.nextRefresh(after: now))
    }

    func testDiffSummaryIsRussian() {
        XCTAssertEqual(SubscriptionDiff(unchanged: 3).summary, "Изменений нет: 3 сервера.")
        XCTAssertEqual(SubscriptionDiff(unchanged: 11).summary, "Изменений нет: 11 серверов.")
        XCTAssertEqual(SubscriptionDiff(added: ["a", "b"], removed: ["c"]).summary, "Добавлено 2, удалено 1.")
    }

    // MARK: Refresh

    func testAddRefreshMergeKeepsEditsChoiceAndSecrets() async throws {
        let fetcher = FakeFetcher()
        let secrets = MemorySecretStore()
        let (manager, store) = try makeManager(fetcher, secrets: secrets)
        fetcher.answers = [.success(body(Self.vless("192.0.2.1", "Alpha"), Self.trojan("192.0.2.2", "Beta"), Self.trojan("192.0.2.3", "Gamma")))]
        let added = try await manager.add(url: url)
        XCTAssertEqual(added.profile.outbounds.map(\.name), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(store.choice(forProfile: added.profile.id), .automatic, "several servers default to «Авто»")
        let id = added.profile.id
        XCTAssertEqual(manager.record(for: id)?.entityTag, "\"v1\"")
        XCTAssertEqual(secrets.items.count, 3)

        // The user picks Beta, renames Gamma, hides Alpha.
        let beta = try XCTUnwrap(added.profile.outbounds.first { $0.name == "Beta" }?.tag)
        try store.setChoice(.server(tag: beta), forProfile: id)
        let gamma = try XCTUnwrap(added.profile.outbounds.first { $0.name == "Gamma" }?.tag)
        try manager.renameServer(gamma, inProfile: id, to: "Мой сервер")
        let alpha = try XCTUnwrap(added.profile.outbounds.first { $0.name == "Alpha" }?.tag)
        try manager.hideServer(alpha, inProfile: id)
        XCTAssertEqual(store.profiles[0].outbounds.map(\.name), ["Beta", "Мой сервер"])
        XCTAssertEqual(secrets.items.count, 2, "the hidden server's secret is removed")

        // Provider reorders, changes Beta's password, drops nothing, adds Delta.
        now = now.addingTimeInterval(86_400)
        fetcher.answers = [.success(.body(
            [Self.trojan("192.0.2.4", "Delta"), Self.trojan("192.0.2.3", "Gamma"), Self.trojan("192.0.2.2", "Beta", password: "new-pass-2"),
             Self.vless("192.0.2.1", "Alpha")].joined(separator: "\n"),
            entityTag: "\"v2\"", lastModified: nil
        ))]
        let outcome = await manager.refresh(id)
        XCTAssertEqual(fetcher.requests.last?.headers["If-None-Match"], "\"v1\"")
        guard case let .updated(diff) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(diff.added, ["Delta"])
        XCTAssertEqual(diff.removed, [])
        let profile = store.profiles[0]
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.outbounds.map(\.name), ["Delta", "Мой сервер", "Beta"], "provider order, user name, hidden stays hidden")
        XCTAssertEqual(profile.outbounds.first { $0.name == "Beta" }?.tag, beta, "tags of kept servers survive")
        XCTAssertEqual(store.choice(forProfile: id), .server(tag: beta), "the user's choice survives")
        XCTAssertEqual(Set(profile.outbounds.map(\.tag)).count, 3)
        let resolved = store.resolvedSecrets(of: profile)
        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(resolved.values.contains("new-pass-2"))
        XCTAssertEqual(secrets.items.count, 3, "old secrets are removed after the replace")
        XCTAssertEqual(manager.record(for: id)?.entityTag, "\"v2\"")
        XCTAssertEqual(manager.record(for: id)?.lastSuccess, now)

        // 304: nothing changes, the success time moves.
        now = now.addingTimeInterval(60)
        fetcher.answers = [.success(.notModified)]
        let unchanged = await manager.refresh(id)
        XCTAssertEqual(unchanged, .notModified)
        XCTAssertEqual(store.profiles[0], profile)

        // Failure: recorded, profile untouched, address not in the message.
        fetcher.answers = [.failure(SubscriptionHTTP.Failure("сервер ответил HTTP 500"))]
        let failed = await manager.refresh(id)
        XCTAssertEqual(failed, .failed("сервер ответил HTTP 500"))
        XCTAssertEqual(store.profiles[0], profile)
        XCTAssertEqual(manager.record(for: id)?.lastOutcome, .failed("сервер ответил HTTP 500"))

        // The records survive a restart and hold no address or secret.
        let file = try String(contentsOf: manager.records.fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("token-abcdef"))
        XCTAssertFalse(file.contains("s3cret"))
        XCTAssertEqual(SubscriptionRecordStore(directory: directory).record(for: id), manager.record(for: id))
    }

    func testRemovedChosenServerFallsBackToAutomatic() async throws {
        let fetcher = FakeFetcher()
        let (manager, store) = try makeManager(fetcher)
        fetcher.answers = [.success(body(Self.trojan("192.0.2.2", "Beta"), Self.trojan("192.0.2.3", "Gamma")))]
        let id = try await manager.add(url: url).profile.id
        let gamma = try XCTUnwrap(store.profiles[0].outbounds.last?.tag)
        try store.setChoice(.server(tag: gamma), forProfile: id)
        fetcher.answers = [.success(body(Self.trojan("192.0.2.2", "Beta"), Self.trojan("192.0.2.5", "Epsilon")))]
        guard case let .updated(diff) = await manager.refresh(id) else { return XCTFail() }
        XCTAssertEqual(diff.removed, ["Gamma"])
        XCTAssertEqual(diff.added, ["Epsilon"])
        XCTAssertEqual(store.choice(forProfile: id), .automatic)
    }

    func testRefreshStaleOnlyRefreshesDueSubscriptions() async throws {
        let fetcher = FakeFetcher()
        let (manager, store) = try makeManager(fetcher)
        fetcher.answers = [.success(body(Self.trojan("192.0.2.2", "Beta")))]
        let id = try await manager.add(url: url, interval: .sixHours).profile.id
        _ = try store.add(try ProfileImporter().importShareLink(Self.trojan("192.0.2.9", "Link")).profile)
        let none = await manager.refreshStale()
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(manager.nextRefresh(), now.addingTimeInterval(6 * 3600))
        now = now.addingTimeInterval(6 * 3600)
        fetcher.answers = [.success(.notModified)]
        let refreshed = await manager.refreshStale()
        XCTAssertEqual(refreshed, [id: .notModified])
        try manager.setInterval(.manual, for: id)
        XCTAssertNil(manager.nextRefresh())
    }

    func testSubscriptionThatLosesAllServersIsNotApplied() async throws {
        let fetcher = FakeFetcher()
        let (manager, store) = try makeManager(fetcher)
        fetcher.answers = [.success(body(Self.trojan("192.0.2.2", "Beta")))]
        let id = try await manager.add(url: url).profile.id
        fetcher.answers = [.success(body("vless://broken"))]
        guard case let .failed(message) = await manager.refresh(id) else { return XCTFail() }
        XCTAssertTrue(message.hasPrefix("подписка не разобрана"), message)
        XCTAssertEqual(store.profiles[0].outbounds.map(\.name), ["Beta"])
    }

    // MARK: Automatic group and in-engine selection

    private func compiled(_ engine: TunnelEngine, choice: ServerChoice) throws -> (CompiledTunnelStart, Profile) {
        let imported = try ProfileImporter().importSubscription(
            text: [Self.vless("192.0.2.1", "Alpha"), Self.trojan("192.0.2.2", "Beta")].joined(separator: "\n"), sourceURL: url
        )
        let profile = imported.profile
        let tags = profile.outbounds.map(\.tag)
        let resolvedChoice: ServerChoice
        if case .server = choice { resolvedChoice = .server(tag: tags[1]) } else { resolvedChoice = choice }
        return (try TunnelStartCompiler().compile(profile, for: engine, choice: resolvedChoice, resolveSecret: { _ in nil }), profile)
    }

    func testXrayAutomaticCompilesABalancerWithObservatory() throws {
        let (result, profile) = try compiled(.xray, choice: .automatic)
        let json = try JSONValue.parse(jsonText: String(decoding: result.configuration, as: UTF8.self))
        let balancer = try XCTUnwrap(json["routing"]?["balancers"]?.arrayValue?.first)
        XCTAssertEqual(balancer["strategy"]?["type"]?.stringValue, "leastPing")
        XCTAssertEqual(json["observatory"]?["probeInterval"]?.stringValue, "\(AutomaticGroup.intervalSeconds)s")
        let plan = try XCTUnwrap(result.selectionPlan)
        XCTAssertEqual(plan.group, balancer["tag"]?.stringValue)
        XCTAssertNil(plan.automaticMember, "Xray: «Авто» clears the pin")
        XCTAssertEqual(plan.measuredGroup, plan.group)
        XCTAssertEqual(Set(plan.members.keys), Set(profile.outbounds.map(\.tag)))
        XCTAssertEqual(Set(plan.members.values), Set(balancer["selector"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        XCTAssertNil(result.initialSelection)
        XCTAssertNil(TunnelStartRequest(compiled: result).groupSelection)
    }

    func testXrayManualChoiceIsAnInitialPin() throws {
        let (result, profile) = try compiled(.xray, choice: .server(tag: ""))
        let plan = try XCTUnwrap(result.selectionPlan)
        let selection = try XCTUnwrap(TunnelStartRequest(compiled: result).groupSelection)
        XCTAssertEqual(selection.group, plan.group)
        XCTAssertEqual(selection.member, plan.members[profile.outbounds[1].tag])
        XCTAssertEqual(plan.profileTag(ofEngineTag: try XCTUnwrap(selection.member)), profile.outbounds[1].tag)
        // The hand-off keeps the selection.
        let handoff = ConfigurationHandoff(directory: directory.appendingPathComponent("StartHandoff"))
        let request = TunnelStartRequest(compiled: result)
        XCTAssertEqual(try handoff.consume(try handoff.write(request)).groupSelection, selection)
    }

    func testMihomoAutomaticUsesASelectorOverAnURLTestGroup() throws {
        let (result, profile) = try compiled(.mihomo, choice: .automatic)
        let yaml = String(decoding: result.configuration, as: UTF8.self)
        XCTAssertTrue(yaml.contains("type: url-test"), yaml)
        XCTAssertTrue(yaml.contains("type: select"), yaml)
        XCTAssertTrue(yaml.contains("tolerance: \(AutomaticGroup.toleranceMilliseconds)"), yaml)
        let plan = try XCTUnwrap(result.selectionPlan)
        XCTAssertNotEqual(plan.group, plan.measuredGroup)
        XCTAssertEqual(plan.automaticMember, plan.measuredGroup, "Mihomo: «Авто» selects the url-test group")
        XCTAssertEqual(plan.selection(for: .automatic)?.member, plan.measuredGroup)
        XCTAssertEqual(plan.selection(for: .server(tag: profile.outbounds[0].tag))?.member, plan.members[profile.outbounds[0].tag])
        XCTAssertNil(plan.selection(for: .server(tag: "missing")))
        XCTAssertNil(result.initialSelection)
    }

    func testSingleServerHasNoPlanAndUnknownChoiceFallsBack() throws {
        let single = try ProfileImporter().importShareLink(Self.trojan("192.0.2.2", "Beta")).profile
        let result = try TunnelStartCompiler().compile(single, for: .xray, choice: .server(tag: "x"), resolveSecret: { _ in "p" })
        XCTAssertNil(result.selectionPlan)
        XCTAssertNil(result.initialSelection)

        let imported = try ProfileImporter().importSubscription(
            text: [Self.trojan("192.0.2.2", "Beta"), Self.trojan("192.0.2.3", "Gamma")].joined(separator: "\n"), sourceURL: nil
        ).profile
        let fallback = try TunnelStartCompiler().compile(imported, for: .xray, choice: .server(tag: "gone"), resolveSecret: { _ in "p" })
        XCTAssertEqual(fallback.choice, .automatic)
        XCTAssertTrue(fallback.notices.contains { $0.text.contains("no longer in the profile") })
    }

    // MARK: Health book and explanation

    func testHealthBookRanksAndExplains() throws {
        let plan = ServerSelectionPlan(group: "group-0000", automaticMember: nil, measuredGroup: "group-0000",
                                       members: ["a": "proxy-0000", "b": "proxy-0001", "c": "proxy-0002"])
        var book = ServerHealthBook(tags: ["a", "b", "c"])
        let t0 = now
        book.record(engine: [
            EngineMemberMeasurement(engineTag: "proxy-0000", alive: true, delayMilliseconds: 120, lastTry: t0),
            EngineMemberMeasurement(engineTag: "proxy-0001", alive: true, delayMilliseconds: 80, lastTry: t0),
            EngineMemberMeasurement(engineTag: "proxy-0002", alive: false, delayMilliseconds: nil, lastTry: t0),
            EngineMemberMeasurement(engineTag: "proxy-0009", alive: true, delayMilliseconds: 1, lastTry: t0),
        ], plan: plan)
        XCTAssertEqual(book.ranked(["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(book.latest["b"]?.milliseconds, 80)
        XCTAssertEqual(book.latest["b"]?.source, .engine)
        XCTAssertEqual(book.fastest(source: .engine)?.tag, "b")

        // The same report again is not counted twice; a newer one moves the smoothed value.
        book.record(engine: [EngineMemberMeasurement(engineTag: "proxy-0001", alive: true, delayMilliseconds: 200, lastTry: t0)], plan: plan)
        XCTAssertEqual(book.latest["b"]?.milliseconds, 80)
        book.record(engine: [EngineMemberMeasurement(engineTag: "proxy-0001", alive: true, delayMilliseconds: 180, lastTry: t0 + 180)], plan: plan)
        XCTAssertEqual(book.latest["b"]?.milliseconds, 180)
        let smoothed = try XCTUnwrap(book.latest["b"]?.smoothedMilliseconds)
        XCTAssertTrue(smoothed > 80 && smoothed < 180, "\(smoothed)")

        let names = ["a": "Alpha", "b": "Beta", "c": "Gamma"]
        let fastest = AutoExplanation.text(.init(connected: true, choice: .automatic, current: "a", engine: .xray, names: names), book: book)
        XCTAssertTrue(fastest.contains("«Alpha»: 120 мс") && fastest.contains("самый быстрый из 2"), fastest)
        let tolerance = AutoExplanation.text(.init(connected: true, choice: .automatic, current: "b", engine: .mihomo, names: names), book: book)
        XCTAssertTrue(tolerance.contains("«Alpha» быстрее на 60 мс") == false, tolerance)
        XCTAssertTrue(tolerance.contains("Самый быстрый сейчас «Alpha»"), tolerance)
        let manual = AutoExplanation.text(.init(connected: true, choice: .server(tag: "c"), current: "c", engine: .xray, names: names), book: book)
        XCTAssertTrue(manual.hasPrefix("Выбран вручную: «Gamma»"), manual)
        let down = AutoExplanation.text(.init(connected: true, choice: .automatic, current: "c", engine: .xray, names: names), book: book)
        XCTAssertTrue(down.contains("не дошла"), down)

        var offline = ServerHealthBook(tags: ["a", "b"])
        let idle = AutoExplanation.text(.init(connected: false, choice: .automatic, current: nil, engine: .xray, names: names), book: offline)
        XCTAssertFalse(idle.contains("мс."), "no number without a measurement: \(idle)")
        offline.record(connect: [ConnectMeasurement(tag: "a", milliseconds: 34, at: t0), ConnectMeasurement(tag: "b", milliseconds: nil, at: t0)])
        let measured = AutoExplanation.text(.init(connected: false, choice: .automatic, current: nil, engine: .xray, names: names), book: offline)
        XCTAssertTrue(measured.contains("«Alpha»: 34 мс"), measured)
        XCTAssertEqual(offline.latest["b"]?.alive, false)
        XCTAssertEqual(offline.ranked(["b", "a"]), ["a", "b"])
    }

    func testConnectProbeTargetsSkipUDPAndAreBounded() throws {
        let lines = (1...70).map { Self.trojan("192.0.2.\($0)", "S\($0)") }
            + ["hysteria2://pass@192.0.2.200:443?sni=example.org#H"]
        let profile = try ProfileImporter().importSubscription(text: lines.joined(separator: "\n"), sourceURL: nil).profile
        let targets = ConnectProbePlan.targets(of: profile)
        XCTAssertEqual(targets.count, ConnectProbePlan.maximumServers)
        XCTAssertFalse(targets.contains { $0.host == "192.0.2.200" })
        XCTAssertEqual(targets.first?.port, 443)
    }
}
