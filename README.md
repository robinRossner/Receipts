# Receipts

A native macOS port of the `Receipts_process` project (Python + FastAPI + browser dashboard) -
same look, same functionality, but a single Swift app with no server process, no browser tab,
and no Python to install.

## Run it

1. Open **`Receipts.xcodeproj`** in Xcode (double-click it, or File ▸ Open).
2. Press ⌘R.

That's it - this is a normal Xcode App project (not a Swift Package), so it builds into a real
`.app` with its own icon and Dock presence, just like any other Mac app. On first run Xcode may
ask you to pick a signing team for local development - any personal team, or "Sign to Run
Locally", works fine.

(`Package.swift` is still in this folder too, purely so I can keep iterating from the command
line with `swift build` - you don't need it. Both point at the exact same `Sources/` files.)

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

**Settings ▸ Cloud sync** connects the app to the shared backend (`docs/api/receipts.md` in the repo
root): server URL, the receipts token (kept in the Keychain), a switch and *Test connection*. With the
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
`backend/apps/receipts/migrate_mac_data.py` derives from it (`LegacyIDs`, pinned by tests), so the first
sync against a migrated server creates no duplicates. Edits are tracked by SQLite triggers
(`Sync/SyncSchema.swift`).

The sync code lives in `Sources/ReceiptsApp/Sync/` and uses no AppKit, so the iOS app can share it.

## Tests

`swift test` (unit tests: UUID compatibility, schema migration and triggers, last-write-wins, upload queue,
archive never confirming on a mismatch or full disk, atomic writes, coordinator). `RECEIPTS_APP_DATA_DIR`
moves the app's data directory (tests use temp dirs; never the real one).

`Tests/run-e2e.sh` runs the Swift sync engine against the real backend (uvicorn from a temp var dir, dummy
token, no Claude credentials, extraction finished through the backend's fake provider): migrate Mac data
with `migrate_mac_data.py`, first sync without duplicates, upload, pull, download, confirm, server file gone,
local file intact. Needs `uv` and the backend's venv (`cd backend && uv sync`).
