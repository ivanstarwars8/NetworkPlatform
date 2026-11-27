// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// The bundled fonts (Resources/Fonts, SIL OFL 1.1) are registered for the process on first use, from the
// package's resource bundle; no Info.plist entry is needed. When a font cannot be registered, the text uses
// the system font of the same text style, so a missing file never leaves text invisible.

#if canImport(SwiftUI)
import CoreText
import Foundation
import SwiftUI

public enum BykFonts {
    /// Families registered successfully (computed once, thread-safe through `static let`).
    public static let available: Set<FontFamily> = {
        var families = Set<FontFamily>()
        for family in FontFamily.allCases where register(family) {
            families.insert(family)
        }
        return families
    }()

    private static func register(_ family: FontFamily) -> Bool {
        guard let url = Bundle.module.url(forResource: family.resourceName, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: family.resourceName, withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }
        // Already registered (a second bundle copy, a previous call) still means usable.
        if let cfError = error?.takeRetainedValue(),
           CFErrorGetCode(cfError) == CFIndex(CTFontManagerError.alreadyRegistered.rawValue) {
            return true
        }
        return false
    }

    /// The licence text of a bundled font (shown in Settings → About).
    public static func licence(of family: FontFamily) -> String? {
        let url = Bundle.module.url(forResource: family.licenceResourceName, withExtension: "txt", subdirectory: "Fonts")
            ?? Bundle.module.url(forResource: family.licenceResourceName, withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

extension RelativeTextStyle {
    var textStyle: Font.TextStyle {
        switch self {
        case .caption: return .caption
        case .footnote: return .footnote
        case .body: return .body
        case .title2: return .title2
        case .largeTitle: return .largeTitle
        }
    }
}

public extension Font {
    /// A font of the type scale. Scales with Dynamic Type relative to the step's text style.
    static func byk(_ step: TypeStep, family: FontFamily = .text, weight: Font.Weight = .regular) -> Font {
        let size = CGFloat(step.pointSize)
        if BykFonts.available.contains(family) {
            return Font.custom(family.familyName, size: size, relativeTo: step.relativeStyle.textStyle).weight(weight)
        }
        if step == .hero {
            return Font.system(size: size, weight: weight)
        }
        return Font.system(step.relativeStyle.textStyle).weight(weight)
    }

    /// Monospaced system font, only for real technical values (addresses, ports, hashes, identifiers).
    static func bykTechnical(_ step: TypeStep = .footnote) -> Font {
        Font.system(step.relativeStyle.textStyle, design: .monospaced)
    }

    static var bykBody: Font { .byk(.body) }
    static var bykBodyEmphasis: Font { .byk(.body, weight: .semibold) }
    static var bykFootnote: Font { .byk(.footnote) }
    static var bykCaption: Font { .byk(.caption) }
    static var bykTitle: Font { .byk(.title, weight: .semibold) }
}
#endif
