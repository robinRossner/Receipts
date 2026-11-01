import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Ports dashboard.html's CSS custom properties. Fonts are substituted with close system
/// equivalents (Special Elite / IBM Plex aren't installed on macOS by default, and bundling
/// Google Fonts would add a network dependency to what's meant to be a self-contained app).
///
/// Paper on a desk, three inks (ink, pen red for "look at this", stamp green for "done"). Every colour is an adaptive
/// light and dark pair, on both platforms, and the values are the same as the iPhone's `Theme`.
enum AppTheme {
    static let paper = Color.themed(light: 0xFAF7EE, dark: 0x2A2723)
    static let desk = Color.themed(light: 0xE6E1D2, dark: 0x171512)
    static let ink = Color.themed(light: 0x2B2823, dark: 0xF1ECE1)
    static let inkSoft = Color.themed(light: 0x665F53, dark: 0xB0A998)
    /// Small text directly on the desk.
    static let label = Color.themed(light: 0x575146, dark: 0xA8A18F)
    static let penRed = Color.themed(light: 0xB33A3A, dark: 0xEC8A83)
    static let penRedBg = Color.themed(light: 0xFBEAE8, dark: 0x3D2422)
    /// Text on a `penRed` fill (a badge).
    static let onRed = Color.themed(light: 0xFFFFFF, dark: 0x2A1412)
    /// The error bar, white text in both modes.
    static let errorBar = Color.themed(light: 0xB33A3A, dark: 0x9E3532)
    /// The `Looks good` fill, with `onGreen` text.
    static let stampGreen = Color.themed(light: 0x3A6B4B, dark: 0x4F8F67)
    static let onGreen = Color.themed(light: 0xFFFFFF, dark: 0x0E1A13)
    /// Green text on paper, and the `Reviewed` status behind it.
    static let greenText = Color.themed(light: 0x2F6341, dark: 0x86C79E)
    static let greenBg = Color.themed(light: 0xE6F0E6, dark: 0x20302A)
    static let rule = Color.themed(light: 0xCFC8B3, dark: 0x48433C)
    /// Raised cards on the desk (the purchase drill-down) and text fields.
    static let card = Color.themed(light: 0xFFFFFF, dark: 0x1F1C19)
    /// A row that stands out from the paper: the selected receipt, a drop target, a nested tree row.
    static let raised = Color.themed(light: 0xFFFDF6, dark: 0x35312C)
    /// Text on an `ink` coloured fill (a filled button).
    static let onInk = Color.themed(light: 0xFFFFFF, dark: 0x171512)

    /// Chart series: muted on paper, lifted on dark paper. No red: that colour means "look at this".
    static let chartPalette: [Color] = [
        .themed(light: 0x3F6B4F, dark: 0x68AD82), .themed(light: 0xC28B2C, dark: 0xE0AE55),
        .themed(light: 0x3F6A8A, dark: 0x7DAFD1), .themed(light: 0x7A4E7E, dark: 0xB88CBC),
        .themed(light: 0x9C6B4A, dark: 0xCC9F7E),
    ]
    static let chartOther = Color.themed(light: 0x9A9484, dark: 0x8C8676)

    /// Special Elite substitute - a typewriter-style serif for store names / headings.
    static func display(_ size: CGFloat) -> Font {
        .custom("American Typewriter", size: size)
    }
    /// IBM Plex Mono substitute - for money amounts, dates, quantities.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// IBM Plex Sans substitute - regular body text.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    /// `light` in light mode, `dark` in dark mode (follows the system appearance on both platforms).
    static func themed(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #endif
    }
}
