// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-25). Not yet built or run on Apple platforms.
import Foundation

// MARK: - Inputs

/// A ready-made configuration document for one core.
///
/// The control plane compiles it (ADR-0002: the engine never builds or
/// rewrites its own configuration); this module treats the payload as opaque
/// bytes and never parses it.
public struct CoreConfiguration: Hashable, Sendable {
    /// Upper bound on the payload accepted by `CoreLifecycle`. This is a
    /// limit of this project (a guard against handing an engine a runaway
    /// document inside a memory-constrained extension), not a limit of any
    /// core.
    public static let maximumPayloadBytes = 8 * 1024 * 1024

    /// The core this document was compiled for.
    public let coreID: CoreIdentifier
    /// Format label chosen by the compiler, e.g. `"json"`.
    public let format: String
    public let payload: Data

    public init(coreID: CoreIdentifier, format: String, payload: Data) {
        self.coreID = coreID
        self.format = format
        self.payload = payload
    }
}

/// Run-time parameters that are not part of the configuration document
/// (ADR-0001 §4–5: the tunnel descriptor and memory limits are passed next to
/// the configuration, never patched into it).
public struct CoreStartOptions: Hashable, Sendable {
    /// File descriptor of the tunnel device, when the core reads it directly.
    public var tunnelFileDescriptor: Int32?
    /// Tunnel MTU chosen by the adapter.
    public var mtu: Int?
    /// Soft memory limit for the core, in bytes.
    public var memoryLimitBytes: UInt64?

    public init(tunnelFileDescriptor: Int32? = nil, mtu: Int? = nil, memoryLimitBytes: UInt64? = nil) {
        self.tunnelFileDescriptor = tunnelFileDescriptor
        self.mtu = mtu
        self.memoryLimitBytes = memoryLimitBytes
    }

    public static let none = CoreStartOptions()
}

// MARK: - Validation

public struct CoreValidationIssue: Hashable, Sendable, Codable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case warning
        case error
    }

    public let severity: Severity
    /// Location inside the configuration, when known (free-form path).
    public let path: String?
    public let message: String

    public init(severity: Severity, path: String? = nil, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public struct CoreValidationReport: Hashable, Sendable, Codable {
    public let issues: [CoreValidationIssue]

    public init(issues: [CoreValidationIssue] = []) {
        self.issues = issues
    }

    public static let valid = CoreValidationReport()

    /// `true` when there is no issue of severity `.error`.
    public var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }

    public var errors: [CoreValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [CoreValidationIssue] {
        issues.filter { $0.severity == .warning }
    }
}

// MARK: - Statistics and health

public struct TrafficCounters: Hashable, Sendable, Codable {
    public var uplinkBytes: UInt64
    public var downlinkBytes: UInt64

    public init(uplinkBytes: UInt64 = 0, downlinkBytes: UInt64 = 0) {
        self.uplinkBytes = uplinkBytes
        self.downlinkBytes = downlinkBytes
    }

    public var totalBytes: UInt64 {
        let (sum, overflow) = uplinkBytes.addingReportingOverflow(downlinkBytes)
        return overflow ? UInt64.max : sum
    }
}

/// One connection a core tracks. `destination` (host or IP with port) is the user's data: for display in the
/// app, never for logs.
public struct CoreConnection: Hashable, Sendable, Codable {
    public var id: String
    public var network: String
    public var destination: String
    public var rule: String?
    /// Outbounds in travel order (group first, final outbound last), engine tags.
    public var chain: [String]
    public var uploadBytes: UInt64
    public var downloadBytes: UInt64
    public var startedAt: Date?

    public init(
        id: String, network: String, destination: String, rule: String? = nil, chain: [String] = [],
        uploadBytes: UInt64 = 0, downloadBytes: UInt64 = 0, startedAt: Date? = nil
    ) {
        self.id = id
        self.network = network
        self.destination = destination
        self.rule = rule
        self.chain = chain
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.startedAt = startedAt
    }
}

/// A bounded list of connections: `total` counts all of them, `items` holds the newest.
public struct CoreConnectionSnapshot: Hashable, Sendable, Codable {
    public var capturedAt: Date
    public var total: Int
    public var items: [CoreConnection]

    public init(capturedAt: Date, total: Int, items: [CoreConnection]) {
        self.capturedAt = capturedAt
        self.total = total
        self.items = items
    }
}

/// A snapshot of what a core reports about itself. Fields a core cannot
/// provide stay `nil` / empty; see `CoreFeature` for what to expect.
public struct CoreStatistics: Hashable, Sendable, Codable {
    public var capturedAt: Date
    public var traffic: TrafficCounters
    /// Counters per outbound tag (`CoreFeature.perOutboundStatistics`).
    public var outbounds: [String: TrafficCounters]
    public var activeConnections: Int?
    /// (`CoreFeature.memoryReporting`)
    public var memoryFootprintBytes: UInt64?
    /// Seconds since the core was started.
    public var uptime: TimeInterval?

    public init(
        capturedAt: Date,
        traffic: TrafficCounters = TrafficCounters(),
        outbounds: [String: TrafficCounters] = [:],
        activeConnections: Int? = nil,
        memoryFootprintBytes: UInt64? = nil,
        uptime: TimeInterval? = nil
    ) {
        self.capturedAt = capturedAt
        self.traffic = traffic
        self.outbounds = outbounds
        self.activeConnections = activeConnections
        self.memoryFootprintBytes = memoryFootprintBytes
        self.uptime = uptime
    }
}

public struct CoreHealth: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable, Codable {
        /// Running and passing its own checks.
        case healthy
        /// Running, but something is wrong (see `detail`).
        case degraded
        /// Not able to carry traffic.
        case unhealthy
        /// Not running or not checked: nothing can be said.
        case unknown
    }

    public var status: Status
    public var detail: String?
    public var checkedAt: Date
    public var lastError: CoreError?

    public init(status: Status, detail: String? = nil, checkedAt: Date, lastError: CoreError? = nil) {
        self.status = status
        self.detail = detail
        self.checkedAt = checkedAt
        self.lastError = lastError
    }
}

// MARK: - System events

public enum CoreMemoryPressureLevel: String, Hashable, Sendable, Codable {
    case warning
    case critical
}

/// Something the operating system told the hosting process and a running
/// core may want to react to. The set is deliberately small: only what the
/// Packet Tunnel host observes today.
public enum CoreSystemEvent: Hashable, Sendable {
    /// The device is about to sleep.
    case willSleep
    /// The device woke up.
    case didWake
    /// The process received a memory-pressure notification.
    case memoryPressure(CoreMemoryPressureLevel)
}

// MARK: - The protocol

/// The surface every engine adapter implements (ADR-0001 §5). Nothing
/// engine-specific crosses this boundary: no engine types, no engine JSON
/// field names.
///
/// Contract:
/// - Implementations throw `CoreError` where they can; anything else is
///   normalised by `CoreError.normalise`.
/// - `start`, `stop` and `reload` are never called concurrently for one
///   instance when the core is driven through `CoreLifecycle`.
/// - `reload` is only called when `capabilities.features` contains
///   `.hotReload`; other cores are restarted by the caller.
/// - `stop` must be safe to call after a failed `start`.
/// - `health` does not throw: failing to check is itself a health status.
/// - `start` and `reload` should honour task cancellation: `CoreLifecycle`
///   cancels them when their deadline passes, when the caller is cancelled
///   and on `shutdown`. A core that cannot be interrupted is still handled
///   (the result of an abandoned start is discarded), only slower.
/// - `stop` is never cancelled.
/// - `handleSystemEvent` is serialised with `start`, `stop` and `reload` and
///   only called while the core is running.
/// - `validate`, `statistics` and `health` are **not** serialised: they may
///   overlap each other and any command, including a `stop` that began after
///   the lifecycle checked its state. Implementations must make them safe to
///   call at any time.
public protocol NetworkCore: Sendable {
    /// Static description: identifier, version, capabilities.
    var descriptor: CoreDescriptor { get }

    /// What this core can do. Defaults to `descriptor.capabilities`.
    var capabilities: CoreCapabilities { get }

    /// Checks a configuration without starting anything.
    func validate(_ configuration: CoreConfiguration) async throws -> CoreValidationReport

    func start(_ configuration: CoreConfiguration, options: CoreStartOptions) async throws

    func stop() async throws

    /// Replaces the running configuration in place.
    func reload(_ configuration: CoreConfiguration) async throws

    func statistics() async throws -> CoreStatistics

    /// The newest connections the core tracks (`CoreFeature.connectionList`). Not serialised, like
    /// `statistics`. The default implementation throws `CoreError.unsupportedFeature(.connectionList)`.
    func connections(limit: Int) async throws -> CoreConnectionSnapshot

    func health() async -> CoreHealth

    /// Reacts to a system event. Must return quickly; it is not allowed to
    /// throw. The default implementation ignores every event.
    func handleSystemEvent(_ event: CoreSystemEvent) async
}

extension NetworkCore {
    public var capabilities: CoreCapabilities { descriptor.capabilities }

    public func handleSystemEvent(_ event: CoreSystemEvent) async {}

    public func connections(limit: Int) async throws -> CoreConnectionSnapshot {
        throw CoreError.unsupportedFeature(.connectionList)
    }
}

// MARK: - Errors

/// The operation a `CoreError` happened in.
public enum CoreOperation: String, Hashable, Sendable, Codable, CaseIterable {
    case validate
    case start
    case stop
    case reload
    case statistics
    case health
    case systemEvent
}

/// The only error type that leaves this module. Adapters translate engine
/// errors into it; `normalise` wraps everything else.
public enum CoreError: Error, Hashable, Sendable {
    /// The configuration was rejected. `issues` holds at least the errors.
    case invalidConfiguration(issues: [CoreValidationIssue])
    /// The configuration was compiled for another core.
    case configurationMismatch(expected: CoreIdentifier, actual: CoreIdentifier)
    /// The operation needs a feature the core does not declare.
    case unsupportedFeature(CoreFeature)
    /// The lifecycle does not allow this event in this state.
    case illegalTransition(from: CoreLifecycleState, event: CoreLifecycleEvent)
    /// The operation needs a running core.
    case notRunning(state: CoreLifecycleState)
    case coreNotRegistered(CoreIdentifier)
    case coreAlreadyRegistered(CoreIdentifier)
    /// No registered core has the required capabilities.
    case noCompatibleCore(reasons: [String])
    /// The core failed while performing `operation`.
    case operationFailed(operation: CoreOperation, message: String)
    /// The core stopped on its own.
    case unexpectedExit(message: String)
    case cancelled(operation: CoreOperation)
    /// The caller stopped waiting for `operation` after `seconds`. The
    /// operation itself may still be in progress.
    case timedOut(operation: CoreOperation, seconds: TimeInterval)

    /// Longest message kept from a foreign error.
    public static let maximumMessageLength = 512

    /// Stable machine-readable code (for logs and IPC).
    public var code: String {
        switch self {
        case .invalidConfiguration: return "invalid_configuration"
        case .configurationMismatch: return "configuration_mismatch"
        case .unsupportedFeature: return "unsupported_feature"
        case .illegalTransition: return "illegal_transition"
        case .notRunning: return "not_running"
        case .coreNotRegistered: return "core_not_registered"
        case .coreAlreadyRegistered: return "core_already_registered"
        case .noCompatibleCore: return "no_compatible_core"
        case .operationFailed: return "operation_failed"
        case .unexpectedExit: return "unexpected_exit"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        }
    }

    /// Turns any error into a `CoreError`: a `CoreError` is returned as is,
    /// `CancellationError` becomes `.cancelled`, everything else becomes
    /// `.operationFailed` with a length-bounded description.
    public static func normalise(_ error: Error, during operation: CoreOperation) -> CoreError {
        if let known = error as? CoreError {
            return known
        }
        if error is CancellationError {
            return .cancelled(operation: operation)
        }
        return .operationFailed(operation: operation, message: clip(String(describing: error)))
    }

    static func clip(_ text: String) -> String {
        if text.count <= maximumMessageLength { return text }
        return String(text.prefix(maximumMessageLength)) + "..."
    }
}

extension CoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidConfiguration(issues):
            let texts = issues.prefix(3).map { issue -> String in
                if let path = issue.path { return "\(path): \(issue.message)" }
                return issue.message
            }
            var text = "invalid configuration"
            if !texts.isEmpty { text += ": " + texts.joined(separator: "; ") }
            if issues.count > 3 { text += "; and \(issues.count - 3) more" }
            return text
        case let .configurationMismatch(expected, actual):
            return "configuration is for core '\(actual)', but the core is '\(expected)'"
        case let .unsupportedFeature(feature):
            return "the core does not support '\(feature)'"
        case let .illegalTransition(from, event):
            return "'\(event.rawValue)' is not allowed in state '\(from.rawValue)'"
        case let .notRunning(state):
            return "the core is not running (state '\(state.rawValue)')"
        case let .coreNotRegistered(id):
            return "core '\(id)' is not registered"
        case let .coreAlreadyRegistered(id):
            return "core '\(id)' is already registered"
        case let .noCompatibleCore(reasons):
            return "no compatible core: " + reasons.joined(separator: "; ")
        case let .operationFailed(operation, message):
            return "\(operation.rawValue) failed: \(message)"
        case let .unexpectedExit(message):
            return "the core stopped unexpectedly: \(message)"
        case let .cancelled(operation):
            return "\(operation.rawValue) was cancelled"
        case let .timedOut(operation, seconds):
            return "\(operation.rawValue) did not finish within \(seconds) s"
        }
    }
}
