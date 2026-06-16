# App Version Display

**Scope:** `mobile/` — the "About" screen (`/about`) on Android, iOS, and Web.
**Last updated:** 2026-06-15

---

## 1. The problem

The About screen showed `Version ${ApiConstants.appVersion}`, which read
`dotenv.env['APP_VERSION']` and fell back to a hardcoded `'1.0.0'` if that
key was missing.

`APP_VERSION` was only ever set by CI (`build-android.yml` and
`codemagic.yaml`), which `grep`'d `pubspec.yaml` and stamped the result into
`.env` at build time. Any local/dev build (`flutter run`, manual
`flutter build apk`, the Flutter web build used for Firebase Hosting) had no
`APP_VERSION` in `.env`, so it always displayed the stale hardcoded
`1.0.0` — regardless of platform.

An attempted fix used [`package_info_plus`](https://pub.dev/packages/package_info_plus)
(`PackageInfo.fromPlatform()`) to read the version from each platform's build
artifact at runtime. This worked when `pubspec.yaml`'s `version:` field had a
`+build` suffix (e.g. `1.19.0+1`), but broke as soon as the suffix was
dropped (e.g. `version: 1.26.0`): with no build number, the Flutter Gradle
plugin leaves `flutter.versionCode` unset in `android/local.properties`, and
Android falls back to its own defaults for **both** `versionCode` and
`versionName` (`1`/`1.0.0`) — ignoring `pubspec.yaml` entirely. The About
screen then showed `Version 1.0.0 (1)` regardless of the real app version.

## 2. The fix

The About screen now shows a **hardcoded literal version string**
(`mobile/lib/presentation/screens/about_screen.dart`), independent of
`pubspec.yaml`, `PackageInfo`, or any build-time stamping:

```dart
const Text(
  'Version 1.26.0',
  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 15),
),
```

This is simple, has no platform-specific build-config dependencies, and
always shows exactly what was intended for the release — no risk of the
Android `versionCode`/`versionName` fallback described above silently
breaking the display again.

## 3. Bumping the version

When cutting a new release, update **both**:

1. `mobile/pubspec.yaml` — the `version:` field, for consistency/tooling.
2. `mobile/lib/presentation/screens/about_screen.dart` — the literal
   `'Version X.Y.Z'` string shown on the About screen.

## 4. Validating

```bash
cd mobile
flutter test test/about_screen_test.dart
```

This widget test asserts the About screen renders the expected
`"Version X.Y.Z"` string. After building for any platform
(`flutter build apk --release`, `flutter build ios`, `flutter build web`),
open the app → menu → **About** and confirm it matches.
