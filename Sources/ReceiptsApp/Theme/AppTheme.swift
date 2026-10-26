import SwiftUI

/// Ports dashboard.html's CSS custom properties. Fonts are substituted with close system
/// equivalents (Special Elite / IBM Plex aren't installed on macOS by default, and bundling
/// Google Fonts would add a network dependency to what's meant to be a self-contained app).
enum AppTheme {
    static let paper = Color(hex: 0xF5F1E6)
    static let desk = Color(hex: 0xDCD6C4)
    static let ink = Color(hex: 0x2B2823)
    static let inkSoft = Color(hex: 0x6B655A)
    static let penRed = Color(hex: 0xB33A3A)
    static let penRedBg = Color(hex: 0xFBEAE8)
    static let stampGreen = Color(hex: 0x3F6B4F)
    static let rule = Color(hex: 0xC9C2AC)

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
