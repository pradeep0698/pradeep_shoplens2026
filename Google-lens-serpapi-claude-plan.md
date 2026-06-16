# Context

**Goal:** Replace all text-based product matching with visual Google Lens matching. Detect products in the image → crop each one → upload to imgbb → Google Lens search with the actual cropped image → exact visual match with working purchase links.

**Key insight:** Google Lens `visual_matches[].link` and `shopping_results[].link` ARE populated (they're pages that contain the matching image), unlike Google Shopping where `link` was always empty.

**Google Shopping is removed entirely.** Product-matcher is bypassed for the mobile app path. ai-analyzer owns the full visual matching pipeline.

---

# Flow

```
Flutter photo (base64)
  → ai-analyzer
      → Gemini: detect items + bounding boxes [y_min, x_min, y_max, x_max] (0–1000 scale)
      → For each detected item:
          → Pillow: crop image to bounding box (+ 5% padding)
          → imgbb API: upload crop → get public URL
          → SerpAPI Google Lens (engine=google_lens, url=imgbb_url)
              → check shopping_results first (structured price+link)
              → fall back to visual_matches
      → Returns items[] + products[]
  → Flutter use case:
      → products[] non-empty → save directly to session (product-matcher skipped)
      → products[] empty (Lens found nothing) → unmatched, nothing shown
```

**Note on live-video (pubsub-worker) path:** That path sends GCS video URIs, not individual frame images. Visual cropping isn't applicable there. The pubsub-worker path is out of scope for this change — it continues calling product-matcher as before, but product-matcher is now a no-op for that path (returns empty until updated separately).

---

# Files Changed

## 1. `services/ai-analyzer/requirements.txt`
```
fastapi==0.111.0
uvicorn[standard]==0.29.0
google-cloud-aiplatform>=1.49.0
Pillow>=10.0.0
requests>=2.31.0
```

## 2. `services/ai-analyzer/.env.example`
```
PORT=8080
PROJECT_ID=shoplens-dev-prj
LOCATION=us-central1
GEMINI_MODEL=gemini-2.5-flash
IMGBB_KEY=your_imgbb_api_key_here
SERPAPI_KEY=your_serpapi_key_here
```

## 3. `services/ai-analyzer/analyzer.py` — Core rewrite

### New env vars at module level
```python
_IMGBB_KEY   = os.environ.get("IMGBB_KEY", "")
_SERPAPI_KEY = os.environ.get("SERPAPI_KEY", "")
```

### New Gemini prompt — ask for bounding boxes
Replace the existing prompt. Ask Gemini to return items with `box: [y_min, x_min, y_max, x_max]` on a 0–1000 scale:
```
Identify every distinct shoppable product visible in this image.
For each product return a JSON object with:
  "name": 1–3 word product label
  "box":  [y_min, x_min, y_max, x_max] as integers 0–1000

Return ONLY a JSON array — no markdown. Example:
[{"name": "Chair", "box": [200, 150, 750, 500]}, {"name": "Lamp", "box": [50, 600, 400, 900]}]

Exclude: food, beverages, produce, ingredients, people, body parts,
walls, floors, ceilings, plain surfaces.
Return [] if no shoppable products are visible.
```
Keep existing `ignore_terms` injection block.

### Helper: `_crop_product(image_bytes, box) → bytes`
```python
from PIL import Image
import io

def _crop_product(image_bytes: bytes, box: list[int]) -> bytes:
    img = Image.open(io.BytesIO(image_bytes))
    W, H = img.size
    y1, x1, y2, x2 = box          # Gemini [y_min, x_min, y_max, x_max] 0–1000
    pad = 0.05
    px1 = max(0, int((x1/1000 - pad) * W))
    py1 = max(0, int((y1/1000 - pad) * H))
    px2 = min(W, int((x2/1000 + pad) * W))
    py2 = min(H, int((y2/1000 + pad) * H))
    crop = img.crop((px1, py1, px2, py2))
    buf = io.BytesIO()
    crop.save(buf, format="JPEG", quality=85)
    return buf.getvalue()
```

### Helper: `_upload_imgbb(image_bytes) → str | None`
```python
import base64
import requests as _req

def _upload_imgbb(image_bytes: bytes) -> str | None:
    b64 = base64.b64encode(image_bytes).decode()
    try:
        resp = _req.post(
            "https://api.imgbb.com/1/upload",
            data={"key": _IMGBB_KEY, "image": b64},
            timeout=15,
        )
        data = resp.json()
        if data.get("success"):
            return data["data"]["url"]
        logger.warning("imgbb error: %s", data.get("error"))
    except Exception as exc:
        logger.warning("imgbb upload failed: %s", exc)
    return None
```

### Helper: `_google_lens(image_url) → dict | None`
Tries `shopping_results` (structured) then `visual_matches` (visual). Both have populated `link` fields in Lens responses:
```python
def _google_lens(image_url: str) -> dict | None:
    try:
        resp = _req.get(
            "https://serpapi.com/search",
            params={"engine": "google_lens", "url": image_url, "api_key": _SERPAPI_KEY},
            timeout=15,
        )
        data = resp.json()
        logger.info("Lens keys: %s", list(data.keys()))

        for r in data.get("shopping_results", []):
            if r.get("title") and r.get("link"):
                raw_price = str(r.get("price", "0")).replace("$","").replace(",","").strip()
                return {
                    "name":         r["title"],
                    "price":        float(raw_price or 0),
                    "image_url":    r.get("thumbnail", ""),
                    "purchase_url": r["link"],
                    "seller":       r.get("source", ""),
                }

        for r in data.get("visual_matches", []):
            if r.get("title") and r.get("link"):
                price_obj = r.get("price", {})
                price_val = price_obj.get("extracted_value", 0) if isinstance(price_obj, dict) else 0
                return {
                    "name":         r["title"],
                    "price":        float(price_val or 0),
                    "image_url":    r.get("thumbnail", ""),
                    "purchase_url": r["link"],
                    "seller":       r.get("source", ""),
                }
        logger.warning("No usable Lens results for %s", image_url)
    except Exception as exc:
        logger.warning("Google Lens failed: %s", exc)
    return None
```

### Updated `analyze_media` signature and body
Change return type to `tuple[list[str], list[dict]]`.

After Gemini detection, if `image_data` is provided (mobile path), run the visual pipeline for each item:
```python
items_raw = _parse_gemini_response(response_text)  # list of {"name":..., "box":[...]}
item_names = [r["name"] for r in items_raw]
products = []

if image_data:
    img_bytes = base64.b64decode(image_data)
    for item in items_raw:
        box  = item.get("box")
        name = item["name"]
        crop = _crop_product(img_bytes, box) if box else img_bytes
        url  = _upload_imgbb(crop)
        if not url:
            logger.warning("imgbb upload failed for '%s', skipping", name)
            continue
        product = _google_lens(url)
        if product:
            products.append(product)
            logger.info("Lens matched '%s' → %s", name, product["name"])

return item_names, products
```

## 4. `services/ai-analyzer/main.py`
Update the `/analyze` endpoint to unpack both return values and include `products` in response:
```python
items, products = analyze_media(...)
return JSONResponse(content={
    "items":     items,
    "products":  products,
    "gcs_uri":   request.gcs_uri,
    "image_url": request.image_url,
})
```
Update `/health` to check `IMGBB_KEY` and `SERPAPI_KEY` as well as `PROJECT_ID`.

## 5. `mobile/lib/data/models/analyze_response.dart`
Add `products: List<Product>` field, parsed from the new `products` key:
```dart
final List<Product> products;

factory AnalyzeResponse.fromJson(Map<String, dynamic> json) => AnalyzeResponse(
  items:    (json['items'] as List? ?? []).cast<String>(),
  products: (json['products'] as List? ?? [])
              .map((e) => Product.fromFirestore(e as Map<String, dynamic>))
              .toList(),
  gcsUri:   json['gcs_uri'] as String?,
  imageUrl: json['image_url'] as String?,
);
```

## 6. `mobile/lib/domain/usecases/analyze_image_usecase.dart`
Replace the two-step analyze→match with: use Lens products if available, skip matcher entirely:
```dart
yield PipelineStep.analyzing;
final analyzeResponse = await _analyzer.analyze(...);

if (analyzeResponse.products.isNotEmpty) {
  yield PipelineStep.saving;
  final ranked = rankProducts(analyzeResponse.products, preferenceTerms);
  await _session.saveProducts(sessionId, ranked);
} else {
  // Lens found nothing — nothing to show
  // (product-matcher / Google Shopping not used)
}
yield PipelineStep.done;
```

## 7. `.github/workflows/deploy-cloudrun.yml`
Update the ai-analyzer deploy `--set-env-vars` to include the two new keys:
```yaml
--set-env-vars "PROJECT_ID=${{ vars.PROJECT_ID }},LOCATION=${{ env.REGION }},IMGBB_KEY=${{ secrets.IMGBB_KEY }},SERPAPI_KEY=${{ secrets.SERPAPI_KEY }}"
```

---

# Deployment (for local testing)

```powershell
# Set keys in your terminal
$env:IMGBB_KEY   = "your_imgbb_key"
$env:SERPAPI_KEY = "your_serpapi_key"

# Deploy ai-analyzer (--update-env-vars keeps existing PROJECT_ID/LOCATION)
gcloud run deploy ai-analyzer `
  --source ./services/ai-analyzer `
  --region us-central1 `
  --project shoplens-dev-prj `
  --update-env-vars "IMGBB_KEY=$env:IMGBB_KEY,SERPAPI_KEY=$env:SERPAPI_KEY" `
  --allow-unauthenticated
```

---

# Verification

1. Get imgbb key from [api.imgbb.com](https://api.imgbb.com) — free
2. Deploy ai-analyzer with both keys set
3. Test: `POST /analyze` with a base64 JPEG — response should have `"products": [{"name":"...","purchase_url":"https://...","image_url":"https://..."}]`
4. In Flutter: scan something → real product appears with image and Buy link pointing to the actual retailer page
