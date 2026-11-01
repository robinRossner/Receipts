import LabCore
import SwiftUI
import UIKit

// MARK: Palette. The one place for colour: every token is a (light, dark) pair. Retune here.

enum BP {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Surfaces: warm paper / warm charcoal.
    static let page = c(0xF3EEE4, 0x23211E)
    static let card = c(0xFBF8F1, 0x2E2B27)
    static let heroBg = c(0xF9F5EC, 0x2A2724)

    // Ink: soft near-black, never #000. Dark-mode outlines are a mid warm grey, not cream.
    static let line = c(0x2C2925, 0x8A8478)
    static let shadow = c(0x2C2925, 0x100F0D)
    static let text = c(0x2C2925, 0xEBE6DB)
    static let text2 = c(0x5F594F, 0xB5AEA1)

    // Accents: dusty, used on small blocks.
    static let yellow = c(0xEBCB6F, 0xD0B45F)
    static let pink = c(0xE6A0AB, 0xCC8B96)
    static let blue = c(0x9CB4D8, 0x8AA3C6)
    static let green = c(0xA3CCA5, 0x8CB890)

    /// Chart lines need more presence than block fills.
    static let chartLines = [c(0x5B79A5, 0x9DB3D0), c(0xB4677A, 0xD09EA8), c(0x5C8C63, 0xA3C9A6), c(0xA98A33, 0xCDB87A)]

    static let redFill = c(0xB0463F, 0x9E443D)
    static let redText = c(0xA33B35, 0xE39A91)
    static let greenText = c(0x3E6B46, 0xA3C9A6)
    static let flagFill = c(0xF6EBC9, 0x3B3526)
    static let focusFill = c(0xF8F0D8, 0x38332A)
    static let disabled = c(0xE6E0D4, 0x35322D)
    static let disabledText = c(0x645E54, 0xA59E91)

    /// Ink on any accent block.
    static let onAccent = c(0x2C2925, 0x1E1C19)
    static let onRed = Color.white
    static let scrim = c(0x2C2925, 0x000000)

    /// Each tab's one signature colour: title block and selected tab.
    static func accent(_ tab: LabScreen.Tab) -> Color {
        switch tab {
        case .receipts: return yellow
        case .overview: return pink
        case .settings: return blue
        }
    }

    static func category(_ name: String) -> Color {
        switch name {
        case "Food": return yellow
        case "Household": return blue
        case "Personal Care": return pink
        default: return green
        }
    }
}

// MARK: Weight. The one place for "a bit more / a bit less".

enum BT {
    // Outlines
    static let border: CGFloat = 2
    static let borderThin: CGFloat = 1.5
    static let borderDialog: CGFloat = 2.25
    // Rules
    static let rule: CGFloat = 1.5
    static let ruleThin: CGFloat = 0.75
    static let barRule: CGFloat = 2
    // Hard shadows. Only what matters most on a screen gets one.
    static let shadowCard: CGFloat = 3.5
    static let shadowControl: CGFloat = 3
    static let shadowSmall: CGFloat = 2.5
    static let shadowDialog: CGFloat = 5.5
    /// How far a shadowless control moves when pressed.
    static let flatTravel: CGFloat = 1.5
    // Tilts, in degrees. Kept to the title block, stickers and the Overview total.
    static let tiltTitle: Double = -1
    static let tiltSticker: Double = 2
    static let tiltSlab: Double = -0.7
    // Opacity of the scrim under dialogs and the filter panel.
    static let scrim: Double = 0.42
}

// MARK: Type

enum BF {
    /// Titles. Slightly widened SF Pro Heavy: keeps character without shouting. 0 = standard, 0.4 = fully expanded.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(Font.Width(0.15)) }
    /// SF Mono: every number.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func body(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func label(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .bold) }
}

// MARK: Slab

extension View {
    /// The core box: square, solid outline, flat by default. Pass a shadow only for what should stand out.
    func slab(_ fill: Color = BP.card, border: CGFloat = BT.border, shadow: CGFloat = 0, line: Color = BP.line) -> some View {
        background(fill)
            .overlay(Rectangle().strokeBorder(line, lineWidth: border))
            .background(BP.shadow.offset(x: shadow, y: shadow).opacity(shadow > 0 ? 1 : 0))
    }
}

/// Moves by the shadow offset and collapses the shadow. A flat button just nudges.
struct SlabButtonStyle: ButtonStyle {
    var fill: Color = BP.yellow
    var ink: Color = BP.onAccent
    var border: CGFloat = BT.border
    var shadow: CGFloat = BT.shadowControl
    var height: CGFloat = 46
    var fullWidth = true
    var font: Font = BF.label(16)
    var horizontalPadding: CGFloat = 14

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && isEnabled
        let active = isEnabled
        let travel = shadow > 0 ? shadow : BT.flatTravel
        return configuration.label
            .font(font)
            .foregroundStyle(active ? ink : BP.disabledText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(active ? fill : BP.disabled)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: border))
            .contentShape(Rectangle())
            .offset(x: down ? travel : 0, y: down ? travel : 0)
            .background(BP.shadow.offset(x: shadow, y: shadow).opacity(active && shadow > 0 ? 1 : 0))
            .animation(.linear(duration: 0.05), value: down)
    }
}

extension ButtonStyle where Self == SlabButtonStyle {
    /// The one main action of a screen.
    static var slabPrimary: SlabButtonStyle { SlabButtonStyle() }
    static func slabPrimary(_ fill: Color) -> SlabButtonStyle { SlabButtonStyle(fill: fill) }
    /// Secondary: flat outline.
    static var slabPlain: SlabButtonStyle { SlabButtonStyle(fill: BP.card, ink: BP.text, shadow: 0) }
    /// Confirming something destructive, in a dialog.
    static var slabDanger: SlabButtonStyle { SlabButtonStyle(fill: BP.redFill, ink: BP.onRed) }
    /// Offering something destructive: flat, red text.
    static var slabDangerQuiet: SlabButtonStyle { SlabButtonStyle(fill: BP.card, ink: BP.redText, shadow: 0) }
    /// A compact button that sits inside a card.
    static func slabSmall(_ fill: Color = BP.card, ink: Color = BP.text) -> SlabButtonStyle {
        SlabButtonStyle(fill: fill, ink: ink, border: BT.borderThin, shadow: 0, height: 44, fullWidth: false, font: BF.label(14), horizontalPadding: 10)
    }
}

/// A square icon button, 44pt, flat.
struct IconBlock: View {
    let system: String
    var label: String
    var fill: Color = BP.card
    var ink: Color = BP.text
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) { IconBlockLabel(system: system, size: size) }
            .buttonStyle(IconBlockStyle(fill: fill, ink: ink))
            .accessibilityLabel(label)
    }
}

struct IconBlockLabel: View {
    let system: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
    }
}

struct IconBlockStyle: ButtonStyle {
    var fill: Color = BP.card
    var ink: Color = BP.text

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && isEnabled
        return configuration.label
            .foregroundStyle(isEnabled ? ink : BP.disabledText)
            .background(isEnabled ? fill : BP.disabled)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
            .contentShape(Rectangle())
            .offset(x: down ? BT.flatTravel : 0, y: down ? BT.flatTravel : 0)
            .animation(.linear(duration: 0.05), value: down)
    }
}

/// A row or card that presses in; the label draws its own box.
struct PressInStyle: ButtonStyle {
    var shadow: CGFloat = BT.shadowCard
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && isEnabled
        let travel = shadow > 0 ? shadow : BT.flatTravel
        return configuration.label
            .contentShape(Rectangle())
            .offset(x: down ? travel : 0, y: down ? travel : 0)
            .background(BP.shadow.offset(x: shadow, y: shadow).opacity(shadow > 0 ? 1 : 0))
            .animation(.linear(duration: 0.05), value: down)
    }
}

// MARK: Labels and stickers

/// Plain section heading.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BF.label(14))
            .foregroundStyle(BP.text)
    }
}

/// A flat colour tag.
struct TagLabel: View {
    let text: String
    var fill: Color = BP.yellow

    var body: some View {
        Text(text)
            .font(BF.label(13))
            .foregroundStyle(BP.onAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
    }
}

/// A small tilted sticker.
struct Sticker: View {
    let text: String
    var fill: Color = BP.yellow
    var angle: Double = BT.tiltSticker
    var font: Font = BF.label(12)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(BP.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
            .rotationEffect(.degrees(angle))
    }
}

/// The screen title as a colour block: the design's signature, and most of a tab's colour.
struct TitleBlock: View {
    let text: String
    let tab: LabScreen.Tab

    var body: some View {
        Text(text)
            .font(BF.display(21))
            .foregroundStyle(BP.onAccent)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(BP.accent(tab))
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.border))
            .background(BP.shadow.offset(x: BT.shadowSmall, y: BT.shadowSmall))
            .rotationEffect(.degrees(BT.tiltTitle))
            .accessibilityAddTraits(.isHeader)
    }
}

struct HeavyRule: View {
    var height: CGFloat = BT.rule
    var body: some View { BP.line.frame(height: height) }
}

// MARK: Spinner

/// A bordered square turning continuously.
struct BlockSpinner: View {
    var size: CGFloat = 14
    var color: Color = BP.text
    @State private var turning = false

    var body: some View {
        Rectangle()
            .strokeBorder(color, lineWidth: max(1.5, size / 8))
            .overlay(Rectangle().fill(color).frame(width: size * 0.3, height: size * 0.3))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("Working")
    }
}

// MARK: Fields

struct BrutalField: View {
    var prompt: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var mono = false
    var alignment: TextAlignment = .leading
    var height: CGFloat = 46
    var fontSize: CGFloat = 15
    var autocap = true
    var isDisabled = false

    @FocusState private var focused: Bool

    private var prompted: Text { Text(prompt).foregroundStyle(BP.text2) }

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: prompted)
            } else {
                TextField("", text: $text, prompt: prompted)
            }
        }
        .focused($focused)
        .font(mono ? BF.mono(fontSize) : BF.body(fontSize, .medium))
        .foregroundStyle(BP.text)
        .multilineTextAlignment(alignment)
        .keyboardType(keyboard)
        .textInputAutocapitalization(autocap ? .sentences : .never)
        .autocorrectionDisabled(!autocap)
        .tint(BP.text)
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(focused ? BP.focusFill : BP.card)
        .overlay(Rectangle().strokeBorder(BP.line, lineWidth: focused ? BT.border : BT.borderThin))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .disabled(isDisabled)
    }
}

/// A labelled picker: a bordered block that opens the system menu.
struct BrutalPicker: View {
    let label: String
    let value: String
    let options: [String]
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    pick(option)
                } label: {
                    if option == value { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(BF.body(13, .medium))
                    .foregroundStyle(BP.text2)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(BF.body(14, .semibold))
                    .foregroundStyle(BP.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BP.text2)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(BP.card)
            .overlay(Rectangle().strokeBorder(BP.line, lineWidth: BT.borderThin))
            .contentShape(Rectangle())
        }
    }
}

// MARK: Date chip

/// A raw-format chip that opens the system calendar or wheel in a popover.
struct BrutalDateChip: View {
    let text: String
    @Binding var selection: Date
    let components: DatePickerComponents
    var fontSize: CGFloat = 14

    @State private var open = false

    var body: some View {
        Button(text) { open = true }
            .buttonStyle(SlabButtonStyle(fill: BP.card, ink: BP.text, border: BT.borderThin, shadow: 0, height: 44, fullWidth: false,
                                         font: BF.mono(fontSize), horizontalPadding: fontSize < 14 ? 6 : 10))
            .fixedSize()
            .popover(isPresented: $open) {
                Group {
                    if components == .date {
                        DatePicker("", selection: $selection, displayedComponents: components)
                            .datePickerStyle(.graphical)
                    } else {
                        DatePicker("", selection: $selection, displayedComponents: components)
                            .datePickerStyle(.wheel)
                    }
                }
                .labelsHidden()
                .tint(BP.text)
                .padding(12)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(BP.card)
            }
    }
}

// MARK: Segmented

struct BrutalSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var accent: Color = BP.yellow

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(selected ? BF.label(14) : BF.body(14, .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? BP.onAccent : BP.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selected ? accent : BP.card)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if index < options.count - 1 { BP.line.frame(width: BT.borderThin, height: 44) }
            }
        }
        .slab(BP.card)
    }
}

// MARK: Header

/// The quiet header: same paper in every tab, with colour only on the title block.
struct HeroSlab<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BP.heroBg.ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { BP.line.frame(height: BT.barRule) }
    }
}

// MARK: Keyboard

/// True while the keyboard is on screen, for the bar that carries `Done`.
@MainActor @Observable
final class KeyboardWatcher {
    var isVisible = false
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = true }
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = false }
        })
    }

    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: Swipe

/// A pan that only begins on a horizontal movement, so it coexists with vertical scrolling.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: onChange(x)
        case .ended, .cancelled, .failed: onEnd(x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

/// Draws the `]` that ties repeats of a product together.
struct BracketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}
