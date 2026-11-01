import LabCore
import Observation
import SwiftUI
import UIKit

// MARK: Palette. The one place for colour: every token is a (light, dark) pair. Retune here.

enum SP {
    private static func c(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    private static func c(_ both: UInt32) -> Color { c(both, both) }

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // Checkout: the counter and the beige till.
    static let counter = c(0xDEDBD3, 0x1C1A18)
    static let till = c(0xCFCBC0, 0x2B2926)
    static let tillEdge = c(0xA9A498, 0x141210)
    static let tillText = c(0x262320, 0xEDE8DD)
    static let tillText2 = c(0x4F4B44, 0xB9B3A5)
    static let slot = c(0x24221F, 0x0B0A09)
    static let counterText = c(0x262320, 0xE8E3D8)
    static let counterText2 = c(0x4F4B44, 0xB3AD9F)

    // Keycaps.
    static let key = c(0xF4F1E9, 0x3F3C37)
    static let keyLip = c(0x9D988B, 0x12100E)
    static let keyText = c(0x262320, 0xF0EBE0)
    static let keyGreen = c(0x1E7A47, 0x23854F)
    static let keyGreenLip = c(0x0F4F2C, 0x0E4A29)
    static let keyRed = c(0xB81E2D, 0xB42230)
    static let keyRedLip = c(0x7A0F1B, 0x6F0F19)
    static let keyDisabled = c(0xD9D5CB, 0x2E2C28)
    static let keyDisabledText = c(0x5C5850, 0xA9A396)

    // The LED customer display looks the same day and night.
    static let led = c(0x14160F)
    static let ledGreen = c(0x7CF29A)
    static let ledAmber = c(0xFFB648)
    static let ledRed = c(0xFF7A6B)

    // Thermal paper. Dimmed after closing, ink stays dark.
    static let paper = c(0xFBF9F2, 0xE6E1D4)
    static let paperShade = c(0xEFEBDF, 0xD6D1C3)
    static let ink = c(0x23201C)
    static let ink2 = c(0x55504A, 0x4A453E)
    static let rule = c(0x8F897D, 0x7E786C)
    static let printRed = c(0xB3261E, 0xA8211A)
    static let printGreen = c(0x1B6A3B, 0x175E34)
    static let stampInk = c(0x1B6A3B, 0x175E34)
    static let highlighter = c(0xFFEA8A, 0xF1D872)
    static let shadow = c(0x3A352C, 0x000000)

    // Price tags and sale signs.
    static let tag = c(0xFFD21F, 0xE9BE1A)
    static let tagInk = c(0x1E1B16)
    static let tagRed = c(0xB00C22, 0xA20B20)
    static let tagWhite = c(0xFDFCF8, 0xE6E1D4)
    static let sticker = c(0xFFD21F, 0xE9BE1A)
    static let note = c(0xFFEE9E, 0xEAD67F)
    static let tape = c(0xD8CFB4, 0xB9B096)

    // The list's calm page, and the tab bar.
    static let page = c(0xD9D6CE, 0x131210)
    // The list's long strip of paper. Dimmed after closing, because it fills the screen.
    static let listPaper = c(0xFBF9F2, 0xB0AA9C)
    static let listInk = c(0x23201C, 0x1C1A16)
    static let listInk2 = c(0x55504A, 0x3A362F)
    static let listRule = c(0x8F897D, 0x6B665A)
    static let listRed = c(0xB3261E, 0x7A120C)
    static let listKey = c(0xEFEBDF, 0xC4BEB0)
    static let bar = c(0xF7F6F1, 0x24221F)
    static let barRule = c(0xC9C6BD, 0x3F3C37)
    static let barText = c(0x55514A, 0xB9B3A5)
    static let barTextOn = c(0x23201C, 0xF0EBE0)
    static let dividerBottom = c(0xC89F0A, 0xA98708)

    // The aisles.
    static let floor = c(0xECEDEA, 0x1E1D1B)
    static let floorLine = c(0xDFE0DC, 0x262523)
    static let shelf = c(0xFAFAF7, 0x2A2926)
    static let shelfEdge = c(0xB7B9B4, 0x45443F)
    static let rail = c(0x8D908D, 0x5F5D57)
    static let aisleText = c(0x1F2123, 0xECE8DE)
    static let aisleText2 = c(0x505456, 0xB5B0A4)
    static let sign = c(0x1D3B5F, 0x223F60)
    static let signText = c(0xFFFFFF, 0xF4F1E6)
    static let signText2 = c(0xC8D6E6, 0xC1CFDF)
    static let wire = c(0x7F8285, 0x55544F)
    static let up = c(0xB3261E, 0xFF8A7A)
    static let down = c(0x1B6A3B, 0x7FD79B)

    // The back office.
    static let wall = c(0xDCE1D6, 0x1D201B)
    static let clipboard = c(0xA47E55, 0x4D3C2B)
    static let clip = c(0x8B8E8C, 0x6A6B68)
    static let form = c(0xFBF9F2, 0x2C2B26)
    static let formLine = c(0xC9C5B8, 0x4B4940)
    static let formText = c(0x26241F, 0xE8E4D8)
    static let formText2 = c(0x57534A, 0xB4AFA1)
    static let field = c(0xF1EEE3, 0x201F1B)
    static let timeCard = c(0xF3E6BE, 0x3A3420)
    static let timeCardLine = c(0xC9B67F, 0x5E5535)
    static let formRed = c(0xB3261E, 0xFF8A7A)
    static let formGreen = c(0x1B6A3B, 0x7FD79B)
    static let openSign = c(0x1E7A47, 0x23854F)
    static let closedSign = c(0xB81E2D, 0xB42230)

    // Pegboard behind the photo.
    static let peg = c(0xCDBFA6, 0x2C2822)
    static let pegHole = c(0xA89A80, 0x171411)
    static let pegText = c(0x262320, 0xE8E3D8)

    // Bottle return.
    static let crate = c(0xC8CBC7, 0x2E2F2C)
    static let crateHole = c(0x9EA29E, 0x1B1C1A)

    /// Accent inside the system calendar popover, which follows the mode.
    static let pickerTint = c(0xB3261E, 0xFFD21F)

    // Alerts.
    static let alarm = c(0xB3261E, 0x9C211A)
    static let alarmText = Color.white
    static let scrim = c(0x1C1A18, 0x000000)

    /// Goods colours for the charts; each is readable next to the others in both modes.
    static func category(_ name: String) -> Color {
        switch name {
        case "Food": return c(0xE6B400, 0xE9BE1A)
        case "Household": return c(0x2F6AA8, 0x6FA5DC)
        case "Personal Care": return c(0xC43A55, 0xE5738A)
        default: return c(0x2E8B62, 0x62C798)
        }
    }

    static let chartLines = [c(0xB3261E, 0xFF8A7A), c(0x2F6AA8, 0x6FA5DC), c(0x1B6A3B, 0x7FD79B), c(0x8A6A00, 0xE9BE1A)]
}

// MARK: Type. One font per place.

enum SF {
    /// Anything printed on thermal paper.
    static func print(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "Menlo-Bold" : "Menlo-Regular", size: size) }
    /// Hanging signs and big labels.
    static func sign(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", size: size) }
    /// Shelf labels and figures.
    static func shelf(_ size: CGFloat) -> Font { .custom("DINAlternate-Bold", size: size) }
    /// Office forms.
    static func form(_ size: CGFloat, bold: Bool = false) -> Font { .custom(bold ? "AmericanTypewriter-Semibold" : "AmericanTypewriter", size: size) }
    /// Hand-written notes.
    static func note(_ size: CGFloat) -> Font { .custom("Noteworthy-Bold", size: size) }
    /// The LED display.
    static func led(_ size: CGFloat) -> Font { .custom("Menlo-Bold", size: size) }
}

// MARK: Weight and geometry. Retune here.

enum ST {
    static let keyLip: CGFloat = 3
    static let keyRadius: CGFloat = 7
    static let tear: CGFloat = 5
    /// Counter visible either side of the list's paper, and print inset from the paper's edge.
    static let paperMargin: CGFloat = 11
    static let paperInset: CGFloat = 13
    static let toothWidth: CGFloat = 9
    static let gutter: CGFloat = 14
    static let noteTilt: Double = -0.8
    static let stampTilt: Double = -9
    static let stampSeconds: Double = 0.45
    static let unfold: Animation = .snappy(duration: 0.22)
}

// MARK: Paper

/// Paper with zig-zag torn edges, a tear on the bottom, the top or both.
struct TornPaper: Shape {
    var top = false
    var bottom = true
    var depth = ST.tear
    var tooth = ST.toothWidth

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let count = max(1, Int((rect.width / tooth).rounded()))
        let w = rect.width / CGFloat(count)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + (top ? depth : 0)))
        if top {
            for i in 0..<count {
                p.addLine(to: CGPoint(x: rect.minX + (CGFloat(i) + 0.5) * w, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.minX + CGFloat(i + 1) * w, y: rect.minY + depth))
            }
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if bottom {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
            for i in (0..<count).reversed() {
                p.addLine(to: CGPoint(x: rect.minX + (CGFloat(i) + 0.5) * w, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * w, y: rect.maxY - depth))
            }
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// A printed dotted rule. `double` is the heavy rule above a sum.
struct DottedRule: View {
    var color = SP.rule
    var dash: [CGFloat] = [1.5, 3.5]
    var width: CGFloat = 1.5

    var body: some View {
        Line()
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: dash))
            .frame(height: width)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

/// The dots between a name and its price, sitting on the baseline.
struct DotLeader: View {
    var color = SP.rule
    var body: some View {
        DottedRule(color: color, dash: [1.5, 4], width: 1.5)
            .frame(minWidth: 8)
            .offset(y: 4)
    }
}

/// A deterministic barcode, so one receipt always has the same bars.
struct Barcode: View {
    var seed: Int
    var color = SP.ink

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var value = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 97)
            var ink = true
            while x < size.width {
                value = value &* 6364136223846793005 &+ 1442695040888963407
                let w = CGFloat(1 + (value >> 33) % 3) * 1.3
                if ink { context.fill(Path(CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)), with: .color(color)) }
                x += w
                ink.toggle()
            }
        }
        .accessibilityHidden(true)
    }
}

/// The loading indicator of this store: a barcode with a red beam sweeping over it.
struct ScanBeam: View {
    var width: CGFloat = 96
    var height: CGFloat = 44
    var barColor = SP.ink
    var beamColor = SP.printRed
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Barcode(seed: 7, color: barColor)
            beamColor
                .frame(height: max(1.5, height / 22))
                .shadow(color: beamColor.opacity(0.8), radius: 3)
                .offset(y: reduceMotion ? height / 2 : (sweep ? height - 1.5 : 0))
        }
        .frame(width: width, height: height)
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityLabel("Working")
    }
}

/// A thermal slip with a torn edge, used for rows, notices and the full receipt.
extension View {
    func slip(top: Bool = false, bottom: Bool = true, shadow: CGFloat = 1.5) -> some View {
        background(
            TornPaper(top: top, bottom: bottom)
                .fill(SP.paper)
                .shadow(color: SP.shadow.opacity(0.28), radius: shadow, y: shadow / 1.5)
        )
    }
}

/// The dark slit in the till that paper comes out of.
struct PrinterSlot: View {
    var body: some View {
        ZStack(alignment: .top) {
            SP.tillEdge.frame(height: 7)
            SP.slot.frame(height: 4).padding(.horizontal, 8).clipShape(Capsule())
                .padding(.top, 1.5)
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

// MARK: Keys

/// A physical till key. It sinks into its lip when pressed.
struct KeycapStyle: ButtonStyle {
    var face = SP.key
    var lip = SP.keyLip
    var ink = SP.keyText
    var height: CGFloat = 44
    var width: CGFloat?
    var font: Font = SF.shelf(16)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        return configuration.label
            .font(font)
            .foregroundStyle(isEnabled ? ink : SP.keyDisabledText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width)
            .frame(maxWidth: width == nil ? nil : width)
            .frame(height: height - ST.keyLip)
            .background(isEnabled ? face : SP.keyDisabled, in: RoundedRectangle(cornerRadius: ST.keyRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ST.keyRadius, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .offset(y: pressed ? ST.keyLip - 0.5 : 0)
            .frame(height: height - ST.keyLip)
            .background(alignment: .bottom) {
                RoundedRectangle(cornerRadius: ST.keyRadius, style: .continuous)
                    .fill(isEnabled ? lip : SP.keyLip.opacity(0.4))
                    .offset(y: ST.keyLip)
            }
            .padding(.bottom, ST.keyLip)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: pressed)
    }
}

extension ButtonStyle where Self == KeycapStyle {
    static var key: KeycapStyle { KeycapStyle() }
    static func key(width: CGFloat) -> KeycapStyle { KeycapStyle(width: width) }
    static var keyGo: KeycapStyle { KeycapStyle(face: SP.keyGreen, lip: SP.keyGreenLip, ink: .white, font: SF.shelf(17)) }
    static var keyStop: KeycapStyle { KeycapStyle(face: SP.keyRed, lip: SP.keyRedLip, ink: .white) }
    static var keyTag: KeycapStyle { KeycapStyle(face: SP.tag, lip: SP.dividerBottom, ink: SP.tagInk) }
}

/// A flat button without a lip, for the calm list.
struct FlatKeyStyle: ButtonStyle {
    var face = SP.paperShade
    var ink = SP.ink
    var font: Font = SF.shelf(14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(face)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Square icon key used in toolbars.
struct IconKey: View {
    let systemName: String
    let label: String
    var active = false
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(KeycapStyle(face: active ? SP.tag : SP.key,
                                 lip: active ? SP.dividerBottom : SP.keyLip,
                                 ink: active ? SP.tagInk : SP.keyText,
                                 height: size, width: size))
        .accessibilityLabel(label)
    }
}

/// Grows a key to the full width. Keeps the style's look.
struct WideLabel: View {
    let text: String
    var body: some View { Text(text).frame(maxWidth: .infinity) }
}

// MARK: Glow

extension View {
    /// Soft glow, for anything lit.
    func glow(_ color: Color, radius: CGFloat = 4) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
    }
}

// MARK: Tags and signs

/// A shelf-edge tag hanging from a rail.
struct ShelfTagButton: View {
    let title: String
    let selected: Bool
    var minWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SF.shelf(14))
                .foregroundStyle(selected ? SP.tagInk : SP.aisleText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(minWidth: minWidth, maxWidth: minWidth == nil ? nil : .infinity)
                .frame(height: 36)
                .background(selected ? SP.tag : SP.shelf)
                .overlay(Rectangle().strokeBorder(selected ? SP.dividerBottom : SP.shelfEdge, lineWidth: 1))
                .overlay(alignment: .top) {
                    (selected ? SP.dividerBottom : SP.shelfEdge).frame(height: 3)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The steel rail a row of tags clips onto.
struct ShelfRail: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            SP.rail.frame(height: 5)
            Color.black.opacity(0.18).frame(height: 1)
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// An OPEN/CLOSED sign on a string, on the checkout's setup state and in the office.
struct DoorSign: View {
    let open: Bool

    var body: some View {
        VStack(spacing: 0) {
            Canvas { context, size in
                var p = Path()
                p.move(to: CGPoint(x: size.width * 0.18, y: size.height))
                p.addLine(to: CGPoint(x: size.width / 2, y: 1))
                p.addLine(to: CGPoint(x: size.width * 0.82, y: size.height))
                context.stroke(p, with: .color(SP.rail), lineWidth: 1.5)
            }
            .frame(width: 130, height: 16)
            Text(open ? "OPEN" : "CLOSED")
                .font(SF.sign(26))
                .tracking(2)
                .foregroundStyle(.white)
                .padding(.top, 5)
                .frame(width: 130, height: 40)
                .background(open ? SP.openSign : SP.closedSign, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).inset(by: 3).strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .glow(open ? SP.openSign : SP.closedSign, radius: 5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of empty shelf tags on a rail.
struct EmptyShelf: View {
    var body: some View {
        VStack(spacing: 0) {
            ShelfRail()
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { _ in
                    Text("—")
                        .font(SF.shelf(16))
                        .foregroundStyle(SP.aisleText2)
                        .frame(width: 48, height: 28)
                        .background(SP.shelf)
                        .overlay(Rectangle().strokeBorder(SP.shelfEdge, lineWidth: 1))
                }
            }
            .padding(.top, 2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Keyboard

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

enum Haptic {
    @MainActor static func stamp() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    @MainActor static func key() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
