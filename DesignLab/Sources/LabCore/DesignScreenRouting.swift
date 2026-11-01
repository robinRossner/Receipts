import Observation
import SwiftUI

/// How a design tells the switcher which screen it is on, so a switch to another design opens the same screen.
///
/// The contract for a design:
/// 1. `DesignRoot(initialScreen:)` opens at `initialScreen` (nil means `.list`), including tabs, pushed screens, dialogs
///    and sheets. Read it once, into `@State`. Later values are not navigation commands.
/// 2. Whenever the visible screen changes, report it: put `.labReportsScreen(value)` on the root, where `value` is
///    derived from your navigation state (tab, path, presented dialog).
///
/// Nothing here ever drives a design. A design rebuilt by a switch gets the new screen through `initialScreen`.
@MainActor @Observable
public final class DesignScreenRouting {
    public var current: LabScreen

    public init(current: LabScreen = .list) {
        self.current = current
    }
}

private struct DesignScreenRoutingKey: EnvironmentKey {
    @MainActor static let defaultValue = DesignScreenRouting()
}

public extension EnvironmentValues {
    var designScreenRouting: DesignScreenRouting {
        get { self[DesignScreenRoutingKey.self] }
        set { self[DesignScreenRoutingKey.self] = newValue }
    }
}

private struct ReportsScreen: ViewModifier {
    let screen: LabScreen
    @Environment(\.designScreenRouting) private var routing

    func body(content: Content) -> some View {
        content.onChange(of: screen, initial: true) { routing.current = screen }
    }
}

public extension View {
    /// Tells the switcher what is on screen. See `DesignScreenRouting`.
    func labReportsScreen(_ screen: LabScreen) -> some View {
        modifier(ReportsScreen(screen: screen))
    }
}
