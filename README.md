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
