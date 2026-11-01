#if LAB_SWITCHER
import Design1Polish
import Design2Glass
import Design3Brutal
import Design4Store
import LabCore
import SwiftUI
import UIKit

/// All four designs. Switching rebuilds the chosen design at the screen the old one last reported.
struct SwitcherRoot: View {
    @AppStorage(SwitcherKeys.design) private var design = 1
    @State private var routing: DesignScreenRouting
    /// What the next DesignRoot opens at. Only changes on a switch, so reports do not rebuild the design.
    @State private var openAt: LabScreen?

    init() {
        if let forced = LabLaunch.design { UserDefaults.standard.set(forced, forKey: SwitcherKeys.design) }
        _routing = State(initialValue: DesignScreenRouting(current: LabLaunch.screen ?? .list))
        _openAt = State(initialValue: LabLaunch.screen)
    }

    var body: some View {
        chosen
            .id(design)
            .environment(\.designScreenRouting, routing)
            .background(PillWindowInstaller())
            .onReceive(NotificationCenter.default.publisher(for: SwitcherKeys.willSwitch)) { _ in
                openAt = routing.current
            }
    }

    @ViewBuilder private var chosen: some View {
        switch design {
        case 2: Design2Glass.DesignRoot(initialScreen: openAt)
        case 3: Design3Brutal.DesignRoot(initialScreen: openAt)
        case 4: Design4Store.DesignRoot(initialScreen: openAt)
        default: Design1Polish.DesignRoot(initialScreen: openAt)
        }
    }
}

enum SwitcherKeys {
    static let design = "lab.design"
    static let pillX = "lab.pill.x"
    static let pillY = "lab.pill.y"
    static let willSwitch = Notification.Name("lab.willSwitch")
}

// MARK: - Pill in its own window, so it stays above sheets, alerts and full-screen covers

/// Puts the pill in a separate window above the app's window once the scene exists.
private struct PillWindowInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { InstallerView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            PillWindow.install(in: scene)
        }
    }
}

/// Only the pill takes touches; everything else falls through to the app below.
private final class PillWindow: UIWindow {
    private static var shared: PillWindow?

    static func install(in scene: UIWindowScene) {
        guard shared == nil else { return }
        let window = PillWindow(windowScene: scene)
        window.windowLevel = .alert + 10
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: SwitcherPill())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        shared = window
    }

    /// Where the pill is, in window coordinates. Checked by geometry because SwiftUI's hit testing returns the hosting
    /// view for its own controls too, so the returned view cannot tell the pill from empty space.
    static var pillFrame: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard Self.pillFrame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Small neutral 1 / 2 / 3 / 4 pill: grey in both appearances, draggable, remembers its place.
private struct SwitcherPill: View {
    @AppStorage(SwitcherKeys.design) private var design = 1
    @AppStorage(SwitcherKeys.pillX) private var storedX = -1.0
    @AppStorage(SwitcherKeys.pillY) private var storedY = -1.0
    @GestureState private var drag: CGSize = .zero

    private let size = CGSize(width: 142, height: 34)

    var body: some View {
        GeometryReader { geo in
            let base = basePosition(in: geo.size)
            pill
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { PillWindow.pillFrame = $0 }
                .position(clamped(CGPoint(x: base.x + drag.width, y: base.y + drag.height), in: geo.size))
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let end = clamped(CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height), in: geo.size)
                            storedX = end.x
                            storedY = end.y
                        }
                )
        }
    }

    private func basePosition(in area: CGSize) -> CGPoint {
        // Default: right side, about two thirds down, clear of the navigation and tab bars.
        if storedX >= 0, storedY >= 0 { return CGPoint(x: storedX, y: storedY) }
        return CGPoint(x: area.width - size.width / 2 - 10, y: area.height * 0.68)
    }

    private func clamped(_ p: CGPoint, in area: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(p.x, size.width / 2), max(area.width - size.width / 2, size.width / 2)),
            y: min(max(p.y, size.height / 2), max(area.height - size.height / 2, size.height / 2))
        )
    }

    private var pill: some View {
        HStack(spacing: 2) {
            ForEach(1...4, id: \.self) { n in
                Button {
                    guard n != design else { return }
                    NotificationCenter.default.post(name: SwitcherKeys.willSwitch, object: nil)
                    design = n
                } label: {
                    Text("\(n)")
                        .font(.system(size: 13, weight: n == design ? .bold : .regular, design: .rounded))
                        .foregroundStyle(n == design ? Color.black : Color.white)
                        .frame(width: 32, height: 28)
                        .background(n == design ? Color.white.opacity(0.9) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Design \(n)")
            }
        }
        .padding(3)
        .background(Color(white: 0.35).opacity(0.72), in: Capsule())
        .frame(width: size.width, height: size.height)
    }
}
#endif
