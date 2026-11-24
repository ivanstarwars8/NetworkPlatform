// Verified on Linux only (Swift 5.10.1, swift test, 2026-11-24). Not yet built or run on Apple platforms.
import Foundation

// MARK: - Selection

/// The outcome of choosing a core, with everything needed to explain it.
public struct CoreSelection: Hashable, Sendable {
    public struct Candidate: Hashable, Sendable {
        public let descriptor: CoreDescriptor
        /// Required capabilities this core lacks; empty when eligible.
        public let missing: CoreCapabilities

        public var isEligible: Bool { missing.isEmpty }
    }

    /// The chosen core, or `nil` when no candidate is eligible.
    public let selected: CoreDescriptor?
    /// Every distinct candidate, ordered by identifier.
    public let candidates: [Candidate]
    /// Human-readable account of the decision, in the order it was made.
    public let reasons: [String]
}

/// Chooses a core for a set of required capabilities.
///
/// The result depends only on the arguments, never on the order of
/// `descriptors`, on hashing order or on time:
/// 1. a core is eligible when it has every required capability;
/// 2. among eligible cores the first one listed in `preference` wins;
/// 3. if none of the preferred cores is eligible, the eligible core with the
///    lowest identifier (string order) wins.
public struct CoreSelector: Hashable, Sendable {
    /// Identifiers in order of preference. Cores not listed come last.
    public var preference: [CoreIdentifier]

    public init(preference: [CoreIdentifier] = []) {
        self.preference = preference
    }

    public func select(from descriptors: [CoreDescriptor], required: CoreCapabilities) -> CoreSelection {
        var reasons: [String] = ["required: \(required)"]

        // Deterministic order; duplicates of an identifier are dropped.
        let ordered = descriptors.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.capabilities.description < rhs.capabilities.description
        }
        var seen = Set<CoreIdentifier>()
        var candidates: [CoreSelection.Candidate] = []
        for descriptor in ordered {
            if seen.contains(descriptor.id) {
                reasons.append("'\(descriptor.id)' \(descriptor.version): ignored, duplicate identifier")
                continue
            }
            seen.insert(descriptor.id)
            let missing = descriptor.capabilities.missing(from: required)
            candidates.append(CoreSelection.Candidate(descriptor: descriptor, missing: missing))
            if missing.isEmpty {
                reasons.append("'\(descriptor.id)' \(descriptor.version): eligible")
            } else {
                reasons.append("'\(descriptor.id)' \(descriptor.version): rejected, missing \(missing)")
            }
        }

        if candidates.isEmpty {
            reasons.append("no core selected: no cores are available")
            return CoreSelection(selected: nil, candidates: candidates, reasons: reasons)
        }

        let eligible = candidates.filter { $0.isEligible }
        if eligible.isEmpty {
            reasons.append("no core selected: none of \(candidates.count) available cores has every required capability")
            return CoreSelection(selected: nil, candidates: candidates, reasons: reasons)
        }

        for (position, preferred) in preference.enumerated() {
            if let match = eligible.first(where: { $0.descriptor.id == preferred }) {
                reasons.append("selected '\(preferred)': eligible and number \(position + 1) in the preference order")
                return CoreSelection(selected: match.descriptor, candidates: candidates, reasons: reasons)
            }
            if seen.contains(preferred) {
                reasons.append("preferred '\(preferred)' is not eligible")
            } else {
                reasons.append("preferred '\(preferred)' is not available")
            }
        }

        // `eligible` keeps the identifier order of `candidates`.
        let chosen = eligible[0].descriptor
        if eligible.count == 1 {
            reasons.append("selected '\(chosen.id)': the only eligible core")
        } else {
            reasons.append("selected '\(chosen.id)': lowest identifier among \(eligible.count) eligible cores")
        }
        return CoreSelection(selected: chosen, candidates: candidates, reasons: reasons)
    }

    /// Like `select`, but throws `CoreError.noCompatibleCore` with the reasons
    /// when nothing is eligible.
    public func requireSelection(from descriptors: [CoreDescriptor], required: CoreCapabilities) throws -> CoreDescriptor {
        let selection = select(from: descriptors, required: required)
        guard let selected = selection.selected else {
            throw CoreError.noCompatibleCore(reasons: selection.reasons)
        }
        return selected
    }
}

// MARK: - Registry

/// The cores present in this build. Thread-safe.
///
/// The registry stores a factory, not an instance: both engines allow only
/// one instance per process (ADR-0001 §1), so creation is left to the caller
/// that owns the process.
public final class CoreRegistry: @unchecked Sendable {
    public typealias Factory = @Sendable () -> any NetworkCore

    private struct Entry {
        let descriptor: CoreDescriptor
        let factory: Factory
    }

    private let lock = NSLock()
    private var entries: [CoreIdentifier: Entry] = [:]

    public init() {}

    /// Adds a core. Throws `CoreError.coreAlreadyRegistered` when the
    /// identifier is taken.
    public func register(_ descriptor: CoreDescriptor, factory: @escaping Factory) throws {
        lock.lock()
        defer { lock.unlock() }
        if entries[descriptor.id] != nil {
            throw CoreError.coreAlreadyRegistered(descriptor.id)
        }
        entries[descriptor.id] = Entry(descriptor: descriptor, factory: factory)
    }

    /// Removes a core. Returns `false` when it was not registered.
    @discardableResult
    public func unregister(_ id: CoreIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.removeValue(forKey: id) != nil
    }

    public func descriptor(for id: CoreIdentifier) -> CoreDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]?.descriptor
    }

    /// Registered descriptors, ordered by identifier.
    public var descriptors: [CoreDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.map { $0.descriptor }.sorted { $0.id < $1.id }
    }

    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Creates an instance of a registered core. Throws
    /// `CoreError.coreNotRegistered` for an unknown identifier.
    public func makeCore(_ id: CoreIdentifier) throws -> any NetworkCore {
        lock.lock()
        let entry = entries[id]
        lock.unlock()
        guard let found = entry else {
            throw CoreError.coreNotRegistered(id)
        }
        // The factory runs outside the lock: it may be slow or re-entrant.
        return found.factory()
    }

    /// Chooses among the registered cores.
    public func select(required: CoreCapabilities, using selector: CoreSelector = CoreSelector()) -> CoreSelection {
        selector.select(from: descriptors, required: required)
    }
}
