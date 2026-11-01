# Design 2: iOS 26 Liquid Glass, scout notes

Sources: installed iOS 26.4 SDK `SwiftUI.swiftinterface` (API names checked there and by compiling), Donny Wals on iOS 26
tab bars and custom glass. Apple's own HIG pages did not come back from search, so the rules below are the commonly
reported ones, verified on the simulator rather than quoted from Apple.

## What identifies the look
- Two layers: content stays flat and opaque, glass floats above it as the navigation and control layer. No glass on rows or cards.
- Floating capsule tab bar that shrinks on scroll (`tabBarMinimizeBehavior`), with a glass accessory above it for global status (`tabViewBottomAccessory`).
- Toolbars without a bar background: grouped glass capsules (`ToolbarItemGroup`, `ToolbarSpacer`), bare glyphs (`ellipsis`, not `ellipsis.circle`; the glass is already the circle), and a scroll edge effect instead of a hairline.
- Large titles, grouped `List`/`Form`, concentric corners, partial-detent sheets that float inset from the screen edge and morph out of their button (`navigationTransition(.zoom)`).
- `safeAreaBar` for custom bars so they get the scroll edge effect. `.glassProminent` for the single primary action, `GlassEffectContainer` when several glass shapes sit together.
- Semantic colours, SF Symbols, Dynamic Type, Swift Charts. Colour only means something: red for destructive or failure, orange for warning, green for confirm.

## Plan per screen
- **Root:** system `TabView`, minimize on scroll. Banners float at the top as glass panels; the error banner uses red-tinted glass.
- **list:** large title, filter glyph left, Scan and Choose photos grouped right, native search. Sync status moves into the bottom accessory. Mail-style dot marks unreviewed rows (replaces the red edge), orange triangle marks flagged ones. Native swipe to delete, pull to refresh.
- **listProcessing:** accessory shows upload progress; the upload panel is a medium/large detent sheet with the list still usable behind it. Processing rows use spinners in the dot slot.
- **listDeletedOpen, listEmpty, listNoMatch, listSetup:** native disclosure row; `ContentUnavailableView` for the empty states.
- **listFilters:** own medium-detent sheet zooming out of the filter button, used for real taps too, because a `Menu` cannot be opened from code.
- **Dialogs, alerts:** system `confirmationDialog` and `alert`, unchanged text.
- **detail:** segmented control in a `safeAreaBar`, `List` rows. Items collapse to one row and expand inline to their editor, so a review can be scanned quickly; repeats collapse to one row with `2×`; flagged items start open and tinted. Bottom glass bar has `Looks good` (green `.glassProminent`) and the `ellipsis` menu.
- **detailPhoto, detailPhotoMissing:** photo in a rounded frame, zoom controls in a floating glass capsule over it. `ContentUnavailableView` when missing.
- **detailBusy:** `Working…` in a glass panel over the disabled list.
- **Processing panels:** first section of the list, with native action rows.
- **overview:** segmented range in a `safeAreaBar`, big total, refresh in the toolbar, charts as grouped sections, tree as native disclosure rows, drill-down inline.
- **settings:** plain system `Form`, nothing custom.

## Deliberate label and icon changes
- Section headers are sentence case (`Needs review`, not `NEEDS REVIEW`): iOS 26 no longer uppercases grouped headers.
- `ellipsis` and `line.3.horizontal.decrease` drop their `.circle`, because the glass button already draws the circle. The filter's active state is a prominent tinted button instead of `.fill`.
- Round `xmark` delete becomes a `trash` toolbar button: in a navigation bar `xmark` reads as "close".
- `⟳` becomes `arrow.clockwise`, the standard refresh symbol, in the toolbar.
- `PHOTO` label dropped from the photo bar, since the selected segment already says it.
- `Total: €…` is shown as a `Total` caption over a large value.
- Dashed drill-down box becomes an ordinary grouped row: dashes are not an iOS idiom.
