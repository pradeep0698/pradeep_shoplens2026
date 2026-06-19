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
| CI/CD — Cloud Run | ❌ Not built | No `.github/workflows/` directory exists in this repo. All 4 Cloud Run services were deployed manually via `gcloud run deploy --source .` from Cloud Shell — see [docs/local-setup.md](docs/local-setup.md) and [docs/status/2026-06-18.md](docs/status/2026-06-18.md) |
| CI/CD — Firebase Hosting | ❌ Not built | No `deploy-firebase.yml` exists. Frontend hasn't been deployed to Firebase Hosting yet — only run locally so far |
| Image analysis path | ✅ Complete | Browser → `ai-analyzer` → `product-matcher` → `state-manager` is fully wired; the Analyze button (`frontend/src/components/admin/VideoAnnotator.tsx`) works end-to-end against the deployed `shoplens-dev-499700` services |

---

## 6. What Is Not Built Yet

| Priority | What | Where to add it |
|----------|------|-----------------|
| 🔴 High | **Live Stream channel not set up yet** — `pubsub-worker` already calls `ai-analyzer` → `product-matcher` → `state-manager` end-to-end (confirmed working), but there's no live RTMP source yet, so nothing triggers the pipeline automatically. Only the on-demand Analyze button path has been tested | Run Part 5 of `docs/shop-lens-cloud-setup.md` to provision the Cloud Live Stream channel, then verify a real stream triggers the full pipeline |
| 🔴 High | **Speech-to-Text transcription** — `analyze_segment()` accepts a `transcript` arg but nothing generates it | Add Cloud Speech-to-Text call in `ai-analyzer/main.py` on the audio track before calling Gemini |
| 🟡 Medium | **Real product catalog** — currently a static 20-item JSON file | Replace `catalog.json` lookup in `product-matcher` with Cloud SQL or Google Shopping API |
| 🟡 Medium | **Cart / "Add" button** — button is UI-only in the frontend | Add a cart service + Firebase Auth for user identity |
| 🟡 Medium | **Cloud Workflows orchestration** — direct HTTP calls between services have no retry/observability | Replace chained HTTP calls with a Cloud Workflows definition |
| 🟢 Low | **Analytics** | Stream Firestore writes to BigQuery via Datastream |
| 🟢 Low | **Multi-tenant sessions** | Pass `session_id` through the whole pipeline to support concurrent shows |

---

## 7. Prerequisites & Deployment Status

There is only one environment, `shoplens-dev-499700` — no separate "prod" project exists. See [docs/status/2026-06-18.md](docs/status/2026-06-18.md) for the full session log this table is based on.

### ✅ Completed

| Step | What | Status | Details |
|------|------|--------|----------|
| 1 | GCP Project + required APIs | ✅ Done | `shoplens-dev-499700` (project number `935092313069`): Cloud Run, Pub/Sub, Storage, Firestore, Firebase, Vertex AI, Speech-to-Text, Vision, Live Stream, Artifact Registry, Cloud Build, IAM, Secret Manager |
| 2 | Service Account + IAM Roles | ✅ Done | `shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com` with Cloud Run Admin, Cloud Run Invoker, Pub/Sub Publisher/Subscriber, Datastore User, Vertex AI User, Storage Object Admin, Live Stream Admin, Secret Manager Secret Accessor, IAM Service Account User |
| 3 | GCS Buckets | ✅ Done | `gs://shoplens-dev-hls-segments` and `gs://shoplens-dev-lens-tmp`, both in us-central1 with public read access |
| 4 | Firestore Database | ✅ Done | Native mode, us-central1 |
| 5 | Pub/Sub Topic + Subscription | ✅ Done | Topic: `video-segments-topic`, Subscription: `video-segments-sub` — push endpoint points at `pubsub-worker`, authenticated via the `shoplens-runner` service account (not public) |
| 6 | GitHub Actions CI/CD | ❌ Not built | `.github/workflows/` doesn't exist. All deploys below were manual `gcloud run deploy --source .` commands from Cloud Shell |
| 7 | Cloud Run Services Deployed | ✅ Done | `ai-analyzer`, `product-matcher`, `state-manager` deployed publicly (`--allow-unauthenticated`, since the browser/mobile app call them directly with no auth token); `pubsub-worker` deployed **without** public access, since only the Pub/Sub push subscription should be able to call it |
| 8 | Firebase Hosting Deployed | ❌ Not done | Frontend has only been run locally (`npm run dev`) so far, not deployed to Firebase Hosting |
| 9 | Image Analysis Path Working | ✅ Done | Analyze button in the frontend calls `ai-analyzer` → `product-matcher` → `state-manager` end-to-end against the deployed services |

### 🔲 Remaining

| Step | What | Details |
|------|------|---------|
| 10 | Set up the Live Stream channel | Part 5 of `docs/shop-lens-cloud-setup.md` — no RTMP source exists yet, so the live (non-Analyze-button) path is untested |
| 11 | Wire GCS bucket notifications | Configure `gs://shoplens-dev-hls-segments` to emit Pub/Sub events on HLS segment finalize, so the live pipeline actually triggers |
| 12 | End-to-end live stream test | Stream RTMP → confirm full pipeline fires → products appear in frontend in real time |
| 13 | Deploy frontend to Firebase Hosting | Hasn't been done yet — currently dev-only via `npm run dev` |
| 14 | (Optional) Build CI/CD | Author `deploy-cloudrun.yml` / `deploy-firebase.yml` if automated deploys are wanted instead of manual `gcloud`/`firebase` commands |

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

This reflects what was actually run (manually, from Cloud Shell, authenticated as the project owner's Google account — not a downloaded service account key). There is no CI/CD for this yet.

### Step 6 — Deploy the Cloud Run Services

```bash
export PROJECT_ID=shoplens-dev-499700
export REGION=us-central1
export SA_EMAIL=shoplens-runner@${PROJECT_ID}.iam.gserviceaccount.com
export SERPAPI_KEY=<the current key — ask the project owner>

cd services/ai-analyzer
gcloud run deploy ai-analyzer \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated \
  --set-env-vars="PROJECT_ID=$PROJECT_ID,LOCATION=$REGION,GEMINI_MODEL=gemini-2.5-pro,GCS_LENS_BUCKET=shoplens-dev-lens-tmp,SERPAPI_KEY=$SERPAPI_KEY"
cd ../..

cd services/product-matcher
gcloud run deploy product-matcher \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated --set-env-vars="SERPAPI_KEY=$SERPAPI_KEY"
cd ../..

cd services/state-manager
gcloud run deploy state-manager \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --allow-unauthenticated --set-env-vars="PROJECT_ID=$PROJECT_ID,SESSION_ID=live-session-001"
cd ../..
```

`ai-analyzer`, `product-matcher`, and `state-manager` all use `--allow-unauthenticated` because the browser and mobile app call them directly with no Google auth token.

**Current real Cloud Run service URLs (`shoplens-dev-499700`):**

| Service | URL |
|---------|-----|
| `ai-analyzer` | `https://ai-analyzer-935092313069.us-central1.run.app` |
| `product-matcher` | `https://product-matcher-935092313069.us-central1.run.app` |
| `state-manager` | `https://state-manager-935092313069.us-central1.run.app` |
| `pubsub-worker` | `https://pubsub-worker-935092313069.us-central1.run.app` (not public — see Step 7) |

### Step 7 — Deploy `pubsub-worker` (locked down, not public)

Unlike the other three, `pubsub-worker` is **not** called directly by any client — only the Pub/Sub push subscription invokes it (`POST /pubsub`). So it's deployed *without* `--allow-unauthenticated`, and Pub/Sub authenticates via the `shoplens-runner` service account:

```bash
export PUSH_ENDPOINT="https://pubsub-worker-935092313069.us-central1.run.app/pubsub"

cd services/pubsub-worker
gcloud run deploy pubsub-worker \
  --source . --project=$PROJECT_ID --region=$REGION --service-account=$SA_EMAIL \
  --no-allow-unauthenticated \
  --set-env-vars="PROJECT_ID=$PROJECT_ID,TOPIC_ID=video-segments-topic,SUBSCRIPTION_ID=video-segments-sub,BUCKET_NAME=shoplens-dev-hls-segments,PUSH_ENDPOINT=$PUSH_ENDPOINT,AI_ANALYZER_URL=https://ai-analyzer-935092313069.us-central1.run.app,PRODUCT_MATCHER_URL=https://product-matcher-935092313069.us-central1.run.app,STATE_MANAGER_URL=https://state-manager-935092313069.us-central1.run.app,SESSION_ID=live-session-001"
cd ../..

# One-time: let the Pub/Sub service agent mint auth tokens as shoplens-runner
gcloud beta services identity create --service=pubsub.googleapis.com --project=$PROJECT_ID
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" --project=$PROJECT_ID

# Create the authenticated push subscription
gcloud pubsub subscriptions create video-segments-sub \
  --project=$PROJECT_ID --topic=video-segments-topic \
  --push-endpoint=$PUSH_ENDPOINT --push-auth-service-account=$SA_EMAIL
```

### Step 9 — Wire GCS Bucket Notifications

Configure the GCS bucket to notify Pub/Sub when HLS segments are finalized:

```powershell
gcloud storage buckets notifications create gs://shoplens-dev-hls-segments `
  --topic=video-segments-topic `
  --event-types=OBJECT_FINALIZE `
  --project=shoplens-dev-499700
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

### Option B: Deploy via GitHub Actions — NOT YET BUILT

**This option doesn't exist yet.** There is no `.github/workflows/` directory in this repo, and no `.github/DEPLOYMENT.md`. Everything deployed so far (§11) was done manually via `gcloud`/`firebase` CLI commands from Cloud Shell, authenticated as a real Google account — not via Workload Identity Federation from a GitHub Actions runner.

The Workload Identity Federation pool/provider *has* been provisioned (see §11.5 below), so the WIF half of the prerequisite work is done if someone wants to build this later. What's still missing is the actual workflow YAML files (`deploy-cloudrun.yml`, `deploy-firebase.yml`, `build-android.yml`, `build-ios.yml`) and the GitHub Environment secrets/variables.

If/when this gets built, here's the real `dev` Environment config it would need (single environment — there is no separate `prod`):

| Type | Name | Value |
|------|------|-------|
| Secret | `WIF_PROVIDER` | `projects/935092313069/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| Secret | `WIF_SERVICE_ACCOUNT` | `shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com` |
| Secret | `SA_EMAIL` | `shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com` |
| Secret | `NEXT_PUBLIC_FIREBASE_API_KEY` | Firebase web API key (ask the project owner) |
| Secret | `SERPAPI_KEY` | SerpApi key (ask the project owner — rotates periodically) |
| Secret | `GOOGLE_SERVICES_JSON` | base64 of `mobile/android/app/google-services.json` |
| Secret | `MOBILE_ENV` | base64 of `mobile/.env` |
| Secret | `GOOGLE_SERVICE_INFO_PLIST` | base64 of `mobile/ios/Runner/GoogleService-Info.plist` |
| Variable | `PROJECT_ID` / `FIREBASE_PROJECT_ID` / `NEXT_PUBLIC_FIREBASE_PROJECT_ID` | `shoplens-dev-499700` |
| Variable | `NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN` | `shoplens-dev-499700.firebaseapp.com` |
| Variable | `NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET` | `shoplens-dev-499700.firebasestorage.app` |
| Variable | `NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID` | `935092313069` |
| Variable | `NEXT_PUBLIC_FIREBASE_APP_ID` | `1:935092313069:web:897de0204af606d618a5e4` |
| Variable | `AI_ANALYZER_URL` | `https://ai-analyzer-935092313069.us-central1.run.app` |
| Variable | `PRODUCT_MATCHER_URL` | `https://product-matcher-935092313069.us-central1.run.app` |
| Variable | `STATE_MANAGER_URL` | `https://state-manager-935092313069.us-central1.run.app` |
| Variable | `BUCKET_NAME` | `shoplens-dev-hls-segments` |
| Variable | `GCS_LENS_BUCKET` | `shoplens-dev-lens-tmp` |
| Variable | `SESSION_ID` | `live-session-001` |
| Variable | `HLS_STREAM_URL` | not set yet — no Live Stream channel exists (§7, step 10) |

A maintainer keeps a working copy of all of these (with real secret values) in a local-only, gitignored file called `github-secrets-dev` at the repo root — ask them for it rather than re-deriving these from scratch. See [docs/local-setup.md](docs/local-setup.md).

> `GCS_LENS_BUCKET` must point at a bucket that allows public object reads (`allUsers` → `roles/storage.objectViewer`, since SerpApi fetches a public `storage.googleapis.com` URL) and grants the runtime SA `roles/storage.objectAdmin` — see [Branching-Strategy.md](Branching-Strategy.md#gcs_lens_bucket-setup-one-time-per-project) for the exact commands. `gs://shoplens-dev-lens-tmp` already satisfies both.

**Required IAM roles for the Cloud Run runner SA** (grant once per project):

```bash
# roles/run.admin — allows deploying and managing Cloud Run services
gcloud projects add-iam-policy-binding shoplens-dev-499700 \
  --member="serviceAccount:shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com" \
  --role="roles/run.admin"

# roles/iam.serviceAccountUser — allows SA to assign itself as Cloud Run runtime identity
gcloud iam service-accounts add-iam-policy-binding \
  shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com \
  --member="serviceAccount:shoplens-runner@shoplens-dev-499700.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

## 13. Next Steps

### ✅ Recently Completed (2026-06-18 — see docs/status/2026-06-18.md)

- ~~Deploy Cloud Run services~~ — all 4 services deployed manually to `shoplens-dev-499700` (3 public, `pubsub-worker` locked to authenticated-only)
- ~~Wire Pub/Sub push endpoint~~ — `video-segments-sub` push subscription created, authenticated via `shoplens-runner`
- ~~Image analysis path~~ — Analyze button works end-to-end against the deployed services
- ~~Firebase app config~~ — Android/iOS apps registered via `flutterfire configure`, web app config retrieved from console
- ~~Rotate leaked SerpApi key~~ — old key purged from git history and revoked, new key in use

### Not yet done — don't assume these work

- **No CI/CD** — `.github/workflows/` is empty; all deploys are manual `gcloud`/`firebase` CLI commands (see §12, Option B)
- **No Firebase Hosting deploy** — frontend only runs locally so far (`npm run dev`)
- **No Live Stream channel** — only the on-demand Analyze button path has been tested; nothing produces a live RTMP/HLS feed yet

### High Priority (Blocking)

1. **Set up the Live Stream channel** — Part 5 of `docs/shop-lens-cloud-setup.md`. Without it there's no RTMP source, so the live (non-Analyze-button) pipeline path is completely untested even though the code/infra for it is wired.

2. **Wire GCS bucket notifications**
   - Run once: `gcloud storage buckets notifications create gs://shoplens-dev-hls-segments --topic=video-segments-topic --event-types=OBJECT_FINALIZE --project=shoplens-dev-499700`
   - This is the missing trigger that starts the live pipeline

3. **Verify end-to-end live stream**
   - Stream RTMP via OBS → confirm HLS segments land in GCS → Pub/Sub fires → Gemini analyzes → products appear in frontend in real time

4. **Deploy the frontend to Firebase Hosting** — currently dev-only

### Medium Priority (Feature Complete)

5. **Add Speech-to-Text transcription**
   - `ai-analyzer/analyzer.py` already accepts a `transcript` parameter
   - Add a Cloud Speech-to-Text call on the audio track before Gemini analysis to improve detection accuracy

6. **Replace product catalog**
   - Currently a static 20-item JSON file in `services/product-matcher/catalog.json`
   - Integrate with Google Shopping API or Cloud SQL

### Low Priority (Polish)

7. **Add Cloud Workflows orchestration**
   - Replace direct HTTP calls with Cloud Workflows for retry logic and observability

8. **Analytics pipeline**
   - Stream Firestore writes to BigQuery via Datastream

9. **Multi-tenant sessions**
   - Pass `session_id` through the entire pipeline to support concurrent live streams

10. **(Optional) Build CI/CD** — author the GitHub Actions workflows referenced in §12 Option B, now that the Workload Identity Federation prerequisite is already provisioned