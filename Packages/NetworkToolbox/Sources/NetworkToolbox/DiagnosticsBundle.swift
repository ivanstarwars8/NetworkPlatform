// The diagnostics bundle the user can export from the analyser: plain text, built only from engine-neutral
// facts (states, counters, error texts) and passed through `DiagnosticsRedactor`, which removes anything
// shaped like a key, password, UUID, address or host name. Connection destinations and toolbox results are
// never included.

import Foundation

public struct DiagnosticsRedactor: Sendable {
    public static let placeholder = "[скрыто]"

    public init() {}

    private struct Rule {
        let expression: NSRegularExpression
        /// Extra condition on a match; `nil` replaces every match.
        let accept: ((Substring) -> Bool)?
    }

    private static let rules: [Rule] = {
        func rule(_ pattern: String, _ accept: ((Substring) -> Bool)? = nil) -> Rule? {
            (try? NSRegularExpression(pattern: pattern)).map { Rule(expression: $0, accept: accept) }
        }
        let list: [Rule?] = [
            // URLs with any scheme (credentials, hosts, paths).
            rule(#"[a-zA-Z][a-zA-Z0-9+.-]{1,15}://\S+"#),
            // E-mail addresses.
            rule(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            // key=value / key: value pairs whose key names a secret or an address.
            rule(#"(?i)\b(?:password|passwd|pass|secret|token|key|uuid|sni|host|server|address)\s*[=:]\s*\S+"#),
            // UUIDs.
            rule(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#),
            // IPv6 literals, optionally bracketed with a port. Clock times ("22:51:09") have the same shape,
            // so a match must contain "::", a hex letter, or at least three colons.
            rule(#"\[?(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}\]?(?::\d{1,5})?"#) { match in
                match.contains("::") || match.contains(where: { "abcdefABCDEF".contains($0) })
                    || match.filter({ $0 == ":" }).count >= 3
            },
            // IPv4 literals with an optional port.
            rule(#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#),
            // Host names: dot-separated labels ending in an alphabetic label (Latin, Cyrillic, or "xn--").
            rule(#"\b(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+(?:xn--[a-z0-9-]{2,59}|\p{L}{2,63})\b(?::\d{1,5})?"#),
            // Key-like runs: 16+ base64/hex characters that contain a digit.
            rule(#"(?=[A-Za-z0-9+/_=-]*\d)[A-Za-z0-9+/_=-]{16,}"#),
        ]
        return list.compactMap { $0 }
    }()

    public func redact(_ text: String) -> String {
        var result = text
        for rule in DiagnosticsRedactor.rules {
            let matches = rule.expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                if let accept = rule.accept, !accept(result[range]) { continue }
                result.replaceSubrange(range, with: DiagnosticsRedactor.placeholder)
            }
        }
        return result
    }
}

public struct DiagnosticsBundle: Sendable {
    public struct Section: Sendable {
        public let title: String
        public let lines: [(String, String)]

        public init(title: String, lines: [(String, String)]) {
            self.title = title
            self.lines = lines
        }
    }

    public let createdAt: Date
    public let sections: [Section]

    public init(createdAt: Date = Date(), sections: [Section]) {
        self.createdAt = createdAt
        self.sections = sections
    }

    /// Outbound tags can carry server names chosen by the user; they are replaced by stable neutral names
    /// in the bundle ("выход 1", "выход 2", … in sorted tag order).
    public static func neutralNames(for tags: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for (index, tag) in tags.sorted().enumerated() {
            map[tag] = "выход \(index + 1)"
        }
        return map
    }

    /// The text of the bundle. Values and titles go through the redactor; the generator line is fixed.
    public func text(redactor: DiagnosticsRedactor = DiagnosticsRedactor()) -> String {
        let formatter = ISO8601DateFormatter()
        var output = "Диагностика «Быка»\nСоздано: \(formatter.string(from: createdAt))\n"
        output += "Ключи, пароли, идентификаторы, адреса серверов и имена узлов удалены.\n"
        for section in sections {
            output += "\n## \(redactor.redact(section.title))\n"
            for (name, value) in section.lines {
                output += "\(redactor.redact(name)): \(redactor.redact(value))\n"
            }
        }
        return output
    }
}
