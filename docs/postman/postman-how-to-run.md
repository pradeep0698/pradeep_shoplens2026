# ShopLens Postman — How to Run

This covers the two Postman collections in this repo, the environments they
run against, how to run them (Postman app or CLI/skill), and known
gotchas/caveats you'll hit along the way.

## Collections

### 1. `docs/postman/shoplens-all-services.postman_collection.json`

The main functional collection — one folder per backend service, plus a
`_Flows` folder with end-to-end scenarios.

| Folder | Requests |
|---|---|
| **AI Analyzer** | Health Check · Get Active Model · Set Active Model · Analyze - Image URL · Analyze - Base64 Image · Analyze - GCS Video URI · Analyze Stream (NDJSON) · Identify - Cropped Product Image · Identify - Rejects image_url (expected 400) |
| **Product Matcher** | Health Check · Match Items to Products · Search Products by Query · Get Thumbnail (CORS Proxy) · Debug - Match Single Item · Debug Raw - SerpAPI Response |
| **State Manager** | Health Check · Save Products to Session · Get Session Products · Clear Session |
| **Voice Assistant** | Health Check · Start Voice Session · Send Session Event · Finalize Voice Session |
| **Pub/Sub Worker** | Health Check · Simulate Pub/Sub Push Message |
| **_Flows** | Full Analyze Pipeline (analyze → match → save → verify) · All Health Checks (one request per service) |

34 requests total.

### 2. `postman/shoplens-analyze-perf.postman_collection.json`

A small fixed-input performance harness for ai-analyzer only — used to
benchmark `/analyze` and `/identify` latency with a consistent test image,
independent of the main functional suite. Run order: `0. Check Current
Model` → `1. Analyze - Fixed Test Image` and/or `2. Identify - Fixed Crop`.
Each request logs `time_ms` to the console so you can track latency over
time. This one always targets ai-analyzer only, via its own environment
(see below) — it isn't parameterized by service like the main collection.

## Environments

| File | Points at | Notes |
|---|---|---|
| `docs/postman/cookshop-dev-rajan-prod.postman_environment.json` | Project `cookshop-dev-prj` (`82592393149`) | The live, actively-used dev environment ("Rajan prod"). All 5 services public and reachable. |
| `docs/postman/shoplens-dev.postman_environment.json` | Project `shoplens-dev-499700`, now on project number `115535290381` | ai-analyzer, product-matcher, state-manager, voice-assistant are public. `pubsub-worker` requires an authenticated Cloud Run invoker and returns `403 Forbidden` from Google's frontend for unauthenticated requests — that's correct/expected, not a bug. |
| `postman/shoplens-dev-cloud.postman_environment.json` | ai-analyzer only, project `115535290381` | Used by the perf collection (`baseUrl` variable). |
| `postman/shoplens-local.postman_environment.json` | `http://localhost:8080` | Used by the perf collection when running ai-analyzer locally (`uvicorn main:app --port 8080`). |

Select the environment in the Postman app's environment dropdown (top
right), or pass it via `-e <file>` with Newman.

## Collection variables (shoplens-all-services)

| Variable | Default | Purpose |
|---|---|---|
| `session_id` | `live-session-001` | Used by State Manager + the Full Analyze Pipeline flow. |
| `firebase_token` | *(empty, secret)* | Firebase ID token for Voice Assistant auth. Get one via `user.getIdToken()` in the Firebase Auth SDK. Without it, Voice Assistant requests return `401` — expected. |
| `voice_session_id` | *(empty)* | Set automatically by the "Start Voice Session" test script. |
| `test_item` | `stand mixer` | Item name used by the Product Matcher debug requests. |
| `test_thumbnail_url` | placeholder Google CDN URL | Used by `GET /thumbnail`. The default is a fake placeholder and will 502 — grab a real `image_url` from a `/match` or `/search` response and set it here to test for real. |
| `image_base64` | tiny valid solid-color JPEG | Used by "Analyze - Base64 Image". Swap in a real product photo's base64 to exercise actual detection. |
| `identify_crop_base64` | tiny valid solid-color JPEG | Used by "Identify - Cropped Product Image". Swap in a real cropped photo's base64 to exercise actual identification. |

## How to run

### Option A — Postman app

1. Import both collections: `docs/postman/shoplens-all-services.postman_collection.json` and `postman/shoplens-analyze-perf.postman_collection.json`.
2. Import the environment(s) you need from the tables above.
3. Pick the environment in the top-right dropdown, then run individual requests or use the Collection Runner for a full pass.
4. For Voice Assistant requests, set `firebase_token` to a real Firebase ID token first.

### Option B — CLI / Newman directly

```bash
newman run docs/postman/shoplens-all-services.postman_collection.json \
  -e docs/postman/cookshop-dev-rajan-prod.postman_environment.json

newman run postman/shoplens-analyze-perf.postman_collection.json \
  -e postman/shoplens-dev-cloud.postman_environment.json
```

Requires `newman` (`npm install -g newman`). Add `--reporters cli,htmlextra
--reporter-htmlextra-export <path>.html` for an HTML report (requires
`npm install -g newman-reporter-htmlextra`).

### Option C — the `/run-postman-tests` skill (recommended)

```bash
bash scripts/run-postman-tests.sh                    # main collection vs cookshop-dev-rajan-prod (default)
bash scripts/run-postman-tests.sh shoplens-dev        # main collection vs shoplens-dev instead
bash scripts/run-postman-tests.sh --with-perf         # main collection + the perf collection
bash scripts/run-postman-tests.sh --perf-only         # only the perf collection
```

This auto-installs `newman-reporter-htmlextra` if missing and writes a
timestamped HTML report to `docs/postman/test-results/<yyyy-mm-dd-hh-mm>-<suite>.html`.
Past reports are kept in that folder for the record — see `.claude/commands/run-postman-tests.md`
for the full skill definition, or just run `/run-postman-tests` in Claude Code.

## Regenerating the OpenAPI specs

`docs/api-specs/*.openapi.json` is generated from each service's live
FastAPI app, not hand-written. Regenerate after any route/schema change:

```bash
python docs/postman/generate_openapi_specs.py                     # local introspection, no server needed
python docs/postman/generate_openapi_specs.py --env shoplens-dev  # fetch from a deployed environment instead
python docs/postman/generate_openapi_specs.py --env cookshop-dev
python docs/postman/generate_openapi_specs.py --service ai-analyzer  # one service only
```

Local mode imports each service's `main.py` directly and calls
`app.openapi()` — it needs that service's `requirements.txt` deps
installed (fastapi, pydantic, etc.) but does **not** need real GCP
credentials, since client objects (Firestore, GCS, Vertex/genai) are all
constructed lazily inside route handlers, not at import time.

## Known issues / expected non-200s

These are not bugs — they're either intentional negative tests or
placeholder example data that needs a real value swapped in:

- **Voice Assistant `401`** on Start/Send/Finalize — no real `firebase_token` set.
- **`Identify - Rejects image_url (expected 400)`** — intentionally sends `image_url` with no `image_data` to verify `/identify` correctly rejects it (the endpoint only accepts base64 `image_data`, since the crop is already selected on-device by ML Kit).
- **`GET /thumbnail` → `502`** — `test_thumbnail_url` is still the placeholder; needs a real CDN URL.
- **`Analyze - GCS Video URI` → `500`** — the example `gcs_uri` points at a bucket from the old `shoplens-dev` project, not reachable from `cookshop-dev-rajan-prod`'s service account. Swap in a real segment URI from whichever project you're targeting.
- **`Simulate Pub/Sub Push Message` → `502`** — the example payload references a GCS object that doesn't actually exist, so ai-analyzer can't fetch it downstream. Swap in a real object path to test the full pipeline.
- **`shoplens-dev`'s `pubsub-worker` → `403`** — Cloud Run IAM blocks unauthenticated access by design; only reachable with a real invoker identity/token. `cookshop-dev-rajan-prod`'s `pubsub-worker` is public and testable as-is.
