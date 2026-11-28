// Thin, portable wrappers over the BSD socket calls the toolbox needs (Darwin and Glibc). Every call here is
// bounded by an explicit deadline; nothing listens, nothing runs in the background.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Posix {
    static var streamType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    static var datagramType: Int32 {
        #if canImport(Darwin)
        return SOCK_DGRAM
        #else
        return Int32(SOCK_DGRAM.rawValue)
        #endif
    }

    static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Monotonic seconds; never goes back when the wall clock changes.
    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func disableSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    enum PollResult: Equatable {
        case ready
        case timedOut
        case failed(Int32)
    }

    /// Waits until `fd` is ready for `events` or the deadline (monotonic seconds) passes.
    static func poll(_ fd: Int32, events: Int16, until deadline: Double) -> PollResult {
        while true {
            let remaining = deadline - now()
            if remaining <= 0 { return .timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up))
            let result = withUnsafeMutablePointer(to: &descriptor) { pointer in
                #if canImport(Darwin)
                return Darwin.poll(pointer, 1, milliseconds)
                #else
                return Glibc.poll(pointer, 1, milliseconds)
                #endif
            }
            if result > 0 { return .ready }
            if result == 0 { return .timedOut }
            if errno == EINTR { continue }
            return .failed(errno)
        }
    }
}

/// A numeric socket address (no name resolution involved).
public struct SocketEndpoint: Sendable, Equatable {
    public let address: String
    public let port: UInt16
    public let isIPv6: Bool
    let storage: [UInt8]

    /// Parses an IPv4 or IPv6 literal (brackets allowed for IPv6). `nil` when `address` is not a literal.
    public init?(address: String, port: UInt16) {
        var text = address.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty, text.utf8.count <= 64 else { return nil }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Posix.streamType
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(text, String(port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        guard let raw = first.pointee.ai_addr else { return nil }
        let length = Int(first.pointee.ai_addrlen)
        storage = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(raw), count: length))
        isIPv6 = first.pointee.ai_family == AF_INET6
        self.port = port
        self.address = SocketEndpoint.numericHost(raw, length: socklen_t(length)) ?? text
    }

    var family: Int32 { isIPv6 ? AF_INET6 : AF_INET }

    /// `host:port`, IPv6 in brackets.
    public var displayText: String {
        isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        storage.withUnsafeBytes { bytes in
            body(bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(bytes.count))
        }
    }

    static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        let text = String(cString: host)
        // Drop a scope suffix ("fe80::1%en0"): it names a local interface, not the address.
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }
}
