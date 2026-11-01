import LabCore
import SwiftUI
#if LAB_SWITCHER || LAB_HOST1
import Design1Polish
#endif
#if LAB_SWITCHER || LAB_HOST2
import Design2Glass
#endif
#if LAB_SWITCHER || LAB_HOST3
import Design3Brutal
#endif
#if LAB_SWITCHER || LAB_HOST4
import Design4Store
#endif

/// One app entry for all five targets. The target's compile flag decides what it shows.
@main
struct LabApp: App {
    var body: some Scene {
        WindowGroup {
            #if LAB_SWITCHER
            SwitcherRoot()
            #else
            HostRoot()
            #endif
        }
    }
}

#if !LAB_SWITCHER
/// Host1/2/3/4: exactly one design, no switcher.
private struct HostRoot: View {
    @State private var routing = DesignScreenRouting(current: LabLaunch.screen ?? .list)

    var body: some View {
        Group {
            #if LAB_HOST1
            Design1Polish.DesignRoot(initialScreen: LabLaunch.screen)
            #elseif LAB_HOST2
            Design2Glass.DesignRoot(initialScreen: LabLaunch.screen)
            #elseif LAB_HOST3
            Design3Brutal.DesignRoot(initialScreen: LabLaunch.screen)
            #elseif LAB_HOST4
            Design4Store.DesignRoot(initialScreen: LabLaunch.screen)
            #endif
        }
        .environment(\.designScreenRouting, routing)
    }
}
#endif
