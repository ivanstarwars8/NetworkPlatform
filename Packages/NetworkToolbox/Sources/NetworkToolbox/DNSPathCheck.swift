// The DNS leak check, by our own logic and without third-party leak-test services: compare the resolvers the
// system is configured to ask with the resolvers the tunnel announces (TunnelAddressing), and send one query
// straight to the tunnel's resolver to confirm the engine answers it. A resolver outside the tunnel while the
// tunnel is up means DNS questions can leave the device without the tunnel.

import CNetworkToolbox
import Foundation

public enum SystemDNSConfiguration {
    /// The resolvers the system resolver library would ask (res_ninit). `nil` when the configuration could
    /// not be read. On Linux only IPv4 resolvers are listed.
    public static func resolvers() -> [String]? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let count = np_system_resolvers(&buffer, Int32(buffer.count))
        guard count >= 0 else { return nil }
        return split(buffer, count: Int(count))
    }

    /// Splits the NUL-separated output of `np_system_resolvers`.
    static func split(_ buffer: [CChar], count: Int) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        for byte in buffer {
            if byte == 0 {
                if current.isEmpty { break }
                result.append(String(decoding: current, as: UTF8.self))
                current = []
                if result.count == count { break }
            } else {
                current.append(UInt8(bitPattern: byte))
            }
        }
        var unique: [String] = []
        for item in result where !unique.contains(item) { unique.append(item) }
        return unique
    }
}

public struct DNSPathCheck: Equatable, Sendable {
    public enum ProbeResult: Equatable, Sendable {
        case answered(seconds: Double)
        case failed(String)
        case notRun
    }

    public enum Verdict: Equatable, Sendable {
        /// Tunnel down: questions go to the network's resolvers, as expected without a tunnel.
        case tunnelOff
        /// Every system resolver is the tunnel's and the tunnel's resolver answers.
        case protected
        /// The system asks resolvers outside the tunnel while the tunnel is up.
        case leaking(outside: [String])
        /// The system points at the tunnel, but the tunnel's resolver did not answer.
        case tunnelResolverSilent
        /// The system configuration could not be read.
        case unknown
    }

    public let tunnelConnected: Bool
    public let tunnelResolvers: [String]
    public let systemResolvers: [String]?
    public let probe: ProbeResult

    public init(tunnelConnected: Bool, tunnelResolvers: [String], systemResolvers: [String]?, probe: ProbeResult) {
        self.tunnelConnected = tunnelConnected
        self.tunnelResolvers = tunnelResolvers
        self.systemResolvers = systemResolvers
        self.probe = probe
    }

    public var verdict: Verdict {
        guard tunnelConnected else { return .tunnelOff }
        guard let system = systemResolvers, !system.isEmpty else { return .unknown }
        let tunnel = Set(tunnelResolvers.compactMap { SocketEndpoint(address: $0, port: 0)?.address ?? $0 })
        let outside = system.filter { !tunnel.contains(SocketEndpoint(address: $0, port: 0)?.address ?? $0) }
        if !outside.isEmpty { return .leaking(outside: outside) }
        if case .failed = probe { return .tunnelResolverSilent }
        return .protected
    }

    public var title: String {
        switch verdict {
        case .tunnelOff: return "Туннель выключен"
        case .protected: return "Утечки нет"
        case .leaking: return "Возможна утечка"
        case .tunnelResolverSilent: return "Резолвер туннеля молчит"
        case .unknown: return "Не удалось проверить"
        }
    }

    public var explanation: String {
        switch verdict {
        case .tunnelOff:
            return "Запросы DNS идут к резолверам текущей сети. Подключитесь и проверьте снова."
        case .protected:
            return "Система спрашивает только резолвер туннеля, и он ответил. Запросы DNS не уходят мимо туннеля."
        case let .leaking(outside):
            return "Кроме резолвера туннеля система спрашивает \(outside.joined(separator: ", ")). Такие запросы могут идти мимо туннеля. Переподключитесь; если не помогло — сообщите об этом в диагностике."
        case .tunnelResolverSilent:
            return "Система направляет запросы в туннель, но резолвер туннеля не ответил: имена не будут разрешаться. Переподключитесь."
        case .unknown:
            return "Система не отдала список резолверов. Повторите проверку."
        }
    }
}
