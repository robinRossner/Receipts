# Receipts for Android

The Android twin of the iPhone app: the same warm paper look, the same screens and the same sync with the receipts server in this repo's `backend/` (`backend/receipts`). API contract in `docs/api/receipts.md`, deployment in `deploy/`. The repo (`~/Projects/Receipts App`) holds the Mac and iPhone apps at its root and this Android app in `android/`.

**Status: ported and run end to end on an emulator.** The screens were ported from the iPhone and checked on an API 35 emulator against a throwaway local server, in light and dark mode: first launch and setup, Settings (test connection, save, sync, photo cache), photo upload and extraction, the receipt list (sections, search, filters, swipe to confirm or delete with Undo, recently deleted, Confirm all, pull to refresh), the receipt detail (items, photo, editing, warnings, printed total and difference, review bar), Overview (range, charts, category tree, price history, Edit), the "Without a category" screen, offline editing with a later push, process death and rotation.

What is in it:
- Gradle project (AGP 9.4.1, Kotlin 2.3.21, Compose Material 3, Room, WorkManager, OkHttp, ML Kit Document Scanner), minSdk 26, package `com.robinrossner.receipts`. HTTPS only; plain HTTP to `10.0.2.2` and localhost in debug builds only (debug network security config).
- Wire types, API client, `CapabilityGuardedApi` (the phone never calls archive-pending, archive-confirm or archive/sync and never sends `accept_failed`), server URL rules.
- Room database, offline-first sync engine (upload, push, pull with a stored cursor, last write wins, tombstones, `photo_location: none` on push), a bounded photo cache (300 MB) with a sha256 check on download, photo preparation (EXIF, 2500 px, under 4.5 MB), a WorkManager upload job, a Keystore-encrypted token.
- Compose screens that follow the iPhone's design tokens, fonts, components and texts (list and capture, detail, Overview with canvas charts, Settings, "Without a category"), an adaptive launcher icon, light and dark theme following the system.
- JVM unit tests (sync merge, last write wins, tombstones, wire format, capability guard, checksum mismatch, flagged items, taxonomy, review queue, UI logic, HTTP behaviour).

Not exercised on a device: the ML Kit document scanner (`Scan receipt`; the emulator has no camera pipeline for it, the code path is the library's own screen) and pinch zoom on the Photo tab (needs two fingers; the zoom buttons and double tap work). The release build is unsigned unless you add a keystore (below).

## Build

Needs JDK 17 and the Android SDK. Create `local.properties` (gitignored) with `sdk.dir=/path/to/Android/sdk`, then:

```
export JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home
export ANDROID_HOME=~/Library/Android/sdk
./gradlew :app:assembleDebug :app:assembleRelease :app:testDebugUnitTest :app:lintDebug
```

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`; install it with `adb install -r`.

Release signing: put `keystore.properties` (gitignored) next to `app/build.gradle.kts` with `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. Without it `assembleRelease` produces `app-release-unsigned.apk`, which Android will not install. To put the app on a phone without Play, sign the release APK with your keystore (or install the debug APK) and copy it over, then allow installs from the file manager.

## Try it against a throwaway server (never the real one)

The iPhone end-to-end tests start the real FastAPI server from a temp directory with a dummy token and no Claude credentials; the same server works for the emulator.

1. Start the server and seed it from the repo root (needs `uv` and `uv sync` in `backend/`):
   ```
   Tests/ios-e2e/server.sh start                              # http://localhost:8787, token ios-e2e-dummy-token
   python3 Tests/ios-e2e/seed_flagged.py 8787 ios-e2e-dummy-token   # receipts and items without a category
   Tests/ios-e2e/server.sh seed                               # finishes queued extractions with the scripted fake provider
   swift Tests/e2e/make_sample_receipts.swift /tmp/samples    # two sample receipt photos
   ```
2. Start an emulator (`emulator -avd <your API 35 AVD>`), push the samples (`adb push /tmp/samples/receipt-1.jpg /sdcard/Pictures/`) and install the debug APK. Check first that the real app is not on that device (`adb shell pm list packages | grep robinrossner`): this build syncs whatever server you give it.
3. In the app's Settings enter `http://10.0.2.2:8787` (the emulator's name for the Mac) and the dummy token, then Test connection and Save. The server listens on `127.0.0.1`, which `10.0.2.2` reaches.
4. Choose photos in the Receipts tab; the upload reaches the server, `server.sh seed` finishes the extraction and the next sync pulls the result in.
5. Stop with `Tests/ios-e2e/server.sh stop` (it deletes the temp data). To test offline behaviour use `adb shell cmd connectivity airplane-mode enable`.

On a small default AVD screen, `adb shell wm size 1080x2400` and `adb shell wm density 420` give phone proportions (`wm size reset` and `wm density reset` undo it).

## Known differences from the iPhone

- Material components where the iPhone uses system ones: date and time pickers, dropdown menus, bottom sheets, the system back gesture instead of a back swipe.
- Fonts: the display voice is the device's serif (the iPhone uses American Typewriter), mono and body are the device's monospace and default sans fonts.
- The pinch gesture on the Photo tab zooms about the picture's centre, as the iPhone's scroll view does.
- Ids are UUIDs, so where the iPhone prints a receipt number the Android app prints the first eight characters of the UUID or leaves it out.
