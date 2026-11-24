import Foundation
import DomainModels

/// Result of decoding a subscription body. Every line is accounted for:
/// it is an entry, a failure, a counted comment, or counted as truncated.
public struct SubscriptionImport: Hashable, Sendable {
    public enum Encoding: String, Codable, Hashable, Sendable {
        /// The body was a plain list of links.
        case plain
        /// The body was base64 (standard or URL-safe, padded or not) of such a list.
        case base64
    }

    public struct Entry: Hashable, Sendable {
        /// 1-based line number in the decoded text.
        public var lineNumber: Int
        public var outbound: Outbound
        public var report: ImportReport

        public init(lineNumber: Int, outbound: Outbound, report: ImportReport) {
            self.lineNumber = lineNumber
            self.outbound = outbound
            self.report = report
        }
    }

    /// A line that could not be imported. The line itself is not stored: it may contain credentials.
    public struct Failure: Hashable, Sendable {
        public var lineNumber: Int
        /// Scheme of the line when it has one.
        public var scheme: String?
        public var error: ImportError

        public init(lineNumber: Int, scheme: String?, error: ImportError) {
            self.lineNumber = lineNumber
            self.scheme = scheme
            self.error = error
        }
    }

    public var encoding: Encoding
    public var entries: [Entry]
    public var failures: [Failure]
    /// Lines starting with `#` or `//`.
    public var commentLineCount: Int
    /// Non-blank lines not processed because of `ImportLimits.maximumSubscriptionLines`.
    public var truncatedLineCount: Int
    public var warnings: [ConversionWarning]

    public init(
        encoding: Encoding,
        entries: [Entry] = [],
        failures: [Failure] = [],
        commentLineCount: Int = 0,
        truncatedLineCount: Int = 0,
        warnings: [ConversionWarning] = []
    ) {
        self.encoding = encoding
        self.entries = entries
        self.failures = failures
        self.commentLineCount = commentLineCount
        self.truncatedLineCount = truncatedLineCount
        self.warnings = warnings
    }

    public var outbounds: [Outbound] {
        return entries.map { $0.outbound }
    }
}

/// Decodes a subscription body: a list of share links, one per line, either plain
/// or base64-encoded as a whole. Tolerates a UTF-8 BOM, CRLF and CR line endings,
/// blank lines and comment lines.
public struct SubscriptionDecoder: Sendable {
    public var limits: ImportLimits

    public init(limits: ImportLimits = .standard) {
        self.limits = limits
    }

    public func decode(_ data: Data) throws -> SubscriptionImport {
        guard data.count <= limits.maximumSubscriptionBytes else {
            throw ImportError.inputTooLarge(limit: limits.maximumSubscriptionBytes, actual: data.count)
        }
        guard let text = SubscriptionDecoder.text(fromUTF8: Array(data)) else {
            throw ImportError.invalidUTF8
        }
        return try decodeBody(text)
    }

    public func decode(text: String) throws -> SubscriptionImport {
        let size = text.utf8.count
        guard size <= limits.maximumSubscriptionBytes else {
            throw ImportError.inputTooLarge(limit: limits.maximumSubscriptionBytes, actual: size)
        }
        guard let stripped = SubscriptionDecoder.text(fromUTF8: Array(text.utf8)) else {
            throw ImportError.invalidUTF8
        }
        return try decodeBody(stripped)
    }

    // MARK: - Internals

    /// Strict UTF-8 decoding with a leading byte order mark removed.
    private static func text(fromUTF8 bytes: [UInt8]) -> String? {
        var payload = bytes[...]
        if payload.count >= 3,
           payload[payload.startIndex] == 0xEF,
           payload[payload.startIndex + 1] == 0xBB,
           payload[payload.startIndex + 2] == 0xBF {
            payload = payload.dropFirst(3)
        }
        return String(bytes: Array(payload), encoding: .utf8)
    }

    private static func splitLines(_ text: String) -> [String] {
        return text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { String($0) }
    }

    private static func containsLink(_ lines: [String]) -> Bool {
        for line in lines {
            if ParsedURI.splitScheme(Text.trimmed(line)) != nil {
                return true
            }
        }
        return false
    }

    private func decodeBody(_ text: String) throws -> SubscriptionImport {
        let body = Text.trimmed(text)
        guard !body.isEmpty else {
            throw ImportError.emptyInput
        }

        var lines = SubscriptionDecoder.splitLines(body)
        var encoding = SubscriptionImport.Encoding.plain
        if !SubscriptionDecoder.containsLink(lines) {
            // Not a list of links as written: the whole body must then be base64 of one.
            guard let data = LenientBase64.decode(body),
                  let decoded = SubscriptionDecoder.text(fromUTF8: Array(data)) else {
                throw ImportError.notASubscription
            }
            lines = SubscriptionDecoder.splitLines(decoded)
            guard SubscriptionDecoder.containsLink(lines) else {
                throw ImportError.notASubscription
            }
            encoding = .base64
        }

        var result = SubscriptionImport(encoding: encoding)
        let importer = ShareLinkImporter(limits: limits)
        var processed = 0
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = Text.trimmed(rawLine)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("//") {
                result.commentLineCount += 1
                continue
            }
            if processed >= limits.maximumSubscriptionLines {
                result.truncatedLineCount += 1
                continue
            }
            processed += 1
            do {
                let imported = try importer.importLink(line)
                result.entries.append(SubscriptionImport.Entry(
                    lineNumber: lineNumber, outbound: imported.outbound, report: imported.report
                ))
            } catch let error as ImportError {
                result.failures.append(SubscriptionImport.Failure(
                    lineNumber: lineNumber, scheme: ParsedURI.splitScheme(line)?.scheme, error: error
                ))
            } catch {
                result.failures.append(SubscriptionImport.Failure(
                    lineNumber: lineNumber, scheme: ParsedURI.splitScheme(line)?.scheme,
                    error: .malformedLink(reason: "unexpected error")
                ))
            }
        }

        if result.truncatedLineCount > 0 {
            result.warnings.append(ConversionWarning(
                code: .truncated,
                message: "\(result.truncatedLineCount) lines beyond the limit of "
                    + "\(limits.maximumSubscriptionLines) were not processed"
            ))
        }
        SubscriptionDecoder.makeTagsUnique(&result)
        return result
    }

    /// Groups refer to outbounds by tag, so tags must be unique within one subscription.
    /// The display name is left as the provider wrote it.
    private static func makeTagsUnique(_ result: inout SubscriptionImport) {
        var used = Set<String>()
        var renamed = 0
        for index in result.entries.indices {
            let original = result.entries[index].outbound.tag
            var candidate = original
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(original) (\(suffix))"
                suffix += 1
            }
            if candidate != original {
                result.entries[index].outbound.tag = candidate
                renamed += 1
            }
            used.insert(candidate)
        }
        if renamed > 0 {
            result.warnings.append(ConversionWarning(
                code: .suspiciousValue,
                message: "\(renamed) entries share a name with an earlier entry; their tags were made unique"
            ))
        }
    }
}
