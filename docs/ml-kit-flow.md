# ShopLens — End-to-End Flow: ML Kit → Gemini → Lens → SerpAPI

_Last updated 2026-06-26. Covers the live scan tap path and the Scan All path with all edge cases._

---

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          MOBILE (Flutter)                               │
│                                                                         │
│   Camera frames ──► ML Kit Object Detection (on-device, real-time)     │
│                            │                                            │
│                    Bounding boxes + coarse labels                       │
│                    drawn as glow overlay on screen                      │
│                            │                                            │
│              ┌─────────────┴──────────────┐                            │
│           User taps                  User presses                       │
│           an object                  "Scan All"                         │
│              │                            │                             │
│         [TAP PATH]                 [SCAN ALL PATH]                      │
│    Crop image to ML Kit box        Full frame, no crop                  │
│    → POST /identify                → POST /analyze/stream               │
└──────────────┬─────────────────────────────┬───────────────────────────┘
               │                             │
               ▼                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      BACKEND  (ai-analyzer Cloud Run)                    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## TAP PATH — `POST /identify`

> User taps a glowing dot on a detected object. ML Kit's bounding box is used
> to crop that exact object out of the captured photo before anything goes to
> the cloud.

> **2026-07-04 update:** the diagram below (last redrawn 2026-06-26) shows
> Gemini description and GCS upload always running in parallel before Lens.
> That's no longer the default — Gemini is now only spent as an **adaptive
> hedge**: `identify_crop()` uploads to GCS, then kicks off Lens immediately.
> If Lens hasn't answered within `LENS_HEDGE_DELAY_SECONDS` (25s default), it
> starts the Gemini description *concurrently with the still-running Lens
> call* rather than waiting for Lens to finish or time out first. Once Gemini
> has a query, if Lens still hasn't answered, Shopping starts too, also
> concurrently with Lens. Whichever source produces usable products first
> wins; if Lens answers at any point with results, Gemini/Shopping are never
> used. On the common fast path (Lens answers within 25s) Gemini is never
> touched at all — cheaper than the diagram implies. `IDENTIFY_SKIP_GEMINI`
> is now a kill-switch for the whole hedge, not a toggle for the parallel
> branch shown below. See `services/ai-analyzer/analyzer.py`'s `identify_crop()`.

```
Mobile: user taps object
        │
        ▼
ML Kit bounding box (already in memory from live stream)
        │
        ▼
Crop full-res photo to bounding box  ←── PNG crop bytes
        │
        ▼
POST /identify  { image_data: <base64 crop>, mlkit_context: { ... } }
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│  identify_crop()  — two things run IN PARALLEL                    │
│                                                                   │
│  ┌──────────────────────────┐   ┌───────────────────────────┐    │
│  │  Gemini (gemini-2.5-     │   │  GCS Upload               │    │
│  │  flash)                  │   │                           │    │
│  │                          │   │  Convert crop → JPEG      │    │
│  │  Prompt: "Describe this  │   │  Upload to                │    │
│  │  product in 3-7 words.   │   │  gs://shoplens-dev-       │    │
│  │  Color, Material, Style, │   │  lens-tmp/<uuid>.jpg      │    │
│  │  Brand, Object Name."    │   │  → public GCS URL         │    │
│  │                          │   │                           │    │
│  │  Returns:                │   │  ┌─────────────────────┐  │    │
│  │  "Mid-century modern     │   │  │ GCS UPLOAD FAILED?  │  │    │
│  │   white ceramic lamp"    │   │  │ → skip Lens entirely│  │    │
│  │                          │   │  │ → Shopping fallback │  │    │
│  │  ┌────────────────────┐  │   │  │   or return []      │  │    │
│  │  │ GEMINI FAILS?      │  │   │  └─────────────────────┘  │    │
│  │  │ → effective_query  │  │   └───────────────────────────┘    │
│  │  │   = "" (empty)     │  │                                    │
│  │  └────────────────────┘  │                                    │
│  └──────────────────────────┘                                    │
│                                                                   │
│  effective_query = Gemini description  (or "" if Gemini failed)  │
└──────────────────────────────┬───────────────────────────────────┘
                               │
                               ▼
              ┌────────────────────────────────┐
              │        Google Lens             │
              │  (via SerpAPI /google_lens)    │
              │                               │
              │  Input:                       │
              │    url  = GCS public URL      │  ← the ML Kit crop image
              │    q    = Gemini description  │  ← text re-ranking hint
              │    type = visual_matches      │
              │    gl   = country ("us")      │
              │                               │
              │  Returns: visual_matches[]    │
              │  Each match:                  │
              │    title, link, source,       │
              │    thumbnail, price           │
              └───────────────┬───────────────┘
                              │
               ┌──────────────┴───────────────┐
               │                              │
         Results found?                 No results?
               │                              │
               ▼                              ▼
       Return products[]          ┌───────────────────────┐
       to mobile                  │  Shopping Fallback     │
                                  │  (SerpAPI              │
                                  │   /google_shopping)    │
                                  │                        │
                                  │  q = Gemini description│
                                  │  (or "" if failed)     │
                                  │                        │
                                  │  ┌─────────────────┐   │
                                  │  │ Still nothing?  │   │
                                  │  │ → return []     │   │
                                  │  │   + warning in  │   │
                                  │  │   warnings[]    │   │
                                  │  └─────────────────┘   │
                                  └───────────────────────┘
```

---

## SCAN ALL PATH — `POST /analyze/stream`

> User presses "Scan All". Full frame goes to Gemini which detects every
> shoppable object, crops each one, and runs Lens searches in parallel.
> Results stream back one item at a time as each Lens search finishes.

```
Mobile: user presses "Scan All"
        │
        ▼
Full-res photo (no ML Kit crop — no object was tapped)
        │
        ▼
POST /analyze/stream  { image_data: <base64 full frame>, mlkit_context: { trigger: "scan_all" } }
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Gemini (gemini-2.5-flash)  — FULL OBJECT DETECTION                      │
│                                                                           │
│  Prompt: "Identify EVERY distinct shoppable product. Return JSON array   │
│  [{name: '...', box: [y_min, x_min, y_max, x_max]}]"                    │
│  Image is downscaled to max 1280px before sending to Gemini.             │
│                                                                           │
│  Categories Gemini looks for:                                             │
│    clothing, footwear, accessories, furniture, home decor,               │
│    kitchenware, electronics, sports equipment, books, stationery         │
│                                                                           │
│  Gemini EXCLUDES: food, groceries, beverages, walls, floors              │
│                                                                           │
│  Returns: items[] with name + bounding box (0-1000 normalized scale)     │
│                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  GEMINI NON-DETERMINISM                                          │   │
│  │  Same image can return 14-47 items across runs. Don't assert     │   │
│  │  on exact count — assert on "at least N" or category presence.   │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────┬────────────────────────────────────────┘
                                   │
                                   ▼
                    Stream event: {"type": "items", "items": [...]}
                    ↑ mobile receives this immediately after Gemini finishes
                                   │
                                   ▼
              Deduplicate items by normalized name
              Cap to max_searches (user setting, hard max = 5)
                                   │
                                   ▼
              ┌────────────────────────────────────────────┐
              │  For each detected item — IN PARALLEL      │
              │  (up to 10 concurrent threads)             │
              │                                            │
              │  1. Crop image to Gemini bounding box      │
              │     (5% padding added around box)          │
              │                                            │
              │     ┌──────────────────────────────────┐   │
              │     │  NO BOUNDING BOX?                │   │
              │     │  (Gemini omitted it)             │   │
              │     │  → use full image as crop        │   │
              │     │  + add warning to warnings[]     │   │
              │     └──────────────────────────────────┘   │
              │                                            │
              │  2. Upload crop to GCS                     │
              │                                            │
              │     ┌──────────────────────────────────┐   │
              │     │  GCS UPLOAD FAILED?              │   │
              │     │  → skip Lens for this item       │   │
              │     │  + add warning                   │   │
              │     └──────────────────────────────────┘   │
              │                                            │
              │  3. Google Lens (visual_matches)           │
              │     url = GCS URL of crop                  │
              │     q   = Gemini item name (e.g.           │
              │           "Black leather office chair")    │
              │     max_results = 1 per item               │
              │                                            │
              │     ┌──────────────────────────────────┐   │
              │     │  NO LENS RESULTS?                │   │
              │     │  → Shopping fallback             │   │
              │     │     q = Gemini item name         │   │
              │     │     max_results = 1              │   │
              │     │                                  │   │
              │     │  STILL NOTHING?                  │   │
              │     │  → skip item, add warning        │   │
              │     └──────────────────────────────────┘   │
              │                                            │
              │  4. Stream result immediately:             │
              │     {"type":"match", "name":"...",         │
              │      "products":[...], "warnings":[...]}   │
              │     ↑ mobile gets this as each item        │
              │       finishes — not all at once           │
              │                                            │
              └────────────────────────────────────────────┘
                                   │
                                   ▼
              Deduplicate products across all items
              (by product_id, then by purchase URL)
                                   │
                                   ▼
              Stream final event: {"type": "done", "warnings": [...]}
```

---

## SerpAPI Quota Edge Case (both paths)

```
Any Lens or Shopping call
        │
        ▼
SerpAPI returns {"error": "ran out of searches ..."}
        │
        ▼
Set quota_exhausted = True (thread-local flag)
        │
        ▼
All remaining Lens/Shopping calls in this request still attempt
(other items may still have quota — flag is per-response, not global)
        │
        ▼
At end of request:
  warnings[] += "SERP_QUOTA_EXCEEDED"
  products returned = whatever was found before exhaustion
```

> **Key point for testing:** A fast response with 0 products is not a bug
> if `warnings` contains `"SERP_QUOTA_EXCEEDED"`. This is the only stable
> warning code — all others are free-text human-readable strings.

---

## Complete Edge Case Summary

| Scenario | Where it happens | What happens | User sees |
|---|---|---|---|
| ML Kit detects object, no label (confidence=0) | Mobile, tap path | Bounding box still used for crop | Same as normal tap — crop sent to /identify |
| ML Kit detects no objects at all | Mobile | Scan All still available; tap path impossible | Glow overlay not shown; Scan All still works |
| Gemini description fails on /identify | Backend | `effective_query = ""` | Lens runs image-only (no text hint); quality slightly reduced |
| GCS upload fails on /identify | Backend | Lens skipped entirely | Shopping text-search fallback runs, or empty result |
| GCS upload fails on /analyze item | Backend | That item's Lens skipped | Other items unaffected; warning added |
| Gemini returns no bounding box for item | Backend, analyze path | Full image used as crop for that item | Warning added; Lens still attempts |
| Gemini parse fails (bad JSON) | Backend | `items_raw = []` | Empty result, no Lens calls run |
| Lens returns 0 results | Backend | Shopping fallback triggered | Slower result (~text search), or empty |
| Shopping fallback also returns 0 | Backend | Item produces no products | Warning added; other items unaffected |
| SerpAPI quota exhausted | Backend | `SERP_QUOTA_EXCEEDED` in warnings | Products from before exhaustion returned; rest empty |
| Stream error mid-response | Backend, stream path | `{"type":"error",...}` event emitted | HTTP status is always 200; error only detectable in-stream |
| Cold start (service scaled to zero) | Cloud Run | Extra ~2-5s startup before first request | First request after idle is slower |
| Product-matcher fallback (/analyze only) | Backend | Triggered only if Lens finds nothing for ALL items | Text-based results, slower, no images |

---

## What Each Component Actually Contributes

| Component | Role | What it produces |
|---|---|---|
| **ML Kit** (on-device) | Real-time bounding box detection on camera frames | Box coordinates for cropping; coarse label (e.g. "Home good", "Fashion good") for logs only |
| **ML Kit crop** | Isolates exactly the tapped object from the full photo | JPEG crop bytes sent to backend |
| **Gemini** (tap path) | Describes the pre-cropped item in rich detail | 3-7 word text description: color + material + style + brand + object name |
| **Gemini** (scan all path) | Full object detection on entire frame | List of `{name, bounding_box}` for every shoppable item |
| **GCS** | Hosts the crop image at a public URL | Public HTTPS URL that Google Lens can fetch |
| **Google Lens** (via SerpAPI) | Visual similarity search using the crop image + text query | `visual_matches[]` — products that look like the image |
| **SerpAPI Shopping** | Text-only product search fallback | `shopping_results[]` — products matching the Gemini description by name |
| **State Manager** | Saves matched products to Firestore session | Shopping list visible in real time on the frontend/mobile |

---

## Log Correlation Quick Reference

Every backend request emits these structured log lines (filter by `req=<X-Request-Id header>`):

```
# Always first when request came from live scan:
MLKIT  | route=identify trigger=tap confidence=0.75 objects=1 labels=['Home good']

# Start of processing:
identify start | image_data_b64_len=84320 query='' country=us

# Gemini description result (tap path):
Gemini crop description: 'Cream knit throw blanket with fringe trim'

# GCS upload:
GCS upload OK: https://storage.googleapis.com/shoplens-dev-lens-tmp/abc123.jpg

# Lens result:
Lens (visual_matches): 3 result(s)

# Timing breakdown (always last) — post-2026-07-04 hedge shape;
# see the update note near the top of the TAP PATH section:
TIMING | total=28.09s upload=0.31s lens=27.6s gemini=3.9s shopping=0.00s hedge_triggered=True lens_timed_out=False quota_exhausted=False
```
