# Switching Between ShopLens and CookShop Environments

## Overview

The mobile app supports two backend environments:

| | ShopLens Dev | CookShop Dev |
|---|---|---|
| GCP Project | `shoplens-dev-499700` | `cookshop-dev-prj` |
| Firebase Project | `shoplens-dev-499700` | `cookshop-dev-prj-bd7e2` |
| Android App ID | `com.shoplens.app` | `com.cookshop.mvp` |
| Analyzer | `ai-analyzer-935092313069.us-central1.run.app` | `ai-analyzer-82592393149.us-central1.run.app` |
| Matcher | `product-matcher-935092313069.us-central1.run.app` | `product-matcher-82592393149.us-central1.run.app` |
| State Manager | `state-manager-935092313069.us-central1.run.app` | `state-manager-82592393149.us-central1.run.app` |
| Voice Assistant | `voice-assistant-935092313069.us-central1.run.app` | `voice-assistant-82592393149.us-central1.run.app` |

---

## Files to change when switching

### 1. `mobile/android/app/build.gradle`

Change `applicationId` in the `defaultConfig` block:

```groovy
// ShopLens
applicationId "com.shoplens.app"

// CookShop
applicationId "com.cookshop.mvp"
```

### 2. `mobile/android/app/google-services.json`

Swap the file for the target environment:

| Environment | Source file |
|---|---|
| ShopLens Dev | `mobile/android/app/google-services.json` (the default — keep in git) |
| CookShop Dev | `mobile/android/app/google-services.cookshop-dev.json` → copy over `google-services.json` |

> Both `google-services.json` and `google-services.cookshop-dev.json` are in `.gitignore` — store them securely (e.g. 1Password, team vault).

### 3. Build command

```bash
# ShopLens Dev
cd mobile
flutter build apk --release

# CookShop Dev
cd mobile
bash scripts/build-cookshop-dev-apk.sh
# — or manually:
flutter build apk --release --dart-define-from-file=.dart_define/cookshop-dev.json
```

The build script (`scripts/build-cookshop-dev-apk.sh`) handles the `google-services.json` swap automatically and restores it after the build.

---

## How it works

- **Service URLs** — `mobile/.dart_define/cookshop-dev.json` overrides the values in `mobile/.env` at compile time via `--dart-define-from-file`. The `.env` file is never modified.
- **Firebase options** — `firebase_options.dart` reads `String.fromEnvironment` for all platforms, with ShopLens values as defaults. The cookshop-dev JSON supplies the overrides.
- **`google-services.json`** — consumed by the Gradle `google-services` plugin at build time. Must match the `applicationId` registered in the target Firebase project.

---

## CookShop Dev — GCP notes

The voice-assistant service has two cross-project dependencies that required one-time setup:

1. **Cloud Run IAM** — `voice-assistant` in `cookshop-dev-prj` must allow unauthenticated invocations (Firebase token auth is handled at the application level).
2. **Firestore cross-project access** — the Cloud Run service account (`82592393149-compute@developer.gserviceaccount.com`) was granted `roles/datastore.user` on `cookshop-dev-prj-bd7e2` so it can read/write `UserProfiles`.
3. **`FIRESTORE_PROJECT_ID` env var** — set to `cookshop-dev-prj-bd7e2` on the voice-assistant Cloud Run service so Firebase Admin SDK validates tokens against the correct Firebase project (not the GCP project `cookshop-dev-prj`).
