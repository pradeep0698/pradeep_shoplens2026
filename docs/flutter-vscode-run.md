# Running the Mobile App Locally in VS Code

Quick-reference for getting the `mobile/` Flutter app running on your machine in VS Code —
SDK/extension setup plus the day-to-day `flutter clean` / `pub get` / `run` cycle.

For config files (`.env`, `google-services.json`, etc.) and the deployed dev backend URLs, see
[docs/local-setup.md](local-setup.md). For building release APKs/IPAs, see
[docs/build-local.md](build-local.md). This doc only covers running a debug build locally.

---

## 1. Install the Flutter SDK

1. Download/clone the Flutter SDK: https://docs.flutter.dev/get-started/install/windows
   - Easiest on Windows: clone it directly so you can update with `git pull` later:
     ```bash
     git clone https://github.com/flutter/flutter.git -b stable C:\Users\<you>\flutter
     ```
2. Add `C:\Users\<you>\flutter\bin` to your `PATH` (System Properties → Environment Variables).
3. Open a **new** terminal and verify:
   ```bash
   flutter doctor
   ```
   Resolve anything `flutter doctor` flags (Android SDK / `ANDROID_HOME`, Android Studio
   licenses, Chrome for web, etc.) before continuing. This repo currently builds against:
   ```
   Flutter 3.44.2 • channel stable
   Dart 3.12.2
   ```
   (check `mobile/pubspec.yaml` → `environment.flutter`/`sdk` for the minimum version it
   actually requires).

## 2. Install the VS Code extension

1. Open VS Code → Extensions (`Ctrl+Shift+X`).
2. Install **Flutter** (publisher: Dart Code) — this pulls in the **Dart** extension as a
   dependency automatically.
3. Reload VS Code. Run **Flutter: New Project** once from the Command Palette
   (`Ctrl+Shift+P`) and cancel it, or just open the `mobile/` folder directly — either way
   confirms the extension found your SDK. If it didn't, set it explicitly in
   `.vscode/settings.json` (project root or `mobile/`):
   ```json
   {
     "dart.flutterSdkPath": "C:\\Users\\<you>\\flutter"
   }
   ```

## 3. Open the right folder

Open **`mobile/`** as the VS Code workspace folder (not the repo root) — `pubspec.yaml` lives
there, and that's what the Dart/Flutter extension needs to detect the project and populate the
device-selector / Run-and-Debug dropdowns.

## 4. One-time config (before first run)

The app won't build without these — see [docs/local-setup.md §4](local-setup.md) for where to
get the real values:

```bash
cd mobile
cp .env.example .env   # fill in ANALYZER_API_URL / MATCHER_API_URL / STATE_API_URL / VOICE_ASSISTANT_API_URL
# place android/app/google-services.json (get from project owner, or `flutterfire configure`)
# place ios/Runner/GoogleService-Info.plist (macOS only, for iOS builds)
```

## 5. The run cycle

From `mobile/`:

```bash
flutter pub get        # fetch/sync dependencies (run after any pubspec.yaml change or pull)
flutter run             # build + launch on the selected device/emulator/simulator, with hot reload
```

In VS Code, you can also just press **F5** (or click the device name in the bottom status bar
to pick a target first) — this runs `flutter run` under the debugger.

Useful flags:

```bash
flutter devices                     # list connected devices/emulators
flutter run -d <device-id>          # target a specific device
flutter run --dart-define-from-file=.dart_define/cookshop-dev.json   # point at a specific env (see scripts/build-cookshop-dev-apk.sh)
```

While `flutter run` is active:
- `r` — hot reload
- `R` — hot restart (use when state-shape or native code changed and hot reload doesn't pick it up)
- `q` — quit

### `flutter clean`

Use this when you hit stale-build weirdness (gradle/Xcode cache issues, plugin not picked up
after adding a new package, switching branches with native-dependency changes):

```bash
flutter clean          # deletes build/, .dart_tool/, and platform build caches
flutter pub get         # re-fetch deps — always needed after `clean`
flutter run
```

`flutter clean` does **not** touch `.env`, `google-services.json`, or anything in
`.dart_define/` — those survive and don't need to be re-copied.

## 6. Common gotchas

- **No devices listed**: start an Android emulator from Android Studio's Device Manager, or
  open an iOS Simulator (macOS only), or plug in a physical device with USB debugging enabled.
- **Stuck on old code after a pull**: run `flutter clean && flutter pub get` first — pubspec
  lockfile or native plugin changes don't always hot-reload cleanly.
- **`MissingPluginException` after adding a package**: do a full stop + `flutter run` again
  (not hot reload/restart) — new native plugin bindings only register on a fresh build.
- **Build/signing errors building for Android**: confirm `android/local.properties` has
  `flutter.sdk` pointing at your Flutter install and `sdk.dir` pointing at your Android SDK —
  VS Code/the Flutter extension usually writes this automatically on first run.
