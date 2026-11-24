// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// The last successfully started request, kept so that the system can start
// the tunnel without the app (On-Demand, the switch in Settings).
//
// ADR-0003 §3.3: the snapshot belongs to the extension and lives in its own
// container, not in the App Group, and its file protection class is set
// explicitly. It holds secrets in clear text because the engine needs them
// (risk R-14).
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
        return ConfigurationSnapshotStore(fileURL: folder.appendingPathComponent("last-start-request.json"))
    }

    func save(_ request: TunnelStartRequest) throws {
        let data = try JSONEncoder().encode(request)
        #if os(macOS)
        let options: Data.WritingOptions = [.atomic]
        #else
        // Readable after the first unlock, so that On-Demand works on a
        // locked device that was unlocked once since boot.
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #endif
        try data.write(to: fileURL, options: options)
    }

    /// Returns `nil` when no snapshot exists.
    func load() throws -> TunnelStartRequest? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(TunnelStartRequest.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
