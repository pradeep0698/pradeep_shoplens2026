# Analyze Pipeline — Top 5 Performance Improvements

**Scope:** the full "Analyze" path a user triggers from the web app — browser upload →
`ai-analyzer` (Gemini detection + Google Lens/Shopping matching) → optional
`product-matcher` fallback → `state-manager` persistence → rendered results.

**Caveat:** I don't have log access to the live `shoplens-dev-499700` Cloud Run services
from this environment, so call-volume/latency claims below are inferred from code
structure and documented third-party API behavior, not measured production numbers.
Where that matters, it's called out explicitly.

These are ranked by impact-for-effort, all are pure wins or near-zero-risk (no feature
behavior changes for the user), and none require infrastructure/cost decisions — they're
all code changes you can make directly.

---

## #1 — Stop blocking the event loop in `product-matcher` and `state-manager`

### What we're changing
Both services call synchronous, blocking code directly inside `async def` FastAPI route
handlers, with no `--workers` flag on Uvicorn (single process, single event loop):

- `services/product-matcher/main.py:46-48` — `match_products(...)` (does a blocking
  `requests` fan-out internally)
- `services/state-manager/main.py:43-60` — `update_session` / `get_session` /
  `clear_session` (synchronous `firebase_admin.firestore` calls)

We're wrapping each in `await asyncio.to_thread(...)`, exactly the pattern
`ai-analyzer` **already uses correctly** for `/analyze` (`services/ai-analyzer/main.py:138-147`).

### Why
A single-worker Uvicorn process has exactly one event loop. When a route handler calls
blocking code directly (no `to_thread`), that call **freezes the entire event loop**
until it returns — every other concurrent request to that instance queues up behind it,
no matter how much spare CPU/network capacity the container has. This isn't a tuning
knob, it's a correctness bug that silently caps each instance at ~1 request at a time for
these two services.

### Benefits
- Removes a hard concurrency ceiling that exists today regardless of Cloud Run scaling settings.
- No behavior change, no new dependencies — same 2-line fix pattern already proven in `ai-analyzer`.
- Makes Cloud Run's per-instance concurrency setting actually meaningful for these services instead of being capped by this bug.

### Before / After

```python
# Before — services/product-matcher/main.py:46-48
@app.post("/match")
async def match(request: MatchRequest) -> JSONResponse:
    result = match_products(request.items, request.ignore_terms, request.max_searches)
    return JSONResponse(content=result)
```
```python
# After
@app.post("/match")
async def match(request: MatchRequest) -> JSONResponse:
    result = await asyncio.to_thread(
        match_products, request.items, request.ignore_terms, request.max_searches
    )
    return JSONResponse(content=result)
```

| | Before | After |
|---|---|---|
| Concurrent requests served per instance while one `/match` or `/session` call is in flight | **1** (everything else queues) | As many as Cloud Run's concurrency setting allows |
| Code pattern consistency across the 4 services | Inconsistent (`ai-analyzer` right, other two wrong) | Consistent everywhere |
| User-visible symptom under load | Random-feeling slow/stalled requests during concurrent traffic | Smooth concurrent handling |

---

## #2 — Cut SerpAPI Lens's redundant second call per item

### What we're changing
`_google_lens()` in `services/ai-analyzer/analyzer.py:438-539` fires **two** SerpAPI
calls per item concurrently, every time, regardless of outcome:

```python
with ThreadPoolExecutor(max_workers=2) as _lens_pool:
    f1 = _lens_pool.submit(_fetch, "products")
    f2 = _lens_pool.submit(_fetch, "visual_matches")   # always runs, not gated on f1
```

We're switching to: try `products` first; only call `visual_matches` if `products` came
back with fewer than the needed results.

### Why
Because both calls already run concurrently, removing one **doesn't save latency** —
but it **halves SerpAPI call volume**, since today every item pays for both tabs whether
or not the first one finds anything. SerpApi's own docs describe `products` and
`visual_matches` as separate tabs whose population varies per image — community reports
and SerpApi's docs note the `products` tab is frequently sparse compared to
`visual_matches`. ([SerpApi Google Lens Products API](https://serpapi.com/google-lens-products-api), [SerpApi Google Lens Visual Matches API](https://serpapi.com/google-lens-visual-matches-api))
This directly reduces exposure to the `SERP_QUOTA_EXCEEDED` failure path already handled
in the code (`analyzer.py:753-755`).

**Before shipping this for real, add the one-line structured log this doc's previous
version recommended** (`{"stage":"lens_pass1","hit":bool}`) for a week, so you're cutting
the call that's actually redundant for your traffic, not just the one that's redundant
in SerpApi's general docs.

### Benefits
- ~50% fewer SerpAPI calls on the Lens path → lower cost, lower quota pressure, fewer `SERP_QUOTA_EXCEEDED` warnings shown to users.
- No latency change (these calls were never on the critical path sequentially).
- No result-quality loss if Pass 1 genuinely isn't contributing for your image mix.

### Before / After

```python
# Before
with ThreadPoolExecutor(max_workers=2) as _lens_pool:
    f1 = _lens_pool.submit(_fetch, "products")
    f2 = _lens_pool.submit(_fetch, "visual_matches")
    pass1_data = f1.result()
    pass2_data = f2.result()
```
```python
# After
pass1_data = _fetch("products")
pass2_data = {}
if len(pass1_data.get("shopping_results", [])) < MAX:
    pass2_data = _fetch("visual_matches")
```

| | Before | After |
|---|---|---|
| SerpAPI calls per detected item (Lens path) | 2, always | 1, or 2 only when Pass 1 underfills |
| Monthly SerpAPI quota consumed by Lens | Baseline | ~50% lower (pending real hit-rate confirmation) |
| Wall-clock latency per item | Same | Same (calls were concurrent, not sequential) |

---

## #3 — Drop the synchronous GCS delete from the request path

### What we're changing
`_delete_gcs()` (`services/ai-analyzer/analyzer.py:279-285`) runs inside a `finally`
block in `_process_item`, *before* the function can return — so it adds directly to the
slowest-item time the per-request `ThreadPoolExecutor(max_workers=10)` waits on
(`analyzer.py:748`). We're removing the explicit per-item delete call.

### Why
The `gs://shoplens-dev-lens-tmp` bucket already has a 1-day lifecycle rule that
auto-deletes everything under the exact `lens-tmp/` prefix `_upload_gcs` writes to
(`docs/shop-lens-cloud-setup.md:96-101`, `analyzer.py:266`). The explicit delete is doing
cleanup that's already going to happen automatically — it's just doing it synchronously,
on the user's critical path, for no benefit.

### Benefits
- Removes one full GCS network round-trip from every item's contribution to total request latency.
- Zero risk of orphaned objects — the lifecycle rule already guarantees cleanup within 24h.
- Simpler code (one less failure mode to log/ignore).

### Before / After

```python
# Before — analyzer.py:702-711
gcs_url = _upload_gcs(crop)
...
try:
    matched = _google_lens(gcs_url, query=name, country=country, max_results=1)
finally:
    _delete_gcs(gcs_url)     # ← synchronous, blocks this item's return
```
```python
# After
gcs_url = _upload_gcs(crop)
...
matched = _google_lens(gcs_url, query=name, country=country, max_results=1)
# cleanup handled by the bucket's existing 1-day lifecycle rule — nothing to await here
```

| | Before | After |
|---|---|---|
| Network round-trips per item on the critical path | Upload + Lens calls + **delete** | Upload + Lens calls |
| Object cleanup | Immediate (but blocking) | Within 24h via lifecycle rule (non-blocking) |
| Latency contributed by cleanup to the slowest item in the batch | ~1 GCS round-trip | 0 |

---

## #4 — Reuse HTTP connections to SerpAPI instead of reconnecting every call

### What we're changing
Replace ad-hoc `requests.get(...)` / `_req.get(...)` calls with a single shared
`requests.Session()` reused across calls, in:
- `services/ai-analyzer/analyzer.py:460-465` (`_fetch`, inside `_google_lens`)
- `services/ai-analyzer/analyzer.py:291-301` (`_search_shopping`)
- `services/product-matcher/matcher.py:59-68` (`_search_product`)

### Why
`requests.get(...)` is a convenience function that creates a **brand-new `Session`
internally on every call**, which defeats connection pooling — every SerpAPI call pays a
fresh TCP handshake + TLS negotiation to `serpapi.com` instead of reusing a warm, pooled
connection. This project makes many concurrent SerpAPI calls per request (up to
`10 items × 2 Lens passes = 20` at peak), so the wasted handshake cost is paid
repeatedly, every single analyze.

### Benefits
- Lower per-call latency to `serpapi.com` (skips repeated TCP+TLS setup on warm paths).
- Connection reuse scales with the existing `ThreadPoolExecutor` concurrency — no code restructuring needed beyond the client object.
- Standard, well-understood Python pattern; near-zero risk.

### Before / After

```python
# Before — analyzer.py:460-465
def _fetch(type_value: str) -> dict:
    resp = _req.get(
        "https://serpapi.com/search",
        params={**base_params, "type": type_value},
        timeout=25,
    )
```
```python
# After — module-level, created once per process
_session = _req.Session()

def _fetch(type_value: str) -> dict:
    resp = _session.get(
        "https://serpapi.com/search",
        params={**base_params, "type": type_value},
        timeout=25,
    )
```

| | Before | After |
|---|---|---|
| TCP+TLS handshake | Repeated on every call | Reused across calls via pooled connections |
| Code change scope | — | One shared `Session` object + swap `requests.get` → `session.get` |
| Risk | — | Negligible — standard library-supported pattern |

---

## #5 — Resize the image before sending it to Gemini

### What we're changing
`_load_image_part()` (`services/ai-analyzer/analyzer.py:219-234`) currently sends the
original, full-resolution image straight to Gemini for detection. We're downscaling it
(e.g., to a 1280px-max-dimension JPEG) before the `generate_content` call in
`analyze_media` (`analyzer.py:647-651`).

### Why
Vertex AI's own documentation states images are tokenized based on resolution (roughly
258 tokens for a 1024×1024 image) and explicitly recommends resizing to the minimum
resolution your use case needs, since larger images increase response latency.
([Vertex AI image understanding docs](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/multimodal/image-understanding))
This is safe here because Gemini's bounding boxes are already normalized to a 0-1000
scale (`analyzer.py:81`) — `_crop_product` maps boxes back against the *original* image
bytes, so downscaling only the copy sent to Gemini doesn't change box semantics or crop
quality at all.

### Benefits
- Lower token usage → lower Vertex AI cost per analyze.
- Faster Gemini response on the one call every single request makes (the very first step of the whole pipeline — improvement here benefits 100% of requests).
- No accuracy/crop-quality trade-off — the original full-resolution bytes are still used for cropping.

### Before / After

```python
# Before — analyzer.py:647-651
media_part = _load_image_part(
    image_url=image_url,
    image_data=image_data,
    image_mime_type=image_mime_type,
)
```
```python
# After
media_part = _load_image_part(
    image_url=image_url,
    image_data=image_data,
    image_mime_type=image_mime_type,
    max_dimension=1280,   # downscaled copy for Gemini only; original bytes still used for cropping
)
```

| | Before | After |
|---|---|---|
| Image resolution sent to Gemini | Original (could be several MP) | Capped at 1280px max dimension |
| Gemini tokens consumed per detection call | Scales with original resolution | Bounded, predictable |
| Crop quality (uses original bytes) | Unaffected | Unaffected — no change |
| Requests benefiting | — | 100% (every analyze makes exactly one Gemini call) |

---

## Suggested order

1. **#1** — fix the concurrency bug first; it's not a trade-off, it's a bug.
2. **#3, #4** — ship together; pure wins, no behavior change, trivial review.
3. **#5** — ship after a quick visual sanity check that detection quality holds at 1280px on a few real test images.
4. **#2** — add the one-line structured log mentioned above for ~a week first, confirm Pass 1's real hit-rate, then cut it.
