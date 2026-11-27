// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// SwiftUI colours of the palette tokens. Each colour follows the light/dark appearance of the view it is
// drawn in (dynamic UIColor / NSColor), so no view switches colours by hand.

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension RGB {
    #if canImport(UIKit)
    var platformColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #elseif canImport(AppKit)
    var platformColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #endif
}

public extension Color {
    /// The colour of a role, resolved for the current appearance when drawn.
    static func byk(_ role: ColorRole) -> Color {
        let light = Palette.color(role, .light).platformColor
        let dark = Palette.color(role, .dark).platformColor
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #endif
    }
}

public extension ShapeStyle where Self == Color {
    static var bykBackground: Color { .byk(.background) }
    static var bykSurface: Color { .byk(.surface) }
    static var bykInk: Color { .byk(.ink) }
    static var bykSecondaryInk: Color { .byk(.secondaryInk) }
    static var bykAccent: Color { .byk(.accent) }
    static var bykAccentText: Color { .byk(.accentText) }
    static var bykOnAccent: Color { .byk(.onAccent) }
    static var bykAlert: Color { .byk(.alert) }
    static var bykGood: Color { .byk(.good) }
    static var bykSeparator: Color { .byk(.separator) }
}
#endif
