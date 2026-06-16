# ShopLens — GCP + Firebase Dev Platform Setup

Single dev environment: GCP project `shoplens-dev-prj`, one GitHub Environment `dev`.

---

## Part 1 — Google Cloud Project & Firebase

Run in Cloud Shell or locally with `gcloud` authenticated.

```bash
# ── 1. Create the GCP project ──────────────────────────────────────────────
export PROJECT_ID=shoplens-dev-prj
export REGION=us-central1
export BILLING_ACCOUNT=$(gcloud billing accounts list --format="value(name)" --limit=1)

gcloud projects create $PROJECT_ID --name="ShopLens Dev"
gcloud billing projects link $PROJECT_ID --billing-account=$BILLING_ACCOUNT
gcloud config set project $PROJECT_ID

# ── 2. Enable all required APIs ────────────────────────────────────────────
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  firestore.googleapis.com \
  pubsub.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  storage.googleapis.com \
  livestream.googleapis.com \
  aiplatform.googleapis.com \
  firebase.googleapis.com \
  firebaserules.googleapis.com \
  speech.googleapis.com \
  vision.googleapis.com \
  secretmanager.googleapis.com \
  eventarc.googleapis.com

# ── 3. Create service account for Cloud Run runtime ────────────────────────
gcloud iam service-accounts create shoplens-runner \
  --display-name="ShopLens Cloud Run Runner" \
  --project=$PROJECT_ID

export SA_EMAIL=shoplens-runner@${PROJECT_ID}.iam.gserviceaccount.com

for ROLE in \
  roles/run.admin \
  roles/run.invoker \
  roles/pubsub.publisher \
  roles/pubsub.subscriber \
  roles/datastore.user \
  roles/aiplatform.user \
  roles/storage.objectAdmin \
  roles/livestream.admin \
  roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$ROLE"
done

# Allow SA to act as itself (required for Cloud Run deployment)
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser"

# ── 4. Create Artifact Registry repository ─────────────────────────────────
gcloud artifacts repositories create shoplens \
  --repository-format=docker \
  --location=$REGION \
  --project=$PROJECT_ID

# ── 5. Create GCS bucket for HLS segments ─────────────────────────────────
gcloud storage buckets create gs://shoplens-dev-hls-segments \
  --project=$PROJECT_ID \
  --location=$REGION \
  --uniform-bucket-level-access

# Public read required for HLS playback in the browser
gcloud storage buckets add-iam-policy-binding gs://shoplens-dev-hls-segments \
  --member=allUsers --role=roles/storage.objectViewer

# ── 6. Create GCS bucket for Google Lens temp images ──────────────────────
gcloud storage buckets create gs://shoplens-dev-lens-tmp \
  --project=$PROJECT_ID \
  --location=$REGION \
  --uniform-bucket-level-access

# Public read required so SerpApi can fetch the temp image URL
gcloud storage buckets add-iam-policy-binding gs://shoplens-dev-lens-tmp \
  --member=allUsers --role=roles/storage.objectViewer

# SA needs write access to upload and delete temp objects
gcloud storage buckets add-iam-policy-binding gs://shoplens-dev-lens-tmp \
  --member="serviceAccount:${SA_EMAIL}" --role=roles/storage.objectAdmin

# Auto-expire anything the delete step missed after 1 day
cat > lifecycle.json <<'EOF'
{"rule":[{"action":{"type":"Delete"},"condition":{"age":1,"matchesPrefix":["lens-tmp/"]}}]}
EOF
gcloud storage buckets update gs://shoplens-dev-lens-tmp --lifecycle-file=lifecycle.json
rm lifecycle.json

# ── 7. Create Firestore database ───────────────────────────────────────────
gcloud firestore databases create \
  --location=$REGION \
  --project=$PROJECT_ID

# ── 8. Create Pub/Sub topic ────────────────────────────────────────────────
# Subscription is created automatically by deploy-cloudrun.yml after pubsub-worker is deployed
gcloud pubsub topics create video-segments-topic --project=$PROJECT_ID

# ── 9. Set up Workload Identity Federation for GitHub Actions ──────────────
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
export GITHUB_ORG=suryaraor
export GITHUB_REPO=shoplens

gcloud iam workload-identity-pools create github-pool \
  --location=global \
  --display-name="GitHub Actions Pool" \
  --project=$PROJECT_ID

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor" \
  --attribute-condition="assertion.repository=='${GITHUB_ORG}/${GITHUB_REPO}'" \
  --project=$PROJECT_ID

gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}"

# ── Print values needed for GitHub secrets ────────────────────────────────
echo ""
echo "=== Copy these into GitHub Secrets ==="
echo "WIF_PROVIDER: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/providers/github-provider"
echo "WIF_SERVICE_ACCOUNT: ${SA_EMAIL}"
echo "SA_EMAIL: ${SA_EMAIL}"
```

---

## Part 2 — Firebase Console (manual, ~10 minutes)

1. Go to [console.firebase.google.com](https://console.firebase.google.com)
2. **Add project** → select existing GCP project `shoplens-dev-prj` → Continue
3. **Build → Authentication** → Get started → enable **Email/Password**
4. **Build → Hosting** → Get started → follow the wizard
5. **Project Settings → Your apps → Add app → Web (`</>`)**
   - App name: `ShopLens Web`
   - Check **Also set up Firebase Hosting**
   - Copy the `firebaseConfig` values — needed for GitHub secrets below
6. **Project Settings → Your apps → Add app → Android**
   - Package name: `com.shoplens.app`
   - Download `google-services.json` → place at `mobile/android/app/google-services.json`
7. **Project Settings → Your apps → Add app → iOS**
   - Bundle ID: `com.shoplens.app`
   - Download `GoogleService-Info.plist` → place at `mobile/ios/Runner/GoogleService-Info.plist`

---

## Part 3 — GitHub Environment: `dev`

Go to **github.com/suryaraor/shoplens → Settings → Environments → New environment** and name it `dev`.

### Secrets

| Name | Value |
|---|---|
| `WIF_PROVIDER` | Output from Part 1 step 9 |
| `WIF_SERVICE_ACCOUNT` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| `SA_EMAIL` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| `NEXT_PUBLIC_FIREBASE_API_KEY` | Firebase Console → Project Settings → Web app → `apiKey` |
| `SERPAPI_KEY` | Your key from serpapi.com |
| `GOOGLE_SERVICES_JSON` | base64 of `mobile/android/app/google-services.json` (see below) |
| `GOOGLE_SERVICE_INFO_PLIST` | base64 of `mobile/ios/Runner/GoogleService-Info.plist` (see below) |
| `MOBILE_ENV` | base64 of `mobile/.env` (see below) |

### Variables

| Name | Value |
|---|---|
| `PROJECT_ID` | `shoplens-dev-prj` |
| `FIREBASE_PROJECT_ID` | `shoplens-dev-prj` |
| `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | `shoplens-dev-prj` |
| `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | `shoplens-dev-prj.firebaseapp.com` |
| `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | `shoplens-dev-prj.firebasestorage.app` |
| `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | Firebase Console → Project Settings → Web app |
| `NEXT_PUBLIC_FIREBASE_APP_ID` | Firebase Console → Project Settings → Web app |
| `BUCKET_NAME` | `shoplens-dev-hls-segments` |
| `GCS_LENS_BUCKET` | `shoplens-dev-lens-tmp` |
| `SESSION_ID` | `live-session-001` |
| `AI_ANALYZER_URL` | *(fill after first Cloud Run deploy)* |
| `PRODUCT_MATCHER_URL` | *(fill after first Cloud Run deploy)* |
| `STATE_MANAGER_URL` | *(fill after first Cloud Run deploy)* |
| `HLS_STREAM_URL` | *(fill after Live Stream channel setup)* |

### Encoding secrets (run from repo root)

**macOS/Linux:**
```bash
base64 -w0 mobile/android/app/google-services.json
base64 -w0 mobile/ios/Runner/GoogleService-Info.plist
base64 -w0 mobile/.env
```

**Windows PowerShell:**
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("mobile\android\app\google-services.json"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("mobile\ios\Runner\GoogleService-Info.plist"))
[Convert]::ToBase64String([IO.File]::ReadAllBytes("mobile\.env"))
```

Paste each output string as the secret value.

---

## Part 4 — After First Cloud Run Deploy

Once `deploy-cloudrun.yml` runs successfully, go to **Cloud Console → Cloud Run** and copy the URLs for each service, then update the three GitHub Variables:

```
AI_ANALYZER_URL     → https://ai-analyzer-<hash>-uc.a.run.app
PRODUCT_MATCHER_URL → https://product-matcher-<hash>-uc.a.run.app
STATE_MANAGER_URL   → https://state-manager-<hash>-uc.a.run.app
```

The Pub/Sub push subscription endpoint is wired automatically by `deploy-cloudrun.yml` as a post-deploy step.

---

## Part 5 — Live Stream Setup (one-time, before a show)

```bash
cd services/live-ingest
pip install google-cloud-video-live-stream python-dotenv
cp .env.example .env   # fill in PROJECT_ID, LOCATION, BUCKET_NAME, CHANNEL_ID, INPUT_ID
python setup_live_stream.py
```

The script prints two values:
- **RTMP ingest URI** — configure OBS or your encoder to stream here
- **HLS manifest URL** — add this as the `HLS_STREAM_URL` GitHub Variable and update `NEXT_PUBLIC_HLS_STREAM_URL` in `frontend/.env.local`
