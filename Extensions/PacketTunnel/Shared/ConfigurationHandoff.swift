// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 45966628451 (workflow apple.yml)
// (compiled and unit-tested on Linux only, see the note in TunnelMessages.swift;
// the `canImport(Darwin)` and `canImport(CryptoKit)` branches were never compiled)
//
// Hand-off of a start request from the app to the Packet Tunnel extension.
//
// The compiled engine configuration can be megabytes; the size the system
// accepts in `startVPNTunnel(options:)` is not documented and was never
// measured by this project (ADR-0003 §7). So the options carry only a
// `TunnelStartReference` (well under 1 KiB) and the request itself travels in
// a file in the shared App Group container:
//
//   app:        write(request)   -> file + reference
//   app:        startVPNTunnel(options: reference.startOptions())
//   extension:  consume(reference) -> request; the file is deleted
//
// Integrity: the reference carries the exact length and the SHA-256 of the
// file. The reference travels through the system (start options), the file
// through the shared container; a truncated, stale, swapped or altered file
// does not match and is refused. This is an integrity check, not secrecy: the
// file holds secrets in clear text, exactly like the snapshot (ADR-0003 §4,
// risk R-14), protected by the container, its protection class and its short
// life.
//
// Not proven (needs a Mac and devices): that a sandboxed macOS app extension
// and a system extension can read the group container the app wrote to, and
// what tvOS does to a group container between launches.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Digest

enum TunnelDigest {
    /// Lower-case hexadecimal SHA-256.
    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return hex(Array(SHA256.hash(data: data)))
        #else
        return hex(sha256Portable(data))
        #endif
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// SHA-256 (FIPS 180-4) without platform libraries, for platforms that
    /// have no CryptoKit. Checked against the standard test vectors.
    static func sha256Portable(_ data: Data) -> [UInt8] {
        var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var schedule = [UInt32](repeating: 0, count: 64)
        let constants = roundConstants

        func compress(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
            for index in 0..<16 {
                let base = offset + index * 4
                schedule[index] = UInt32(bytes[base]) << 24
                    | UInt32(bytes[base + 1]) << 16
                    | UInt32(bytes[base + 2]) << 8
                    | UInt32(bytes[base + 3])
            }
            for index in 16..<64 {
                let w15 = schedule[index - 15]
                let w2 = schedule[index - 2]
                let s0 = (w15 >> 7 | w15 << 25) ^ (w15 >> 18 | w15 << 14) ^ (w15 >> 3)
                let s1 = (w2 >> 17 | w2 << 15) ^ (w2 >> 19 | w2 << 13) ^ (w2 >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ choice &+ constants[index] &+ schedule[index]
                let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        let count = data.count
        let fullBlocks = count / 64
        data.withUnsafeBytes { bytes in
            for block in 0..<fullBlocks {
                compress(bytes, at: block * 64)
            }
        }

        var tail = [UInt8](data.suffix(count % 64))
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        let bitCount = UInt64(count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        tail.withUnsafeBytes { bytes in
            for block in 0..<(tail.count / 64) {
                compress(bytes, at: block * 64)
            }
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }
}

// MARK: - Container

/// Binary form of a `TunnelStartRequest`, used for the hand-off file and for
/// the extension's snapshot.
///
///     8 bytes   "NPSTART" and one byte of format version
///     4 bytes   header length, big-endian
///     header    JSON: engine identifier, format label, network plan
///     rest      the engine configuration, raw
///
/// The configuration is kept raw instead of base64-in-JSON: the extension has
/// little memory, and a third more of it for an encoding is waste.
enum TunnelStartContainer {
    static let formatVersion: UInt8 = 1
    static let magic: [UInt8] = Array("NPSTART".utf8)
    static let prefixLength = 12

    /// Limits of this project. `maximumConfigurationBytes` must equal
    /// `CoreConfiguration.maximumPayloadBytes` (a unit test compares them;
    /// this file cannot import `CoreAbstraction` because the app links it).
    static let maximumConfigurationBytes = 8 * 1024 * 1024
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBytes = prefixLength + maximumHeaderBytes + maximumConfigurationBytes

    private struct Header: Codable {
        var coreID: String
        var format: String
        var network: TunnelNetworkPlan
    }

    static func encode(_ request: TunnelStartRequest) throws -> Data {
        guard !request.configuration.isEmpty else {
            throw TunnelIPCError(.noConfiguration, "the configuration is empty")
        }
        guard request.configuration.count <= maximumConfigurationBytes else {
            throw TunnelIPCError(
                .handoffTooLarge,
                "configuration is \(request.configuration.count) bytes, the limit is \(maximumConfigurationBytes)"
            )
        }
        try request.network.validate()
        let header = Header(coreID: request.coreID, format: request.format, network: request.network)
        guard let headerData = try? JSONEncoder().encode(header), headerData.count <= maximumHeaderBytes else {
            throw TunnelIPCError(.handoffTooLarge, "start request header exceeds \(maximumHeaderBytes) bytes")
        }
        var data = Data()
        data.reserveCapacity(prefixLength + headerData.count + request.configuration.count)
        data.append(contentsOf: magic)
        data.append(formatVersion)
        let length = UInt32(headerData.count)
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        data.append(headerData)
        data.append(request.configuration)
        return data
    }

    static func decode(_ container: Data) throws -> TunnelStartRequest {
        func corrupt(_ text: String) -> TunnelIPCError {
            TunnelIPCError(.handoffCorrupt, text)
        }
        guard container.count <= maximumBytes else {
            throw TunnelIPCError(.handoffTooLarge, "start request is \(container.count) bytes, the limit is \(maximumBytes)")
        }
        // Rebased so that indices start at zero whatever slice was passed.
        let bytes = container.startIndex == 0 ? container : Data(container)
        guard bytes.count >= prefixLength else {
            throw corrupt("start request is shorter than its prefix")
        }
        guard Array(bytes[0..<magic.count]) == magic else {
            throw corrupt("start request has no signature")
        }
        guard bytes[magic.count] == formatVersion else {
            throw TunnelIPCError(.unsupportedVersion, "start request format \(bytes[magic.count]) is not supported")
        }
        let headerLength = Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11])
        guard headerLength > 0, headerLength <= maximumHeaderBytes, prefixLength + headerLength <= bytes.count else {
            throw corrupt("start request header length is out of range")
        }
        let headerEnd = prefixLength + headerLength
        guard let header = try? JSONDecoder().decode(Header.self, from: bytes.subdata(in: prefixLength..<headerEnd)) else {
            throw corrupt("start request header cannot be decoded")
        }
        let configuration = bytes.subdata(in: headerEnd..<bytes.count)
        guard !configuration.isEmpty else {
            throw corrupt("start request carries no configuration")
        }
        guard configuration.count <= maximumConfigurationBytes else {
            throw TunnelIPCError(.handoffTooLarge, "configuration exceeds \(maximumConfigurationBytes) bytes")
        }
        guard !header.coreID.isEmpty, header.coreID.utf8.count <= 128, header.format.utf8.count <= 64 else {
            throw corrupt("start request names no engine")
        }
        try header.network.validate()
        return TunnelStartRequest(
            coreID: header.coreID,
            format: header.format,
            configuration: configuration,
            network: header.network
        )
    }
}

// MARK: - Reference

/// The only thing that travels in `startVPNTunnel(options:)`.
struct TunnelStartReference: Codable, Equatable, Sendable {
    var version: UInt16
    /// Name of the hand-off file without its extension: a UUID string.
    var handoffID: String
    /// Exact length of the hand-off file.
    var byteCount: Int
    /// Lower-case hexadecimal SHA-256 of the hand-off file.
    var sha256: String

    /// Structural check, including the one that keeps `handoffID` from
    /// naming a path outside the hand-off directory.
    func validate() throws {
        func malformed(_ text: String) -> TunnelIPCError {
            TunnelIPCError(.malformedStartReference, text)
        }
        guard version == TunnelIPC.protocolVersion else {
            throw TunnelIPCError(.unsupportedVersion, "start reference version \(version) is not supported")
        }
        guard let uuid = UUID(uuidString: handoffID), uuid.uuidString == handoffID else {
            throw malformed("hand-off identifier is not a canonical UUID")
        }
        guard byteCount > TunnelStartContainer.prefixLength else {
            throw malformed("hand-off length is too small")
        }
        guard byteCount <= TunnelStartContainer.maximumBytes else {
            throw TunnelIPCError(.handoffTooLarge, "hand-off is \(byteCount) bytes, the limit is \(TunnelStartContainer.maximumBytes)")
        }
        let isHex = sha256.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        guard sha256.utf8.count == 64, isHex else {
            throw malformed("hand-off digest is not a lower-case SHA-256")
        }
    }

    /// Encodes the reference for `startVPNTunnel(options:)`.
    func startOptions() throws -> [String: NSObject] {
        try validate()
        guard let data = try? JSONEncoder().encode(self), data.count <= TunnelIPC.maximumStartReferenceBytes else {
            throw TunnelIPCError(.malformedStartReference, "start reference cannot be encoded")
        }
        return [TunnelIPC.startReferenceOptionKey: NSData(data: data)]
    }

    /// Decodes the reference from start options. Returns `nil` when the
    /// options carry none (On-Demand start, the switch in Settings).
    static func from(startOptions: [String: NSObject]?) throws -> TunnelStartReference? {
        guard let value = startOptions?[TunnelIPC.startReferenceOptionKey] else {
            return nil
        }
        guard let boxed = value as? NSData else {
            throw TunnelIPCError(.malformedStartReference, "start reference is not a data value")
        }
        guard boxed.length <= TunnelIPC.maximumStartReferenceBytes else {
            throw TunnelIPCError(.malformedStartReference, "start reference exceeds \(TunnelIPC.maximumStartReferenceBytes) bytes")
        }
        // Copied, so that nothing keeps pointing into the options dictionary.
        let data = Data(Data(referencing: boxed))
        guard let reference = try? JSONDecoder().decode(TunnelStartReference.self, from: data) else {
            throw TunnelIPCError(.malformedStartReference, "start reference cannot be decoded")
        }
        try reference.validate()
        return reference
    }
}

// MARK: - Hand-off directory

struct ConfigurationHandoff {
    /// A directory both processes can reach. Injected, so that the logic can
    /// be tested anywhere; see `sharedDirectory()` for the real one.
    let directory: URL

    static let fileExtension = "start"
    /// Files older than this are leftovers of starts that never happened.
    static let staleAfter: TimeInterval = 600

    init(directory: URL) {
        self.directory = directory
    }

    func fileURL(for handoffID: String) -> URL {
        directory.appendingPathComponent(handoffID).appendingPathExtension(ConfigurationHandoff.fileExtension)
    }

    // MARK: App side

    /// Writes the request and returns the reference to put into the start
    /// options. Leftovers of earlier starts are removed first.
    func write(_ request: TunnelStartRequest, now: Date = Date()) throws -> TunnelStartReference {
        let container = try TunnelStartContainer.encode(request)
        let reference = TunnelStartReference(
            version: TunnelIPC.protocolVersion,
            handoffID: UUID().uuidString,
            byteCount: container.count,
            sha256: TunnelDigest.sha256Hex(container)
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            removeStale(now: now)
            try container.write(to: fileURL(for: reference.handoffID), options: ConfigurationHandoff.writingOptions)
        } catch {
            // The system error may contain the path, never the content.
            throw TunnelIPCError(.handoffWriteFailed, "hand-off file could not be written: \(type(of: error))")
        }
        return reference
    }

    /// Removes the file of a start that will not happen (the system refused
    /// `startVPNTunnel`).
    func discard(_ reference: TunnelStartReference) {
        guard (try? reference.validate()) != nil else { return }
        try? FileManager.default.removeItem(at: fileURL(for: reference.handoffID))
    }

    /// Removes hand-off files older than `staleAfter`. Returns how many.
    @discardableResult
    func removeStale(now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in names where name.hasSuffix("." + ConfigurationHandoff.fileExtension) {
            let url = directory.appendingPathComponent(name)
            guard
                let attributes = try? manager.attributesOfItem(atPath: url.path),
                let modified = attributes[.modificationDate] as? Date,
                now.timeIntervalSince(modified) > ConfigurationHandoff.staleAfter
            else {
                continue
            }
            if (try? manager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: Extension side

    /// Reads the request a reference points to, checks its length and digest
    /// and deletes the file, whatever the outcome: a hand-off is used once.
    func consume(_ reference: TunnelStartReference) throws -> TunnelStartRequest {
        try reference.validate()
        let url = fileURL(for: reference.handoffID)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw TunnelIPCError(.handoffMissing, "hand-off file does not exist or cannot be opened")
        }
        defer { try? handle.close() }

        // One byte more than announced is enough to notice a longer file
        // without reading it.
        let limit = reference.byteCount + 1
        var container = Data()
        container.reserveCapacity(reference.byteCount)
        while container.count < limit {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: limit - container.count)
            } catch {
                throw TunnelIPCError(.handoffCorrupt, "hand-off file cannot be read")
            }
            guard let piece = chunk, !piece.isEmpty else { break }
            container.append(piece)
        }
        guard container.count == reference.byteCount else {
            throw TunnelIPCError(.handoffCorrupt, "hand-off file length does not match its reference")
        }
        guard TunnelDigest.sha256Hex(container) == reference.sha256 else {
            throw TunnelIPCError(.handoffCorrupt, "hand-off file digest does not match its reference")
        }
        return try TunnelStartContainer.decode(container)
    }

    // MARK: Platform

    static var writingOptions: Data.WritingOptions {
        #if canImport(Darwin) && !os(macOS)
        // Readable after the first unlock, like the snapshot.
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    #if canImport(Darwin)
    /// Info.plist key that names the App Group; filled from the build
    /// setting `NP_APP_GROUP` in both targets (Apps/project.yml). The
    /// identifier has different forms on iOS and on macOS, so it is never
    /// hard-coded or derived here.
    static let appGroupInfoKey = "NPAppGroupIdentifier"

    /// The hand-off directory in the App Group container.
    static func sharedDirectory(bundle: Bundle = .main) throws -> URL {
        guard
            let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
            !group.isEmpty,
            !group.contains("$(")
        else {
            throw TunnelIPCError(.handoffUnavailable, "the bundle names no App Group")
        }
        // On macOS this returns a URL even for a group the process is not
        // entitled to; the failure then surfaces when the file is written or
        // opened.
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TunnelIPCError(.handoffUnavailable, "the App Group container is not available")
        }
        return container.appendingPathComponent("StartHandoff", isDirectory: true)
    }
    #endif
}
