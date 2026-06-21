# Automation Regression Suite — Reference Notes

Everything QA needs to build an automated regression suite against the
ShopLens backend (and the mobile/frontend integration points that depend on
it), gathered from the actual deployed services and current code as of
2026-06-21. Where something is a known gap, inconsistency, or flaky-by-design
behavior, it's called out explicitly rather than glossed over — these are the
things that will otherwise cause false failures in an automated suite.

---

## 1. Environment

| Thing | Value |
|---|---|
| GCP project | `shoplens-dev-499700` (project number `935092313069`) |
| Region | `us-central1` |
| Auth | **None required** — all three services have `allUsers` granted `roles/run.invoker` (public). No API key, no bearer token, no IAM. |
| CORS | Wide open (`allow_origins=["*"]`) on all three services. |

### Service URLs

| Service | URL |
|---|---|
| `ai-analyzer` | `https://ai-analyzer-935092313069.us-central1.run.app` |
| `product-matcher` | `https://product-matcher-935092313069.us-central1.run.app` |
| `state-manager` | `https://state-manager-935092313069.us-central1.run.app` |

Cloud Run also exposes each service under an alternate hash-based hostname
(e.g. `https://ai-analyzer-u3vs4m3yza-uc.a.run.app`) — both forms resolve to
the same live service. Use the project-number form above; it's what the
existing Postman environment and `docs/local-setup.md` already use.

There is only **one environment** (no separate staging/prod) — this dev
project's Cloud Run services are what the mobile app, frontend, and any
automation all point at. Be aware that load you generate here is shared with
real usage and other testing (see §6, SerpAPI quota).

### Checking what's actually live right now

```bash
curl -s https://ai-analyzer-935092313069.us-central1.run.app/health
curl -s https://ai-analyzer-935092313069.us-central1.run.app/config   # current Gemini model
```

---

## 2. Services & endpoints

### `ai-analyzer` (the main service — Gemini detection + Google Lens matching)

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | `{"status": "ok", "gcs_lens_bucket_set": bool, "serpapi_key_set": bool, "project_id_set": bool}` |
| GET | `/config` | `{"model": "<active Gemini model>"}` |
| POST | `/config` | Body `{"model": "gemini-2.5-flash"}` — switches the active model **in memory only**, resets to the `GEMINI_MODEL` env var on cold start/redeploy. Don't rely on this for a persistent change. |
| POST | `/analyze` | Full pipeline: Gemini multi-object detection → crop each item → Google Lens per item. One JSON response after every item finishes (bounded by the slowest item). |
| POST | `/analyze/stream` | Same pipeline as `/analyze`, but NDJSON — one line per item as it completes instead of waiting for all of them. See §2a. |
| POST | `/identify` | Tap-to-identify: skips Gemini's object detection (image is already a single pre-cropped item), goes straight to Gemini description → Google Lens. |

**`/analyze` and `/identify` request body** (same `AnalyzeRequest` model for both; not all fields apply to both endpoints):

```jsonc
{
  "gcs_uri": null,            // analyze only — GCS video URI (live-stream path, no Lens matching)
  "image_url": null,          // a fetchable image URL, alternative to image_data
  "image_data": "<base64>",   // base64-encoded image bytes — the path mobile/frontend actually use
  "image_mime_type": "image/jpeg",
  "transcript": "",           // unused by either current code path, kept for the video pipeline
  "ignore_terms": [],         // case-insensitive substrings; matching detected items are dropped
  "query": "",                // identify only — fallback text query if Gemini's description fails
  "country": "us",            // passed through to SerpAPI's gl param
  "max_searches": 5           // analyze only — hard cap is 5 regardless of what's requested (MAX_SEARCHES_PER_RUN)
}
```

Exactly one of `gcs_uri` / `image_url` / `image_data` must be provided to
`/analyze`, or you get `400 {"error_code": "INVALID_REQUEST"}`. `/identify`
specifically requires `image_data` (not `image_url`).

**`/analyze` and `/identify` response body:**

```jsonc
{
  "items": ["Black red silver Poly over-ear headphones", "..."],  // identify always returns [] here
  "products": [ /* Product[], see §3 */ ],
  "warnings": ["SERP_QUOTA_EXCEEDED"],   // see §6 for the real list — most warnings are free-text, not stable codes
  "gcs_uri": null,                        // analyze only, echoes the request
  "image_url": null                       // analyze only, echoes the request
}
```

Response header `X-Request-Id` (8 hex chars) is present on every response,
including errors — correlate with Cloud Run logs via `req=<id>`.

**Error responses** (non-2xx):

```jsonc
{"detail": "<message>", "error_code": "INVALID_REQUEST"}
```

| HTTP status | `error_code` | When |
|---|---|---|
| 400 | `INVALID_REQUEST` | Missing required input, or a `ValueError` inside the pipeline |
| 502 | `UPSTREAM_ERROR` | Timeout/connection/network error talking to Vertex AI, GCS, or SerpAPI |
| 500 | `INTERNAL_ERROR` | Anything else unhandled |
| (any) | `REQUEST_ERROR` | A raised `HTTPException` (rare on these two routes) |

#### 2a. `POST /analyze/stream` — NDJSON streaming (new, not yet in the Postman collection)

Same request body as `/analyze` (`gcs_uri` not supported — 400 if neither
`image_url` nor `image_data` given). Response is `Content-Type:
application/x-ndjson`, one JSON object per line, **no enclosing array**:

```
{"type": "items", "items": ["Black red silver Poly over-ear headphones", "Purple plastic small electronics case"]}
{"type": "match", "name": "Black red silver Poly over-ear headphones", "products": [ /* Product[] */ ], "warnings": []}
{"type": "match", "name": "Purple plastic small electronics case", "products": [...], "warnings": []}
{"type": "done", "warnings": []}
```

- `"items"` always arrives first (right after Gemini detection completes).
- One `"match"` per detected item, **in completion order, not detection
  order** — don't assert on ordering, only on the final set once `"done"`
  arrives.
- `"done"` is always last and signals end-of-stream (the HTTP connection
  closes after it).
- `{"type": "error", "detail": "...", "error_code": "..."}` replaces
  everything above if the pipeline throws mid-stream — same `error_code`
  values as the table above. **The HTTP status code is always 200 for this
  endpoint** — once a `StreamingResponse` starts, the status line is already
  sent, so failures are only detectable in-band via this event. Don't write
  an automation check that asserts a non-200 status for stream failures.

A quick way to sanity-check this from a shell:

```bash
curl -N -X POST https://ai-analyzer-935092313069.us-central1.run.app/analyze/stream \
  -H "Content-Type: application/json" -d @payload.json
```
(`-N` disables curl's own buffering — without it you won't see lines arrive progressively.)

### `product-matcher` (text-based fallback search, used when Lens finds nothing)

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | `{"status": "ok"}` or `503 {"status": "degraded", "missing_env": ["SERPAPI_KEY"]}` |
| POST | `/match` | Body `{"items": ["item name", ...], "ignore_terms": [], "max_searches": 5}` → `{"matched_products": [Product, ...], "unmatched": ["item name", ...]}` |
| GET | `/debug/{item}` | Single-item text search, for manual debugging only |
| GET | `/debug-raw/{item}` | Raw SerpAPI passthrough, for manual debugging only |

`max_searches` is hard-capped at 5 server-side regardless of what's
requested (`MAX_SEARCHES_PER_RUN` in `matcher.py`). Results are cached
in-process for 30 minutes per normalized item name (`cachetools.TTLCache`) —
**identical repeated `/match` calls within 30 min may return stale-but-cached
data instead of hitting SerpAPI fresh.** If a regression test depends on a
fresh SerpAPI lookup, use a unique/unseen item name, or expect the cache.

### `state-manager` (Firestore-backed session/shopping-list storage)

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | `{"status": "ok"}` |
| GET | `/session/{session_id}` | Returns the Firestore doc, or `404` if it doesn't exist |
| POST | `/session/{session_id}/products` | Body `{"products": [Product, ...]}` — **replaces the entire document**, does not merge/append (`ref.set(...)`, not `update`/`merge`) |
| DELETE | `/session/{session_id}` | Clears the session (sets `products: []`) — **note: the web/mobile clients don't actually call this**; they POST an empty `products` array instead, because (per a comment in `mobile/lib/data/sources/remote/session_api.dart`) the DELETE method "returns 500 in production." Worth a regression test on its own. |

Firestore collection: `LiveShoppingSessions`, document ID = the `session_id`
path param. Document shape:
```jsonc
{"products": [Product, ...], "last_updated": <Firestore server timestamp>}
```

**Session ID convention:** `shoplens-user-{firebase_uid}` — must match
exactly between the Flutter app and the Next.js frontend (there's an
explicit warning comment about this in `mobile/lib/core/utils/session_id.dart`
because they write to the same Firestore document and silently diverge if
the format ever drifts between platforms).

**Important semantic for regression tests:** because `/session/{id}/products`
*replaces* rather than merges, any test that calls it twice and expects
accumulation will fail unless the caller does its own load-merge-save first
(the mobile app's `TapIdentifyUseCase` does this client-side as of
2026-06-21 — see commit `4fa30ba` — but `state-manager` itself has no merge
semantics at all).

---

## 3. `Product` schema

Returned in `products` arrays from `/analyze`, `/identify`, `/match`, and
stored in Firestore via `state-manager`:

```jsonc
{
  "name": "Poly Blackwire 8225 UC: Crystal-Clear Calls, All-Day Comfort",
  "price": 206.0,
  "image_url": "https://...",
  "purchase_url": "https://...",
  "seller": "headsetadvisor.com",
  "product_id": "headsetadvisorcom-poly-blackwire--a1b2c3",   // slug + 6-char sha1 hash, NOT globally unique across runs for the same product if the title varies even slightly
  "category": "Electronics"
}
```

`category` is inferred from keyword matching against the product name/seller
(see `_CATEGORY_KEYWORDS` in `services/ai-analyzer/analyzer.py`), not from
any structured taxonomy. Possible values: `Furniture`, `Clothing`, `Kitchen &
Cookware`, `Accessories`, `Electronics`, `Home Decor`, `Sports & Outdoors`,
`Books & Stationery`, `General` (the fallback when nothing matches).

`product_id` is **not stable** across runs for "the same" real-world
product — it's derived from whatever exact title/seller string SerpAPI
returned that call, which can vary slightly run to run. Don't assert on
exact `product_id` values in regression tests; assert on `name`/`category`
patterns or just non-emptiness instead.

---

## 4. Existing Postman collection — what it covers and what it doesn't

Location: `postman/` in this repo.

| File | Purpose |
|---|---|
| `shoplens-analyze-perf.postman_collection.json` | The collection itself |
| `shoplens-local.postman_environment.json` | `baseUrl = http://localhost:8080` |
| `shoplens-dev-cloud.postman_environment.json` | `baseUrl` = the deployed `ai-analyzer` URL above |
| `_generate_collection.py` | Regenerates the collection — **edit this script and re-run it, don't hand-edit the collection JSON**, since the fixed test image is base64-embedded as a collection variable and would be unreadable to hand-edit anyway |

**Currently covers (3 requests):**
1. `GET /config` ("0. Check Current Model")
2. `POST /analyze` ("1. Analyze - Fixed Test Image") — fixed image embedded as `image_base64`
3. `POST /identify` ("2. Identify - Fixed Crop") — a deterministic crop of the same fixed image, embedded as `identify_crop_base64` (the crop region is controlled by `IDENTIFY_CROP_BOX_FRACTIONS` in `_generate_collection.py`)

**Gaps QA will need to add:**
- `POST /analyze/stream` — not in the collection at all yet. NDJSON responses don't fit Postman's normal request/test model well; either use Postman's raw response body + manual line-splitting in a test script, or drive this one from a real test framework (Python `requests` with `stream=True`, or similar) instead of Postman.
- `product-matcher` (`/match`, `/health`) — no coverage at all currently.
- `state-manager` (`/session/{id}`, GET/POST/DELETE) — no coverage at all currently.
- Negative/error-path tests (missing fields, invalid image data, etc.) — the existing collection only exercises the happy path.
- `/analyze` with `gcs_uri` (the live-video path) — untested by this collection; it requires a real GCS video URI as input, not just an image.

**Fixed test fixtures** (for byte-identical, reproducible runs):
- Analyze: `C:\ShopLens\images\image-1.webp` (a kitchen-scene photo, ~17-26 detectable items depending on Gemini's non-deterministic detection — see §6). Local path only — if QA needs this fixture outside the original dev machine, pull it from the collection's `image_base64` variable.
- Identify: a deterministic crop of the same image (the dress, face excluded), generated by `_generate_collection.py`.

**Running it without the Postman GUI** (newman, useful for CI):
```bash
npm install -g newman
newman run postman/shoplens-analyze-perf.postman_collection.json \
  -e postman/shoplens-dev-cloud.postman_environment.json \
  -n 5 --reporters cli
# isolate one request:
newman run postman/shoplens-analyze-perf.postman_collection.json \
  -e postman/shoplens-dev-cloud.postman_environment.json \
  --folder "2. Identify - Fixed Crop" -n 1 --reporters cli
```

---

## 5. Known sources of non-determinism (design tests around these, don't fight them)

1. **Gemini's object detection count varies run to run** on byte-identical
   input — observed range 14-47 items detected on the same fixed test image
   across this session's testing. **Don't assert on exact item counts.**
   Assert on "at least N items", category presence, or schema shape instead.
2. **`products` count also varies** for the same reason, plus SerpAPI match
   availability — even `max_searches=5` doesn't guarantee 5 products back if
   Lens/Shopping both come up empty for some items.
3. **SerpAPI quota is shared and finite.** This session hit
   `SERP_QUOTA_EXCEEDED` twice from cumulative testing alone (once on the
   original key, once again on its replacement). When the key is exhausted,
   every Lens/Shopping call fails fast (~0 results, fast response) instead of
   doing a real lookup — **a fast response with 0 products is not
   necessarily a bug, check for `SERP_QUOTA_EXCEEDED` in `warnings` before
   treating it as a failure.** A regression suite that runs frequently will
   plausibly exhaust quota on its own; budget for this (see §7) or get a
   dedicated automation key.
4. **Lens's `products` tab (as opposed to `visual_matches`) was observed
   returning 0 results on every single call this session** (hundreds of
   samples) and was removed from the code entirely as of commit `5232e0d` —
   if you see references to "Pass 1"/"Pass 2" in old logs/docs, that's the
   removed behavior; current code only ever calls `visual_matches`.
5. **Cold starts.** All three services scale to zero. The first request
   after idle time pays container startup latency on top of normal
   processing — expect occasional outlier-slow first requests in any test
   run, especially after the suite has been idle.
6. **Gemini model in use is configurable and currently `gemini-2.5-flash`**
   (switched from `gemini-2.5-pro` on 2026-06-21 after benchmarking — see
   `docs/analyze-perf-test-results.md` row 9). `GET /config` tells you what's
   currently active; don't hardcode an assumption into test assertions.

---

## 6. Warning codes — what's real vs. aspirational

The backend (`services/ai-analyzer/analyzer.py`) only ever emits **one**
stable warning code: **`SERP_QUOTA_EXCEEDED`**. Everything else in the
`warnings` array is a free-text, human-readable message (e.g. `"No results
for 'X' (Lens + Shopping both empty)"`, `"No bounding box for 'X' — used full
image"`) — don't pattern-match on exact wording, these aren't a stable
contract.

**Known discrepancy worth flagging to dev if QA hits it:** the mobile app
(`mobile/lib/presentation/widgets/pipeline_status_bar.dart`) has UI logic
checking for warning codes `GEMINI_BLOCKED`, `GEMINI_PARSE_FAILED`, and
`GEMINI_TRUNCATED` — **none of these are ever actually emitted by the current
backend.** That UI branch is currently dead code (or forward-looking for a
not-yet-implemented backend change). Don't write a regression test asserting
these codes appear; they won't, today.

---

## 7. Performance baselines (so QA can set sane timeouts, not arbitrary ones)

Full methodology and raw data: `docs/analyze-perf-test-results.md` and
`docs/2026-06-21-analyzer-api-changes.md`. Headline numbers as of the current
deployed code (`gemini-2.5-flash`, Lens `products` tab removed):

| Endpoint | Median (5-run) | Observed range | Notes |
|---|---|---|---|
| `POST /analyze` | ~30s | 11-55s | Dominated by Gemini detection (~10-30s) + the single slowest item's Lens call (~10-20s) |
| `POST /identify` | ~28s | 9-46s | Dominated by Gemini's crop description + one Lens call |
| `POST /analyze/stream` | first match in well under the full-request time | items typically begin arriving 15-20s after request start | use this, not `/analyze`, if testing perceived/first-result latency |

**Recommendation:** set automation timeouts generously (90-120s for
`/analyze`/`/identify`) rather than tight ones — given the noise documented
in §5, a tight timeout will produce flaky failures unrelated to real
regressions. If you need a tight latency assertion, assert on the
`TIMING | ...` line in Cloud Run logs for the specific request (see below),
not on wall-clock test-runner time, which also includes network overhead
from wherever the suite runs.

**Built-in timing breakdown:** every `/analyze`, `/analyze/stream`, and
`/identify` call logs a single structured line to Cloud Run logs:
```
TIMING | total=28.09s gemini=11.39s items_phase=16.69s items=4 | slowest_item='Poly black red on-ear headphones' crop=0.17s upload=0.12s lens=16.40s shopping=0.00s item_total=16.68s
```
Correlate via the `X-Request-Id` response header → Cloud Run log filter
`textPayload:"TIMING" AND textPayload:"<request_id>"`. Useful for root-causing
a slow run without re-instrumenting anything.

---

## 8. Recent regressions worth dedicated test coverage for

These are real bugs found and fixed this session (2026-06-20/21) — each is a
good candidate for its own regression test, since each one shipped to
production undetected for a while:

1. **Mobile app calling the wrong Cloud Run project entirely.**
   `mobile/lib/core/constants/api_constants.dart` had a hardcoded project
   number that didn't match the actual deployed backend — the live-camera
   "tap to identify" feature silently called a different service for an
   unknown period. Regression test: assert the mobile build's configured
   base URLs match `935092313069` (the real project).
2. **Duplicate `MainActivity.kt`** under two different leftover package
   paths from an old project rename caused every Android release build to
   fail outright (`Redeclaration` compile error). Regression test: an Android
   release build is its own smoke test here — make sure CI actually runs
   `flutter build apk --release`, not just `flutter analyze`.
3. **`TapIdentifyUseCase` overwrote the shopping list instead of merging** —
   every tap-to-identify call cleared the whole session then saved only that
   tap's matches, discarding everything found by previous taps. Fixed in
   commit `4fa30ba`. Regression test: tap-identify item A, then item B,
   assert the session contains **both**.
4. **Tap-identify gave identical UI feedback for "found a match" and "found
   nothing."** `TapIdentifySuccess` rendered as an empty box regardless of
   whether `productName` was set. Fixed in the same commit. Regression test:
   assert the UI shows different text/state for a real match vs. an empty
   result.
5. **Lens `products` tab call was pure waste** — see §5.4. No user-facing
   regression, but worth a backend test asserting `_google_lens` only ever
   makes one SerpAPI call per item now, not two.

---

## 9. Mobile/frontend integration points relevant to backend regression testing

- `mobile/lib/core/constants/api_constants.dart` — hardcoded backend base
  URLs (see bug #1 above). `mobile/.env` also has these values but is
  **not actually read** by the app currently (a known, separate gap noted in
  that file's own comment) — don't assume changing `.env` changes app
  behavior.
- `mobile/lib/data/sources/remote/dio_client.dart` — client-side timeouts:
  `connectTimeout: 60s` for all services, `receiveTimeout: 5 minutes`
  specifically for the analyzer (the other two default to 60s). If
  automating against a cold/slow backend, match or exceed these.
- App version: `mobile/pubspec.yaml` (`version: 1.29.0` as of this writing)
  and a **separately hardcoded** copy in
  `mobile/lib/presentation/screens/about_screen.dart` — these aren't linked,
  bumping one doesn't bump the other (a manual step today, not a bug exactly,
  but worth a regression test that they stay in sync if that matters to QA).

---

## 10. Quick reference: building a request by hand

```bash
# Build a payload from a local image file
python3 -c "
import base64, json
with open('test.jpg', 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()
json.dump({
    'image_data': b64,
    'image_mime_type': 'image/jpeg',
    'country': 'us',
    'max_searches': 5,
}, open('payload.json', 'w'))
"

curl -s -X POST https://ai-analyzer-935092313069.us-central1.run.app/analyze \
  -H "Content-Type: application/json" -d @payload.json | python3 -m json.tool
```
