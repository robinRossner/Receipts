import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Ports dashboard.html's CSS custom properties. Fonts are substituted with close system
/// equivalents (Special Elite / IBM Plex aren't installed on macOS by default, and bundling
/// Google Fonts would add a network dependency to what's meant to be a self-contained app).
enum AppTheme {
    // The Mac app is always "paper". The iPhone app follows the system appearance: the same colours in light mode and
    // a dark counterpart (dark paper, light ink) in dark mode.
    static let paper = Color.themed(light: 0xF5F1E6, dark: 0x26231F)
    static let desk = Color.themed(light: 0xDCD6C4, dark: 0x171512)
    static let ink = Color.themed(light: 0x2B2823, dark: 0xEFEADF)
    static let inkSoft = Color.themed(light: 0x6B655A, dark: 0xA8A18F)
    static let penRed = Color.themed(light: 0xB33A3A, dark: 0xE27A74)
    static let penRedBg = Color.themed(light: 0xFBEAE8, dark: 0x3B2321)
    static let stampGreen = Color.themed(light: 0x3F6B4F, dark: 0x4E8A64)
    static let rule = Color.themed(light: 0xC9C2AC, dark: 0x45403A)
    /// Raised cards on the desk (the purchase drill-down).
    static let card = Color.themed(light: 0xFFFFFF, dark: 0x1E1B18)
    /// Text on an `ink` coloured fill (a filled button).
    static let onInk = Color.themed(light: 0xFFFFFF, dark: 0x171512)

    /// Chart series colors: five categories plus a neutral for "Other". Muted to sit on the paper tone.
    static let chartPalette: [Color] = [
        Color(hex: 0x3F6B4F), Color(hex: 0xB33A3A), Color(hex: 0xC28B2C), Color(hex: 0x3F6A8A), Color(hex: 0x7A4E7E),
    ]
    static let chartOther = Color(hex: 0x9A9484)

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
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Color {
    /// `light` on the Mac (always) and in light mode, `dark` in dark mode on the iPhone.
    static func themed(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        Color(hex: light)
        #endif
    }
}
