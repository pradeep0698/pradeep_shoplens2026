# CookShop — Project Progress Tracker

Last Updated: 2026-05-04

---

## Demo Status

| Area | Status | What's Needed |
|------|--------|---------------|
| Cloud Infrastructure | ✅ Complete | — |
| AI + Product Pipeline | ✅ Complete | — |
| Pub/Sub Wiring | ✅ Complete | — |
| Live Stream Channel | ⚠️ Pending | Run `setup_live_stream.py` |
| Frontend Deployed | ⚠️ Pending | Fill `.env.local`, run Firebase deploy |
| End-to-End Pipeline | ❌ Not Tested | Requires Live Stream + OBS + Frontend |

**Overall: ~75% to first live demo. Two steps remain.**

---

## Critical Path to Demo

### Step 1 — Provision the Live Stream Channel
```bash
cd services/live-ingest
python setup_live_stream.py
```
Save the two outputs printed at the end:
- **RTMP ingest URI** → enter into OBS encoder (Settings → Stream → Custom)
- **HLS manifest URL** → set as `NEXT_PUBLIC_HLS_STREAM_URL` in `frontend/.env.local`

Stop the channel between sessions to save cost:
```bash
gcloud livestream channels stop my-cooking-show-channel --location us-central1 --project cookshop-poc
```

### Step 2 — Configure OBS
- Settings → Stream → Service: **Custom...**
- Server: `rtmp://<ip>/live` (everything **before** the last `/`)
- Stream Key: `my-rtmp-input` (everything **after** the last `/`)
- Click Apply → Start Streaming

### Step 3 — Deploy the Frontend
1. Fill `frontend/.env.local` with Firebase config values (see [GCP_SETUP.md](GCP_SETUP.md) Step 10)
2. Build and deploy:
   ```bash
   cd frontend
   npm install
   npm run build
   firebase deploy --only hosting
   ```
3. **Demo URL:** `https://cookshop-poc.web.app`

### Step 4 — Smoke Test
1. Check all 4 Cloud Run health endpoints (see URLs below)
2. POST a test product directly to state-manager and verify the frontend shopping list updates in < 2s:
   ```bash
   curl -X POST https://state-manager-1017419148960.us-central1.run.app/session/live-session-001/products \
     -H "Content-Type: application/json" \
     -d '{"products": [{"product_id": "p001", "name": "Roma Tomatoes", "price": 2.99, "image_url": "https://placehold.co/200x200?text=Tomato"}]}'
   ```
3. Start OBS, wait 15–30 seconds, watch pubsub-worker logs, confirm shopping list auto-updates

---

## Cloud Run Service URLs

| Service | URL |
|---------|-----|
| state-manager | https://state-manager-1017419148960.us-central1.run.app |
| product-matcher | https://product-matcher-1017419148960.us-central1.run.app |
| ai-analyzer | https://ai-analyzer-1017419148960.us-central1.run.app |
| pubsub-worker | https://pubsub-worker-1017419148960.us-central1.run.app |
| Frontend | https://cookshop-poc.web.app *(pending deploy)* |

---

## Infrastructure — Completed

| Component | Resource | Done |
|-----------|----------|------|
| GCP Project | cookshop-poc | ✅ |
| APIs (13) | Cloud Run, Pub/Sub, Storage, Firestore, Firebase, Vertex AI, Speech-to-Text, Vision, Live Stream, Artifact Registry, Cloud Build, IAM, Secret Manager | ✅ |
| Service Account | cookshop-runner@cookshop-poc.iam.gserviceaccount.com — 8 roles | ✅ |
| Cloud Storage | gs://cookshop-poc-hls-segments — us-central1, public read | ✅ |
| Firestore | Default database, Native mode, us-central1 | ✅ |
| Pub/Sub | video-segments-topic + video-segments-sub → pubsub-worker | ✅ |
| state-manager | Deployed, allow-unauthenticated | ✅ |
| product-matcher | Deployed, allow-unauthenticated | ✅ |
| ai-analyzer | Deployed, 2Gi / 2 CPU / 120s timeout | ✅ |
| pubsub-worker | Deployed, env vars set (all 3 service URLs + SESSION_ID) | ✅ |

---

## Phase 1 — MVP Task Detail

### Epic 1: Video Ingestion & AI Analysis Pipeline

**Story 1.1 — Live Video Ingestion**

| # | Task | Status |
|---|------|--------|
| 1.1.1 | GCP project setup + enable all APIs | ✅ |
| 1.1.2 | IAM service account + 8 roles | ✅ |
| 1.1.3 | Live Stream SDK setup script | ✅ `services/live-ingest/setup_live_stream.py` |
| 1.1.4 | Configure RTMP input endpoint | ✅ `create_input()` in setup script |
| 1.1.5 | Configure HLS/DASH output → GCS | ✅ manifest.m3u8 → gs://cookshop-poc-hls-segments |
| 1.1.6 | End-to-end: stream sample video, verify segments in GCS | ⬜ Requires Live Stream provisioned |

**Story 1.2 — Event-Driven Worker Triggering**

| # | Task | Status |
|---|------|--------|
| 1.2.1 | Create Pub/Sub topic | ✅ video-segments-topic |
| 1.2.2 | Configure GCS bucket → Pub/Sub notification | ✅ `configure_gcs_notifications()` in pubsub_setup.py |
| 1.2.3 | FastAPI /pubsub endpoint | ✅ `services/pubsub-worker/main.py` |
| 1.2.4 | Parse Pub/Sub message + extract GCS URL | ✅ `_decode_pubsub_message()` |
| 1.2.5 | Containerize (Dockerfile) | ✅ `services/pubsub-worker/Dockerfile` |
| 1.2.6 | Deploy to Cloud Run | ✅ pubsub-worker deployed |
| 1.2.7 | Wire Pub/Sub push subscription → Cloud Run endpoint | ✅ push endpoint configured |
| 1.2.8 | Integration test: verify trigger fires on new segment | ⬜ Requires full pipeline running |

**Story 1.3 — Core AI Stream Analysis**

| # | Task | Status |
|---|------|--------|
| 1.3.1 | Speech-to-Text transcription | ⬜ transcript param exists; nothing generates it yet |
| 1.3.2 | Vision AI object detection | ⬜ Gemini handles visual; standalone Vision AI not wired |
| 1.3.3 | Vertex AI Gemini prompt (cooking show analyst persona) | ✅ `analyze_segment()` in `services/ai-analyzer/analyzer.py` |
| 1.3.4 | Pass video segment + transcript → Gemini, parse JSON | ✅ Downloads GCS video, calls Gemini 2.0 Flash |
| 1.3.5 | Validate + parse Gemini JSON output | ✅ Regex extraction with empty-array fallback |
| 1.3.6 | Unit tests with sample segment fixtures | ⬜ |
| 1.3.7 | Wire AI analysis into Cloud Run handler | ✅ pubsub-worker → ai-analyzer → product-matcher → state-manager |

### Epic 2: Product Matching, State & Frontend UI

**Story 2.1 — Product Search & Matching**

| # | Task | Status |
|---|------|--------|
| 2.1.1 | Static JSON catalog (20 grocery/retail items) | ✅ `services/product-matcher/catalog.json` |
| 2.1.2 | Product Matcher FastAPI — POST /match | ✅ `services/product-matcher/main.py` |
| 2.1.3 | Fuzzy matching (rapidfuzz WRatio) | ✅ `match_products()` in `matcher.py` |
| 2.1.4 | Return enriched product objects | ✅ product_id, name, price, image_url |
| 2.1.5 | Containerize (Dockerfile) | ✅ `services/product-matcher/Dockerfile` |
| 2.1.6 | Deploy to Cloud Run | ✅ product-matcher deployed |
| 2.1.7 | Unit tests for matching function | ⬜ |

**Story 2.2 — Live State Management**

| # | Task | Status |
|---|------|--------|
| 2.2.1 | Create Firestore database (Native mode) | ✅ us-central1 |
| 2.2.2 | Define LiveShoppingSessions collection schema | ✅ products[] + last_updated |
| 2.2.3 | Python function to overwrite session doc (Firebase Admin SDK) | ✅ `update_session()` in `state_manager.py` |
| 2.2.4 | last_updated SERVER_TIMESTAMP field | ✅ |
| 2.2.5 | Connect product-matcher output → Firestore write | ✅ pubsub-worker orchestrates via HTTP |
| 2.2.6 | Test real-time listener reflects writes within 2s | ⬜ |

**Story 2.3 — Live Web Application**

| # | Task | Status |
|---|------|--------|
| 2.3.1 | Scaffold Next.js 14 app (TypeScript + Tailwind) | ✅ `frontend/` |
| 2.3.2 | Firebase Hosting config | ✅ `firebase.json` + `.firebaserc` + `next.config.js` |
| 2.3.3 | Two-panel layout: video player + shopping list sidebar | ✅ `frontend/src/app/page.tsx` |
| 2.3.4 | HLS video player (hls.js, low-latency mode) | ✅ `frontend/src/components/VideoPlayer.tsx` |
| 2.3.5 | Firestore onSnapshot listener | ✅ `frontend/src/components/ShoppingList.tsx` |
| 2.3.6 | Product cards (name, price, image, buy link, LIVE/OFFLINE badge) | ✅ |
| 2.3.7 | Deploy to Firebase Hosting + smoke test | ⬜ **Next action** |

---

## Phase 2 — Production Roadmap

All items below are open and not started. Phase 1 (demo) must be complete before starting Phase 2.

| Epic | Goal | Priority |
|------|------|----------|
| **Epic 3: Enterprise Delivery** | Media CDN, Cloud Storage for recordings, CDN caching | Medium |
| **Epic 4: Advanced AI** | Eventarc + Cloud Workflows orchestration, Vision OCR, enhanced Gemini (quantities, confidence) | Medium |
| **Epic 5: Product Discovery** | Google Shopping API, Retailer/Grocery APIs (Instacart, Kroger), affiliate links, sponsored products | High |
| **Epic 6: Data Layer** | Cloud SQL (PostgreSQL), BigQuery analytics, PDF/CSV export, shareable lists | Medium |
| **Epic 7: Security & DevOps** | IAM hardening, Secret Manager for all creds, Cloud Monitoring/Alerting, Cloud Build CI/CD | High |
