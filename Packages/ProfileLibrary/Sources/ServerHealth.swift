import AdaptiveBalancer
import DomainModels
import Foundation

/// Where a latency number comes from. Both are real measurements; they measure different things and the UI
/// says which.
public enum LatencySource: String, Hashable, Sendable, Codable {
    /// The running engine's health check through the server (Xray observatory, Mihomo url-test): the time of
    /// a small HTTP request through the proxy.
    case engine
    /// The app's own TCP connect to the server's address while disconnected: network distance only, without
    /// the proxy handshake.
    case tcpConnect
}

/// One engine measurement of a group member, in engine tags (from the extension's group report).
public struct EngineMemberMeasurement: Hashable, Sendable {
    public var engineTag: String
    public var alive: Bool
    public var delayMilliseconds: Int?
    public var lastTry: Date?

    public init(engineTag: String, alive: Bool, delayMilliseconds: Int?, lastTry: Date?) {
        self.engineTag = engineTag
        self.alive = alive
        self.delayMilliseconds = delayMilliseconds
        self.lastTry = lastTry
    }
}

/// One result of the app's TCP connect test.
public struct ConnectMeasurement: Hashable, Sendable {
    public var tag: String
    /// `nil` when the connection did not open within the test's timeout.
    public var milliseconds: Int?
    public var at: Date

    public init(tag: String, milliseconds: Int?, at: Date) {
        self.tag = tag
        self.milliseconds = milliseconds
        self.at = at
    }
}

/// The latest known state of one server.
public struct ServerLatency: Hashable, Sendable {
    public var alive: Bool
    /// Last measured value; `nil` when the last attempt failed.
    public var milliseconds: Int?
    /// Smoothed over recent measurements of the same network (AdaptiveBalancer's EWMA); `nil` before the
    /// first success.
    public var smoothedMilliseconds: Int?
    public var measuredAt: Date
    public var source: LatencySource
}

/// What the app knows about the servers of one profile, fed by real measurements only, with the smoothing and
/// failure tracking of `AdaptiveBalancer`. It decides nothing about traffic: with «Авто» the engine chooses
/// (that keeps working while the app is closed); this book ranks servers for the list and explains choices.
public struct ServerHealthBook: Sendable {
    public private(set) var latest: [String: ServerLatency] = [:]
    private var balancer: AdaptiveBalancer
    private var ids: [String: Candidate] = [:]
    private var lastEngineTry: [String: Date] = [:]

    /// `tags`: the profile's server tags. Candidates get opaque ids (`s<index>`), never names or addresses.
    public init(tags: [String], network: NetworkClass = .unknown) {
        var descriptors: [CandidateDescriptor] = []
        for (index, tag) in tags.enumerated() {
            let candidate = Candidate(engine: "engine", transport: "profile", server: ServerID("s\(index)"))
            ids[tag] = candidate
            descriptors.append(CandidateDescriptor(candidate))
        }
        balancer = AdaptiveBalancer(candidates: descriptors, network: network)
    }

    public var tags: Set<String> { Set(ids.keys) }

    private static func instant(_ date: Date) -> Instant {
        Instant(seconds: date.timeIntervalSinceReferenceDate)
    }

    /// Records the engine's measurements of the measured group. A member whose `lastTry` did not move since
    /// the last report is not counted again.
    public mutating func record(engine members: [EngineMemberMeasurement], plan: ServerSelectionPlan) {
        for member in members {
            guard let tag = plan.profileTag(ofEngineTag: member.engineTag), let candidate = ids[tag],
                  let tried = member.lastTry else { continue }
            if let previous = lastEngineTry[tag], previous >= tried { continue }
            lastEngineTry[tag] = tried
            record(candidate: candidate, tag: tag, alive: member.alive, milliseconds: member.delayMilliseconds, at: tried, source: .engine)
        }
    }

    /// Records results of the app's TCP connect test.
    public mutating func record(connect results: [ConnectMeasurement]) {
        for result in results {
            guard let candidate = ids[result.tag] else { continue }
            record(candidate: candidate, tag: result.tag, alive: result.milliseconds != nil, milliseconds: result.milliseconds, at: result.at, source: .tcpConnect)
        }
    }

    private mutating func record(candidate: Candidate, tag: String, alive: Bool, milliseconds: Int?, at: Date, source: LatencySource) {
        let sample: ProbeSample
        if alive, let value = milliseconds {
            let measurement = source == .engine
                ? ProbeMeasurement(rttMillis: Double(value))
                : ProbeMeasurement(rttMillis: Double(value), connectMillis: Double(value))
            sample = .success(candidate, at: ServerHealthBook.instant(at), measurement)
        } else {
            sample = .failure(candidate, at: ServerHealthBook.instant(at), .timeout)
        }
        balancer.record(sample)
        let smoothed = balancer.metrics(of: candidate)?.rtt.current.map { Int($0.rounded()) }
        latest[tag] = ServerLatency(
            alive: alive, milliseconds: alive ? milliseconds : nil, smoothedMilliseconds: smoothed,
            measuredAt: at, source: source
        )
    }

    /// Server tags ordered for display: answering servers by smoothed latency, then unmeasured, then failed.
    public func ranked(_ tags: [String]) -> [String] {
        func key(_ tag: String) -> (Int, Int) {
            guard let entry = latest[tag] else { return (1, 0) }
            guard entry.alive, let value = entry.smoothedMilliseconds ?? entry.milliseconds else { return (2, 0) }
            return (0, value)
        }
        return tags.enumerated().sorted { lhs, rhs in
            let a = key(lhs.element), b = key(rhs.element)
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The fastest answering server by the latest measurement of `source`.
    public func fastest(source: LatencySource) -> (tag: String, milliseconds: Int)? {
        latest.compactMap { tag, entry -> (String, Int)? in
            guard entry.source == source, entry.alive, let value = entry.milliseconds else { return nil }
            return (tag, value)
        }.min { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }

    /// Consecutive failures the balancer's circuit breaker saw for a server; open = stopped answering.
    public func isFailing(_ tag: String, now: Date) -> Bool {
        guard let candidate = ids[tag] else { return false }
        if case .open = balancer.health(of: candidate, now: ServerHealthBook.instant(now)) { return true }
        return false
    }
}

/// The explanation of «Авто» in plain Russian, built only from what was measured.
public enum AutoExplanation {
    public struct Context: Sendable {
        public var connected: Bool
        public var choice: ServerChoice
        /// Profile tag of the server the engine uses now, when it said.
        public var current: String?
        public var engine: TunnelEngine
        public var names: [String: String]

        public init(connected: Bool, choice: ServerChoice, current: String?, engine: TunnelEngine, names: [String: String]) {
            self.connected = connected
            self.choice = choice
            self.current = current
            self.engine = engine
            self.names = names
        }
    }

    public static func text(_ context: Context, book: ServerHealthBook) -> String {
        func name(_ tag: String) -> String { "«\(context.names[tag] ?? tag)»" }
        let minutes = AutomaticGroup.intervalSeconds / 60
        if case let .server(tag) = context.choice {
            return "Выбран вручную: \(name(tag)). Включите «Авто», чтобы движок сам выбирал самый быстрый сервер."
        }
        guard context.connected else {
            var text = "После подключения движок проверяет все серверы раз в \(minutes) мин и ведёт новые соединения через самый быстрый из отвечающих."
            if let best = book.fastest(source: .tcpConnect) {
                text += " По проверке соединения сейчас ближе всех \(name(best.tag)): \(best.milliseconds) мс."
            }
            return text
        }
        let engineMeasured = book.latest.values.filter { $0.source == .engine }
        let answering = engineMeasured.filter(\.alive).count
        guard let current = context.current else {
            return "Движок ещё не сообщил, какой сервер выбран."
        }
        guard !engineMeasured.isEmpty, let entry = book.latest[current], entry.source == .engine else {
            return "Сейчас \(name(current)). Движок ещё проверяет серверы; пока замеров нет, используется первый в списке."
        }
        guard entry.alive, let value = entry.milliseconds else {
            return "Сейчас \(name(current)), но последняя проверка движка до него не дошла. Если другие серверы отвечают, движок переключится на следующей проверке."
        }
        var text = "Сейчас \(name(current)): \(value) мс по последней проверке движка"
        if let best = book.fastest(source: .engine), best.tag != current, best.milliseconds < value {
            if context.engine == .mihomo && value - best.milliseconds <= AutomaticGroup.toleranceMilliseconds {
                text += ". \(name(best.tag)) быстрее на \(value - best.milliseconds) мс — меньше порога \(AutomaticGroup.toleranceMilliseconds) мс, поэтому движок не переключается."
            } else {
                text += ". Самый быстрый сейчас \(name(best.tag)) (\(best.milliseconds) мс): новые соединения пойдут через него."
            }
        } else {
            text += " — самый быстрый из \(answering) \(answering == 1 ? "отвечающего" : "отвечающих")."
        }
        return text
    }
}

/// The bounds of the app's on-demand TCP connect test, used only while disconnected (when connected, the
/// engine measures). Limits of this project.
public enum ConnectProbePlan {
    public static let maximumServers = 64
    public static let concurrency = 4
    public static let timeoutSeconds: Double = 3

    public struct Target: Hashable, Sendable {
        public var tag: String
        public var host: String
        public var port: UInt16
    }

    /// Protocols carried over UDP: a TCP connect says nothing about them, so they are not tested.
    static let udpProtocols: Set<ProxyProtocolKind> = [.hysteria, .hysteria2, .tuic, .wireGuard, .amneziaWG, .masque]

    /// The servers of `profile` the test may contact, at most `maximumServers`, in profile order.
    public static func targets(of profile: Profile) -> [Target] {
        var result: [Target] = []
        for outbound in profile.outbounds where !udpProtocols.contains(outbound.kind) {
            if case .kcp = outbound.stream.transport { continue }
            if case .quic = outbound.stream.transport { continue }
            guard !outbound.server.host.isEmpty, outbound.server.port != 0 else { continue }
            result.append(Target(tag: outbound.tag, host: outbound.server.host, port: outbound.server.port))
            if result.count == maximumServers { break }
        }
        return result
    }
}
