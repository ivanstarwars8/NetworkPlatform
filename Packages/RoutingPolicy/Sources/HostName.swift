import Foundation

/// Host names as the engines compare them: lower-case ASCII, labels of letters, digits, `-` and `_`,
/// internationalised labels in punycode (`пример.рф` → `xn--e1afmkfd.xn--p1ai`).
///
/// The conversion lower-cases and punycode-encodes each label (RFC 3492). It does not apply the full IDNA
/// mapping tables (no NFKC, no width folding): names typed in ordinary Cyrillic or Latin come out as the
/// browser sends them; exotic compatibility characters may not.
public enum HostName {
    public static let maximumLength = 253
    public static let maximumLabelLength = 63

    /// The ASCII form of a host name, or `nil` when it is not a valid name. One trailing dot is dropped.
    public static func ascii(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.unicodeScalars.count <= maximumLength * 4 else { return nil }
        // Ideographic and fullwidth full stops separate labels too (UTS #46).
        let separators: Set<Unicode.Scalar> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]
        var labels: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if separators.contains(scalar) {
                labels.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        labels.append(String(current))
        var encoded: [String] = []
        for label in labels {
            guard let ascii = asciiLabel(label) else { return nil }
            encoded.append(ascii)
        }
        let name = encoded.joined(separator: ".")
        guard name.utf8.count <= maximumLength else { return nil }
        return name
    }

    /// `true` for an ASCII host name label: 1–63 of `a-z 0-9 - _`, not starting or ending with `-`.
    static func isValidASCIILabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLabelLength else { return false }
        guard bytes.first != 0x2D, bytes.last != 0x2D else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }
    }

    private static func asciiLabel(_ label: String) -> String? {
        if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return isValidASCIILabel(label) ? label : nil
        }
        // Only letters, marks and digits are encoded; anything else (spaces, symbols) is not a host name.
        for scalar in label.unicodeScalars where !scalar.isASCII {
            let properties = scalar.properties
            guard properties.isAlphabetic || properties.generalCategory == .decimalNumber
                || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark else { return nil }
        }
        for scalar in label.unicodeScalars where scalar.isASCII {
            let byte = UInt8(scalar.value)
            guard (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D else { return nil }
        }
        guard let encoded = Punycode.encode(label) else { return nil }
        let result = "xn--" + encoded
        return isValidASCIILabel(result) ? result : nil
    }
}

/// RFC 3492 encoder (bootstring with the punycode parameters).
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 0x80

    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in scalars {
                if c < n {
                    delta += 1
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ value: Int) -> Character {
        value < 26 ? Character(Unicode.Scalar(UInt8(97 + value))) : Character(Unicode.Scalar(UInt8(22 + value)))
    }

    private static func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
