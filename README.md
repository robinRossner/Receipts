# Receipts

A native macOS port of the `Receipts_process` project (Python + FastAPI + browser dashboard) -
same look, same functionality, but a single Swift app with no server process, no browser tab,
and no Python to install.

> **Where things live.** This repo holds the Mac and iPhone apps (root), the paused Android app (`android/`) and the
> server they sync with: `backend/` (FastAPI + SQLite, own `pyproject.toml`, `Dockerfile` and Alembic setup), the API
> contract `docs/api/receipts.md` and the deployment scripts in `deploy/` (see `deploy/README.md`). The e2e tests below
> start that server from a temp var dir; `RECEIPTS_BACKEND_DIR` (default: this repo's `backend/`) points them at another copy.

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

By default the Mac app reads receipts through the **Claude connection**: the `claude` CLI you are already logged in
with (Claude Code), with the model hardcoded to `claude-haiku-5-5` at high effort (`ClaudeModel` in
`Sources/ReceiptsApp/Pipeline/LLMSettings.swift`; why: `docs/decisions.md`). Settings > AI Backend can switch to the Claude
API, a subscription token, or local Ollama. With Cloud sync on, the server does the reading and uses the same model.

- Only for the Ollama backend (or as the fallback when Claude fails): [Ollama](https://ollama.com) running locally with:
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

**Settings ▸ Cloud sync** connects the app to the shared backend (`docs/api/receipts.md`): server URL, the receipts token (kept in the Keychain), a switch and *Test connection*. With the
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

**Flagged categories ("no good category").** When the AI finds no fitting category in the taxonomy for an item it flags the
item instead of forcing a poor fit: the dictionary entry is filed under Other > Miscellaneous > General (so Overview totals
stay valid), `category_flagged` is set and `suggested_category` / `suggested_parent` say what is missing (e.g. "Pet Food" under
"Household > Pets"). The Mac pipeline and the server both do this; the flag syncs with the dictionary entry. A flagged item is
resolved with `ReceiptStore.resolveFlaggedItems(_:to:)` (existing category) or `resolveFlaggedItems(_:addingCategory:)` (adds a
path to the taxonomy, which syncs as `taxonomy_additions`, then files the items there); editing a category the normal way clears the
flag too. List them with `flaggedItems()` / `flaggedGroups()`, count in `flaggedItemCount`. Contract: `docs/api/receipts.md`, "Flagged categories".

Existing receipts keep their numeric ids locally; migration 7 gives every row the UUID that
`backend/receipts/migrate_mac_data.py` derives from it (`LegacyIDs`, pinned by tests), so the first
sync against a migrated server creates no duplicates. Edits are tracked by SQLite triggers
(`Sync/SyncSchema.swift`).

The sync code lives in `Sources/ReceiptsApp/Sync/` and uses no AppKit; the iPhone app uses it unchanged.

## iPhone app

`ReceiptsiOS` (bundle id `com.robinrossner.receipts`, iOS 17+, iPhone) is the phone front end of the same backend. It
photographs receipts, the **server** reads them, and the result comes back through sync; there is no AI on the phone
(no Ollama, no Claude CLI, no API key). It shares `Sources/ReceiptsApp/` with the Mac app (sync engine, SQLite store,
models, the photo view; platform differences sit behind `#if os(...)`), and has its own screens and theme in
`Sources/ReceiptsiOS/`. Files the phone build leaves out are listed under `excludes` in `project.yml`.

- **Setup** (Settings tab): server URL (HTTPS; plain `http://localhost` works in Debug builds only, and Release has no
  App Transport Security exception at all) and the receipts token (iOS Keychain), *Test connection*, then it syncs.
- **Capture**: the VisionKit document camera (finds and straightens the page; a multi-page scan adds only the first
  page, because a receipt is one photo; not available in the simulator) and the photo library (several at once, HEIC
  included). Photos are straightened (`DocumentScanner`, falling back to the upright photo when no outline is found),
  converted to JPEG (at most 2500 px, under 4.5 MB), stored in `uploads_outbox/` and uploaded idempotently by receipt
  UUID, so offline captures wait and uploads resume after a relaunch.
- **Review**: list with always-visible search, a filter panel, needs-review first with the first reason on the row, a
  review-count tab badge, pull to refresh, swipe right to confirm and left to delete (both with Undo); detail with
  Items/Photo tabs, editable header, compact items that expand to their editor (flagged ones start open), add/delete
  item, *Looks good* moves on to the next receipt; waiting/reading/failed states with retry (retry on the phone only
  re-queues the extraction on the server). Overview with the charts, range picker and drill-down, `Edit` opens the
  receipt with that item open. Its own adaptive light and dark palette (`Sources/ReceiptsiOS/Theme.swift`).
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
   `DEVELOPMENT_TEAM`.
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

`RECEIPTS_MAC_SHOTS=<folder> swift test --filter MacScreensTests` renders the real Mac screens from a temp database, in
light and dark, to PNGs in a window off screen (no permissions needed). `Tests/ios-e2e/seed_flagged.py` seeds a throwaway
e2e backend for `FlagFlowTests` (real taps through "Items without a category") and checks afterwards what reached the server.

`Tests/ios-e2e/run.sh [shots_dir]` is the iPhone end-to-end run: the real backend from a temp var dir (dummy token, no
Claude credentials, extraction finished by `Tests/e2e/seed_extractions.py`) and XCUITests on the `iPhone 17 Pro`
simulator: set up and test the connection, add two photos (JPEG + HEIC added with `simctl addmedia`) from the photo
picker, seed the extraction, edit an item and confirm, check on the server that the edit arrived, let the Mac sync engine
archive the photos (`ArchiveHelperTests`), clear the phone's cached photos and see "on your laptop", then a screen tour
in light and dark mode (screenshots in `shots_dir`). `Tests/ios-e2e/banners.sh` does the same with the server's
archive-overdue and disk-warning thresholds forced on, to see the banners. Needs `uv` + `uv sync` in `backend/` (found via `RECEIPTS_BACKEND_DIR`, default this repo's `backend/`,
clear error if missing), Xcode and the simulator; it uses a copy of nothing real (no `backend/var`, no real app data). `MacRenderTests` draws the Mac's
Settings > Cloud sync and main window (with the banners) to PNG files in-process (`MAC_RENDER_DIR=...`).

`Tests/run-e2e.sh` runs the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy
token, no Claude credentials, extraction finished through the backend's fake provider): migrate Mac data
with `migrate_mac_data.py`, first sync without duplicates, upload, pull, download, confirm, server file gone,
local file intact. Needs `uv` and the backend's venv (`uv sync` in `backend/`; `RECEIPTS_BACKEND_DIR`, default this repo's `backend/`).

## Server (`backend/`)

The sync server is a self-contained FastAPI app: `server.py` (entry point), `receipts/` (API, extraction queue and
worker, LLM providers, sync, photo archive, Mac data migration, Alembic migrations in `receipts/alembic/`) and `core/`
(bearer auth with a failed-token throttle, settings base, db helpers, log redaction, scheduler helper). Routes live under
`/api/v1/receipts/...` plus a public `/health`; every receipts route needs `RECEIPTS_API_TOKEN` (no other token is
accepted). Contract: `docs/api/receipts.md`.

    cd backend
    uv sync
    cp .env.example .env              # optional, see the comments inside (gitignored)
    uv run alembic upgrade head       # creates var/receipts.db
    uv run uvicorn server:app --reload
    uv run pytest -q                  # no network, no real Claude call
    uv run ruff check . && uv run ruff format --check .

State lives in `backend/var/` (`receipts.db`, `receipts_photos/`). Production runs the same code in Docker on a VM
(`deploy/`, runbook in `deploy/README.md`); the production data directory is `/opt/receipts/deploy/data`.
