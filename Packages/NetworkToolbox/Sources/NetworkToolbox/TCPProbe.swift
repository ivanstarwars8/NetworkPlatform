// TCP connect timing (the "TCP ping"), the port check and name resolution through the system resolver.
// A TCP ping measures the time of the three-way handshake to a port: no ICMP (an app may not open raw
// sockets on Apple platforms), and nothing is written to the connection. Each attempt is bounded by its
// timeout; a whole run by `count × (timeout + interval)`.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bounds of this project for user-started probes; requests outside them are clamped, not refused.
public enum ProbeLimits {
    public static let timeoutRange: ClosedRange<Double> = 0.2...10
    public static let defaultTimeout: Double = 3
    public static let pingCountRange: ClosedRange<Int> = 1...20
    public static let defaultPingCount = 5
    public static let pingInterval: Double = 0.5
    /// Longest host name or address accepted from the user.
    public static let maximumHostLength = 253
}

public enum TCPConnectOutcome: Equatable, Sendable {
    /// The handshake completed after this many seconds.
    case connected(seconds: Double)
    /// The host answered with a reset: reachable, nothing listens on the port.
    case refused
    /// No answer within the timeout: filtered, dropped or unreachable.
    case timedOut
    case failed(String)

    public var connectedSeconds: Double? {
        if case let .connected(seconds) = self { return seconds }
        return nil
    }
}

public enum TCPProbe {
    /// One TCP handshake to a numeric endpoint. Blocks the calling thread for at most `timeout`.
    public static func connect(to endpoint: SocketEndpoint, timeout: Double) -> TCPConnectOutcome {
        let limit = timeout.clamped(to: ProbeLimits.timeoutRange)
        let fd = socket(endpoint.family, Posix.streamType, 0)
        guard fd >= 0 else { return .failed(Posix.errorText(errno)) }
        defer { close(fd) }
        Posix.disableSigPipe(fd)
        guard Posix.setNonBlocking(fd) else { return .failed(Posix.errorText(errno)) }

        let start = Posix.now()
        let deadline = start + limit
        let result = endpoint.withSockaddr { address, length in
            #if canImport(Darwin)
            return Darwin.connect(fd, address, length)
            #else
            return Glibc.connect(fd, address, length)
            #endif
        }
        if result == 0 {
            return .connected(seconds: Posix.now() - start)
        }
        let code = errno
        if code == ECONNREFUSED { return .refused }
        guard code == EINPROGRESS || code == EINTR else { return .failed(Posix.errorText(code)) }

        switch Posix.poll(fd, events: Int16(POLLOUT), until: deadline) {
        case .timedOut:
            return .timedOut
        case let .failed(pollError):
            return .failed(Posix.errorText(pollError))
        case .ready:
            let elapsed = Posix.now() - start
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                return .failed(Posix.errorText(errno))
            }
            switch socketError {
            case 0: return .connected(seconds: elapsed)
            case ECONNREFUSED: return .refused
            case ETIMEDOUT: return .timedOut
            default: return .failed(Posix.errorText(socketError))
            }
        }
    }

    /// `count` handshakes one after another, `interval` apart. Blocks the calling thread; `isCancelled` is
    /// checked between attempts.
    public static func ping(
        _ endpoint: SocketEndpoint,
        count: Int,
        timeout: Double,
        interval: Double = ProbeLimits.pingInterval,
        isCancelled: () -> Bool = { false }
    ) -> [TCPConnectOutcome] {
        let attempts = count.clamped(to: ProbeLimits.pingCountRange)
        var outcomes: [TCPConnectOutcome] = []
        for index in 0..<attempts {
            if isCancelled() { break }
            outcomes.append(connect(to: endpoint, timeout: timeout))
            if index + 1 < attempts {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        return outcomes
    }
}

/// Min / average / max / jitter / loss of a series of attempts; `nil` entries are lost attempts.
public struct LatencySummary: Equatable, Sendable {
    public let sent: Int
    public let received: Int
    public let minimum: Double?
    public let average: Double?
    public let maximum: Double?
    /// Mean absolute difference between consecutive received samples (RFC 3550 style, unsmoothed).
    public let jitter: Double?

    public init(samples: [Double?]) {
        sent = samples.count
        let values = samples.compactMap { $0 }
        received = values.count
        minimum = values.min()
        maximum = values.max()
        average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        if values.count >= 2 {
            var total = 0.0
            for index in 1..<values.count {
                total += abs(values[index] - values[index - 1])
            }
            jitter = total / Double(values.count - 1)
        } else {
            jitter = nil
        }
    }

    public init(outcomes: [TCPConnectOutcome]) {
        self.init(samples: outcomes.map { $0.connectedSeconds })
    }

    /// Lost attempts in percent, 0...100.
    public var lossPercent: Double {
        sent == 0 ? 0 : Double(sent - received) * 100 / Double(sent)
    }
}

public enum PortState: Equatable, Sendable {
    case open(seconds: Double)
    case closed
    case noAnswer
    case failed(String)

    public init(_ outcome: TCPConnectOutcome) {
        switch outcome {
        case let .connected(seconds): self = .open(seconds: seconds)
        case .refused: self = .closed
        case .timedOut: self = .noAnswer
        case let .failed(text): self = .failed(text)
        }
    }

    public var title: String {
        switch self {
        case .open: return "Открыт"
        case .closed: return "Закрыт"
        case .noAnswer: return "Нет ответа"
        case .failed: return "Ошибка"
        }
    }

    public var explanation: String {
        switch self {
        case .open: return "Соединение установлено: на порту кто-то слушает."
        case .closed: return "Узел ответил отказом: доступен, но порт никто не слушает."
        case .noAnswer: return "Ответа не было: порт фильтруется, узел недоступен или пакеты теряются."
        case let .failed(text): return "Проверка не выполнилась: \(text)."
        }
    }
}

// MARK: - System resolver

public enum ResolutionError: Error, Equatable, Sendable {
    case timedOut
    case notFound
    case failed(String)

    public var message: String {
        switch self {
        case .timedOut: return "Системный резолвер не ответил вовремя. Проверьте сеть и повторите."
        case .notFound: return "Имя не найдено. Проверьте написание."
        case let .failed(text): return "Имя не разрешилось: \(text)."
        }
    }
}

public struct Resolution: Equatable, Sendable {
    /// Numeric addresses in the order the resolver returned them, without duplicates.
    public let addresses: [String]
    public let seconds: Double
}

public enum SystemResolver {
    /// Resolves through the operating system (getaddrinfo), which follows the system DNS settings and, while
    /// the tunnel is up, the tunnel's resolver. getaddrinfo has no timeout of its own: it runs on its own
    /// thread and the caller stops waiting after `timeout` (the thread finishes on its own).
    public static func resolve(_ host: String, timeout: Double) -> Result<Resolution, ResolutionError> {
        if let endpoint = SocketEndpoint(address: host, port: 0) {
            return .success(Resolution(addresses: [endpoint.address], seconds: 0))
        }
        let box = ResolutionBox()
        let start = Posix.now()
        let thread = Thread {
            box.finish(lookup(host, start: start))
        }
        thread.stackSize = 256 * 1024
        thread.start()
        guard box.wait(timeout: timeout.clamped(to: ProbeLimits.timeoutRange)) else {
            return .failure(.timedOut)
        }
        return box.result ?? .failure(.timedOut)
    }

    private static func lookup(_ host: String, start: Double) -> Result<Resolution, ResolutionError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Posix.streamType
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &list)
        let elapsed = Posix.now() - start
        guard status == 0 else {
            if status == EAI_NONAME { return .failure(.notFound) }
            // EAI_NODATA (-5 in glibc, not exported to Swift): the name exists without addresses.
            #if canImport(Glibc)
            if status == -5 { return .failure(.notFound) }
            #endif
            return .failure(.failed(String(cString: gai_strerror(status))))
        }
        defer { freeaddrinfo(list) }
        var addresses: [String] = []
        var cursor = list
        while let entry = cursor {
            if let raw = entry.pointee.ai_addr,
               let text = SocketEndpoint.numericHost(raw, length: entry.pointee.ai_addrlen),
               !addresses.contains(text) {
                addresses.append(text)
            }
            cursor = entry.pointee.ai_next
        }
        return addresses.isEmpty ? .failure(.notFound) : .success(Resolution(addresses: addresses, seconds: elapsed))
    }
}

private final class ResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var stored: Result<Resolution, ResolutionError>?

    func finish(_ value: Result<Resolution, ResolutionError>) {
        lock.lock()
        stored = value
        lock.unlock()
        done.signal()
    }

    func wait(timeout: Double) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    var result: Result<Resolution, ResolutionError>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
