// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Memory telemetry of the extension process (ADR-0003 §5, risk R-03): the
// Swift host measures `phys_footprint` itself and counts memory-pressure
// events, independently of what an engine reports.
//
// The extension's memory limit is not documented by Apple and has not been
// measured by this project on any device.

import Dispatch
import Foundation

final class MemoryPressureMonitor: @unchecked Sendable {
    enum Level: String {
        case warning
        case critical
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "np.tunnel.memory-pressure")
    private var source: DispatchSourceMemoryPressure?
    private var warnings = 0
    private var criticals = 0

    /// Starts listening. `handler` runs on a private queue for every warning
    /// or critical event. Calling `start` twice replaces the handler.
    func start(handler: @escaping @Sendable (Level, UInt64?) -> Void) {
        stop()
        let newSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self = self, let event = newSource?.data else { return }
            let level: Level = event.contains(.critical) ? .critical : .warning
            self.lock.lock()
            if level == .critical {
                self.criticals += 1
            } else {
                self.warnings += 1
            }
            self.lock.unlock()
            handler(level, MemoryPressureMonitor.physicalFootprintBytes())
        }
        lock.lock()
        source = newSource
        lock.unlock()
        newSource.resume()
    }

    func stop() {
        lock.lock()
        let current = source
        source = nil
        lock.unlock()
        current?.cancel()
    }

    var counts: (warnings: Int, criticals: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (warnings, criticals)
    }

    /// `phys_footprint` of this process, the figure the system's memory limit
    /// for extensions is believed to be applied to. `nil` when the kernel
    /// call fails.
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(info.phys_footprint)
    }
}
