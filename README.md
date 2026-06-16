# ShopLens — AI-Powered Live Shopping Platform

> Turn a live cooking stream into a real-time shoppable experience. Gemini watches the video, detects ingredients and utensils, matches them to products, and pushes updates to viewers in under a few seconds.

---

## Table of Contents

1. [What This Is](#1-what-this-is)
2. [Architecture Overview](#2-architecture-overview)
3. [Data Flow](#3-data-flow)
4. [Repository Structure](#4-repository-structure)
5. [What Is Built (MVP)](#5-what-is-built-mvp)
6. [What Is Not Built Yet](#6-what-is-not-built-yet)
7. [Prerequisites](#7-prerequisites)
8. [Service Setup Guide](#8-service-setup-guide)
   - [live-ingest — Cloud Live Stream Setup](#live-ingest--cloud-live-stream-setup)
   - [pubsub-worker — Segment Event Receiver](#pubsub-worker--segment-event-receiver)
   - [ai-analyzer — Gemini Video Analysis](#ai-analyzer--gemini-video-analysis)
   - [product-matcher — Fuzzy Product Matching](#product-matcher--fuzzy-product-matching)
   - [state-manager — Firestore Session Writer](#state-manager--firestore-session-writer)
   - [frontend — Next.js Live Shopping UI](#frontend--nextjs-live-shopping-ui)
9. [End-to-End Local Test](#9-end-to-end-local-test)
10. [Environment Variables Reference](#10-environment-variables-reference)
11. [Deployment to Google Cloud](#11-deployment-to-google-cloud)
12. [Next Steps](#12-next-steps)

---

## 1. What This Is

A **Google Cloud-native, event-driven pipeline** that:

1. Ingests a live RTMP camera feed via the **Google Cloud Live Stream API**
2. Emits a Pub/Sub event every time a new HLS video segment lands in Cloud Storage
3. Passes the segment to **Vertex AI Gemini** which returns a JSON list of detected ingredients and utensils
4. Fuzzy-matches those items against a product catalog using **rapidfuzz**
5. Writes the matched products to **Firestore**
6. Pushes the update to every browser in real time via a **Firestore `onSnapshot` listener** in the Next.js frontend

---

## 2. Architecture Overview

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │                          PRODUCER SIDE                               │
 │                                                                      │
 │  Camera / OBS  ──RTMP──►  Cloud Live Stream API  ──HLS segments──►  │
 │                                Cloud Storage bucket                  │
 └──────────────────────────────────────────────────────────────────────┘
                                     │
                         GCS Object Finalize notification
                                     │
                                     ▼
                              Pub/Sub Topic
                          (video-segments-topic)
                                     │
                           Push subscription
                                     │
                                     ▼
                    ┌────────────────────────────────┐
                    │  services/pubsub-worker        │
                    │  Cloud Run  POST /pubsub       │
                    │  Extracts gs:// segment URL   │
                    └────────────────┬───────────────┘
                                     │  calls
                                     ▼
                    ┌────────────────────────────────┐
                    │  services/ai-analyzer          │
                    │  Cloud Run  POST /analyze      │
                    │  Vertex AI Gemini 2.0 Flash    │
                    │  Returns ["Tomato","Knife"...] │
                    └────────────────┬───────────────┘
                                     │  calls
                                     ▼
                    ┌────────────────────────────────┐
                    │  services/product-matcher      │
                    │  Cloud Run  POST /match        │
                    │  rapidfuzz against catalog     │
                    │  Returns enriched products     │
                    └────────────────┬───────────────┘
                                     │  calls
                                     ▼
                    ┌────────────────────────────────┐
                    │  services/state-manager        │
                    │  Cloud Run  POST /session/{id} │
                    │  Overwrites Firestore document │
                    └────────────────┬───────────────┘
                                     │  Firestore onSnapshot
                                     ▼
                    ┌────────────────────────────────┐
                    │  frontend/                     │
                    │  Next.js on Firebase Hosting   │
                    │  HLS video + live product list │
                    └────────────────────────────────┘
```

---

## 3. Data Flow

| Step | From | To | Protocol | Payload |
|------|------|----|----------|---------|
| 1 | Camera | Cloud Live Stream API | RTMP | Raw video |
| 2 | Live Stream API | Cloud Storage | Internal | HLS segments (`.ts` + `manifest.m3u8`) |
| 3 | Cloud Storage | Pub/Sub | GCS Notification | `{"bucket":"...", "name":"..."}` |
| 4 | Pub/Sub | pubsub-worker | HTTPS push | Base64-encoded GCS event |
| 5 | pubsub-worker | ai-analyzer | HTTP POST | `{"bucket":"...", "name":"..."}` |
| 6 | ai-analyzer | Vertex AI Gemini | gRPC | Video file + prompt |
| 7 | ai-analyzer | product-matcher | HTTP POST | `{"items": ["Tomato", "Chef's Knife"]}` |
| 8 | product-matcher | state-manager | HTTP POST | `{"products": [{...}, {...}]}` |
| 9 | state-manager | Firestore | Firebase SDK | `LiveShoppingSessions/{session_id}` |
| 10 | Firestore | Browser | WebSocket | Real-time snapshot updates |

---

## 4. Repository Structure

```
rsr01/
│
├── services/                          # One directory per Cloud Run service
│   │
│   ├── live-ingest/                   # Run-once setup: provisions GCP Live Stream resources
│   │   ├── setup_live_stream.py       # Creates RTMP input + HLS channel + starts stream
│   │   ├── requirements.txt
│   │   └── .env.example
│   │
│   ├── pubsub-worker/                 # Cloud Run: pipeline entry point
│   │   ├── main.py                    # POST /pubsub — receives GCS events, extracts segment URL
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── .env.example
│   │
│   ├── ai-analyzer/                   # Cloud Run: Gemini multimodal analysis
│   │   ├── analyzer.py                # analyze_segment(gcs_uri, transcript) → list[str]
│   │   ├── main.py                    # POST /analyze — calls analyzer, returns item list
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── .env.example
│   │
│   ├── product-matcher/               # Cloud Run: fuzzy product lookup
│   │   ├── catalog.json               # 20 mock grocery/kitchen products
│   │   ├── matcher.py                 # match_products(items) → matched + unmatched
│   │   ├── main.py                    # POST /match
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── .env.example
│   │
│   └── state-manager/                 # Cloud Run: Firestore session writer
│       ├── state_manager.py           # update / get / clear session
│       ├── main.py                    # POST|GET|DELETE /session/{id}
│       ├── Dockerfile
│       ├── requirements.txt
│       └── .env.example
│
├── frontend/                          # Next.js 14 app — Firebase Hosting
│   ├── src/
│   │   ├── app/
│   │   │   ├── page.tsx               # Root layout: video left, shopping list right
│   │   │   ├── layout.tsx
│   │   │   └── globals.css
│   │   ├── components/
│   │   │   ├── VideoPlayer.tsx        # HLS.js player with Safari fallback
│   │   │   └── ShoppingList.tsx       # Firestore onSnapshot — live-updating product list
│   │   └── lib/
│   │       └── firebase.ts            # Firebase app singleton
│   ├── package.json
│   ├── next.config.js                 # output: 'export' for static Firebase Hosting
│   ├── firebase.json
│   ├── .firebaserc
│   └── .env.local.example
│
├── infra/                             # One-time GCP wiring scripts (not deployed)
│   └── pubsub_setup.py                # Creates Pub/Sub topic, push subscription, GCS notification
│
├── docs/                              # Product briefs, tech stack, design docs
│   ├── brief.txt
│   ├── tech_stack.txt
│   └── product_sprtint_stories.txt
│
└── README.md
```

---

## 5. What Is Built (MVP)

| Component | Status | Description |
|-----------|--------|-------------|
| `services/live-ingest` | ✅ Complete | Provisions Cloud Live Stream channel, RTMP input, and HLS output to GCS |
| `services/pubsub-worker` | ✅ Complete | FastAPI Cloud Run service receives GCS Pub/Sub push events and extracts segment URLs |
| `services/ai-analyzer` | ✅ Complete | Vertex AI Gemini 2.0 Flash analyzes video + transcript, returns structured JSON item list |
| `services/product-matcher` | ✅ Complete | rapidfuzz matches detected items against 20-item mock catalog with 70-score threshold |
| `services/state-manager` | ✅ Complete | Firebase Admin SDK overwrites `LiveShoppingSessions/{id}` with products + server timestamp |
| `frontend` | ✅ Complete | Next.js 14 app with HLS.js video player and Firestore `onSnapshot` real-time shopping list |
| CI/CD — Cloud Run | ✅ Complete | GitHub Actions (`deploy-cloudrun.yml`) builds and deploys all 4 Cloud Run services on push to `main` / `develop` via Workload Identity Federation |
| CI/CD — Firebase Hosting | ✅ Complete | GitHub Actions (`deploy-firebase.yml`) builds and deploys Next.js frontend with per-environment API URLs baked in at build time |
| Image analysis path | ✅ Complete | Browser → `ai-analyzer` → `product-matcher` → `state-manager` is fully wired; Analyze button works end-to-end in prod |

---

## 6. What Is Not Built Yet

| Priority | What | Where to add it |
|----------|------|-----------------|
| 🔴 High | **Live stream pipeline wiring** — `pubsub-worker` receives GCS events but does not yet call `ai-analyzer`; the streaming path is not connected | Add `httpx` call in `pubsub-worker/main.py` after extracting the segment URL: POST to `AI_ANALYZER_URL/analyze` |
| 🔴 High | **Speech-to-Text transcription** — `analyze_segment()` accepts a `transcript` arg but nothing generates it | Add Cloud Speech-to-Text call in `ai-analyzer/main.py` on the audio track before calling Gemini |
| 🟡 Medium | **Real product catalog** — currently a static 20-item JSON file | Replace `catalog.json` lookup in `product-matcher` with Cloud SQL or Google Shopping API |
| 🟡 Medium | **Cart / "Add" button** — button is UI-only in the frontend | Add a cart service + Firebase Auth for user identity |
| 🟡 Medium | **Cloud Workflows orchestration** — direct HTTP calls between services have no retry/observability | Replace chained HTTP calls with a Cloud Workflows definition |
| 🟢 Low | **Analytics** | Stream Firestore writes to BigQuery via Datastream |
| 🟢 Low | **Multi-tenant sessions** | Pass `session_id` through the whole pipeline to support concurrent shows |

---

## 7. Prerequisites & Deployment Status

### ✅ Completed

| Step | What | Status | Details |
|------|------|--------|----------|
| 1 | GCP Project + 13 APIs | ✅ Done | Cloud Run, Pub/Sub, Storage, Firestore, Firebase, Vertex AI, Speech-to-Text, Vision, Live Stream, Artifact Registry, Cloud Build, IAM, Secret Manager |
| 2 | Service Account + IAM Roles | ✅ Done | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` with Cloud Run Admin, Cloud Run Invoker, Pub/Sub Publisher/Subscriber, Datastore User, Vertex AI User, Storage Object Viewer/Admin, Live Stream Admin, IAM Service Account User |
| 3 | GCS Bucket | ✅ Done | `gs://shoplens-dev-hls-segments` in us-central1, public read access for HLS playback |
| 4 | Firestore Database | ✅ Done | Native mode, Standard edition, us-central1 |
| 5 | Pub/Sub Topic + Subscription | ✅ Done | Topic: `video-segments-topic`, Subscription: `video-segments-sub` (push type, endpoint wired via deploy workflow) |
| 6 | GitHub Actions CI/CD | ✅ Done | `deploy-cloudrun.yml` and `deploy-firebase.yml` with Workload Identity Federation; dev and prod GitHub Environments fully configured with secrets and variables |
| 7 | Cloud Run Services Deployed (prod) | ✅ Done | `ai-analyzer`, `product-matcher`, `state-manager`, `pubsub-worker` deployed to `shoplens-dev-prj` via GitHub Actions |
| 8 | Firebase Hosting Deployed (prod) | ✅ Done | Frontend live on Firebase Hosting; API URLs (`AI_ANALYZER_URL`, `PRODUCT_MATCHER_URL`, `STATE_MANAGER_URL`) baked in at build time via GitHub Environment variables |
| 9 | Image Analysis Path Working | ✅ Done | Analyze button in prod frontend calls `ai-analyzer` → `product-matcher` → `state-manager` end-to-end |

### 🔲 Remaining

| Step | What | Details |
|------|------|---------|
| 10 | Wire live stream pipeline | `pubsub-worker` needs to call `ai-analyzer` after extracting GCS segment URL |
| 11 | Wire GCS bucket notifications | Configure GCS bucket to emit Pub/Sub events on HLS segment finalize |
| 12 | End-to-end live stream test | Stream RTMP → confirm full pipeline fires → products appear in frontend in real time |

### Local Machine Requirements

- **Python 3.11+** for all backend services
- **Node.js 18+** and **npm** for the frontend
- **Google Cloud CLI** authenticated with the service account key
- **Firebase CLI**: `npm install -g firebase-tools`

---

## 8. Service Setup Guide

### `live-ingest` — Cloud Live Stream Setup

**Purpose:** Provisions the Cloud Live Stream channel. Run once before a show starts — not a deployed service.

```bash
cd services/live-ingest
pip install google-cloud-video-live-stream python-dotenv
cp .env.example .env                              # fill in your values
python setup_live_stream.py
```

The script prints two values you'll need later:
- **RTMP ingest URI** — point OBS / your encoder here
- **HLS playback URL** — paste this into `NEXT_PUBLIC_HLS_STREAM_URL` in `frontend/.env.local`

Key functions in [setup_live_stream.py](services/live-ingest/setup_live_stream.py):
| Function | What it does |
|----------|-------------|
| `create_input()` | Provisions RTMP_PUSH input endpoint |
| `create_channel()` | Creates channel: H.264 720p / AAC 128kbps, 6-second HLS segments |
| `start_channel()` | Transitions channel to STREAMING state |
| `get_channel_status()` | Polls until live |

---

### `pubsub-worker` — Segment Event Receiver

**Purpose:** Receives GCS object-finalize Pub/Sub push events and extracts the video segment URL. This is the **pipeline entry point**.

```bash
cd services/pubsub-worker
pip install -r requirements.txt
cp .env.example .env

# Run the one-time infra wiring AFTER the Cloud Run service is deployed:
# 1. Deploy first (see §11) to get the Cloud Run URL
# 2. Set PUSH_ENDPOINT=https://<cloud-run-url>/pubsub in .env
# 3. Run: python ../../infra/pubsub_setup.py

# Local dev
uvicorn main:app --reload --port 8080
```

API:
- `POST /pubsub` — receives Pub/Sub push, extracts `gs://bucket/segment.ts`, returns 200
- `GET /health`

> **TODO:** After extracting the segment URL, call `ai-analyzer`'s `/analyze` endpoint. See [Next Steps](#12-next-steps).

---

### `ai-analyzer` — Gemini Video Analysis

**Purpose:** Sends the video segment to Vertex AI Gemini 2.0 Flash and returns a list of detected ingredients and utensils.

```bash
cd services/ai-analyzer
pip install -r requirements.txt
cp .env.example .env     # set PROJECT_ID and LOCATION

uvicorn main:app --reload --port 8081
```

API:
- `POST /analyze` — accepts a Pub/Sub push body, returns `{"items": ["Tomato", "Chef's Knife"], "gcs_uri": "gs://..."}`
- `GET /healthz`

Core function in [analyzer.py](services/ai-analyzer/analyzer.py):
```python
analyze_segment(gcs_video_uri: str, transcript: str) -> list[str]
```

> **TODO:** After getting items, call `product-matcher`'s `/match` endpoint. See [Next Steps](#12-next-steps).

---

### `product-matcher` — Fuzzy Product Matching

**Purpose:** Fuzzy-matches detected item names against the product catalog and returns enriched product objects.

```bash
cd services/product-matcher
pip install -r requirements.txt

uvicorn main:app --reload --port 8082
```

API:
- `POST /match` — body: `{"items": ["Tomato", "knife"]}` — returns `{"matched_products": [...], "unmatched": [...]}`
- `GET /health`

To extend the catalog, edit [catalog.json](services/product-matcher/catalog.json). Each entry:
```json
{
  "product_id": "p001",
  "name": "Roma Tomatoes",
  "price": 2.99,
  "image_url": "https://...",
  "keywords": ["tomato", "tomatoes"]
}
```

Match threshold is 70 (WRatio score). Tune in [matcher.py](services/product-matcher/matcher.py) `_SCORE_THRESHOLD`.

> **TODO:** Replace static catalog with Cloud SQL or Google Shopping API calls.

---

### `state-manager` — Firestore Session Writer

**Purpose:** Overwrites the live session document in Firestore, which triggers real-time updates in every connected browser.

```bash
cd services/state-manager
pip install -r requirements.txt
cp .env.example .env     # set PROJECT_ID; optionally GOOGLE_APPLICATION_CREDENTIALS

uvicorn main:app --reload --port 8083
```

API:
- `POST /session/{session_id}/products` — body: `{"products": [{...}]}` — overwrites Firestore doc
- `GET /session/{session_id}` — reads current state
- `DELETE /session/{session_id}` — clears product list
- `GET /health`

Firestore document written to: `LiveShoppingSessions/{session_id}`
```json
{
  "products": [{ "product_id": "...", "name": "...", "price": 2.99, "image_url": "..." }],
  "last_updated": "<server timestamp>"
}
```

---

### `frontend` — Next.js Live Shopping UI

**Purpose:** Two-panel UI — live HLS video on the left, real-time shopping list on the right. Hosted on Firebase Hosting.

```bash
cd frontend
npm install
cp .env.local.example .env.local    # fill in Firebase config + HLS stream URL
npm run dev                          # http://localhost:3000
```

Key components:
| File | Purpose |
|------|---------|
| [VideoPlayer.tsx](frontend/src/components/VideoPlayer.tsx) | HLS.js with low-latency mode, Safari native HLS fallback, loading state |
| [ShoppingList.tsx](frontend/src/components/ShoppingList.tsx) | `onSnapshot` on `LiveShoppingSessions/{sessionId}` — pulsing LIVE badge, product cards, last-updated footer |
| [firebase.ts](frontend/src/lib/firebase.ts) | Firebase singleton (guards against double-init on hot-reload) |

**Deploy to Firebase Hosting:**
```bash
npm run build                   # produces out/
firebase login
firebase use <your-project-id>  # update .firebaserc first
firebase deploy --only hosting
```

---

## 9. End-to-End Local Test

Run all four backend services in separate terminals, then drive them with curl to simulate a full pipeline cycle:

```bash
# Terminal 1-4: start each service
uvicorn services/pubsub-worker/main:app   --port 8080
uvicorn services/ai-analyzer/main:app     --port 8081
uvicorn services/product-matcher/main:app --port 8082
uvicorn services/state-manager/main:app   --port 8083
```

```bash
# Step 1 — simulate Gemini analysis (skipping Pub/Sub, going direct)
curl -X POST http://localhost:8081/analyze \
  -H "Content-Type: application/json" \
  -d '{"message":{"data":"'$(echo -n '{"bucket":"my-bucket","name":"hls-output/seg001.ts"}' | base64)'"}}'
# → {"items": ["Tomato", "Olive Oil", "Chef's Knife"], "gcs_uri": "gs://..."}

# Step 2 — match items to products
curl -X POST http://localhost:8082/match \
  -H "Content-Type: application/json" \
  -d '{"items": ["Tomato", "Olive Oil", "Chef'\''s Knife"]}'
# → {"matched_products": [...], "unmatched": []}

# Step 3 — write to Firestore
curl -X POST http://localhost:8083/session/live-session-001/products \
  -H "Content-Type: application/json" \
  -d '{"products": [{"product_id":"p001","name":"Roma Tomatoes","price":2.99,"image_url":"https://placehold.co/200x200?text=Tomatoes"}]}'
# → {"status": "updated", "session_id": "live-session-001"}

# Step 4 — open http://localhost:3000 — shopping list updates instantly
```

---

## 10. Environment Variables Reference

| Service | Variable | Description |
|---------|----------|-------------|
| `live-ingest` | `PROJECT_ID` | GCP project ID |
| `live-ingest` | `LOCATION` | GCP region (i.e. `us-central1`) |
| `live-ingest` | `BUCKET_NAME` | GCS bucket name for HLS output (no `gs://`) |
| `live-ingest` | `CHANNEL_ID` | Live Stream channel resource ID |
| `live-ingest` | `INPUT_ID` | RTMP input resource ID |
| `pubsub-worker` | `TOPIC_ID` | Pub/Sub topic name |
| `pubsub-worker` | `SUBSCRIPTION_ID` | Pub/Sub push subscription name |
| `pubsub-worker` | `PUSH_ENDPOINT` | Deployed Cloud Run URL for `/pubsub` |
| `ai-analyzer` | `PROJECT_ID` | GCP project ID |
| `ai-analyzer` | `LOCATION` | Vertex AI region |
| `state-manager` | `PROJECT_ID` | GCP project ID |
| `state-manager` | `GOOGLE_APPLICATION_CREDENTIALS` | Path to service account JSON (omit to use ADC) |
| `frontend` | `NEXT_PUBLIC_FIREBASE_API_KEY` | Firebase web API key |
| `frontend` | `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | Firebase project ID |
| `frontend` | `NEXT_PUBLIC_FIREBASE_APP_ID` | Firebase app ID |
| `frontend` | `NEXT_PUBLIC_SESSION_ID` | Firestore document ID to subscribe to |
| `frontend` | `NEXT_PUBLIC_HLS_STREAM_URL` | HLS manifest URL output by `live-ingest` |
| `frontend` | `NEXT_PUBLIC_ANALYZER_API_URL` | Cloud Run URL for `ai-analyzer` (set via GitHub var `AI_ANALYZER_URL`) |
| `frontend` | `NEXT_PUBLIC_MATCHER_API_URL` | Cloud Run URL for `product-matcher` (set via GitHub var `PRODUCT_MATCHER_URL`) |
| `frontend` | `NEXT_PUBLIC_STATE_API_URL` | Cloud Run URL for `state-manager` (set via GitHub var `STATE_MANAGER_URL`) |

---

## 11. Deployment to Google Cloud

### Step 6 — Download Service Account Key & Deploy Cloud Run Services

Set up authentication and deploy the backend services to Cloud Run:

```powershell
# Download service account key (one-time, for local development)
gcloud iam service-accounts keys create ./shoplens-runner-key.json `
  --iam-account=shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com `
  --project=shoplens-dev-prj

# Set project and region defaults
gcloud config set project shoplens-dev-prj
gcloud config set run/region us-central1

# Set credentials for local development
$env:GOOGLE_APPLICATION_CREDENTIALS = "$(Get-Location)\shoplens-runner-key.json"
```

Deploy each service in order (state-manager first, pubsub-worker last):

```powershell
# Deploy state-manager
gcloud run deploy state-manager `
  --source ./services/state-manager `
  --platform managed `
  --allow-unauthenticated `
  --set-env-vars PROJECT_ID=shoplens-dev-prj

# Deploy product-matcher
gcloud run deploy product-matcher `
  --source ./services/product-matcher `
  --platform managed `
  --allow-unauthenticated

# Deploy ai-analyzer
gcloud run deploy ai-analyzer `
  --source ./services/ai-analyzer `
  --platform managed `
  --allow-unauthenticated `
  --set-env-vars PROJECT_ID=shoplens-dev-prj,LOCATION=us-central1

# Deploy pubsub-worker (entry point)
gcloud run deploy pubsub-worker `
  --source ./services/pubsub-worker `
  --platform managed `
  --allow-unauthenticated `
  --set-env-vars PROJECT_ID=shoplens-dev-prj,TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=shoplens-dev-hls-segments
```

After each deployment, the command prints the service URL. **Save these URLs** — you'll need them in Steps 7 and 9.

**Prod Cloud Run service URLs (shoplens-dev-prj):**

| Service | URL |
|---------|-----|
| `ai-analyzer` | `https://ai-analyzer-4lcxbpnnlq-uc.a.run.app` |
| `product-matcher` | `https://product-matcher-4lcxbpnnlq-uc.a.run.app` |
| `state-manager` | `https://state-manager-4lcxbpnnlq-uc.a.run.app` |

### Step 8 — Update Pub/Sub Push Endpoint

After `pubsub-worker` is deployed, get its Cloud Run URL and update the Pub/Sub subscription:

```powershell
# Get the deployed pubsub-worker URL
gcloud run services describe pubsub-worker --region us-central1 --project shoplens-dev-prj --format="value(status.url)"
```

Then update the subscription:

1. Go to **Google Cloud Console > Pub/Sub > Subscriptions > video-segments-sub**
2. Click **Edit**
3. Under **Push endpoint**, paste: `https://<pubsub-worker-url>/pubsub`
4. Click **Save**

### Step 9 — Wire GCS Bucket Notifications

Configure the GCS bucket to notify Pub/Sub when HLS segments are finalized:

```powershell
gcloud storage buckets notifications create gs://shoplens-dev-hls-segments `
  --topic=video-segments-topic `
  --event-types=OBJECT_FINALIZE `
  --project=shoplens-dev-prj
```

This completes the event-driven pipeline wiring.

### Step 10 — Set Up Live Stream & Deploy Frontend

Run the live-ingest setup script to provision the Cloud Live Stream API resources:

```powershell
cd services/live-ingest
pip install google-cloud-video-live-stream python-dotenv
python setup_live_stream.py
```

The script will output:
- **RTMP ingest URL** — configure your camera/OBS encoder to stream here
- **HLS manifest URL** — the playback stream

Then set up and deploy the frontend:

```powershell
cd frontend
cp .env.local.example .env.local
# Edit .env.local and fill in Firebase config and HLS stream URL
npm install
npm run build

firebase login
firebase deploy --only hosting
```

---

## 12. Deployment Options

### Option A: Deploy Manually (for Development)

Follow the steps in **§11 Deployment to Google Cloud** above. Deploy each service individually and test locally before moving to the next service. This gives you fine-grained control and immediate feedback.

### Option B: Deploy via GitHub Actions (Recommended for CI/CD)

This repository includes GitHub Actions workflows for automated deployment:

- **`.github/workflows/deploy-cloudrun.yml`** — Deploys all Cloud Run services on push to `services/`
- **`.github/workflows/deploy-firebase.yml`** — Builds and deploys frontend to Firebase Hosting on push to `frontend/`
- **`.github/workflows/build-android.yml`** — Builds the Flutter Android APK on push to `develop` / `main`
- **`.github/workflows/build-ios.yml`** — Builds an unsigned iOS IPA on manual dispatch

To use GitHub Actions:

1. Push this repo to GitHub
2. Set up Workload Identity Federation (see [`.github/DEPLOYMENT.md`](.github/DEPLOYMENT.md))
3. Add GitHub Secrets and Variables per environment (see table below)
4. Push to `main` to trigger automated deployment

**GitHub Environment configuration** (Settings → Environments → `prod` / `dev`):

| Type | Name | prod value | dev value |
|------|------|-----------|-----------|
| Secret | `WIF_PROVIDER` | WIF provider resource name | WIF provider resource name |
| Secret | `WIF_SERVICE_ACCOUNT` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| Secret | `SA_EMAIL` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` | `shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com` |
| Secret | `NEXT_PUBLIC_FIREBASE_API_KEY` | Firebase web API key | Firebase web API key |
| Variable | `PROJECT_ID` | `shoplens-dev-prj` | `shoplens-dev-prj` |
| Variable | `FIREBASE_PROJECT_ID` | `shoplens-dev-prj` | `shoplens-dev-prj` |
| Variable | `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | `shoplens-dev-prj.firebaseapp.com` | `shoplens-dev-prj.firebaseapp.com` |
| Variable | `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | `shoplens-dev-prj` | `shoplens-dev-prj` |
| Variable | `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | `shoplens-dev-prj.firebasestorage.app` | `shoplens-dev-prj.firebasestorage.app` |
| Variable | `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | `645158438988` | `156370923364` |
| Variable | `NEXT_PUBLIC_FIREBASE_APP_ID` | `1:645158438988:web:b319ef6814bd85e0bb4ce9` | `1:156370923364:web:4bb870de319c305a70d471` |
| Variable | `AI_ANALYZER_URL` | `https://ai-analyzer-4lcxbpnnlq-uc.a.run.app` | Cloud Run URL |
| Variable | `PRODUCT_MATCHER_URL` | `https://product-matcher-4lcxbpnnlq-uc.a.run.app` | Cloud Run URL |
| Variable | `STATE_MANAGER_URL` | `https://state-manager-4lcxbpnnlq-uc.a.run.app` | Cloud Run URL |
| Variable | `BUCKET_NAME` | `shoplens-dev-hls-segments` | dev bucket name |
| Variable | `SESSION_ID` | Firestore session document ID | Firestore session document ID |
| Variable | `HLS_STREAM_URL` | HLS manifest URL | HLS manifest URL |
| Variable | `GCS_LENS_BUCKET` | GCS bucket for temp Lens images, e.g. `shoplens-dev-prj-lens-tmp` | e.g. `shoplens-dev-prj-lens-tmp` |
| Secret | `SERPAPI_KEY` | SerpApi key (Google Lens visual matching) | SerpApi key (Google Lens visual matching) |
| Secret | `GOOGLE_SERVICES_JSON` | base64 of `mobile/android/app/google-services.json` | base64 of `mobile/android/app/google-services.json` |
| Secret | `MOBILE_ENV` | base64 of `mobile/.env` (see `mobile/.env.example`) | base64 of `mobile/.env` (see `mobile/.env.example`) |
| Secret | `GOOGLE_SERVICE_INFO_PLIST` | base64 of `mobile/ios/Runner/GoogleService-Info.plist` | base64 of `mobile/ios/Runner/GoogleService-Info.plist` |

> `GOOGLE_SERVICES_JSON`, `MOBILE_ENV`, and `GOOGLE_SERVICE_INFO_PLIST` are read by
> `build-android.yml` / `build-ios.yml`, which select the `dev` or `prod`
> Environment based on the branch (or the `environment` input for manual iOS
> builds). Encode each file with `base64 -w0 <file>` (macOS: `base64 -i <file>`)
> and paste the output as the secret value.

> `GCS_LENS_BUCKET` is an Environment **Variable** (not a secret) read by
> `deploy-cloudrun.yml` for `ai-analyzer`. If unset, `vars.GCS_LENS_BUCKET`
> silently resolves to an empty string (no workflow error) and `ai-analyzer`
> logs `GCS_LENS_BUCKET or SERPAPI_KEY not set — visual matching disabled`.
> The bucket must exist, allow public object reads (`allUsers` →
> `roles/storage.objectViewer`, since SerpApi fetches a public
> `storage.googleapis.com` URL), and grant the runtime SA
> `roles/storage.objectAdmin` — see [Branching-Strategy.md](Branching-Strategy.md#gcs_lens_bucket-setup-one-time-per-project)
> for the exact commands.

**Required IAM roles for the Cloud Run runner SA** (grant once per project):

```bash
# roles/run.admin — allows deploying and managing Cloud Run services
gcloud projects add-iam-policy-binding shoplens-dev-prj \
  --member="serviceAccount:shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com" \
  --role="roles/run.admin"

# roles/iam.serviceAccountUser — allows SA to assign itself as Cloud Run runtime identity
gcloud iam service-accounts add-iam-policy-binding \
  shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com \
  --member="serviceAccount:shoplens-runner@shoplens-dev-prj.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

## 13. Next Steps

### ✅ Recently Completed

- ~~Deploy Cloud Run services~~ — all 4 services live in prod (`shoplens-dev-prj`)
- ~~Set up CI/CD~~ — GitHub Actions with Workload Identity Federation, deploying on push to `main`
- ~~Deploy frontend~~ — Firebase Hosting live with correct prod API URLs
- ~~Wire Pub/Sub push endpoint~~ — automated in `deploy-cloudrun.yml` post-deploy step
- ~~Image analysis path~~ — Analyze button works end-to-end in prod

### High Priority (Blocking)

1. **Wire live stream pipeline** — `pubsub-worker` extracts the GCS segment URL but does not yet call `ai-analyzer`
   - Add `httpx` POST to `${AI_ANALYZER_URL}/analyze` in `services/pubsub-worker/main.py` after extracting the segment
   - `AI_ANALYZER_URL` is already injected as an env var by the deploy workflow

2. **Wire GCS bucket notifications**
   - Run once: `gcloud storage buckets notifications create gs://shoplens-dev-hls-segments --topic=video-segments-topic --event-types=OBJECT_FINALIZE --project=shoplens-dev-prj`
   - This is the missing trigger that starts the live pipeline

3. **Verify end-to-end live stream**
   - Stream RTMP via OBS → confirm HLS segments land in GCS → Pub/Sub fires → Gemini analyzes → products appear in frontend in real time

### Medium Priority (Feature Complete)

4. **Add Speech-to-Text transcription**
   - `ai-analyzer/analyzer.py` already accepts a `transcript` parameter
   - Add a Cloud Speech-to-Text call on the audio track before Gemini analysis to improve detection accuracy

5. **Replace product catalog**
   - Currently a static 20-item JSON file in `services/product-matcher/catalog.json`
   - Integrate with Google Shopping API or Cloud SQL

### Low Priority (Polish)

6. **Add Cloud Workflows orchestration**
   - Replace direct HTTP calls with Cloud Workflows for retry logic and observability

7. **Analytics pipeline**
   - Stream Firestore writes to BigQuery via Datastream

8. **Multi-tenant sessions**
   - Pass `session_id` through the entire pipeline to support concurrent live streams