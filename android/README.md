# Receipts for Android

**Status: paused.** The app is partly built; work stopped so the iPhone UI can be finished first and its changes ported afterwards.

**Server and contract.** This app syncs with the receipts server in this repo's `backend/` (`backend/receipts`), API contract in `docs/api/receipts.md`, deployment in `deploy/`. The repo (`~/Projects/Receipts App`) holds the Mac and iPhone apps at its root and this Android app in `android/`.

Done (compiles, `./gradlew assembleDebug` works, nothing run on a device yet):
- Gradle project (AGP 9.4.1, Kotlin 2.3.21, Compose Material 3, Room, WorkManager, OkHttp, ML Kit Document Scanner), minSdk 26, package `com.robinrossner.receipts`; HTTPS only, plain HTTP to `10.0.2.2`/localhost in debug builds only (debug network security config).
- Wire types, API client, `CapabilityGuardedApi` (the phone never calls archive-pending, archive-confirm, archive/sync, never sends `accept_failed`), server URL rules.
- Room database, offline-first sync engine (upload, push, pull with stored cursor, last write wins, tombstones, `photo_location: none` on push), bounded photo cache (300 MB) with sha256 check on download, photo preparation (EXIF, 2500 px, under 4.5 MB), WorkManager upload job, Keystore-encrypted token.
- Compose screens written but never run: list/search/filters, review detail (Items/Photo tabs, editing, category pickers, Looks good and next), Overview with canvas charts, Settings, banners, warm paper theme (light/dark).

Not done:
- JVM unit tests (sync merge, LWW, tombstones, wire format, capability guard, sha mismatch) and `testDebugUnitTest`, `assembleRelease`, `lint` runs.
- Emulator end-to-end run, screenshots, checking the layouts and the document scanner.
- No AVD created. Release signing notes, install-by-APK and testing sections of this README, the line in the root README.
- Not yet ported from the iPhone: any UI changes made there after this paused.

Build: `JAVA_HOME=<JDK 17> ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug` (needs a `local.properties` with `sdk.dir`, which is gitignored). The APK is `app/build/outputs/apk/debug/app-debug.apk`.
