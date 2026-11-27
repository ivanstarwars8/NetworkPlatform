// Colour tokens of «Бык»: forged bronze and slate (Documentation/Design/DESIGN.md §2).
// Platform-neutral values; the SwiftUI colours are built from them in SwiftUI/Color+Palette.swift.

import Foundation

/// An opaque sRGB colour, 8 bits per channel.
public struct RGB: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32) {
        self.init(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    /// `#RRGGBB`, upper case.
    public var description: String {
        let digits = Array("0123456789ABCDEF")
        var text = "#"
        for channel in [red, green, blue] {
            text.append(digits[Int(channel >> 4)])
            text.append(digits[Int(channel & 0x0F)])
        }
        return text
    }

    /// WCAG 2.x relative luminance (0 black … 1 white).
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio between two colours (1 … 21).
    public func contrast(with other: RGB) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Light or dark appearance.
public enum Appearance: CaseIterable, Sendable {
    case light
    case dark
}

/// What a colour is for. Views ask for a role, never for a literal colour.
public enum ColorRole: String, CaseIterable, Sendable {
    /// Window and grouped-list background (slate).
    case background
    /// Rows, grouped sections, sheets.
    case surface
    /// Primary text and glyphs.
    case ink
    /// Secondary text, captions, the unfilled horn.
    case secondaryInk
    /// Bronze: the tunnel is working, the main action. Graphics only (the horn fill, the active glyph).
    case accent
    /// Bronze for text and for fills that carry text (the primary button); darker in light mode so that
    /// text keeps WCAG AA contrast (DESIGN.md §2).
    case accentText
    /// Text and glyphs on an `accentText` fill.
    case onAccent
    /// Something failed; the user has to act.
    case alert
    /// Healthy, verified.
    case good
    /// Hairlines between rows.
    case separator
}

public enum Palette {
    public static func color(_ role: ColorRole, _ appearance: Appearance) -> RGB {
        switch (role, appearance) {
        case (.background, .light): return RGB(hex: 0xEEF1F3)
        case (.background, .dark): return RGB(hex: 0x15191D)
        case (.surface, .light): return RGB(hex: 0xFFFFFF)
        case (.surface, .dark): return RGB(hex: 0x1E2429)
        case (.ink, .light): return RGB(hex: 0x1B2228)
        case (.ink, .dark): return RGB(hex: 0xE6EAED)
        case (.secondaryInk, .light): return RGB(hex: 0x5B6670)
        case (.secondaryInk, .dark): return RGB(hex: 0x93A0AA)
        case (.accent, .light): return RGB(hex: 0xA2772A)
        case (.accent, .dark): return RGB(hex: 0xC99A45)
        case (.accentText, .light): return RGB(hex: 0x8F6620)
        case (.accentText, .dark): return RGB(hex: 0xC99A45)
        case (.onAccent, .light): return RGB(hex: 0xFFFFFF)
        case (.onAccent, .dark): return RGB(hex: 0x15191D)
        case (.alert, .light): return RGB(hex: 0xB3412E)
        case (.alert, .dark): return RGB(hex: 0xE06A55)
        case (.good, .light): return RGB(hex: 0x2E7D5B)
        case (.good, .dark): return RGB(hex: 0x4FB487)
        case (.separator, .light): return RGB(hex: 0xD5DBE0)
        case (.separator, .dark): return RGB(hex: 0x2C343B)
        }
    }
}
