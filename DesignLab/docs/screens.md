# iOS screen inventory

The source of truth for what the production iOS app has. Paths are relative to the repo root. `Views/` means
`Sources/ReceiptsApp/Views/` (shared with the Mac, iOS branches only are described here). `iOS/` means
`Sources/ReceiptsiOS/`.

**Language.** All app text is English. Store names and item names on receipts are German (`nameDe`), each item has an
English translation field. Not localized: there are no string catalogs.

**Formats.** Money `€12.34` (euro sign first, dot decimal: `Views/Formatting.swift:4`, `LabFormat.money`), nil shows `—`.
Dates are shown raw as `2026-10-30`, except the month label `October 2026` and the detail's system date pickers.

**Appearance.** Follows system light/dark (`Sources/ReceiptsApp/Theme/AppTheme.swift:12`). Current look: paper and
typewriter, for reference only.

**Structure.** Three tabs (`iOS/RootView.swift:18`): Receipts (`list.bullet.rectangle.portrait`), Overview
(`chart.bar.xaxis`), Settings (`gearshape`). Banners sit above the tabs. Detail is a push from the list, with the tab bar
hidden. The app has no custom sheets at all: only alerts, confirmation dialogs, a menu, and two system screens.

Ids below are `LabScreen` cases and `-screen` values. Data: `LabScreen.fixtureReceipt` and `LabData`.

## Receipts tab (`iOS/ReceiptListScreen.swift`)

### `list`: main list (:121)
Title `Receipts`. Toolbar: left filter icon (`line.3.horizontal.decrease.circle`, `.fill` when filtering, :254); right
`doc.viewfinder` "Scan receipt" (:262) and `photo.on.rectangle` "Choose photos" (:266, max 20).
Search field prompt `Store, item or amount` (:145). Pull to refresh runs a sync.
Rows top to bottom:
- Sync status row when sync is on (`Views/CloudSyncViews.swift:5`): small text `Synced 12 minutes ago`, `Syncing…` (with
  spinner), `Sync failed, retrying`, `Sync failed` (red), `Not synced yet`, and a sync icon button
  (`arrow.triangle.2.circlepath`). `LabData.syncStatus*`.
- Section `NEEDS REVIEW` with a badge `4 to review` (:182, count of the section) and section `REVIEWED` (no badge).
  `LabData.unreviewed`, `LabData.reviewedReceipts`.
- Collapsed `RECENTLY DELETED (2)` disclosure (:224).

Row (:274): store name (nil: `Unknown`), date, total on the right. An unreviewed row has a red left edge (:307), a row
with `needsReview` has a `⚠` top right (:310). Tap pushes detail. Swipe left: `Delete` (trash icon, no confirmation, moves
to Recently deleted, :175).

### `listProcessing`: uploads and processing rows
`LabData.uploadQueue` panel (`Views/UploadQueueView.swift:12`) above the list, and `LabData.processingReceipts` in Needs
review.
- Panel: `UPLOADS - 3 of 5`, buttons `Cancel all` (pending), `Retry failed` (failures), `Clear finished`; a progress bar;
  rows up to 180pt then scrolling, each with a 22pt thumbnail, status icon, file name, status text, and a cancel `xmark`
  on unfinished ones. Status text: `LabUploadJob.State.text`. Tapping a finished row loads that receipt.
- Processing row (:285): name `New receipt` when no store, then in place of the date the label, with a mini spinner when
  active: `Waiting to upload`, `Reading receipt on the server…`; in red without spinner `Upload failed`,
  `Could not read this receipt`. Total hidden unless known (:299).

### `listDeletedOpen`: recently deleted open (:203)
Each row: store, `date · total`, `Restore`, red `Delete` (opens `dialogPermanentDelete`).

### `listEmpty` (:135)
`No receipts yet. Scan one with the camera or choose photos.` Server is set up, no receipts. Sync row and toolbar remain.

### `listNoMatch` (:137)
`No receipts match.` Search or filters active. Filter icon in its `.fill` state.

### `listSetup`: not connected (:94)
No server and no receipts. Icon `icloud.and.arrow.up`, `Connect to your server`, `Receipts are read by your own backend.
Enter its address and the receipts token in Settings.`, button `Open Settings` (goes to the Settings tab).

### `listFilters`: filter menu open (:238)
A system `Menu`: picker `Date` (`All time`, `This month`, `Last 3 months`, `This year`), picker `Store` (`All stores`, then
each store in use), `Clear filters` (only while filtering), divider, `Confirm all without flags (2)` (only when count > 0,
opens `dialogConfirmAll`).
**Note:** SwiftUI cannot open a `Menu` from code. For this launch state, either build the filters as your own panel or
open your closest equivalent. Say so in your summary if you keep a system menu.

### `dialogConfirmAll` (:65)
Title `Confirm 2 receipts without flags?` Message `Marks every unreviewed receipt that has no review reasons as reviewed.
Receipts with warnings stay in “Needs review”.` Buttons `Confirm all`, `Cancel`.

### `dialogPermanentDelete` (:74)
Title `Permanently delete this receipt?` Message `This removes the receipt, its items and the photo copy on this phone. It
cannot be undone.` Buttons `Delete permanently` (destructive), `Cancel`.

### `alertScanUnavailable` (:57)
Title `Document camera not available`. Message `This device cannot scan documents. Use “Choose photos” instead.` Button `OK`.
This is what the simulator shows when Scan is tapped.

### `alertScanNote` (:62, text from `iOS/CaptureViews.swift:51-75`)
Title `Scan`, button `OK`. Message one of: `Only the first of 3 pages was added. A receipt is one photo; scan the other
pages as separate receipts.`, `The scan could not be saved.`, `2 photo(s) could not be loaded.`

### System screens, not designable, no ids
`VNDocumentCameraViewController` full-screen cover (`iOS/CaptureViews.swift:7`) and the `PhotosPicker` sheet. A design
keeps only the two entry buttons. In this lab: Scan shows `alertScanUnavailable`; Choose photos may do nothing or open a
real `PhotosPicker` that is ignored.

## Root banners (`iOS/RootView.swift:38`)
Above the tabs, on every tab.

### `bannerSync` (`Views/CloudSyncViews.swift:39`)
One per text in `LabData.banners`: icon `externaldrive.badge.exclamationmark`, red text, `Sync now` button.

### `bannerError` (`iOS/RootView.swift:41`)
Red bar, white `⚠ <error>` (`LabData.errorBanner`, a sample: any store error appears here), `xmark` to dismiss.

## Receipt detail (`iOS/ReceiptDetailScreen.swift`, `Views/ReceiptDetailView.swift`)
Inline title = store name, or `Receipt`. Tab bar hidden. Keyboard toolbar has `Done`.

### `detail`: needs review, Items tab (:75)
Top: segmented `Items` / `Photo`. Then a scrolling card, then a fixed action bar.
Card, in order:
- Editable store name, centered (:158). Placeholder `Store`. While focused, up to 5 suggestions below it (:476,
  `LabData.storeSuggestions`). Round `xmark` top right opens `dialogDelete`.
- Date picker and time picker (compact system pickers, :186), `xmark.circle.fill` clears the time. Without values:
  `Set date`, `+ Add time`.
- Warning box, one `⚠ <reason>` per review reason (:241). Reason wording in fixtures matches production:
  `Item prices sum to 22.84, but printed total is 25.24 (difference: 2.4). Check raw_text per item.`,
  `Possible duplicate of receipt #409`.
- Items, grouped by product. Repeats share a bracket with `2×` on the right (:269, `LabReceipt.groupedItems`).
- `+ Add missing item` (:310). Starts open when the sum mismatches. Toggle text when open: `– Cancel`.
- Footer (:351): `Items total: €22.84` and `Printed total:` with an editable euro field.

Item row (`Views/ItemRowView.swift:57`), all editable inline:
- German name, bold (`nameDe`).
- `qty × unit price = total` with two number fields (:63).
- `Translation` text field (:89).
- Three labelled pickers, stacked: `Category`, `Subcategory`, `Item group` (:150), cascading. `LabTaxonomy`.
- `Save` (states `Saving…`, `Saved`, `Bad qty/price`, :48) and a trash icon (deletes the item at once).
- A flagged item (`needsReview`) has a tinted background (:133).

Action bar (:379): `Looks good` (green, centered). Confirms, then moves to the next receipt to review, in place
(`iOS/ReceiptDetailScreen.swift:4`). On the right `ellipsis.circle` menu: `Re-run extraction…` (only if
`photoLocation == "server"`) and `Delete receipt…` (destructive).

### `detailLoading` (`iOS/ReceiptDetailScreen.swift:18`)
Centered spinner only, before the receipt has loaded. Title `Receipt`.

### `detailReviewed`
As `detail` with no warning box, button `Reviewed ✓`, dimmed and disabled (:397).

### `detailPhoto`: Photo tab (`Views/ReceiptPhotoView.swift`)
Bar (:68): `PHOTO`, zoom out, `Fit`, `100%`, zoom in. Below it the photo, fitted, scrollable when zoomed, pinch to zoom up
to 8×. Action bar stays. Use `ReceiptPhotoPlaceholder`.

### `detailPhotoMissing` (`Views/ReceiptPhotoView.swift:118`)
Photo tab, no photo. Icon `photo.badge.exclamationmark`, note text, bar disabled. Notes on the phone
(`Database/ReceiptStore.swift:306-310`): `This photo is on your laptop.` (fixture), `Loading the photo from the server…`,
`This receipt has no photo.` No `Re-run extraction…` in the menu for this fixture.

### `detailAddItem` (:317)
Add form open: `Item name`, `Qty` (default 1), `Price €`, `Add` (busy `Adding…`). Error `Enter an item name and a price.`

### `detailItemEdited`: category changed, unsaved (`Views/ItemRowView.swift:96`)
A row with changed pickers shows `info.circle` and `Saving updates the dictionary entry, so it applies to 3 line items
across 2 receipts.` (Before the counts load: `This changes the shared dictionary entry for this item.`)

### `detailBusy` (:132)
Card disabled, `Working…` spinner box over it. Action bar disabled.

### Processing panel (`Views/CloudSyncViews.swift:71`), top of the card, above the store field
- `detailWaiting`: spinner, `Waiting to upload`, `The photo is saved on this Mac and uploads as soon as the server is
  reachable. Last attempt: <error>` (production really says "this Mac" on the iPhone, :85).
- `detailProcessing`: spinner, `Reading receipt on the server…`, `The server reads the photo; the result appears here by
  itself.`
- `detailUploadFailed`: red, `Upload failed`, `<error> Retry, or remove this receipt and add a clearer photo.`, buttons
  `Retry upload`, `Remove receipt` (destructive).
- `detailFailed`: red, `Could not read this receipt`, `<error> Retry it, or fill in the fields below by hand.`, button
  `Retry extraction`. The give-up button at :99 is Mac only.

Empty fields apply on these fixtures: `Set date`, `+ Add time`, no items, `Items total: —`.

### `dialogDelete` (:176)
Title `Delete this receipt?` Message `It moves to "Recently deleted" and can be restored from there.` Buttons `Delete`
(destructive), `Cancel`.

### `dialogRerun` (:432)
Title `Re-run extraction?` Message `The server reads the photo again and marks the receipt as not yet reviewed. If you
already edited or confirmed this receipt, the server keeps your version.` Buttons `Re-run extraction` (destructive),
`Cancel`.

## Overview tab (`Views/OverviewView.swift`, `Views/OverviewCharts.swift`)
Title `Overview`. There is no loading state: before data arrives it shows `Total: —`.

### `overview`: Month range (:42)
- Segmented `Month`, `Year`, `Custom`, `All time` (:68).
- `‹` `October 2026` `›` and a `⟳` refresh (:78, :90).
- `Total: €…` (:45).
- Card `SPENDING BY MONTH` (`OverviewCharts.swift:52`): stacked bars, 12 months up to the selected one, top 5 categories
  plus `Other`, legend below, y labels `€300`. Unselected months dimmed to 45%. `LabData.monthly`, `LabData.highlightMonth`.
- Card `BY STORE` (`OverviewCharts.swift:69`): horizontal bars with the amount at the end, top 8 plus `Other`.
  `LabData.storeTotals(_:)`.
- Tree (:220): rows category > subcategory > item group, `▸`/`▾`, label, delta, amount. Tap expands. Deltas on the first
  two levels only (:335): `+12% vs last month`, `±0% vs last month`, `new vs last month`; red when up, green when down.
  `LabData.summary(_:)`, `LabData.previousSummary(_:)`.

### `overviewYear`
Label `2026`, deltas say `last year`, chart covers the year.

### `overviewCustom` (:85)
`From` and `To` date pickers instead of the arrows, plus `⟳`. No deltas.

### `overviewAll` (:88)
Label `All time`, plus `⟳`. No deltas.

### `overviewEmpty` (:226)
`Total: —`, no charts, `No spending in this period.`

### `overviewDrilldown`: item group open (:281)
`LabData.drilldownPath` open. Dashed box with `PRICE HISTORY (unit price, all time)` line chart, one line per product,
legend (`OverviewCharts.swift:107`, shown with 2 or more points; `LabData.priceHistory`). Then purchase rows (:307): date,
store, English name (or German), amount, `Edit` (`LabData.purchases`). Other states: `Loading…`, `No purchases found.`
`Edit` is meant to open that receipt with the item highlighted (`Database/ReceiptStore.swift:84`), but on iOS it only loads
the receipt in the background: no navigation happens, so the tap looks like it does nothing. A design may make it open
`detail`, the evident intent.

## Settings tab (`iOS/SettingsScreen.swift`)
Title `Settings`. A grouped form.

### `settings`: connected (:48)
- `Server`: `Server URL` field (`LabData.serverURL`), `Receipts token` secure field (prompt `Saved in Keychain`), `Save`,
  `Remove token and disconnect` (destructive). Footer `Your own receipts backend. Photos are sent there and read by it;
  this phone has no AI of its own. The token is stored in the iOS Keychain.`
- Test: `Test connection` (busy `Testing…`).
- `Sync`: `Last sync` value (`LabData.lastSync`, or `Never`), `Not sent yet` `2 change(s)`, `Refused by the server` `1
  record(s)` plus `Edit such a record again to send it again.`, an error line when there is one, `Sync now` (busy
  `Syncing…`). Footer `Syncs when the app opens, shortly after edits, and when you pull the list down.`
- `Photos`: `Cached photos` value (`LabData.cachedPhotos`), `Clear cached photos` (destructive). Footer `This phone keeps
  up to 300 MB of receipt photos, oldest dropped first. The permanent photo archive is on your laptop: this phone never
  archives photos or releases the server's copy.`
- `About`: `Item categories (the dictionary) are edited on the Mac; changes sync here.`

### `settingsUnconfigured`
Empty URL (placeholder `https://receipts.example.com`), token prompt `Paste the token`, `Save` and `Test connection`
disabled, no disconnect, no `Sync` section.

### `settingsInvalidURL` (:37)
Red under the fields: `Not a valid address. Use https://… (plain http:// works for localhost in debug builds only).`
Save disabled. (Release builds omit the bracket.)

### `settingsTestOK` (:84)
Under the test button, `checkmark.circle` and `LabData.connectionOK`. Also used for `Saved. Syncing…`.

### `settingsTestFailed`
`xmark.octagon`, red, `LabData.connectionFailed`. Other production messages: `That is not a valid server URL.`, `Save the
receipts token first.`, `The token could not be saved to the Keychain.`

### `dialogClearCache` (:137)
Title `Clear cached photos?` Message `Receipts keep their data. A photo the server still holds is downloaded again when
you open it; one that is only on your laptop shows “This photo is on your laptop”.` Buttons `Clear cached photos`
(destructive), `Cancel`.

## Not on iOS (do not design these)
Export, dictionary editor, AI backend settings, Re-categorize items, upload drop zone, the review page, give up and
archive the photo. All Mac only (`project.yml:43-59` excludes those views).
