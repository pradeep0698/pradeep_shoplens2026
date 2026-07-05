# Sunday Prod Release — Step by Step

Deploy directly from `main` to cookshop-dev (Rajan prod). No separate release branch needed.

---

## Platforms

| | Dev | Prod (Rajan) |
|---|---|---|
| Branch | `main` | `main` (deploy directly) |
| GCP Project | `shoplens-dev-499700` | `cookshop-dev-prj` |
| Firebase Project | `shoplens-dev-499700` | `cookshop-dev-prj-bd7e2` |
| Android App ID | `com.shoplens.app` | `com.cookshop.mvp` |
| Project Number | `935092313069` | `82592393149` |

---

## What you need in your vault

Before starting, confirm these files are on your machine (all are gitignored):

- `mobile/android/app/google-services.cookshop-dev.json` — Android Firebase config for cookshop-dev
- `mobile/.dart_define/cookshop-dev.json` — Flutter compile-time overrides (Firebase keys + service URLs)
- `frontend/.env.cookshop-dev` — Frontend env for cookshop-dev (copy to `.env.local` before deploying)
- `services/*/.env.cookshop-dev` — Per-service env files for cookshop-dev Cloud Run

---

## Step 1 — Mobile (Android APK)

Make sure you are on `main` and it is up to date, then run:

```bash
git checkout main && git pull origin main
cd mobile
bash scripts/build-cookshop-dev-apk.sh
```

The script:
1. Swaps in `android/app/google-services.cookshop-dev.json` temporarily
2. Builds with `--dart-define-from-file=.dart_define/cookshop-dev.json` (overrides all service URLs and Firebase config)
3. Restores the original `google-services.json` after build

Output APK: `mobile/build/app/outputs/flutter-apk/app-release.apk`

Distribute the APK to Rajan manually.

**iOS:** Trigger the Codemagic build manually from the Codemagic UI (firebase-cookshop var group) — no branch push needed.

---

## Step 2 — Services deploy (only if changed)

Deploy only the services whose code changed since the last prod release. Check with:

```bash
git log --oneline <last-prod-sha>..main -- services/
```

The `.env.cookshop-dev` files are `KEY=VALUE` format — convert them inline when deploying.
`PORT` is reserved by Cloud Run and must be excluded. Use this pattern for each service:

```bash
VARS=$(grep -v '^#' services/<svc>/.env.cookshop-dev | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//') && \
gcloud run deploy <svc> \
  --project cookshop-dev-prj \
  --region us-central1 \
  --source services/<svc> \
  --set-env-vars "$VARS" \
  --quiet
```

Active services for cookshop-dev (deploy when their code changes):

```bash
# ai-analyzer
VARS=$(grep -v '^#' services/ai-analyzer/.env.cookshop-dev | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//') && \
gcloud run deploy ai-analyzer --project cookshop-dev-prj --region us-central1 --source services/ai-analyzer --set-env-vars "$VARS" --quiet

# product-matcher
VARS=$(grep -v '^#' services/product-matcher/.env.cookshop-dev | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//') && \
gcloud run deploy product-matcher --project cookshop-dev-prj --region us-central1 --source services/product-matcher --set-env-vars "$VARS" --quiet

# state-manager
VARS=$(grep -v '^#' services/state-manager/.env.cookshop-dev | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//') && \
gcloud run deploy state-manager --project cookshop-dev-prj --region us-central1 --source services/state-manager --set-env-vars "$VARS" --quiet

# voice-assistant
VARS=$(grep -v '^#' services/voice-assistant/.env.cookshop-dev | grep '=' | grep -v '^PORT=' | tr '\n' ',' | sed 's/,$//') && \
gcloud run deploy voice-assistant --project cookshop-dev-prj --region us-central1 --source services/voice-assistant --set-env-vars "$VARS" --quiet

```

> **live-ingest and pubsub-worker are NOT deployed to cookshop-dev** — the live video pipeline is not used in the Rajan prod environment. Skip both.

---

## Step 3 — Frontend deploy (only if changed)

```bash
cp frontend/.env.cookshop-dev frontend/.env.local
cd frontend
npm run build
firebase deploy --project prod
```

`firebase deploy --project prod` resolves to `cookshop-dev-prj-bd7e2` via `frontend/.firebaserc`.

---

## Config files at a glance

| File | Tracked in git | Where stored |
|---|---|---|
| `mobile/.dart_define/cookshop-dev.json` | No (gitignored) | Vault / Codemagic `firebase-cookshop` var group |
| `mobile/android/app/google-services.cookshop-dev.json` | No (gitignored) | Vault |
| `frontend/.env.cookshop-dev` | No (gitignored) | Vault |
| `services/*/.env.cookshop-dev` | No (gitignored) | Vault |
| `mobile/.firebaserc` | Yes | In repo — `prod` alias = `cookshop-dev-prj-bd7e2` |
| `frontend/.firebaserc` | Yes | In repo — `prod` alias = `cookshop-dev-prj-bd7e2` |

---

## How platform switching works

### Mobile
- Service URLs and Firebase config come from `--dart-define-from-file=.dart_define/cookshop-dev.json` at compile time
- `google-services.json` (consumed by Gradle) is swapped by the build script
- `firebase_options.dart` reads `String.fromEnvironment` with shoplens-dev as defaults; cookshop-dev JSON supplies all overrides

### Frontend
- All config is in `.env.local` (Next.js reads this at build time)
- Copy `frontend/.env.cookshop-dev` over `.env.local` before running `npm run build` + deploy

### Services (Cloud Run)
- Env vars are set directly on the Cloud Run service via `--set-env-vars-file`
- `PROJECT_ID` differs: most services use `cookshop-dev-prj` (GCP project); `state-manager` uses `cookshop-dev-prj-bd7e2` (Firebase/Firestore project)
- `voice-assistant` has `FIRESTORE_PROJECT_ID=cookshop-dev-prj-bd7e2` separate from `PROJECT_ID=cookshop-dev-prj` because Vertex AI and Firestore live in different projects

---

## Rollback

If something breaks after a release, redeploy from the last known-good commit:

```bash
git checkout <last-good-sha>
cd mobile && bash scripts/build-cookshop-dev-apk.sh
# Re-run gcloud run deploy for affected services from this checkout
git checkout main   # return to main when done
```
