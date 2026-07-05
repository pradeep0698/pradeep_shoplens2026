# ShopLens 2026-Dev Platform Setup Guide

**New project:** `shoplens2026-dev`  
**Project ID:** `project-b1a5dd5a-69e6-4db3-9d7`  
**Project Number:** `115535290381`  
**Owner email:** `suryarao.r@gmail.com`  
**Region:** `us-central1`  
**Date:** 2026-06-29

---

## Overview

This guide provisions the full ShopLens infrastructure on a new GCP + Firebase project. It mirrors the existing `shoplens-dev-499700` project with all services: Cloud Run microservices, Firestore, Firebase Auth/Hosting/Storage, Pub/Sub, Vertex AI, Cloud Live Stream, Artifact Registry, and GitHub Actions CI/CD via Workload Identity Federation.

Work through each section in order — some later steps depend on earlier ones.

---

## Prerequisites

```bash
# Authenticate and set account
gcloud auth login suryarao.r@gmail.com
gcloud config set account suryarao.r@gmail.com

# Install firebase CLI if not already installed
npm install -g firebase-tools
firebase login
```

---

## Section 1 — Project Initialization

```bash
# Set the project
gcloud config set project project-b1a5dd5a-69e6-4db3-9d7

# Verify you are owner
gcloud projects get-iam-policy project-b1a5dd5a-69e6-4db3-9d7 \
  --flatten="bindings[].members" \
  --filter="bindings.members:suryarao.r@gmail.com" \
  --format="table(bindings.role)"

# Set a convenience shell variable (run this in every terminal session)
export PROJECT_ID="project-b1a5dd5a-69e6-4db3-9d7"
export PROJECT_NUMBER="115535290381"
export REGION="us-central1"
```

---

## Section 2 — Enable All Required APIs

Enable all 18 APIs in a single batch (takes ~2 minutes):

```bash
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
  eventarc.googleapis.com \
  cloudresourcemanager.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID"
```

Verify all are enabled:

```bash
gcloud services list --enabled --project="$PROJECT_ID" --format="table(name)"
```

---

## Section 3 — Firebase Setup

### 3.1 — Add Firebase to the GCP Project

Go to [Firebase Console](https://console.firebase.google.com) → **Add project** → **Add Firebase to a Google Cloud project** → select `project-b1a5dd5a-69e6-4db3-9d7`.

Or use the CLI:

```bash
firebase projects:addfirebase project-b1a5dd5a-69e6-4db3-9d7
```

### 3.2 — Enable Firebase Authentication

In Firebase Console → Authentication → **Get started** → enable **Email/Password** provider.

Or via REST (after Firebase is added):

```bash
# Enable the Identity Platform (Firebase Auth backend)
gcloud services enable identitytoolkit.googleapis.com --project="$PROJECT_ID"
```

### 3.3 — Create Firestore Database

```bash
gcloud firestore databases create \
  --location=us-central1 \
  --type=firestore-native \
  --project="$PROJECT_ID"
```

### 3.4 — Deploy Firestore Security Rules

From the `frontend/` directory:

```bash
cd frontend
firebase use --add
# When prompted: select project-b1a5dd5a-69e6-4db3-9d7, alias it as "shoplens2026-dev"

firebase deploy --only firestore:rules --project shoplens2026-dev
```

### 3.5 — Firebase Hosting Setup

```bash
# From the frontend/ directory
firebase deploy --only hosting --project shoplens2026-dev
```

Update `frontend/.firebaserc` to add the new project alias:

```json
{
  "projects": {
    "default": "<existing-dev-alias>",
    "shoplens2026-dev": "project-b1a5dd5a-69e6-4db3-9d7"
  }
}
```

### 3.6 — Firebase Storage

Firebase Storage is auto-provisioned when the Firebase project is created.  
Default bucket: `project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app`

Confirm in Firebase Console → Storage → **Get started** → choose `us-central1`.

### 3.7 — Generate Firebase App Config Files

**Web (Next.js frontend):**  
Firebase Console → Project Settings → Your apps → **Add app** → Web.  
Copy the firebaseConfig object into `frontend/.env.shoplens2026-dev`:

```bash
NEXT_PUBLIC_FIREBASE_API_KEY=<from console>
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=project-b1a5dd5a-69e6-4db3-9d7.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=115535290381
NEXT_PUBLIC_FIREBASE_APP_ID=<from console>
```

**Android (Flutter):**  
Firebase Console → Project Settings → Your apps → **Add app** → Android.  
- Android package name: `com.shoplens.app` (match your existing app)  
- Download `google-services.json` → save as `mobile/android/app/google-services.shoplens2026-dev.json`

**iOS (Flutter):**  
Firebase Console → Your apps → **Add app** → Apple.  
- Bundle ID: match existing app bundle ID  
- Download `GoogleService-Info.plist` → save as `mobile/ios/Runner/GoogleService-Info.shoplens2026-dev.plist`

---

## Section 4 — Cloud Storage Buckets

### 4.1 — HLS Segments Bucket

```bash
gcloud storage buckets create gs://shoplens2026-dev-hls-segments \
  --location=us-central1 \
  --project="$PROJECT_ID"

# Allow public read for HLS playback in browser
gcloud storage buckets add-iam-policy-binding gs://shoplens2026-dev-hls-segments \
  --member="allUsers" \
  --role="roles/storage.objectViewer"

# Enable uniform bucket-level access
gcloud storage buckets update gs://shoplens2026-dev-hls-segments \
  --uniform-bucket-level-access
```

### 4.2 — Lens Temp Images Bucket

```bash
gcloud storage buckets create gs://shoplens2026-dev-lens-tmp \
  --location=us-central1 \
  --project="$PROJECT_ID"

# Public read for SerpAPI image fetching
gcloud storage buckets add-iam-policy-binding gs://shoplens2026-dev-lens-tmp \
  --member="allUsers" \
  --role="roles/storage.objectViewer"

# Auto-delete after 1 day
gcloud storage buckets update gs://shoplens2026-dev-lens-tmp \
  --lifecycle-file=/dev/stdin <<'EOF'
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "Delete"},
        "condition": {"age": 1}
      }
    ]
  }
}
EOF
```

---

## Section 5 — Artifact Registry

```bash
gcloud artifacts repositories create shoplens \
  --repository-format=docker \
  --location=us-central1 \
  --description="ShopLens 2026-dev Docker images" \
  --project="$PROJECT_ID"

# Configure Docker auth
gcloud auth configure-docker us-central1-docker.pkg.dev
```

Image paths will be:  
`us-central1-docker.pkg.dev/project-b1a5dd5a-69e6-4db3-9d7/shoplens/<service-name>`

---

## Section 6 — Service Account & IAM

### 6.1 — Create Runtime Service Account

```bash
gcloud iam service-accounts create shoplens-runner \
  --display-name="ShopLens Runtime Service Account" \
  --description="Used by Cloud Run services and GitHub Actions CI/CD" \
  --project="$PROJECT_ID"

export SA_EMAIL="shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com"
```

### 6.2 — Grant IAM Roles

```bash
# Cloud Run
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/run.invoker"

# Pub/Sub
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/pubsub.publisher"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/pubsub.subscriber"

# Firestore
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/datastore.user"

# Vertex AI
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/aiplatform.user"

# Cloud Storage
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectAdmin"

# Cloud Live Stream
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/livestream.admin"

# Secret Manager
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/secretmanager.secretAccessor"

# Artifact Registry (push/pull images)
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/artifactregistry.writer"

# Cloud Build
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/cloudbuild.builds.editor"

# Self-impersonation (required for Cloud Run deployment)
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID"
```

### 6.3 — Grant Cloud Build Service Account Access

Cloud Build needs permission to push to Artifact Registry and deploy to Cloud Run:

```bash
export BUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$BUILD_SA" --role="roles/run.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$BUILD_SA" --role="roles/artifactregistry.writer"

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:$BUILD_SA" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID"
```

---

## Section 7 — Workload Identity Federation (GitHub Actions)

Allows GitHub Actions to deploy Cloud Run services without storing long-lived service account keys.

### 7.1 — Create the Identity Pool

```bash
gcloud iam workload-identity-pools create github-pool \
  --location=global \
  --display-name="GitHub Actions Pool" \
  --description="Workload Identity Pool for GitHub Actions CI/CD" \
  --project="$PROJECT_ID"
```

### 7.2 — Create the OIDC Provider

Replace `YOUR_GITHUB_ORG` and `YOUR_GITHUB_REPO` with your actual values (e.g., `shoplensai-coder/shoplens`):

```bash
export GITHUB_REPO="shoplensai-coder/shoplens"

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub Actions Provider" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.actor=assertion.actor,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
  --project="$PROJECT_ID"
```

### 7.3 — Bind the Service Account to the Pool

```bash
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_REPO}" \
  --project="$PROJECT_ID"
```

### 7.4 — Get the Provider Resource Name (for GitHub secret)

```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --project="$PROJECT_ID" \
  --format="value(name)"
```

Copy the output — it will look like:  
`projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider`

---

## Section 8 — GitHub Actions Secrets

In your GitHub repo → Settings → Secrets and variables → Actions, add:

| Secret name | Value |
|---|---|
| `GCP_PROJECT_ID_2026_DEV` | `project-b1a5dd5a-69e6-4db3-9d7` |
| `GCP_PROJECT_NUMBER_2026_DEV` | `115535290381` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER_2026_DEV` | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_SERVICE_ACCOUNT_2026_DEV` | `shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com` |
| `SERPAPI_KEY` | `<your SerpAPI key>` |

---

## Section 9 — Pub/Sub (Live Video Pipeline)

```bash
# Create topic
gcloud pubsub topics create video-segments-topic --project="$PROJECT_ID"

# Create push subscription (endpoint will be set after pubsub-worker is deployed)
# Run this AFTER Section 10 Cloud Run deployment
gcloud pubsub subscriptions create video-segments-sub \
  --topic=video-segments-topic \
  --push-endpoint="https://pubsub-worker-${PROJECT_NUMBER}.us-central1.run.app/pubsub" \
  --ack-deadline=60 \
  --project="$PROJECT_ID"

# Configure GCS bucket to send notifications to Pub/Sub on new segment uploads
gcloud storage buckets notifications create gs://shoplens2026-dev-hls-segments \
  --topic=video-segments-topic \
  --event-types=OBJECT_FINALIZE \
  --project="$PROJECT_ID"
```

---

## Section 10 — Cloud Run Services

Set your common deploy flags:

```bash
export DEPLOY_FLAGS="--region=us-central1 --service-account=$SA_EMAIL --project=$PROJECT_ID"
```

### 10.1 — ai-analyzer

```bash
cd services/ai-analyzer

gcloud run deploy ai-analyzer \
  --source=. \
  --allow-unauthenticated \
  --port=8080 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},LOCATION=us-central1,GEMINI_MODEL=gemini-2.5-flash,GCS_LENS_BUCKET=shoplens2026-dev-lens-tmp,SERPAPI_KEY=<YOUR_SERPAPI_KEY>" \
  $DEPLOY_FLAGS
```

### 10.2 — product-matcher

```bash
cd services/product-matcher

gcloud run deploy product-matcher \
  --source=. \
  --allow-unauthenticated \
  --port=8080 \
  --set-env-vars="SERPAPI_KEY=<YOUR_SERPAPI_KEY>" \
  $DEPLOY_FLAGS
```

### 10.3 — state-manager

```bash
cd services/state-manager

gcloud run deploy state-manager \
  --source=. \
  --allow-unauthenticated \
  --port=8080 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID}" \
  $DEPLOY_FLAGS

# Note: if Firestore is in a DIFFERENT project, also set:
# --set-env-vars="PROJECT_ID=${PROJECT_ID},FIRESTORE_PROJECT_ID=<firestore-project-id>"
```

### 10.4 — voice-assistant

```bash
cd services/voice-assistant

# Get product-matcher URL
export PRODUCT_MATCHER_URL=$(gcloud run services describe product-matcher \
  --region=us-central1 --project="$PROJECT_ID" --format="value(status.url)")

gcloud run deploy voice-assistant \
  --source=. \
  --no-allow-unauthenticated \
  --port=8080 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},LOCATION=us-central1,VOICE_MODEL=gemini-live-2.5-flash-native-audio,EXTRACTION_MODEL=gemini-2.5-flash,VOICE_NAME=Puck,SESSION_MAX_SECONDS=300,INACTIVITY_NUDGE_SECONDS=30,INACTIVITY_CLOSE_GRACE_SECONDS=10,SESSION_CONTEXT_WINDOW_TOKENS=8000,PRODUCT_MATCHER_URL=${PRODUCT_MATCHER_URL}" \
  $DEPLOY_FLAGS
```

### 10.5 — pubsub-worker

```bash
cd services/pubsub-worker

# Gather downstream service URLs first
export AI_ANALYZER_URL=$(gcloud run services describe ai-analyzer \
  --region=us-central1 --project="$PROJECT_ID" --format="value(status.url)")
export STATE_MANAGER_URL=$(gcloud run services describe state-manager \
  --region=us-central1 --project="$PROJECT_ID" --format="value(status.url)")

gcloud run deploy pubsub-worker \
  --source=. \
  --no-allow-unauthenticated \
  --port=8080 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=shoplens2026-dev-hls-segments,AI_ANALYZER_URL=${AI_ANALYZER_URL},STATE_MANAGER_URL=${STATE_MANAGER_URL}" \
  $DEPLOY_FLAGS
```

Allow Pub/Sub to invoke pubsub-worker (push subscription auth):

```bash
gcloud run services add-iam-policy-binding pubsub-worker \
  --region=us-central1 \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID"
```

### 10.6 — Verify All Service URLs

```bash
gcloud run services list \
  --region=us-central1 \
  --project="$PROJECT_ID" \
  --format="table(metadata.name, status.url)"
```

Expected URLs (with project number `115535290381`):

| Service | URL |
|---|---|
| ai-analyzer | `https://ai-analyzer-115535290381.us-central1.run.app` |
| product-matcher | `https://product-matcher-115535290381.us-central1.run.app` |
| state-manager | `https://state-manager-115535290381.us-central1.run.app` |
| voice-assistant | `https://voice-assistant-115535290381.us-central1.run.app` |
| pubsub-worker | `https://pubsub-worker-115535290381.us-central1.run.app` |

---

## Section 11 — Allow Voice-Assistant to Be Invoked by Authenticated Users

The voice-assistant service requires a Firebase ID token. Grant all authenticated users invoke access:

```bash
gcloud run services add-iam-policy-binding voice-assistant \
  --region=us-central1 \
  --member="allAuthenticatedUsers" \
  --role="roles/run.invoker" \
  --project="$PROJECT_ID"
```

> **Note:** This grants any Google-authenticated user invoke access. If you want to restrict to Firebase-authenticated users only, keep `--no-allow-unauthenticated` and validate Firebase ID tokens inside the service (already implemented in the existing code).

---

## Section 12 — Cloud Live Stream Setup

Run the existing setup script with the new project's config:

```bash
cd services/live-ingest

PROJECT_ID="project-b1a5dd5a-69e6-4db3-9d7" \
LOCATION="us-central1" \
BUCKET_NAME="shoplens2026-dev-hls-segments" \
CHANNEL_ID="shoplens2026-channel" \
INPUT_ID="shoplens2026-input" \
python setup_live_stream.py
```

After setup, note the RTMP ingest endpoint from the output. Configure OBS or your encoder to stream to that URL.

---

## Section 13 — Environment Variable Files

Create these local config files (never commit them):

### `services/ai-analyzer/.env.shoplens2026-dev`

```bash
PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
LOCATION=us-central1
GEMINI_MODEL=gemini-2.5-flash
GCS_LENS_BUCKET=shoplens2026-dev-lens-tmp
SERPAPI_KEY=<your-serpapi-key>
```

### `services/product-matcher/.env.shoplens2026-dev`

```bash
SERPAPI_KEY=<your-serpapi-key>
```

### `services/state-manager/.env.shoplens2026-dev`

```bash
PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
# FIRESTORE_PROJECT_ID=<only if Firestore is in a separate project>
```

### `services/voice-assistant/.env.shoplens2026-dev`

```bash
PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
LOCATION=us-central1
VOICE_MODEL=gemini-live-2.5-flash-native-audio
EXTRACTION_MODEL=gemini-2.5-flash
VOICE_NAME=Puck
SESSION_MAX_SECONDS=300
INACTIVITY_NUDGE_SECONDS=30
INACTIVITY_CLOSE_GRACE_SECONDS=10
SESSION_CONTEXT_WINDOW_TOKENS=8000
PRODUCT_MATCHER_URL=https://product-matcher-115535290381.us-central1.run.app
# FIRESTORE_PROJECT_ID=<only if Firestore is in a separate project>
```

### `services/pubsub-worker/.env.shoplens2026-dev`

```bash
PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
TOPIC_ID=video-segments-topic
SUBSCRIPTION_ID=video-segments-sub
BUCKET_NAME=shoplens2026-dev-hls-segments
AI_ANALYZER_URL=https://ai-analyzer-115535290381.us-central1.run.app
STATE_MANAGER_URL=https://state-manager-115535290381.us-central1.run.app
SESSION_ID=dev-session-001
```

### `frontend/.env.shoplens2026-dev`

```bash
NEXT_PUBLIC_FIREBASE_API_KEY=<from Firebase console>
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=project-b1a5dd5a-69e6-4db3-9d7.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=project-b1a5dd5a-69e6-4db3-9d7
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=115535290381
NEXT_PUBLIC_FIREBASE_APP_ID=<from Firebase console>
NEXT_PUBLIC_AI_ANALYZER_URL=https://ai-analyzer-115535290381.us-central1.run.app
NEXT_PUBLIC_PRODUCT_MATCHER_URL=https://product-matcher-115535290381.us-central1.run.app
NEXT_PUBLIC_STATE_MANAGER_URL=https://state-manager-115535290381.us-central1.run.app
NEXT_PUBLIC_VOICE_ASSISTANT_URL=https://voice-assistant-115535290381.us-central1.run.app
```

### `mobile/.dart_define/shoplens2026-dev.json`

**Gitignored — not tracked in git** (`mobile/.gitignore` excludes the whole `.dart_define/`
directory), so this file must be created locally and this doc is the only source of truth
for its shape. An earlier version of this doc was missing 5 of the 9 required keys — the
resulting incomplete file builds an APK that shows a **blank screen instead of the login
screen**, because `Firebase.initializeApp()` throws in `main()` (before any UI renders) when
`FIREBASE_PROJECT_ID` doesn't match the Firebase API key/App ID/sender ID it's paired with.
Undefined dart-define keys silently fall back to `lib/firebase_options.dart`'s hardcoded
defaults, which point at the *old* `shoplens-dev-499700` project — hence the mismatch.

Backend URL keys must be named `ANALYZER_API_URL` / `MATCHER_API_URL` / `STATE_API_URL` /
`VOICE_ASSISTANT_API_URL` — that's what `lib/core/constants/api_constants.dart` actually
reads via `String.fromEnvironment(...)`. (`AI_ANALYZER_URL` etc., used in an earlier version
of this doc, are not read anywhere — they'd be silently ignored, and the app would fall back
to whatever URLs are in the bundled `mobile/.env`, which point at the old project.)

Get the four `FIREBASE_ANDROID_*`/`FIREBASE_MESSAGING_SENDER_ID`/`FIREBASE_STORAGE_BUCKET`
values from `mobile/android/app/google-services.shoplens2026-dev.json` (also gitignored,
already present in this checkout — download fresh from Firebase console > Project settings >
Your apps > Android if it's ever missing):
- `FIREBASE_ANDROID_API_KEY` ← `client[0].api_key[0].current_key`
- `FIREBASE_ANDROID_APP_ID` ← `client[0].client_info.mobilesdk_app_id`
- `FIREBASE_MESSAGING_SENDER_ID` ← `project_info.project_number`
- `FIREBASE_STORAGE_BUCKET` ← `project_info.storage_bucket`

```json
{
  "ANALYZER_API_URL": "https://ai-analyzer-115535290381.us-central1.run.app",
  "MATCHER_API_URL": "https://product-matcher-115535290381.us-central1.run.app",
  "STATE_API_URL": "https://state-manager-115535290381.us-central1.run.app",
  "VOICE_ASSISTANT_API_URL": "https://voice-assistant-115535290381.us-central1.run.app",

  "FIREBASE_PROJECT_ID": "project-b1a5dd5a-69e6-4db3-9d7",
  "FIREBASE_MESSAGING_SENDER_ID": "<project_info.project_number from google-services.shoplens2026-dev.json>",
  "FIREBASE_STORAGE_BUCKET": "<project_info.storage_bucket from google-services.shoplens2026-dev.json>",

  "FIREBASE_ANDROID_API_KEY": "<client[0].api_key[0].current_key from google-services.shoplens2026-dev.json>",
  "FIREBASE_ANDROID_APP_ID": "<client[0].client_info.mobilesdk_app_id from google-services.shoplens2026-dev.json>"
}
```

---

## Section 14 — Mobile App Build for shoplens2026-dev

```bash
cd mobile

# Swap in the new project's Firebase config
cp android/app/google-services.json android/app/google-services.original.json
cp android/app/google-services.shoplens2026-dev.json android/app/google-services.json

# Build APK
flutter build apk --release \
  --dart-define-from-file=.dart_define/shoplens2026-dev.json

# Restore original config
cp android/app/google-services.original.json android/app/google-services.json
```

---

## Section 15 — GitHub Actions Workflow

Create `.github/workflows/deploy-shoplens2026-dev.yml` by copying the existing `deploy-cookshop-dev.yml` and updating:

- `GCP_PROJECT_ID` secret name → `GCP_PROJECT_ID_2026_DEV`
- `GCP_WORKLOAD_IDENTITY_PROVIDER` → `GCP_WORKLOAD_IDENTITY_PROVIDER_2026_DEV`
- `GCP_SERVICE_ACCOUNT` → `GCP_SERVICE_ACCOUNT_2026_DEV`
- Any hardcoded project IDs → `project-b1a5dd5a-69e6-4db3-9d7`
- Artifact registry path → `us-central1-docker.pkg.dev/project-b1a5dd5a-69e6-4db3-9d7/shoplens`

---

## Section 16 — Verification Checklist

Run these checks after completing all sections:

```bash
# 1. All APIs enabled
gcloud services list --enabled --project="$PROJECT_ID" | grep -E "run|firestore|pubsub|aiplatform|livestream|artifactregistry"

# 2. Service account exists with correct roles
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:shoplens-runner" \
  --format="table(bindings.role)"

# 3. Workload Identity pool and provider
gcloud iam workload-identity-pools list --location=global --project="$PROJECT_ID"
gcloud iam workload-identity-pools providers list \
  --location=global \
  --workload-identity-pool=github-pool \
  --project="$PROJECT_ID"

# 4. Cloud Run services running
gcloud run services list --region=us-central1 --project="$PROJECT_ID"

# 5. GCS buckets exist
gcloud storage buckets list --project="$PROJECT_ID"

# 6. Artifact Registry repo exists
gcloud artifacts repositories list --location=us-central1 --project="$PROJECT_ID"

# 7. Pub/Sub topic and subscription
gcloud pubsub topics list --project="$PROJECT_ID"
gcloud pubsub subscriptions list --project="$PROJECT_ID"

# 8. Firestore database
gcloud firestore databases list --project="$PROJECT_ID"

# 9. Smoke test: hit ai-analyzer health endpoint
curl -s "https://ai-analyzer-115535290381.us-central1.run.app/health" | jq .

# 10. Smoke test: hit product-matcher health endpoint
curl -s "https://product-matcher-115535290381.us-central1.run.app/health" | jq .
```

---

## Quick Reference

| Resource | Value |
|---|---|
| GCP Project ID | `project-b1a5dd5a-69e6-4db3-9d7` |
| GCP Project Number | `115535290381` |
| Firebase Project ID | `project-b1a5dd5a-69e6-4db3-9d7` |
| Region | `us-central1` |
| Service Account | `shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com` |
| Artifact Registry | `us-central1-docker.pkg.dev/project-b1a5dd5a-69e6-4db3-9d7/shoplens` |
| HLS Bucket | `gs://shoplens2026-dev-hls-segments` |
| Lens Tmp Bucket | `gs://shoplens2026-dev-lens-tmp` |
| Firebase Storage Bucket | `project-b1a5dd5a-69e6-4db3-9d7.firebasestorage.app` |
| Workload Identity Pool | `projects/115535290381/locations/global/workloadIdentityPools/github-pool` |
| WIF Provider | `projects/115535290381/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| Voice model location constraint | `us-central1` only (gemini-live-2.5-flash-native-audio) |
