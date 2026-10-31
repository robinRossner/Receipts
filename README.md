# Receipts

A native macOS port of the `Receipts_process` project (Python + FastAPI + browser dashboard) -
same look, same functionality, but a single Swift app with no server process, no browser tab,
and no Python to install.

> **Where things live.** This repo holds the Mac and iPhone apps (root) and the paused Android app (`android/`).
> The server they sync with (the receipts backend) is **not** here: its code is in the FitnessBuddy repo at
> `backend/apps/receipts`, the API contract is `docs/api/receipts.md` there, and deploys happen from that repo
> (default location `~/Projects/FitnessBuddy`). The e2e tests below start that server from a temp var dir and find it
> through `RECEIPTS_BACKEND_DIR` (default `$HOME/Projects/FitnessBuddy/backend`).

## Run it

1. Open **`Receipts.xcodeproj`** in Xcode (double-click it, or File ▸ Open).
2. Press ⌘R.

That's it - this is a normal Xcode App project (not a Swift Package), so it builds into a real
`.app` with its own icon and Dock presence, just like any other Mac app. On first run Xcode may
ask you to pick a signing team for local development - any personal team, or "Sign to Run
Locally", works fine.

(`Package.swift` is still in this folder too, purely so I can keep iterating from the command
line with `swift build` - you don't need it. Both point at the exact same `Sources/` files.)

`Receipts.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and the
generated project is committed, so opening it needs no tools; after changing `project.yml` run `xcodegen generate`.
It holds the Mac app (`ReceiptsApp`) and the iPhone app (`ReceiptsiOS`, below).

The Mac app keeps its data in `~/Library/Application Support/ReceiptsApp/` (receipts.db, receipts_archive/,
classification_log.jsonl).

## Requirements

- [Ollama](https://ollama.com) running locally with:
  - `qwen2.5vl:7b` (receipt photo -> structured data)
  - `qwen2.5:7b-instruct` (item categorization + translation)

  The app checks for Ollama on launch and starts it automatically if it's not already running
  (`ollama serve`); it never stops it on quit, since Ollama may be shared with other apps.

## What changed vs. the Python version

- Document scanning (find + straighten the receipt) uses Vision's built-in document
  segmentation instead of DocAligner + OpenCV.
- Both LLM calls go straight to Ollama's local HTTP API instead of through the Python `ollama`
  client.
- Data is stored via a small native SQLite wrapper - same schema, same file format.
- There's no "Stop" button (that only existed to kill the old FastAPI process) - just quit the
  app normally.
- HEIC photos from iPhones now work; the old pipeline had `pillow_heif` installed but never
  registered it, so `.heic` uploads silently failed.
- You can select or drop several receipt photos at once - they're processed one after another,
  in order, with a "Reading receipt N of M" progress label.
- Uploading no longer freezes the rest of the app - the scan/LLM/save pipeline for one receipt
  now runs off the main thread, so you can keep browsing and editing other receipts while a
  photo is being processed.

## Cloud sync (optional)

**Settings ▸ Cloud sync** connects the app to the shared backend (`docs/api/receipts.md` in the
FitnessBuddy repo): server URL, the receipts token (kept in the Keychain), a switch and *Test connection*. With the
switch **off** nothing changes: everything is local and photos are read by the AI backend you chose.
With it **on**:

- New photos are straightened on this Mac (`DocumentScanner`), converted to a JPEG of about 2500 px
  under 5 MB and uploaded (idempotently, by receipt UUID); the **server** reads them and the result
  arrives through sync. Receipts show *waiting / reading / failed* with retry; a failed one can be filled
  in by hand or explicitly given up on ("Give up and archive the photo"), the only way `accept_failed` is sent.
- Receipts, items and the item dictionary sync both ways: push, then pull with a stored cursor, last write
  wins per record, deletes are tombstones. It runs at launch, shortly after edits, every 15 minutes, on
  **⇧⌘R / Sync now**, and retries failures by itself (status in the top bar, no alerts).
- **This Mac is the permanent photo archive** (device id `macbook-archive`). After each sync it lists the
  photos the server still holds, downloads each, writes it into `receipts_archive/` (temp file, `F_FULLFSYNC`,
  rename), re-reads the saved file and hashes it, and only if that equals the server's sha256 (and the
  extraction is finished) sends `archive-confirm`, after which the server deletes its copy. Mismatch or full
  disk: nothing is confirmed, it retries next time.
- Banners show the server's `archive_overdue` / `disk_warning`; a local notification (and banner) appears
  when the Mac has not synced for 30 days.

Existing receipts keep their numeric ids locally; migration 7 gives every row the UUID that
`backend/apps/receipts/migrate_mac_data.py` (FitnessBuddy repo) derives from it (`LegacyIDs`, pinned by tests), so the first
sync against a migrated server creates no duplicates. Edits are tracked by SQLite triggers
(`Sync/SyncSchema.swift`).

The sync code lives in `Sources/ReceiptsApp/Sync/` and uses no AppKit; the iPhone app uses it unchanged.

## iPhone app

`ReceiptsiOS` (bundle id `com.robinrossner.receipts`, iOS 17+, iPhone) is the phone front end of the same backend. It
photographs receipts, the **server** reads them, and the result comes back through sync; there is no AI on the phone
(no Ollama, no Claude CLI, no API key). It shares `Sources/ReceiptsApp/` with the Mac app (sync engine, SQLite store,
models, theme, detail/item/overview views; platform differences sit behind `#if os(...)`), and has its own screens in
`Sources/ReceiptsiOS/`. Files the phone build leaves out are listed under `excludes` in `project.yml`.

- **Setup** (Settings tab): server URL (HTTPS; plain `http://localhost` works in Debug builds only, and Release has no
  App Transport Security exception at all) and the receipts token (iOS Keychain), *Test connection*, then it syncs.
- **Capture**: the VisionKit document camera (finds and straightens the page; a multi-page scan adds only the first
  page, because a receipt is one photo; not available in the simulator) and the photo library (several at once, HEIC
  included). Photos are straightened (`DocumentScanner`, falling back to the upright photo when no outline is found),
  converted to JPEG (at most 2500 px, under 4.5 MB), stored in `uploads_outbox/` and uploaded idempotently by receipt
  UUID, so offline captures wait and uploads resume after a relaunch.
- **Review**: list with search and filters, needs-review first, pull to refresh; detail with Items/Photo tabs, editable
  header, items, categories, add/delete item, *Looks good* moves on to the next receipt; waiting/reading/failed states with
  retry (retry on the phone only re-queues the extraction on the server). Overview with the charts, range picker and
  drill-down. Same colours as the Mac app, with a dark counterpart.
- **Sync** at launch, when the app comes to the foreground, a few seconds after edits, on pull to refresh and every
  15 minutes while open, with the Mac's engine and merge rules. Banners show the server's `archive_overdue` and `disk_warning`.
- **The phone is not the archive.** It never calls `archive/pending`, `archive-confirm` or `archive/sync` and never
  sends `accept_failed`: the sync engine talks to the server through `CapabilityGuardedAPI`, which refuses those calls
  for a device without `SyncCapabilities.archivesPhotos` (tests: `CapabilityTests`). The phone keeps a bounded cache of
  photos (`photo_cache/`, 300 MB, oldest dropped first; uploaded photos go there, others are downloaded when opened). A
  photo the server released to the laptop and that is not cached shows "This photo is on your laptop."
- **Left out of this first version**: editing the item dictionary (Mac only; changes sync to the phone), CSV/JSON export,
  backups, "Give up and archive" for failed receipts (Mac only, it is the only place `accept_failed` is sent),
  re-categorizing items (needs an AI), merging a multi-page scan.

### Run it in the simulator

```
xcodebuild -project Receipts.xcodeproj -scheme ReceiptsiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
or open `Receipts.xcodeproj`, pick the `ReceiptsiOS` scheme and an iPhone, ⌘R. The simulator reaches a backend on the
Mac as `http://localhost:8000` (Debug builds). `RECEIPTS_APP_DATA_DIR` moves the app's data directory.

### Install it on your iPhone

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig` (gitignored) and put your Apple Developer team id in
   `DEVELOPMENT_TEAM`, the same file layout as `ios/` in the FitnessBuddy repo. (That one's team id works here too.)
2. Plug the iPhone in, unlock it, enable **Settings > Privacy & Security > Developer Mode** (iOS 16+, restarts the
   phone), and trust the Mac when asked.
3. In Xcode pick the `ReceiptsiOS` scheme and your iPhone as destination and press ⌘R (or
   `xcodebuild -project Receipts.xcodeproj -scheme ReceiptsiOS -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build`
   and install the app from Xcode's Devices window). The first launch may need **Settings > General > VPN & Device
   Management > Developer App > Trust**. With a free account the app expires after 7 days and must be reinstalled.
4. In the app: Settings tab, enter the server's HTTPS address (`https://<domain>`, no path) and the receipts token
   (`RECEIPTS_API_TOKEN` of the backend), *Save*, *Test connection*. The Release build refuses `http://` addresses.

The Mac stays the photo archive: keep syncing it at least every 30 days (see above).

## Tests

`swift test` (unit tests: UUID compatibility, schema migration and triggers, last-write-wins, upload queue,
archive never confirming on a mismatch or full disk, atomic writes, coordinator). `RECEIPTS_APP_DATA_DIR`
moves the app's data directory (tests use temp dirs; never the real one).

iPhone: `xcodebuild test -project Receipts.xcodeproj -scheme ReceiptsiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ReceiptsiOSTests`
runs the shared unit tests plus the phone's own on the simulator.

`Tests/ios-e2e/run.sh [shots_dir]` is the iPhone end-to-end run: the real backend from a temp var dir (dummy token, no
Claude credentials, extraction finished by `Tests/e2e/seed_extractions.py`) and XCUITests on the `iPhone 17 Pro`
simulator: set up and test the connection, add two photos (JPEG + HEIC added with `simctl addmedia`) from the photo
picker, seed the extraction, edit an item and confirm, check on the server that the edit arrived, let the Mac sync engine
archive the photos (`ArchiveHelperTests`), clear the phone's cached photos and see "on your laptop", then a screen tour
in light and dark mode (screenshots in `shots_dir`). `Tests/ios-e2e/banners.sh` does the same with the server's
archive-overdue and disk-warning thresholds forced on, to see the banners. Needs `uv` + `uv sync` in the FitnessBuddy `backend/` (found via `RECEIPTS_BACKEND_DIR`, default
`$HOME/Projects/FitnessBuddy/backend`, clear error if missing), Xcode and
the simulator; it uses a copy of nothing real (no `backend/var`, no real app data). `MacRenderTests` draws the Mac's
Settings > Cloud sync and main window (with the banners) to PNG files in-process (`MAC_RENDER_DIR=...`).

`Tests/run-e2e.sh` runs the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy
token, no Claude credentials, extraction finished through the backend's fake provider): migrate Mac data
with `migrate_mac_data.py`, first sync without duplicates, upload, pull, download, confirm, server file gone,
local file intact. Needs `uv` and the backend's venv (`uv sync` in the FitnessBuddy `backend/`; `RECEIPTS_BACKEND_DIR`, default
`$HOME/Projects/FitnessBuddy/backend`).
