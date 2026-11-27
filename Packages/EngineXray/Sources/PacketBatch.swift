// Verified on Linux only (Swift 5.10.1, swift test). Not yet run on Apple platforms.
import Foundation

/// The batch format of the bridge's packet interface (`tun.mode = "flow"`, both directions): a sequence of
/// frames, each a little-endian `UInt16` length followed by that many bytes of one IP packet
/// (`Cores/Bridge/engine/packetqueue.go`). There is no address family in the frame.
///
/// Swift does not parse packets (ADR-0001 §4.1). The only byte it looks at is the IP version nibble of an
/// outgoing packet, because `NEPacketTunnelFlow.writePackets` wants an address family per packet.
public enum PacketFrame {
    public static let headerSize = 2
    /// Largest packet a frame can carry (the length field is 16 bits).
    public static let maximumPacketBytes = Int(UInt16.max)
}

/// Address family of a packet, as `NEPacketTunnelFlow` wants it.
public enum PacketAddressFamily: Hashable, Sendable {
    case ipv4
    case ipv6

    /// From the version nibble of the first byte; `nil` for anything that is not IPv4 or IPv6.
    @inlinable
    public static func of(firstByte: UInt8) -> PacketAddressFamily? {
        switch firstByte >> 4 {
        case 4: return .ipv4
        case 6: return .ipv6
        default: return nil
        }
    }
}

/// A reusable buffer that packets are framed into before one `npb_tun_write`.
///
/// The storage is allocated once with a fixed capacity and reused for every batch, so encoding allocates
/// nothing per packet or per batch.
public struct PacketBatchEncoder {
    public enum AppendResult: Equatable {
        case appended
        /// The packet would not fit next to what is already in the buffer: flush and append again.
        case full
        /// Empty or longer than a frame can carry; it can never be sent.
        case invalid
    }

    public let capacity: Int
    private(set) var storage: [UInt8]
    public private(set) var byteCount = 0
    public private(set) var packetCount = 0

    /// `capacity` must hold at least one frame of the largest packet the tunnel can produce (MTU + header);
    /// it is clamped to that of a maximum-size frame so that any valid packet fits into an empty buffer.
    public init(capacity: Int) {
        self.capacity = max(capacity, PacketFrame.headerSize + PacketFrame.maximumPacketBytes)
        self.storage = [UInt8](repeating: 0, count: self.capacity)
    }

    public var isEmpty: Bool { packetCount == 0 }

    public mutating func reset() {
        byteCount = 0
        packetCount = 0
    }

    public mutating func append(_ packet: Data) -> AppendResult {
        let size = packet.count
        guard size > 0, size <= PacketFrame.maximumPacketBytes else { return .invalid }
        guard byteCount + PacketFrame.headerSize + size <= capacity else { return .full }
        let offset = byteCount
        storage.withUnsafeMutableBytes { raw in
            raw[offset] = UInt8(truncatingIfNeeded: size)
            raw[offset + 1] = UInt8(truncatingIfNeeded: size >> 8)
            let destination = UnsafeMutableRawBufferPointer(rebasing: raw[(offset + PacketFrame.headerSize)...])
            packet.copyBytes(to: destination.bindMemory(to: UInt8.self), count: size)
        }
        byteCount += PacketFrame.headerSize + size
        packetCount += 1
        return .appended
    }

    /// Gives the framed bytes to `body` (the bridge may modify them in place).
    public mutating func withFramedBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        let used = byteCount
        return try storage.withUnsafeMutableBytes { raw in
            try body(UnsafeMutableRawBufferPointer(rebasing: raw[0..<used]))
        }
    }
}

/// Splits the bytes `npb_tun_read` wrote into packets.
public enum PacketBatchDecoder {
    public struct Outcome: Equatable {
        /// Packets handed to `emit`.
        public var packets = 0
        /// Packets skipped because their IP version is neither 4 nor 6.
        public var unknownFamily = 0
        /// `true` when the bytes ended inside a frame (the bridge never writes that; counted, not trusted).
        public var truncated = false
    }

    /// Calls `emit` for every whole frame, in order, with the packet bytes and their family.
    @discardableResult
    public static func decode(
        _ bytes: UnsafeRawBufferPointer,
        emit: (UnsafeRawBufferPointer, PacketAddressFamily) -> Void
    ) -> Outcome {
        var outcome = Outcome()
        var offset = 0
        let end = bytes.count
        while offset < end {
            guard end - offset >= PacketFrame.headerSize else {
                outcome.truncated = true
                break
            }
            let size = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            let start = offset + PacketFrame.headerSize
            guard size > 0, size <= end - start else {
                outcome.truncated = true
                break
            }
            if let family = PacketAddressFamily.of(firstByte: bytes[start]) {
                emit(UnsafeRawBufferPointer(rebasing: bytes[start..<(start + size)]), family)
                outcome.packets += 1
            } else {
                outcome.unknownFamily += 1
            }
            offset = start + size
        }
        return outcome
    }
}
