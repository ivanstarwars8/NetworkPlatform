import ConfigurationEngine
import DomainModels
import Foundation

/// One line the user should see after an import or a compilation. Texts never contain credentials: they come
/// from `ImportReport`/`ConversionReport` (whose messages are written without input values) or are built here
/// from names and codes only.
public struct ProfileNotice: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        case info
        case warning
        case error
    }

    public var severity: Severity
    public var text: String

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }
}

/// What the user pasted, as far as it can be told without the network.
public enum ImportInput: Equatable {
    /// One share link (`vless://`, `ss://`, …).
    case shareLink(String)
    /// An `http(s)://` address of a subscription; the caller downloads the body.
    case subscriptionURL(URL)
    /// A subscription body: share links one per line, or base64 of them.
    case subscriptionBody(String)

    /// Classifies pasted text. A single line with a supported link scheme is a share link, a single
    /// `http`/`https` URL is a subscription address, anything else is treated as a subscription body (the
    /// decoder reports what it cannot use).
    public static func classify(_ text: String) throws -> ImportInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyInput }
        let singleLine = !trimmed.contains(where: { $0.isNewline })
        if singleLine, let colon = trimmed.firstIndex(of: ":") {
            let scheme = trimmed[..<colon].lowercased()
            if scheme == "http" || scheme == "https" {
                guard let url = URL(string: trimmed), url.host != nil else {
                    throw ImportError.malformedLink(reason: "not a valid subscription address")
                }
                return .subscriptionURL(url)
            }
            if ShareLinkImporter.isSupportedScheme(scheme) {
                return .shareLink(trimmed)
            }
        }
        return .subscriptionBody(trimmed)
    }
}

/// The result of an import: a profile ready to be stored (secrets still inline) and what the user should know.
public struct ProfileImportResult: Sendable {
    public var profile: Profile
    public var notices: [ProfileNotice]

    public init(profile: Profile, notices: [ProfileNotice]) {
        self.profile = profile
        self.notices = notices
    }
}

/// An import that produced no profile, with everything that was learnt on the way (for example why each
/// subscription line was skipped).
public struct ProfileImportFailure: Error, Sendable {
    public var notices: [ProfileNotice]

    public init(notices: [ProfileNotice]) {
        self.notices = notices
    }
}

/// Turns pasted share links and subscription bodies into profiles through the importers of
/// ConfigurationEngine. Pure: no I/O, no global state.
public struct ProfileImporter: Sendable {
    public var limits: ImportLimits

    public init(limits: ImportLimits = .standard) {
        self.limits = limits
    }

    /// One share link → a profile with one outbound, selected.
    public func importShareLink(_ link: String) throws -> ProfileImportResult {
        let imported = try ShareLinkImporter(limits: limits).importLink(link)
        var outbound = imported.outbound
        if outbound.tag.isEmpty { outbound.tag = "server-1" }
        let name = outbound.name.isEmpty ? imported.report.scheme : outbound.name
        let profile = Profile(name: name, source: .shareLink, outbounds: [outbound], selectedTag: outbound.tag)
        return ProfileImportResult(profile: profile, notices: ProfileImporter.notices(of: imported.report, prefix: nil))
    }

    /// A subscription body → a profile with every importable link, the first one selected. Lines that could
    /// not be imported are reported, not dropped silently. `sourceURL` names the subscription; it is stored
    /// in the profile as its source and never shown in notices.
    public func importSubscription(text: String, sourceURL: URL?, name: String? = nil) throws -> ProfileImportResult {
        let decoded = try SubscriptionDecoder(limits: limits).decode(text: text)
        var notices: [ProfileNotice] = []
        if decoded.encoding != .plain {
            notices.append(ProfileNotice(.info, "Subscription body was \(decoded.encoding.rawValue)-encoded"))
        }
        for warning in decoded.warnings {
            notices.append(ProfileNotice(.warning, "\(warning.code.rawValue): \(warning.message)"))
        }
        for failure in decoded.failures {
            let scheme = failure.scheme.map { "\($0) link" } ?? "line"
            notices.append(ProfileNotice(
                .error, "Line \(failure.lineNumber) (\(scheme)) skipped: \(ProfileImporter.describe(failure.error))"
            ))
        }
        if decoded.truncatedLineCount > 0 {
            notices.append(ProfileNotice(.warning, "\(decoded.truncatedLineCount) line(s) beyond the import limit were not read"))
        }

        var outbounds: [Outbound] = []
        var used = Set<String>()
        for entry in decoded.entries {
            var outbound = entry.outbound
            outbound.tag = ProfileImporter.uniqueTag(outbound.tag, index: outbounds.count, used: &used)
            outbounds.append(outbound)
            notices.append(contentsOf: ProfileImporter.notices(of: entry.report, prefix: "Line \(entry.lineNumber)"))
        }
        guard !outbounds.isEmpty else {
            notices.append(ProfileNotice(.error, ProfileImporter.describe(ImportError.notASubscription)))
            throw ProfileImportFailure(notices: notices)
        }
        let title = name ?? sourceURL?.host ?? "Subscription"
        let source: ProfileSource = sourceURL.map { .subscription(url: $0.absoluteString) } ?? .manual
        let profile = Profile(name: title, source: source, outbounds: outbounds, selectedTag: outbounds[0].tag)
        notices.insert(ProfileNotice(.info, "Imported \(outbounds.count) server(s)"), at: 0)
        return ProfileImportResult(profile: profile, notices: notices)
    }

    /// Imports any classified input that needs no network: a link or a body. A subscription URL must be
    /// downloaded by the caller and passed to `importSubscription(text:sourceURL:)`.
    public func importOffline(_ input: ImportInput) throws -> ProfileImportResult {
        switch input {
        case let .shareLink(link):
            return try importShareLink(link)
        case let .subscriptionBody(body):
            return try importSubscription(text: body, sourceURL: nil)
        case .subscriptionURL:
            throw ImportError.malformedLink(reason: "a subscription address must be downloaded first")
        }
    }

    // MARK: - Helpers

    /// Tags are the key of an outbound inside a profile; subscriptions often repeat names.
    static func uniqueTag(_ proposed: String, index: Int, used: inout Set<String>) -> String {
        let base = proposed.isEmpty ? "server-\(index + 1)" : proposed
        var candidate = base
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base) (\(counter))"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    /// Warnings and parameters that did not become model fields. Parameter values are never shown: only
    /// their names, which come from the link's structure.
    static func notices(of report: ImportReport, prefix: String?) -> [ProfileNotice] {
        let lead = prefix.map { "\($0): " } ?? ""
        var result: [ProfileNotice] = report.warnings.map {
            ProfileNotice(.warning, "\(lead)\($0.code.rawValue): \($0.message)")
        }
        for parameter in report.unsupported {
            let kept = parameter.disposition == .preservedInEngineExtras ? "kept for the engine" : "not applied"
            result.append(ProfileNotice(
                .warning, "\(lead)parameter '\(parameter.name)' \(kept) (\(parameter.reason.rawValue))"
            ))
        }
        return result
    }

    /// A message for an import error. `ImportError` cases carry names and reasons, never input values.
    public static func describe(_ error: Error) -> String {
        if let failure = error as? ProfileImportFailure {
            return failure.notices.last(where: { $0.severity == .error })?.text ?? "import failed"
        }
        guard let error = error as? ImportError else {
            return "import failed (\(type(of: error)))"
        }
        switch error {
        case .emptyInput: return "nothing to import"
        case let .inputTooLarge(limit, actual): return "input is \(actual) bytes, the limit is \(limit)"
        case .invalidUTF8: return "input is not UTF-8 text"
        case let .unsupportedScheme(scheme): return "unsupported link type '\(scheme)'"
        case let .malformedLink(reason): return "malformed link: \(reason)"
        case let .missingField(field): return "missing \(field)"
        case let .invalidField(name, reason): return "invalid \(name): \(reason)"
        case let .unsupportedValue(parameter, _): return "unsupported value of '\(parameter)'"
        case let .invalidBase64(context): return "invalid base64 in \(context)"
        case let .invalidJSON(context): return "invalid JSON in \(context)"
        case let .tooManyParameters(limit): return "more than \(limit) parameters"
        case .notASubscription: return "no importable share links found"
        }
    }
}
