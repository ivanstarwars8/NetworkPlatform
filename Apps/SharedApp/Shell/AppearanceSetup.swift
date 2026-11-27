// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// System bars drawn by UIKit (navigation titles, tab labels) take the text face too, scaled with Dynamic Type.
// SwiftUI has no font modifier for them. When the bundled font is missing the system font stays.

import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppearanceSetup {
    @MainActor static func apply() {
        #if os(iOS)
        guard BykFonts.available.contains(.text) else { return }
        func font(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont? {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: FontFamily.text.familyName,
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
            let base = UIFont(descriptor: descriptor, size: size)
            // A descriptor that matched nothing falls back to another family; keep the system font then.
            guard base.familyName == FontFamily.text.familyName else { return nil }
            return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        }
        let ink = UIColor { traits in
            let rgb = Palette.color(.ink, traits.userInterfaceStyle == .dark ? .dark : .light)
            return UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
        let navigation = UINavigationBar.appearance()
        if let large = font(34, .semibold, .largeTitle) {
            navigation.largeTitleTextAttributes = [.font: large, .foregroundColor: ink]
        }
        if let inline = font(17, .semibold, .headline) {
            navigation.titleTextAttributes = [.font: inline, .foregroundColor: ink]
        }
        if let tab = font(10, .medium, .caption2) {
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
        }
        #endif
    }
}
