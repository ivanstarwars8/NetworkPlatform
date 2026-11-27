// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS,
// visionOS, unsigned (CODE_SIGNING_ALLOWED=NO), https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/45966628451
//
// The last successfully started request, kept so that the system can start
// the tunnel without the app (On-Demand, the switch in Settings).
//
// ADR-0003 §3.3: the snapshot belongs to the extension and lives in its own
// container, not in the App Group, and its file protection class is set
// explicitly. It holds secrets in clear text because the engine needs them
// (risk R-14).
//
// The file uses the same container format as the hand-off file
// (`TunnelStartContainer`, tested on Linux), so a damaged or oversized
// snapshot is refused instead of being handed to an engine.
//
// Not proven (ADR-0003 §7): that the file is readable on an On-Demand start
// before the first unlock, and that tvOS keeps it between launches.

import Foundation

struct ConfigurationSnapshotStore {
    let fileURL: URL

    /// A file in the extension's own container. tvOS offers no durable
    /// location, so the caches directory is used there and the snapshot may
    /// disappear; the tunnel then fails with a clear error instead of running
    /// without an engine.
    static func inOwnContainer() throws -> ConfigurationSnapshotStore {
        #if os(tvOS)
        let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let directory = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif
        let base = try FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("TunnelSnapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ConfigurationSnapshotStore(fileURL: folder.appendingPathComponent("last-start-request.bin"))
    }

    func save(_ request: TunnelStartRequest) throws {
        let data = try TunnelStartContainer.encode(request)
        // Same options as the hand-off: atomic, and on iOS-family systems
        // readable after the first unlock, so that On-Demand works on a
        // locked device that was unlocked once since boot.
        try data.write(to: fileURL, options: ConfigurationHandoff.writingOptions)
    }

    /// Returns `nil` when no snapshot exists. Throws `TunnelIPCError` when
    /// one exists but is too large or damaged.
    func load() throws -> TunnelStartRequest? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        // One byte past the limit is enough to notice an oversized file
        // without reading it into memory.
        let limit = TunnelStartContainer.maximumBytes + 1
        var data = Data()
        while data.count < limit {
            guard let piece = try handle.read(upToCount: min(limit - data.count, 1 << 20)), !piece.isEmpty else {
                break
            }
            data.append(piece)
        }
        return try TunnelStartContainer.decode(data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
