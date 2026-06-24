# Sunday Prod Release — Step by Step

Every Sunday, code on `main` (shoplens-dev) is released to `release/prod` (cookshop-dev / Rajan prod).

---

## Platforms

| | Dev | Prod (Rajan) |
|---|---|---|
| Branch | `main` | `release/prod` |
| GCP Project | `shoplens-dev-499700` | `cookshop-dev-prj` |
| Firebase Project | `shoplens-dev-499700` | `cookshop-dev-prj-bd7e2` |
| Android App ID | `com.shoplens.app` | `com.cookshop.mvp` |
| Project Number | `935092313069` | `82592393149` |

---

## What you need in your vault

Before starting, confirm these files are on your machine (all are gitignored):

- `mobile/android/app/google-services.cookshop-dev.json` — Android Firebase config for cookshop-dev
- `mobile/ios/Runner/GoogleService-Info.plist` — iOS Firebase config (cookshop-dev version, injected by Codemagic)
- `mobile/.dart_define/cookshop-dev.json` — Flutter compile-time overrides (Firebase keys + service URLs)
- `frontend/.env.cookshop-dev` — Frontend env for cookshop-dev (copy to `.env.local` before deploying)
- `services/*/.env.cookshop-dev` — Per-service env files for cookshop-dev Cloud Run

---

## Step 1 — Merge and push code

```bash
git checkout release/prod
git merge main
git push origin release/prod
```

This push automatically triggers the **Codemagic iOS build** (ios-unsigned workflow, firebase-cookshop var group).

---

## Step 2 — Mobile (Android APK)

Build the Android APK for cookshop-dev:

```bash
cd mobile
bash scripts/build-cookshop-dev-apk.sh
```

The script:
1. Swaps in `android/app/google-services.cookshop-dev.json` temporarily
2. Builds with `--dart-define-from-file=.dart_define/cookshop-dev.json` (overrides all service URLs and Firebase config)
3. Restores the original `google-services.json` after build

Output APK: `mobile/build/app/outputs/flutter-apk/app-release.apk`

Distribute the APK to Rajan manually.

---

## Step 3 — Frontend deploy

```bash
cp frontend/.env.cookshop-dev frontend/.env.local
cd frontend
npm run build
firebase deploy --project prod
```

`firebase deploy --project prod` resolves to `cookshop-dev-prj-bd7e2` via `frontend/.firebaserc`.

---

## Step 4 — Services deploy (only if changed)

Most Sundays you can skip this if no service code changed. Deploy only what changed.

```bash
# ai-analyzer
gcloud run deploy ai-analyzer \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/ai-analyzer/.env.cookshop-dev

# product-matcher
gcloud run deploy product-matcher \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/product-matcher/.env.cookshop-dev

# state-manager
gcloud run deploy state-manager \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/state-manager/.env.cookshop-dev

# voice-assistant
gcloud run deploy voice-assistant \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/voice-assistant/.env.cookshop-dev

# pubsub-worker
gcloud run deploy pubsub-worker \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/pubsub-worker/.env.cookshop-dev

# live-ingest (rarely changes)
gcloud run deploy live-ingest \
  --project cookshop-dev-prj \
  --region us-central1 \
  --set-env-vars-file services/live-ingest/.env.cookshop-dev
```

---

## Config files at a glance

| File | Tracked in git | Where stored |
|---|---|---|
| `mobile/.dart_define/cookshop-dev.json` | No (gitignored) | Vault |
| `mobile/android/app/google-services.cookshop-dev.json` | No (gitignored) | Vault |
| `frontend/.env.cookshop-dev` | No (gitignored) | Vault |
| `services/*/.env.cookshop-dev` | No (gitignored) | Vault |
| `mobile/.dart_define/cookshop-dev.json` | No | Codemagic `firebase-cookshop` var group |
| `mobile/.firebaserc` | No (gitignored) | In repo — `prod` alias = `cookshop-dev-prj-bd7e2` |
| `frontend/.firebaserc` | No (gitignored) | In repo — `prod` alias = `cookshop-dev-prj-bd7e2` |

---

## How platform switching works

### Mobile
- Service URLs and Firebase config come from `--dart-define-from-file=.dart_define/cookshop-dev.json` at compile time
- `google-services.json` (consumed by Gradle) is swapped by the build script
- `firebase_options.dart` reads `String.fromEnvironment` with shoplens-dev as defaults; cookshop-dev JSON supplies all overrides
- Codemagic injects `GOOGLE_SERVICE_INFO_PLIST` (base64) and service URL env vars for the iOS build via the `firebase-cookshop` var group

### Frontend
- All config is in `.env.local` (Next.js reads this at build time)
- Copy `frontend/.env.cookshop-dev` over `.env.local` before running `npm run build` + deploy

### Services (Cloud Run)
- Env vars are set directly on the Cloud Run service via `--set-env-vars-file`
- `PROJECT_ID` differs: most services use `cookshop-dev-prj` (GCP project); `state-manager` uses `cookshop-dev-prj-bd7e2` (Firebase/Firestore project)
- `voice-assistant` has `FIRESTORE_PROJECT_ID=cookshop-dev-prj-bd7e2` separate from `PROJECT_ID=cookshop-dev-prj` because Vertex AI and Firestore live in different projects

---

## Rollback

If something is wrong after a Sunday release:

```bash
# Find the last known-good commit on release/prod
git log release/prod --oneline

# Roll back to that commit
git checkout release/prod
git revert HEAD   # or revert to specific commit
git push origin release/prod
# Then re-run Step 3 and Step 4 for the affected layers
```
