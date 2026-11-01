import LabCore
import SwiftUI
import UIKit

/// The production paper palette, tuned for contrast. Everything is an adaptive light and dark pair.
enum P {
    static let paper = adaptive(0xFAF7EE, 0x2A2723)
    static let desk = adaptive(0xE6E1D2, 0x171512)
    static let ink = adaptive(0x2B2823, 0xF1ECE1)
    static let inkSoft = adaptive(0x665F53, 0xB0A998)
    /// Small text directly on the desk.
    static let label = adaptive(0x575146, 0xA8A18F)
    static let red = adaptive(0xB33A3A, 0xEC8A83)
    /// The error bar, white text in both modes.
    static let errorBar = adaptive(0xB33A3A, 0x9E3532)
    static let redBg = adaptive(0xFBEAE8, 0x3D2422)
    static let onRed = adaptive(0xFFFFFF, 0x2A1412)
    static let green = adaptive(0x3A6B4B, 0x4F8F67)
    static let greenText = adaptive(0x2F6341, 0x86C79E)
    static let greenBg = adaptive(0xE6F0E6, 0x20302A)
    static let onGreen = adaptive(0xFFFFFF, 0x0E1A13)
    static let rule = adaptive(0xCFC8B3, 0x48433C)
    static let field = adaptive(0xFFFFFF, 0x1F1C19)
    static let onInk = adaptive(0xFFFFFF, 0x171512)

    /// Chart series: muted on paper, lifted on dark paper.
    static let series: [Color] = [
        adaptive(0x3F6B4F, 0x68AD82), adaptive(0xC28B2C, 0xE0AE55), adaptive(0x3F6A8A, 0x7DAFD1), adaptive(0x7A4E7E, 0xB88CBC),
    ]
    static let seriesOther = adaptive(0x9A9484, 0x8C8676)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

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
            .font(P.body(11, .semibold))
            .kerning(0.6)
            .foregroundStyle(P.label)
    }
}

extension View {
    /// A sheet of paper on the desk.
    func paperCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(P.paper, in: RoundedRectangle(cornerRadius: P.corner))
            .overlay(RoundedRectangle(cornerRadius: P.corner).strokeBorder(P.rule, lineWidth: 1))
    }

    /// An inline text field box.
    func fieldBox() -> some View {
        self.padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(P.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(P.rule, lineWidth: 1))
    }
}

/// An outlined button with a 44pt target.
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = P.ink
    var fill: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(P.body(14, .medium))
            .lineLimit(1)
            .foregroundStyle(fill ? P.onInk : color)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(fill ? AnyShapeStyle(P.ink) : AnyShapeStyle(P.paper))
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
    var color: Color = P.inkSoft
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
                .font(P.body(14, selected ? .semibold : .regular))
                .foregroundStyle(selected ? P.onInk : P.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(selected ? AnyShapeStyle(P.ink) : AnyShapeStyle(P.paper), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.clear : P.rule, lineWidth: 1))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Wraps children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (points, widest, y + rowHeight)
    }
}

/// The inline note used for connection and error results.
struct NoteBox: View {
    let systemName: String
    let text: String
    let color: Color
    let background: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemName)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(P.body(13))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}
