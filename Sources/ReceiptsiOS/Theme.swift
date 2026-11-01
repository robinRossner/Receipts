import SwiftUI

/// The iPhone look: paper on a desk, three inks (ink, pen red for "look at this", stamp green for "done") and three type
/// voices (American Typewriter for names and headings, SF Mono for money, dates and quantities, SF Pro for the rest).
/// Every colour is an adaptive light and dark pair, the same values as the Mac's `AppTheme`.
enum Theme {
    static let paper = Color.themed(light: 0xFAF7EE, dark: 0x2A2723)
    static let desk = Color.themed(light: 0xE6E1D2, dark: 0x171512)
    static let ink = Color.themed(light: 0x2B2823, dark: 0xF1ECE1)
    static let inkSoft = Color.themed(light: 0x665F53, dark: 0xB0A998)
    /// Small text directly on the desk.
    static let label = Color.themed(light: 0x575146, dark: 0xA8A18F)
    static let red = Color.themed(light: 0xB33A3A, dark: 0xEC8A83)
    /// The error bar, white text in both modes.
    static let errorBar = Color.themed(light: 0xB33A3A, dark: 0x9E3532)
    static let redBg = Color.themed(light: 0xFBEAE8, dark: 0x3D2422)
    static let onRed = Color.themed(light: 0xFFFFFF, dark: 0x2A1412)
    static let green = Color.themed(light: 0x3A6B4B, dark: 0x4F8F67)
    static let greenText = Color.themed(light: 0x2F6341, dark: 0x86C79E)
    static let greenBg = Color.themed(light: 0xE6F0E6, dark: 0x20302A)
    static let onGreen = Color.themed(light: 0xFFFFFF, dark: 0x0E1A13)
    static let rule = Color.themed(light: 0xCFC8B3, dark: 0x48433C)
    static let field = Color.themed(light: 0xFFFFFF, dark: 0x1F1C19)
    static let onInk = Color.themed(light: 0xFFFFFF, dark: 0x171512)

    /// Chart series: muted on paper, lifted on dark paper. No red: that colour means "look at this".
    static let series: [Color] = [
        .themed(light: 0x3F6B4F, dark: 0x68AD82), .themed(light: 0xC28B2C, dark: 0xE0AE55),
        .themed(light: 0x3F6A8A, dark: 0x7DAFD1), .themed(light: 0x7A4E7E, dark: 0xB88CBC),
        .themed(light: 0x9C6B4A, dark: 0xCC9F7E),
    ]
    static let seriesOther = Color.themed(light: 0x9A9484, dark: 0x8C8676)

    static func display(_ size: CGFloat) -> Font { .custom("American Typewriter", size: size) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    static let corner: CGFloat = 8
}

/// Small uppercase label used for every section and card heading.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.body(11, .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.label)
    }
}

extension View {
    /// A sheet of paper on the desk.
    func paperCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.rule, lineWidth: 1))
    }

    /// An inline text field box.
    func fieldBox() -> some View {
        self.padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule, lineWidth: 1))
    }
}

/// An outlined (or ink filled) button with a 44pt target.
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = Theme.ink
    var fill: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(14, .medium))
            .lineLimit(1)
            .foregroundStyle(fill ? Theme.onInk : color)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(fill ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.paper))
            }
            .overlay {
                if !fill { RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.45), lineWidth: 1) }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// An icon button with a 44pt target.
struct IconButton: View {
    let systemName: String
    var label: String
    var color: Color = Theme.inkSoft
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A selectable filter chip.
struct Chip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Theme.body(14, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onInk : Theme.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(selected ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.paper), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.clear : Theme.rule, lineWidth: 1))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The inline note used for connection and error results.
struct NoteBox: View {
    let systemName: String
    let text: String
    let color: Color
    let background: Color
    var identifier: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemName).accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .font(Theme.body(13))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SnackbarView: View {
    let snack: SnackCenter.Snack
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(snack.text)
                .font(Theme.body(14))
                .foregroundStyle(Theme.onInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: undo) {
                Text("Undo")
                    .font(Theme.body(14, .semibold))
                    .foregroundStyle(Theme.onInk)
                    .underline()
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("undoButton")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}
