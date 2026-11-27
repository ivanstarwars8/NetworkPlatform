import XCTest
@testable import DesignSystem

final class PaletteTests: XCTestCase {
    func testSpecifiedValues() {
        XCTAssertEqual(Palette.color(.background, .light).description, "#EEF1F3")
        XCTAssertEqual(Palette.color(.background, .dark).description, "#15191D")
        XCTAssertEqual(Palette.color(.surface, .light).description, "#FFFFFF")
        XCTAssertEqual(Palette.color(.surface, .dark).description, "#1E2429")
        XCTAssertEqual(Palette.color(.ink, .light).description, "#1B2228")
        XCTAssertEqual(Palette.color(.ink, .dark).description, "#E6EAED")
        XCTAssertEqual(Palette.color(.secondaryInk, .light).description, "#5B6670")
        XCTAssertEqual(Palette.color(.secondaryInk, .dark).description, "#93A0AA")
        XCTAssertEqual(Palette.color(.accent, .light).description, "#A2772A")
        XCTAssertEqual(Palette.color(.accent, .dark).description, "#C99A45")
        XCTAssertEqual(Palette.color(.alert, .light).description, "#B3412E")
        XCTAssertEqual(Palette.color(.alert, .dark).description, "#E06A55")
        XCTAssertEqual(Palette.color(.good, .light).description, "#2E7D5B")
        XCTAssertEqual(Palette.color(.good, .dark).description, "#4FB487")
    }

    func testLuminanceEndpoints() {
        XCTAssertEqual(RGB(hex: 0x000000).relativeLuminance, 0, accuracy: 1e-9)
        XCTAssertEqual(RGB(hex: 0xFFFFFF).relativeLuminance, 1, accuracy: 1e-9)
        XCTAssertEqual(RGB(hex: 0x000000).contrast(with: RGB(hex: 0xFFFFFF)), 21, accuracy: 1e-6)
    }

    /// WCAG AA: text 4.5:1, graphics and large text 3:1. Checked in both appearances.
    func testContrast() {
        for appearance in Appearance.allCases {
            let c = { (role: ColorRole) in Palette.color(role, appearance) }
            for ground in [ColorRole.background, .surface] {
                XCTAssertGreaterThanOrEqual(c(.ink).contrast(with: c(ground)), 7, "ink on \(ground), \(appearance)")
                XCTAssertGreaterThanOrEqual(c(.secondaryInk).contrast(with: c(ground)), 4.5, "secondary on \(ground), \(appearance)")
                XCTAssertGreaterThanOrEqual(c(.accentText).contrast(with: c(ground)), 4.5, "accent text on \(ground), \(appearance)")
                XCTAssertGreaterThanOrEqual(c(.accent).contrast(with: c(ground)), 3, "horn fill on \(ground), \(appearance)")
            }
            XCTAssertGreaterThanOrEqual(c(.alert).contrast(with: c(.surface)), 4.5, "alert, \(appearance)")
            XCTAssertGreaterThanOrEqual(c(.good).contrast(with: c(.surface)), 4.5, "good, \(appearance)")
            XCTAssertGreaterThanOrEqual(c(.onAccent).contrast(with: c(.accentText)), 4.5, "primary button label, \(appearance)")
        }
    }

    func testEveryRoleDiffersBetweenAppearances() {
        for role in ColorRole.allCases {
            XCTAssertNotEqual(Palette.color(role, .light), Palette.color(role, .dark), "\(role)")
        }
    }
}

final class TypographyTests: XCTestCase {
    func testScale() {
        XCTAssertEqual(TypeStep.allCases.map(\.pointSize), [12, 14, 17, 22, 34, 56])
    }

    func testFamilies() {
        XCTAssertEqual(FontFamily.display.familyName, "Unbounded")
        XCTAssertEqual(FontFamily.text.familyName, "Golos Text")
    }

    /// The fonts and their licences are shipped in the package resources.
    func testBundledFontFilesExist() throws {
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignSystem/Resources/Fonts")
        for family in FontFamily.allCases {
            let font = fonts.appendingPathComponent(family.resourceName + ".ttf")
            let data = try Data(contentsOf: font)
            // TrueType outlines: sfnt version 0x00010000.
            XCTAssertEqual(Array(data.prefix(4)), [0, 1, 0, 0], family.resourceName)
            let licence = try String(contentsOf: fonts.appendingPathComponent(family.licenceResourceName + ".txt"), encoding: .utf8)
            XCTAssertTrue(licence.contains("SIL Open Font License, Version 1.1"), family.licenceResourceName)
        }
    }

    func testSpacingGrid() {
        XCTAssertEqual(Spacing.scale, Spacing.scale.sorted())
        for step in Spacing.scale {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 4), 0, "\(step)")
        }
    }
}
