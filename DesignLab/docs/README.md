# DesignLab

A throwaway app for comparing four designs of the Receipts iOS app in the simulator. UI and fake data only. It imports
nothing from production.

## Layout

```
DesignLab/
  Package.swift          local package; never needs editing (new files are picked up automatically)
  project.yml            XcodeGen; generates DesignLab.xcodeproj (git-ignored)
  App/                   shared app entry; compile flags pick what each target shows
  Sources/LabCore/       models, fake data, LabScreen, DesignScreenRouting, ReceiptPhotoPlaceholder
  Sources/Design1Polish/ design 1, used by Host1 and DesignLab
  Sources/Design2Glass/  design 2, used by Host2 and DesignLab
  Sources/Design3Brutal/ design 3, used by Host3 and DesignLab
  Sources/Design4Store/  design 4, used by Host4 and DesignLab
  docs/screens.md        every screen and state, with ids, exact text and production file:line pointers
```

Targets: `DesignLab` has all four designs and the switcher. `Host1`, `Host2`, `Host3`, `Host4` have one design each and no
switcher, so a design agent never compiles another agent's code.

| Scheme | Bundle id | Design folder |
| --- | --- | --- |
| DesignLab | com.robin.designlab | all |
| Host1 | com.robin.designlab.host1 | Sources/Design1Polish |
| Host2 | com.robin.designlab.host2 | Sources/Design2Glass |
| Host3 | com.robin.designlab.host3 | Sources/Design3Brutal |
| Host4 | com.robin.designlab.host4 | Sources/Design4Store |

## The contract for a design

Work only in your own `Sources/DesignN…/` folder. Do not edit `LabCore`, `App/`, `Package.swift` or `project.yml`.

Keep `public struct DesignRoot: View` with `public init(initialScreen: LabScreen?)`, and:

1. Open at `initialScreen` (nil means `.list`), every id in `LabScreen`, including dialogs and alerts. Read it once into
   `@State`.
2. Report what is on screen with `.labReportsScreen(screen)` on your root, where `screen` is derived from your navigation
   state. That is how the switcher keeps the screen when changing design.
3. Replace `DesignRoot.swift`'s placeholder. Add as many files as you like.

Data comes from `LabData`, `LabTaxonomy`, `LabFormat` and `screen.fixtureReceipt`. Use `ReceiptPhotoPlaceholder` for
photos. Actions change local `@State` only, or nothing.

## Build and run one Host

Copy, set `N` (1, 2, 3 or 4) and use your own derived data folder so parallel builds do not collide.

```sh
N=1
UDID=5CBE5CF5-5C8D-4E84-8A58-0AB80813395E
DD=/tmp/designlab-dd-host$N
cd "/path/to/receipts/DesignLab"
[ -d DesignLab.xcodeproj ] || xcodegen generate
xcodebuild -project DesignLab.xcodeproj -scheme Host$N \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" build 2>&1 | grep -E " error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl install $UDID "$DD/Build/Products/Debug-iphonesimulator/Host$N.app"
xcrun simctl launch --terminate-running-process $UDID com.robin.designlab.host$N -screen list
```

The whole lab is the same with `-scheme DesignLab`, `DesignLab.app` and `com.robin.designlab`.

## Screenshots with `-screen`

```sh
xcrun simctl launch --terminate-running-process $UDID com.robin.designlab.host$N -screen detail
sleep 2
xcrun simctl io $UDID screenshot /tmp/host$N-detail.png
```

`-screen <id>` takes any id from `docs/screens.md`. An unknown id prints the known ones to the console and opens `list`.
DesignLab also takes `-design <1|2|3|4>`:

```sh
xcrun simctl launch --terminate-running-process $UDID com.robin.designlab -design 2 -screen overview
```

The simulator is shared: when several agents screenshot at once, launch and screenshot in one command to keep the pair
together.

## Light and dark

```sh
xcrun simctl ui $UDID appearance dark
xcrun simctl ui $UDID appearance light
```

## The switcher (DesignLab only)

A grey 1 / 2 / 3 / 4 pill in its own window above the app, so it stays over sheets, alerts and dialogs. Drag it anywhere.
The design and the pill position are remembered. Switching rebuilds the new design at the screen the old one last
reported, so a design that does not report restarts at the launch screen.
