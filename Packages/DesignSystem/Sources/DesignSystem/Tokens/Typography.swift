// Type tokens (Documentation/Design/DESIGN.md §3). Two bundled families, both SIL OFL 1.1 with Cyrillic:
// Unbounded only for the connection state word and the big live numbers, Golos Text for everything else.
// Sizes are base sizes at the default Dynamic Type setting; the SwiftUI fonts scale them relative to a
// text style (SwiftUI/Fonts.swift), and fall back to the system font when a bundled font is missing.

/// A bundled font family.
public enum FontFamily: String, CaseIterable, Sendable {
    /// Display face: the state word under the horn and the live speed numbers. Nothing else.
    case display
    /// Text face: every other label, list, form and button.
    case text

    /// Family name the font registers under (CoreText / SwiftUI `Font.custom`).
    public var familyName: String {
        switch self {
        case .display: return "Unbounded"
        case .text: return "Golos Text"
        }
    }

    /// The font file in the package resources (Resources/Fonts), without the extension.
    public var resourceName: String {
        switch self {
        case .display: return "Unbounded"
        case .text: return "GolosText"
        }
    }

    /// The licence file shipped next to the font.
    public var licenceResourceName: String { resourceName + "-OFL" }
}

/// The type scale. Six steps; nothing in the app uses a size outside it.
public enum TypeStep: CaseIterable, Sendable {
    /// 12 — captions under values, footnotes of reports.
    case caption
    /// 14 — secondary lines of rows, section headers.
    case footnote
    /// 17 — body text, rows, buttons.
    case body
    /// 22 — screen titles inside content, live numbers on compact layouts.
    case title
    /// 34 — the state word under the horn.
    case display
    /// 56 — the state word on tvOS (seen from across a room).
    case hero

    public var pointSize: Double {
        switch self {
        case .caption: return 12
        case .footnote: return 14
        case .body: return 17
        case .title: return 22
        case .display: return 34
        case .hero: return 56
        }
    }

    /// The system text style the size scales with under Dynamic Type.
    public var relativeStyle: RelativeTextStyle {
        switch self {
        case .caption: return .caption
        case .footnote: return .footnote
        case .body: return .body
        case .title: return .title2
        case .display, .hero: return .largeTitle
        }
    }
}

/// Platform-neutral names of the system text styles used for relative sizing.
public enum RelativeTextStyle: Sendable {
    case caption, footnote, body, title2, largeTitle
}

/// Spacing scale on a 4-point grid.
public enum Spacing {
    public static let xxs: Double = 4
    public static let xs: Double = 8
    public static let s: Double = 12
    public static let m: Double = 16
    public static let l: Double = 24
    public static let xl: Double = 32
    public static let xxl: Double = 48

    /// All steps, smallest first (tests check the grid).
    public static let scale: [Double] = [xxs, xs, s, m, l, xl, xxl]
}

/// Corner radii. Grouped sections use the system's own; these are for the few custom containers.
public enum Radius {
    /// Inline message panels.
    public static let panel: Double = 12
    /// The primary button.
    public static let button: Double = 14
}
