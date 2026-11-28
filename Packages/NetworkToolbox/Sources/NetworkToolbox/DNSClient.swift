// One DNS question over UDP to a resolver the user chose. Bounded by a timeout and by
// `DNSMessage.maximumMessageBytes`; answers that do not match the question are ignored until the deadline.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DNSLookupError: Error, Equatable, Sendable {
    case timedOut
    case network(String)
    case dns(DNSError)

    public var message: String {
        switch self {
        case .timedOut: return "Резолвер не ответил вовремя. Проверьте адрес резолвера и сеть."
        case let .network(text): return "Запрос не отправился: \(text)."
        case let .dns(error): return error.message
        }
    }
}

public struct DNSLookupResult: Equatable, Sendable {
    public let resolver: String
    public let response: DNSResponse
    public let seconds: Double
}

public enum DNSClient {
    public static let port: UInt16 = 53

    /// Sends one query and waits for the matching answer. Blocks the calling thread for at most `timeout`.
    public static func lookup(
        _ name: String,
        type: DNSRecordType,
        resolver: SocketEndpoint,
        timeout: Double
    ) -> Result<DNSLookupResult, DNSLookupError> {
        let id = UInt16.random(in: 1...UInt16.max)
        let query: [UInt8]
        do {
            query = try DNSMessage.query(id: id, name: name, type: type)
        } catch let error as DNSError {
            return .failure(.dns(error))
        } catch {
            return .failure(.dns(.invalidName("\(error)")))
        }

        let fd = socket(resolver.family, Posix.datagramType, 0)
        guard fd >= 0 else { return .failure(.network(Posix.errorText(errno))) }
        defer { close(fd) }
        guard Posix.setNonBlocking(fd) else { return .failure(.network(Posix.errorText(errno))) }
        let connected = resolver.withSockaddr { address, length in
            #if canImport(Darwin)
            return Darwin.connect(fd, address, length)
            #else
            return Glibc.connect(fd, address, length)
            #endif
        }
        guard connected == 0 else { return .failure(.network(Posix.errorText(errno))) }

        let start = Posix.now()
        let deadline = start + timeout.clamped(to: ProbeLimits.timeoutRange)
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == query.count else { return .failure(.network(Posix.errorText(errno))) }

        var buffer = [UInt8](repeating: 0, count: DNSMessage.maximumMessageBytes)
        while true {
            switch Posix.poll(fd, events: Int16(POLLIN), until: deadline) {
            case .timedOut:
                return .failure(.timedOut)
            case let .failed(code):
                return .failure(.network(Posix.errorText(code)))
            case .ready:
                let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if received < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    return .failure(.network(Posix.errorText(errno)))
                }
                guard let response = try? DNSMessage.parse(Array(buffer[0..<received])), response.id == id else {
                    continue // not ours or garbage: keep waiting for the real answer
                }
                return .success(DNSLookupResult(resolver: resolver.address, response: response, seconds: Posix.now() - start))
            }
        }
    }
}
