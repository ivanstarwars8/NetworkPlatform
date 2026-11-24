// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation
import XCTest
@testable import CoreAbstraction

/// A test-only core. It runs nothing: it records calls, can be told to fail
/// or to be slow, and measures whether operations ever overlapped.
final class MockCore: NetworkCore, @unchecked Sendable {
    enum Call: String, Equatable {
        case validate
        case start
        case stop
        case reload
        case statistics
        case health
    }

    struct Failure: Error, CustomStringConvertible, Equatable {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    let descriptor: CoreDescriptor

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var errors: [Call: Error] = [:]
    private var delays: [Call: UInt64] = [:]
    private var active = 0
    private var maximumActive = 0
    private var lastStart: (configuration: CoreConfiguration, options: CoreStartOptions)?
    private var lastReload: CoreConfiguration?
    private var report = CoreValidationReport.valid

    init(
        id: CoreIdentifier = "mock",
        version: String = "1.0",
        capabilities: CoreCapabilities = MockCore.fullCapabilities
    ) {
        descriptor = CoreDescriptor(id: id, displayName: "Mock \(id)", version: version, capabilities: capabilities)
    }

    static let fullCapabilities = CoreCapabilities(
        protocols: [.vless, .trojan],
        transports: [.tcp, .websocket],
        features: [.hotReload, .trafficStatistics]
    )

    static func configuration(for id: CoreIdentifier = "mock", payload: String = "{}") -> CoreConfiguration {
        CoreConfiguration(coreID: id, format: "json", payload: Data(payload.utf8))
    }

    // MARK: Test controls

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setError(_ error: Error?, for call: Call) {
        withLock { errors[call] = error }
    }

    func setDelay(milliseconds: UInt64, for call: Call) {
        withLock { delays[call] = milliseconds * 1_000_000 }
    }

    func setValidationReport(_ newReport: CoreValidationReport) {
        withLock { report = newReport }
    }

    var calls: [Call] {
        withLock { recordedCalls }
    }

    /// Lifecycle-relevant calls only (`start`, `stop`, `reload`).
    var commandCalls: [Call] {
        withLock { recordedCalls.filter { $0 == .start || $0 == .stop || $0 == .reload } }
    }

    /// Highest number of `start` / `stop` / `reload` calls in flight at once.
    var maximumConcurrentCommands: Int {
        withLock { maximumActive }
    }

    var startedConfiguration: CoreConfiguration? {
        withLock { lastStart?.configuration }
    }

    var startedOptions: CoreStartOptions? {
        withLock { lastStart?.options }
    }

    var reloadedConfiguration: CoreConfiguration? {
        withLock { lastReload }
    }

    // MARK: NetworkCore

    private func begin(_ call: Call, isCommand: Bool) -> (error: Error?, delay: UInt64) {
        return withLock { () -> (error: Error?, delay: UInt64) in
            recordedCalls.append(call)
            if isCommand {
                active += 1
                maximumActive = max(maximumActive, active)
            }
            return (errors[call], delays[call] ?? 0)
        }
    }

    private func end() {
        withLock { active -= 1 }
    }

    private func runCommand(_ call: Call) async throws {
        let plan = begin(call, isCommand: true)
        if plan.delay > 0 {
            try? await Task.sleep(nanoseconds: plan.delay)
        } else {
            // Always suspend at least once so that overlapping calls, if the
            // lifecycle allowed them, would actually interleave.
            await Task.yield()
        }
        end()
        if let error = plan.error {
            throw error
        }
    }

    func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport {
        let plan = begin(.validate, isCommand: false)
        if let error = plan.error {
            throw error
        }
        return withLock { report }
    }

    func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws {
        try await runCommand(.start)
        withLock { lastStart = (configuration, options) }
    }

    func stop() async throws {
        try await runCommand(.stop)
    }

    func reload(_ configuration: CoreConfiguration) async throws {
        try await runCommand(.reload)
        withLock { lastReload = configuration }
    }

    func statistics() async throws -> CoreStatistics {
        let plan = begin(.statistics, isCommand: false)
        if let error = plan.error {
            throw error
        }
        return CoreStatistics(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            traffic: TrafficCounters(uplinkBytes: 10, downlinkBytes: 20),
            outbounds: ["proxy": TrafficCounters(uplinkBytes: 7, downlinkBytes: 9)],
            activeConnections: 3
        )
    }

    func health() async -> CoreHealth {
        _ = begin(.health, isCommand: false)
        return CoreHealth(status: .healthy, detail: "mock", checkedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

// MARK: - Async assertion helpers

/// Runs `body` and expects it to throw exactly `expected`.
func assertThrows(
    _ expected: CoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected), but nothing was thrown", file: file, line: line)
    } catch let error as CoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected CoreError, got \(error)", file: file, line: line)
    }
}

/// Polls `condition` until it holds or the time-out expires.
func waitUntil(
    timeoutMilliseconds: Int = 5_000,
    _ condition: () async -> Bool
) async -> Bool {
    var waited = 0
    while waited < timeoutMilliseconds {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
        waited += 2
    }
    return await condition()
}
