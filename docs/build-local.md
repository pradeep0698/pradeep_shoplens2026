# Local Build Commands — Backend (Cloud Run) + Mobile (APK)

This is a command reference for building/deploying this repo from your own machine. There
is **no CI/CD** — `.github/workflows/` does not exist (verified 2026-06-21) and `codemagic.yaml`
only builds an unsigned iOS IPA. Every Cloud Run deploy and every APK build so far has been
run manually from a developer machine or Cloud Shell. If you need full env var values,
project IDs, or secrets, see [docs/local-setup.md](local-setup.md) and
[docs/shop-lens-dev-details.md](shop-lens-dev-details.md) first — this doc only covers the
*build/deploy commands themselves*.

---

## 1. Prerequisites

- `gcloud` CLI, authenticated: `gcloud auth login` and `gcloud config set project shoplens-dev-499700`
- Docker is **not** required locally — `gcloud run deploy --source .` uploads source to
  **Google Cloud Build**, which builds the container image remotely (no local Docker daemon
  needed, but you do need `cloudbuild.googleapis.com` and `artifactregistry.googleapis.com`
  enabled on the project — see [docs/shop-lens-cloud-setup.md](shop-lens-cloud-setup.md))
- Flutter SDK + Dart, for the mobile app
- Android SDK / `ANDROID_HOME` set up (comes with Android Studio), for APK builds

Common values used below:

```bash
export PROJECT_ID=shoplens-dev-499700
export REGION=us-central1
export SA_EMAIL=shoplens-runner@${PROJECT_ID}.iam.gserviceaccount.com
```

---

## 2. Building & Deploying Cloud Run Services (Google Cloud Build)

Each service under `services/*` is a plain FastAPI app with its own `Dockerfile`. There is no
separate "build" step — `gcloud run deploy --source .` does it all: it zips the directory,
uploads it to Cloud Build, Cloud Build builds the image from the `Dockerfile` and pushes it to
Artifact Registry (`shoplens` repo, created in cloud setup), then Cloud Run deploys the new
revision. This is the **only** way these services have been built/deployed so far — there is
no `cloudbuild.yaml`, no GitHub Actions, no manual `docker build`.

You can watch the build itself in **Cloud Console → Cloud Build → History**, or stream it from
the CLI by leaving off `--async` (default — the command blocks and tails Cloud Build logs).

### `ai-analyzer`

```bash
export SERPAPI_KEY=<current key — ask the project owner>

cd services/ai-analyzer
gcloud run deploy ai-analyzer \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated \
  --set-env-vars="PROJECT_ID=$PROJECT_ID,LOCATION=$REGION,GEMINI_MODEL=gemini-2.5-pro,GCS_LENS_BUCKET=shoplens-dev-lens-tmp,SERPAPI_KEY=$SERPAPI_KEY"
cd ../..
```

### `product-matcher`

```bash
cd services/product-matcher
gcloud run deploy product-matcher \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated --set-env-vars="SERPAPI_KEY=$SERPAPI_KEY"
cd ../..
```

### `state-manager`

```bash
cd services/state-manager
gcloud run deploy state-manager \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated --set-env-vars="PROJECT_ID=$PROJECT_ID,SESSION_ID=live-session-001"
cd ../..
```

`ai-analyzer`, `product-matcher`, and `state-manager` use `--allow-unauthenticated` because the
browser and mobile app call them directly without a Google auth token.

### `pubsub-worker` (locked down — not public)

Only the Pub/Sub push subscription calls this one, so it's deployed **without**
`--allow-unauthenticated`:

```bash
export PUSH_ENDPOINT="https://pubsub-worker-935092313069.us-central1.run.app/pubsub"

cd services/pubsub-worker
gcloud run deploy pubsub-worker \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --no-allow-unauthenticated \
  --set-env-vars="PROJECT_ID=$PROJECT_ID,TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=shoplens-dev-hls-segments,PUSH_ENDPOINT=$PUSH_ENDPOINT,AI_ANALYZER_URL=https://ai-analyzer-935092313069.us-central1.run.app,PRODUCT_MATCHER_URL=https://product-matcher-935092313069.us-central1.run.app,STATE_MANAGER_URL=https://state-manager-935092313069.us-central1.run.app,SESSION_ID=live-session-001"
cd ../..
```

Current deployed URLs are listed in [docs/shop-lens-dev-details.md](shop-lens-dev-details.md).

### Building the image only, without deploying

If you just want Cloud Build to build+push the image (e.g. to test the Dockerfile) without
touching the running Cloud Run revision:

```bash
cd services/ai-analyzer
gcloud builds submit --tag $REGION-docker.pkg.dev/$PROJECT_ID/shoplens/ai-analyzer .
cd ../..
```

### Running a service's Dockerfile locally (no Cloud Build, sanity check only)

```bash
cd services/ai-analyzer
docker build -t ai-analyzer-local .
docker run -p 8081:8080 --env PROJECT_ID=$PROJECT_ID --env LOCATION=$REGION ai-analyzer-local
cd ../..
```

For day-to-day local dev, running `uvicorn main:app --reload --port 8081` directly (see
[docs/local-setup.md](local-setup.md) §7) is faster than rebuilding a container each time.

---

## 3. Building the Frontend (Next.js → Firebase Hosting)

Not Cloud Build — Firebase Hosting deploys are a separate local build + `firebase deploy`:

```bash
cd frontend
npm install
npm run build              # produces out/
firebase login
firebase use $PROJECT_ID   # update .firebaserc first if needed
firebase deploy --only hosting
cd ..
```

---

## 4. Building the Mobile App (Flutter → APK)

```bash
cd mobile
flutter pub get
flutter build apk --release
cd ..
```

Output: `mobile/build/app/outputs/flutter-apk/app-release.apk`

Other relevant build variants:

```bash
flutter build apk --debug              # debug APK, faster build, not optimized
flutter build appbundle --release      # .aab for Play Store upload
flutter build apk --release --split-per-abi   # smaller per-architecture APKs
```

**Signing note:** `mobile/android/app/build.gradle` currently sets
`signingConfig signingConfigs.debug` for the `release` build type — there is no real release
keystore configured yet. `flutter build apk --release` will succeed and produce an installable
APK, but it's signed with the Flutter debug key, not a production signing key. Don't upload
this artifact to the Play Store as-is.

### Required setup before building

The APK build needs the same config files as `flutter run` (see
[docs/local-setup.md](local-setup.md) §4 and §6):

| File | Source |
|---|---|
| `mobile/.env` | copy from `mobile/.env.example`, fill in the 3 Cloud Run URLs |
| `mobile/android/app/google-services.json` | get from project owner or regenerate via `flutterfire configure` |

```bash
cd mobile
cp .env.example .env   # then fill in ANALYZER_API_URL / MATCHER_API_URL / STATE_API_URL
# place google-services.json at android/app/google-services.json
flutter build apk --release
cd ..
```

### Building via Codemagic (iOS only, currently)

[codemagic.yaml](../codemagic.yaml) at the repo root defines an `ios-unsigned` workflow that
builds an unsigned iOS `.ipa` (no code signing) from `mobile/`. There is no equivalent Android
workflow in Codemagic — Android builds are done with `flutter build apk` directly as above.

### Bumping the app version

When cutting a new release, update both (see [docs/version.md](version.md)):

1. `mobile/pubspec.yaml` — the `version:` field
2. `mobile/lib/presentation/screens/about_screen.dart` — the hardcoded `'Version X.Y.Z'`
   string shown on the About screen (intentionally not derived from `pubspec.yaml` or
   `PackageInfo` at build time — see docs/version.md for why)

---

## 5. Known Gaps

- No CI/CD: all of the above is run by hand. `README.md` and `docs/shop-lens-cloud-setup.md`
  reference a `deploy-cloudrun.yml` / `build-android.yml` / `build-ios.yml` that don't exist.
- No production Android signing key — release APKs are debug-signed (§4 above).
- `gcloud run deploy --source .` requires Cloud Build + Artifact Registry APIs enabled and the
  `shoplens` Artifact Registry repo to already exist (one-time setup, see
  [docs/shop-lens-cloud-setup.md](shop-lens-cloud-setup.md) Part 1, steps 2 & 4).
