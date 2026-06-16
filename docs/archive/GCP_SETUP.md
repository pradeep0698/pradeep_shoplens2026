# CookShop — GCP Infrastructure Setup Guide

**Project:** cookshop-poc | **Region:** us-central1 | **Est. first-time setup:** ~2–3 hours

---

## Prerequisites

- `gcloud` CLI installed and authenticated
- Docker installed (used by `gcloud run deploy --source`)
- Node.js 18+ and npm
- Firebase CLI: `npm install -g firebase-tools`
- Python 3.11+
- GCP account with billing enabled

## Naming Conventions

| Variable | Value |
|----------|-------|
| PROJECT_ID | `cookshop-poc` |
| REGION | `us-central1` |
| BUCKET_NAME | `cookshop-poc-hls-segments` |
| TOPIC_ID | `video-segments-topic` |
| SUBSCRIPTION_ID | `video-segments-sub` |
| CHANNEL_ID | `my-cooking-show-channel` |
| INPUT_ID | `my-rtmp-input` |
| SESSION_ID | `live-session-001` |
| SA_EMAIL | `cookshop-runner@cookshop-poc.iam.gserviceaccount.com` |

---

## Completed Steps ✅

These steps are done. **Do not re-run them.**

### Step 1 — GCP Project + APIs ✅

Project `cookshop-poc` created with billing linked. All 13 APIs enabled:
Cloud Run, Pub/Sub, Cloud Storage, Firestore, Firebase Management, Vertex AI, Speech-to-Text, Cloud Vision, Live Stream API, Artifact Registry, Cloud Build, IAM, Secret Manager.

### Step 2 — IAM Service Account ✅

Service account `cookshop-runner` created with 8 roles:
`roles/run.invoker`, `roles/pubsub.publisher`, `roles/pubsub.subscriber`, `roles/datastore.user`, `roles/aiplatform.user`, `roles/storage.objectViewer`, `roles/storage.admin`, `roles/livestream.admin`

To download the JSON key for local testing (if needed):
```powershell
gcloud iam service-accounts keys create ./cookshop-runner-key.json `
  --iam-account=cookshop-runner@cookshop-poc.iam.gserviceaccount.com `
  --project=cookshop-poc
# !! Do NOT commit this file. Add to .gitignore immediately.
$env:GOOGLE_APPLICATION_CREDENTIALS = "$(Get-Location)\cookshop-runner-key.json"
```

### Step 3 — Cloud Storage Bucket ✅

Bucket `gs://cookshop-poc-hls-segments` created in us-central1 with uniform bucket-level access.
`allUsers` granted `roles/storage.objectViewer` for HLS playback.

Live Stream API service account needs write access (run once after first channel creation attempt):
```powershell
# Get your project number first:
gcloud projects describe cookshop-poc --format="value(projectNumber)"
# Then (replace PROJECT_NUMBER):
gcloud storage buckets add-iam-policy-binding gs://cookshop-poc-hls-segments `
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-livestream.iam.gserviceaccount.com" `
  --role="roles/storage.objectCreator"
```

### Step 4 — Firestore Database ✅

Default Firestore database created in Native mode, us-central1.

Firebase also linked to the project (required for firebase-admin SDK + Firebase Hosting).
Firebase Web App config captured in Step 5c — needed for `frontend/.env.local`.

### Step 5 — Pub/Sub Topic + Subscription ✅

- Topic: `video-segments-topic`
- Subscription: `video-segments-sub` — push delivery to `https://pubsub-worker-1017419148960.us-central1.run.app/pubsub`

GCS bucket notifications configured via `infra/pubsub_setup.py`.

### Step 6 — All 4 Cloud Run Services Deployed ✅

Deployed 2026-05-04. All services: `--allow-unauthenticated`, `cookshop-runner` service account, `us-central1`.

| Service | URL | Config |
|---------|-----|--------|
| state-manager | https://state-manager-1017419148960.us-central1.run.app | 512Mi, PROJECT_ID + SESSION_ID |
| product-matcher | https://product-matcher-1017419148960.us-central1.run.app | 512Mi |
| ai-analyzer | https://ai-analyzer-1017419148960.us-central1.run.app | 2Gi, 2 CPU, 120s timeout, PROJECT_ID + LOCATION |
| pubsub-worker | https://pubsub-worker-1017419148960.us-central1.run.app | 512Mi, 120s timeout, all 3 service URLs + SESSION_ID |

Verify all 4 are healthy:
```bash
curl https://state-manager-1017419148960.us-central1.run.app/health
curl https://product-matcher-1017419148960.us-central1.run.app/health
curl https://ai-analyzer-1017419148960.us-central1.run.app/healthz
curl https://pubsub-worker-1017419148960.us-central1.run.app/health
# All should return: {"status": "ok"}
```

---

## Remaining Steps ⚠️

### Step 7 — Provision the Live Stream Channel

Run once before the first demo. The channel can be stopped and restarted between sessions.

**7a.** Create `services/live-ingest/.env` (gitignored — create manually):
```
PROJECT_ID=cookshop-poc
LOCATION=us-central1
BUCKET_NAME=cookshop-poc-hls-segments
CHANNEL_ID=my-cooking-show-channel
INPUT_ID=my-rtmp-input
```

**7b.** Install dependencies and run:
```bash
cd services/live-ingest
pip install google-cloud-video-live-stream python-dotenv
python setup_live_stream.py
```

Expected output — **save both values**:
```
RTMP ingest URI: rtmp://x.x.x.x/live/my-rtmp-input   ← point OBS here
HLS playback URL: https://storage.googleapis.com/cookshop-poc-hls-segments/hls-output/manifest.m3u8
                  ← set as NEXT_PUBLIC_HLS_STREAM_URL in frontend/.env.local
Channel state: STREAMING
```

**7c.** Stop channel when not streaming (saves cost):
```powershell
gcloud livestream channels stop my-cooking-show-channel `
  --location us-central1 --project cookshop-poc
```

**7d.** Restart before each demo:
```powershell
gcloud livestream channels start my-cooking-show-channel `
  --location us-central1 --project cookshop-poc
```

### Step 8 — Configure OBS (or any RTMP encoder)

Using the RTMP URI from Step 7b:

- Settings → Stream → Service: **Custom...**
- **Server:** `rtmp://x.x.x.x/live` (everything **before** the last `/`)
- **Stream Key:** `my-rtmp-input` (everything **after** the last `/`)
- Click Apply → Start Streaming

Verify segments arrive in GCS (after 10–15 seconds of streaming):
```powershell
gcloud storage ls gs://cookshop-poc-hls-segments/hls-output/
# Should show .ts files: segment_000001.ts, etc., and manifest.m3u8
```

### Step 9 — Configure and Deploy the Frontend

**9a.** Create `frontend/.env.local` (gitignored — never commit):
```
NEXT_PUBLIC_FIREBASE_API_KEY=AIzaSy...
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=cookshop-poc.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=cookshop-poc
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=cookshop-poc.appspot.com
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=<from Firebase console>
NEXT_PUBLIC_FIREBASE_APP_ID=<from Firebase console>
NEXT_PUBLIC_SESSION_ID=live-session-001
NEXT_PUBLIC_HLS_STREAM_URL=<HLS manifest URL from Step 7b>
```
Firebase config values: Firebase Console → Project Settings → General → Your apps → CookShop Web.

**9b.** Test locally (optional):
```bash
cd frontend && npm install && npm run dev
# Open http://localhost:3000
# Expected: two-panel layout, shopping list shows "Waiting for items..."
```

**9c.** Deploy:
```bash
cd frontend
firebase login       # signs in via browser
firebase use cookshop-poc
npm run build
firebase deploy --only hosting
# Demo URL: https://cookshop-poc.web.app
```

### Step 10 — End-to-End Smoke Test

Run these checks in order:

**Check 1 — Frontend loads:**
Open `https://cookshop-poc.web.app`
→ Two-panel layout, video player on left, "Waiting for items..." on right

**Check 2 — All services healthy:**
```bash
curl https://state-manager-1017419148960.us-central1.run.app/health     # {"status":"ok"}
curl https://product-matcher-1017419148960.us-central1.run.app/health   # {"status":"ok"}
curl https://ai-analyzer-1017419148960.us-central1.run.app/healthz      # {"status":"ok"}
curl https://pubsub-worker-1017419148960.us-central1.run.app/health     # {"status":"ok"}
```

**Check 3 — Firestore → Frontend real-time update:**
```bash
curl -X POST https://state-manager-1017419148960.us-central1.run.app/session/live-session-001/products \
  -H "Content-Type: application/json" \
  -d '{"products": [{"product_id": "p001", "name": "Roma Tomatoes", "price": 2.99, "image_url": "https://placehold.co/200x200?text=Tomato"}]}'
# Expected response: {"status":"updated","session_id":"live-session-001"}
# Expected in browser: shopping list updates within 1–2s without refresh
```

**Check 4 — Product matcher:**
```bash
curl -X POST https://product-matcher-1017419148960.us-central1.run.app/match \
  -H "Content-Type: application/json" \
  -d '{"items": ["Tomato", "Olive Oil", "Chef knife"]}'
# Expected: {"matched": [3 product objects], "unmatched": []}
```

**Check 5 — Full pipeline (OBS → shopping list):**
1. Start streaming in OBS
2. Watch logs: `gcloud run services logs read pubsub-worker --region us-central1 --limit 50`
3. Expected sequence:
   ```
   New video segment ready: gs://cookshop-poc-hls-segments/hls-output/segment_000001.ts
   ai-analyzer returned 4 item(s): ["Tomato", "Olive Oil", "Chef's Knife", "Cutting Board"]
   product-matcher returned 3 matched product(s)
   ```
4. Frontend shopping list updates automatically

---

## Environment Variables Reference

**`services/pubsub-worker/.env`** (gitignored)
```
PROJECT_ID=cookshop-poc
TOPIC_ID=video-segments-topic
SUBSCRIPTION_ID=video-segments-sub
BUCKET_NAME=cookshop-poc-hls-segments
PUSH_ENDPOINT=https://pubsub-worker-1017419148960.us-central1.run.app/pubsub
AI_ANALYZER_URL=https://ai-analyzer-1017419148960.us-central1.run.app
PRODUCT_MATCHER_URL=https://product-matcher-1017419148960.us-central1.run.app
STATE_MANAGER_URL=https://state-manager-1017419148960.us-central1.run.app
SESSION_ID=live-session-001
PORT=8080
```

**`services/ai-analyzer/.env`** (gitignored)
```
PROJECT_ID=cookshop-poc
LOCATION=us-central1
PORT=8080
```

**`services/product-matcher/.env`** (gitignored)
```
PORT=8080
```

**`services/state-manager/.env`** (gitignored)
```
PROJECT_ID=cookshop-poc
SESSION_ID=live-session-001
PORT=8080
GOOGLE_APPLICATION_CREDENTIALS=C:\path\to\cookshop-runner-key.json  # local dev only
```

**`services/live-ingest/.env`** (gitignored)
```
PROJECT_ID=cookshop-poc
LOCATION=us-central1
BUCKET_NAME=cookshop-poc-hls-segments
CHANNEL_ID=my-cooking-show-channel
INPUT_ID=my-rtmp-input
```

**`infra/.env`** (gitignored)
```
PROJECT_ID=cookshop-poc
TOPIC_ID=video-segments-topic
SUBSCRIPTION_ID=video-segments-sub
BUCKET_NAME=cookshop-poc-hls-segments
PUSH_ENDPOINT=https://pubsub-worker-1017419148960.us-central1.run.app/pubsub
```

**`frontend/.env.local`** (gitignored)
```
NEXT_PUBLIC_FIREBASE_API_KEY=AIzaSy...
NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=cookshop-poc.firebaseapp.com
NEXT_PUBLIC_FIREBASE_PROJECT_ID=cookshop-poc
NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET=cookshop-poc.appspot.com
NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID=<from Firebase console>
NEXT_PUBLIC_FIREBASE_APP_ID=<from Firebase console>
NEXT_PUBLIC_SESSION_ID=live-session-001
NEXT_PUBLIC_HLS_STREAM_URL=<HLS manifest URL from Step 7b>
```

---

## Troubleshooting

**pubsub-worker logs show 502 when calling ai-analyzer**
Cold start takes 10–20 seconds. Keep ai-analyzer warm with a minimum instance:
```powershell
gcloud run services update ai-analyzer --min-instances 1 --region us-central1 --project cookshop-poc
# Note: min-instances 1 costs ~$15-20/month even when not streaming
```

**ai-analyzer returns empty items list for every segment**
- Check env vars: `gcloud run services describe ai-analyzer --region us-central1 --format="value(spec.template.spec.containers[0].env)"`  
  Verify `PROJECT_ID=cookshop-poc` and `LOCATION=us-central1`
- Check if the .ts segment is too short (< 2 seconds) or corrupt

**Frontend shopping list does not update after Firestore write**
- `SESSION_ID` mismatch: `NEXT_PUBLIC_SESSION_ID` in `frontend/.env.local` must equal `live-session-001`
- Firebase project mismatch: `NEXT_PUBLIC_FIREBASE_PROJECT_ID` must be `cookshop-poc`
- Frontend was built before `.env.local` existed: re-run `npm run build && firebase deploy --only hosting`

**pubsub-worker receives nothing (no segment events)**
GCS notification may have been misconfigured. Delete and recreate:
```bash
gcloud pubsub subscriptions delete video-segments-sub --project cookshop-poc
gcloud pubsub topics delete video-segments-topic --project cookshop-poc
python infra/pubsub_setup.py
```

**OBS connects but no .ts segments appear in GCS**
- RTMP URI split incorrectly in OBS — verify Server vs Stream Key split
- Channel not in STREAMING state: `gcloud livestream channels describe my-cooking-show-channel --location us-central1 --project cookshop-poc --format="value(streamingState)"`
- If not STREAMING: re-run `python services/live-ingest/setup_live_stream.py`

---

## Estimated Monthly Cost (POC)

| Service | Est. Cost/Month |
|---------|----------------|
| Cloud Run (4 services, low traffic) | $0–5 |
| Vertex AI Gemini (depends on segment volume) | $5–20 |
| Live Stream API | $5–10 per hour of active channel |
| Cloud Storage | $1–3 |
| Pub/Sub, Firestore, Firebase Hosting | $0 (within free tier) |
| **Total (idle)** | **~$15–40/month** |
| **Per hour of live streaming** | **+$5–10** |

**Save money:** Always stop the Live Stream channel between demo sessions (Step 7c).
