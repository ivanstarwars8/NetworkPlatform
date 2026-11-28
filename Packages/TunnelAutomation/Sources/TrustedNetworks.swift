// Validation of trusted Wi-Fi network names (SSIDs) entered by the user. The app cannot read the name of the
// current network without the Access Wi-Fi Information entitlement and location permission, which this app does
// not request; names are typed in. Matching is done by the system (NEOnDemandRule.ssidMatch), byte for byte.

import Foundation

public enum TrustedNetworks {
    /// IEEE 802.11 limit on an SSID.
    public static let maximumNameBytes = 32
    /// A limit on the list so the rule stays small.
    public static let maximumCount = 50

    public enum Rejection: Error, Equatable, Sendable {
        case empty
        case tooLong
        case controlCharacters
        case duplicate
        case listFull

        /// What happened and what to do, for the UI.
        public var message: String {
            switch self {
            case .empty: return "Введите имя сети."
            case .tooLong: return "Имя сети длиннее 32 байт — такой сети не бывает. Проверьте имя."
            case .controlCharacters: return "В имени сети есть перевод строки или служебный символ. Уберите его."
            case .duplicate: return "Эта сеть уже в списке."
            case .listFull: return "В списке уже \(TrustedNetworks.maximumCount) сетей. Удалите ненужные."
            }
        }
    }

    /// Adds `name` to `list`. Leading and trailing whitespace is removed (inner spaces are part of the name);
    /// letter case is kept, because the system compares names exactly.
    public static func adding(_ name: String, to list: [String]) -> Result<[String], Rejection> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let rejection = check(trimmed) { return .failure(rejection) }
        if list.contains(trimmed) { return .failure(.duplicate) }
        if list.count >= maximumCount { return .failure(.listFull) }
        return .success(list + [trimmed])
    }

    /// Why `name` cannot be an SSID, or nil.
    public static func check(_ name: String) -> Rejection? {
        if name.isEmpty { return .empty }
        if name.utf8.count > maximumNameBytes { return .tooLong }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            return .controlCharacters
        }
        return nil
    }

    /// Valid, unique names in their original order, at most `maximumCount` (for records read from storage).
    public static func sanitized(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names where check(name) == nil && !result.contains(name) {
            result.append(name)
            if result.count == maximumCount { break }
        }
        return result
    }
}
