# C3 — Component (AI Analyzer internals)

Shows the internal components of the AI Analyzer service and how they connect to each other and to external systems.

```mermaid
C4Component
    title AI Analyzer Service — Components

    Person_Ext(mobile, "Flutter Mobile App")

    Component(route_analyze, "POST /analyze", "FastAPI route", "Full pipeline: Gemini detects all objects in image, crops each, runs Lens per object")
    Component(route_stream, "POST /analyze/stream", "FastAPI route", "Same as /analyze but streams one NDJSON line per item as Lens results arrive")
    Component(route_identify, "POST /identify", "FastAPI route", "Tap path: skips bounding-box detection, runs Gemini describe + Lens on pre-cropped image")

    Component(analyze_media, "analyze_media()", "analyzer.py", "1. Gemini detection prompt → items + boxes\n2. Crop each box from image\n3. _describe_crop per item\n4. _upload_gcs per crop\n5. _google_lens per crop")
    Component(identify_crop, "identify_crop()", "analyzer.py", "1. TTLCache lookup (perceptual hash)\n2. _describe_crop + _upload_gcs (parallel)\n3. _google_lens\n4. _search_shopping fallback\n5. Store in TTLCache")

    Component(ttlcache, "TTLCache", "cachetools (in-process)", "30-min / 200-entry cache keyed on perceptual hash + country — repeat taps skip Gemini + GCS + Lens entirely")
    Component(describe_crop, "_describe_crop()", "analyzer.py", "Sends JPEG crop to Gemini with describe-product prompt → returns text query string for Lens")
    Component(upload_gcs, "_upload_gcs()", "analyzer.py", "Uploads JPEG to GCS bucket → returns public URL for Lens to fetch")
    Component(google_lens, "_google_lens()", "analyzer.py", "Calls SerpAPI Google Lens endpoint with GCS URL + text query → ranked product list")
    Component(shopping_fallback, "_search_shopping()", "analyzer.py", "Text-only Shopping search via SerpAPI — used when Lens returns no results")

    System_Ext(gemini, "Google Gemini API")
    System_Ext(gcs, "Google Cloud Storage")
    System_Ext(serpapi, "SerpAPI")

    Rel(mobile, route_analyze, "POST /analyze")
    Rel(mobile, route_stream, "POST /analyze/stream")
    Rel(mobile, route_identify, "POST /identify")

    Rel(route_analyze, analyze_media, "calls")
    Rel(route_stream, analyze_media, "calls (streaming variant)")
    Rel(route_identify, identify_crop, "calls")

    Rel(identify_crop, ttlcache, "check on entry / store on exit")
    Rel(identify_crop, describe_crop, "parallel via ThreadPoolExecutor")
    Rel(identify_crop, upload_gcs, "parallel via ThreadPoolExecutor")
    Rel(identify_crop, google_lens, "after describe + upload complete")
    Rel(identify_crop, shopping_fallback, "fallback if Lens returns empty")

    Rel(analyze_media, describe_crop, "once per detected object")
    Rel(analyze_media, upload_gcs, "once per detected object")
    Rel(analyze_media, google_lens, "once per detected object")
    Rel(analyze_media, shopping_fallback, "fallback per item if Lens empty")

    Rel(describe_crop, gemini, "generate_content (describe prompt)")
    Rel(upload_gcs, gcs, "upload_blob")
    Rel(google_lens, serpapi, "GET /search?engine=google_lens")
    Rel(shopping_fallback, serpapi, "GET /search?engine=google_shopping")
```

## Key points

- **`/identify` vs `/analyze` difference**: `/identify` skips Gemini bounding-box detection (the crop arrives pre-made from ML Kit); `/analyze` runs Gemini on the full image first to find objects, then crops each one
- **Gemini is still called by `/identify`** — `_describe_crop` sends the crop to Gemini for a rich text description (color, material, brand) that improves Lens query quality; only the detection pass is skipped
- **TTLCache only guards `/identify`** — `/analyze` (Scan All) has no cache; repeat Scan All presses re-run everything
- **`_describe_crop` and `_upload_gcs` run in parallel** inside `identify_crop` via a `ThreadPoolExecutor(max_workers=2)` — the upload does not wait for the description to finish
- **Shopping fallback is text-only** — it only fires when Lens returns zero results; it uses the Gemini-generated description text as the query
