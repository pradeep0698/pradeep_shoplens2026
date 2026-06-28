import base64
import hashlib
import io
import json
import logging
import mimetypes
import os
import re
import threading
import time
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional

from cachetools import TTLCache
from google.cloud import storage as gcs

import requests as _req
from google import genai
from google.genai import types
from PIL import Image

logger = logging.getLogger(__name__)

_PROJECT      = os.environ.get("PROJECT_ID", "")
_LOCATION     = os.environ.get("LOCATION", "us-central1")
_DEFAULT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-pro")
_GCS_LENS_BUCKET        = os.environ.get("GCS_LENS_BUCKET", "")
_SERPAPI_KEY            = os.environ.get("SERPAPI_KEY", "")
_LENS_TIMEOUT           = int(os.environ.get("LENS_TIMEOUT_SECONDS", "8"))
# Skip Gemini description on /identify by default — Lens works fine without it
# and Gemini adds 3-6s to every tap. Set to "false" to re-enable.
_IDENTIFY_SKIP_GEMINI   = os.environ.get("IDENTIFY_SKIP_GEMINI", "true").lower() not in ("0", "false", "no")

# Hard ceiling on SerpAPI (Lens) calls per analyze_media() run, regardless of
# what the caller requests — protects the shared SerpAPI quota from a single
# busy frame. Per-user profile preference (1-5) is clamped against this.
MAX_SEARCHES_PER_RUN = 5

_tls = threading.local()


def clamp_max_searches(requested: int | None) -> int:
    if requested is None:
        return MAX_SEARCHES_PER_RUN
    return max(1, min(int(requested), MAX_SEARCHES_PER_RUN))


def _is_serp_quota_error(data: dict) -> bool:
    err = data.get("error", "").lower()
    return "run out of searches" in err or "ran out of searches" in err


_session = _req.Session()

# Cache for /identify results — keyed on perceptual hash (8x8 avg hash) + country.
# Perceptual hash is robust to minor crop/scale differences from live scan taps
# (different camera frames of the same object hash identically). SHA-256 was
# wrong here — each tap produced a different raw-byte hash even for the same object.
# 30-minute TTL matches product-matcher's cache. maxsize=200 keeps memory
# bounded (~200 crops in flight at once is well above realistic concurrency).
_identify_cache: TTLCache = TTLCache(maxsize=200, ttl=1800)

_gcs_client: Optional[gcs.Client] = None


def _get_gcs_client() -> gcs.Client:
    global _gcs_client
    if _gcs_client is None:
        _gcs_client = gcs.Client()
    return _gcs_client

_active_model: str = _DEFAULT_MODEL


def get_active_model() -> str:
    return _active_model


def set_active_model(model_name: str) -> None:
    global _active_model
    _active_model = model_name


_PROMPT = (
    "Identify EVERY distinct shoppable product visible in this image. "
    "Do NOT limit the number of products — return one entry for every single "
    "qualifying item, even if there are many.\n\n"
    "For each product, return a JSON object with:\n"
    '- "name": Highly descriptive search query (3-5 words). MUST include '
    "[Color] + [Material] + [Style/Shape] + [Brand/Logo if visible] + [Object Name]. "
    "(e.g., \"Vintage-style white ceramic utensil holder\" or "
    "\"Nike black cotton baseball cap\"). If the brand is not identifiable, omit it.\n"
    '- "box": [y_min, x_min, y_max, x_max] as integers 0-1000.\n\n'
    "**Proactive Search Protocol:**\n"
    "1. Scan the image systematically (top-left, top-right, bottom-left, bottom-right, center).\n"
    "2. Pay specific attention to flat surfaces (countertops, tables) to identify items that "
    "often blend into the background (e.g., cutting boards, mats, decor).\n"
    "3. The bounding box must be a \"tight crop\" — it must encapsulate the ENTIRE object "
    "with minimal background noise.\n\n"
    "Return ONLY a JSON array — no markdown, no explanation.\n"
    "Example:\n"
    '[{{"name": "Mid-century modern white wooden dining chair", "box": [200, 150, 750, 500]}},\n'
    ' {{"name": "Nike gold finish gooseneck kitchen faucet", "box": [50, 600, 400, 900]}}]\n\n'
    "{ignore_block}"
    "ONLY include items from these categories: clothing, footwear, accessories "
    "(bags, watches, jewellery, sunglasses), furniture, home decor, kitchenware, "
    "electronics, sports equipment, books, stationery.\n\n"
    "STRICTLY EXCLUDE everything else: food, packaged food, groceries, dairy products, "
    "beverages, drinks, snacks, produce, cooking ingredients, condiments, supplements, "
    "medicine, cleaning products, walls, floors, ceilings, plain surfaces.\n"
    "IMPORTANT: If a person is visible, DO NOT exclude their clothing, shoes, bags, "
    "jewellery, or any accessory they are wearing — identify each wearable item as a "
    "separate product. Only exclude the person themselves (face, skin, body), not what "
    "they are wearing.\n\n"
    "Return [] only if the image contains absolutely no shoppable products from the listed categories."
)

_IDENTIFY_PROMPT = (
    "Describe the single product visible in this image in 3–7 words. "
    "Include as many of these as visible: Color, Material, Style/Shape, Brand, Object Name. "
    "Examples: 'Nike black cotton baseball cap', 'Vintage-style white ceramic utensil holder', "
    "'Stainless steel gooseneck pour-over kettle'. "
    "Return ONLY the description — no punctuation at the end, no explanation."
)

_SAFETY = [
    types.SafetySetting(category="HARM_CATEGORY_HATE_SPEECH",      threshold="BLOCK_NONE"),
    types.SafetySetting(category="HARM_CATEGORY_HARASSMENT",        threshold="BLOCK_NONE"),
    types.SafetySetting(category="HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold="BLOCK_NONE"),
    types.SafetySetting(category="HARM_CATEGORY_DANGEROUS_CONTENT", threshold="BLOCK_NONE"),
]


# ── Gemini helpers ────────────────────────────────────────────────────────────

_genai_client: Optional[genai.Client] = None


def _get_client() -> genai.Client:
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client(vertexai=True, project=_PROJECT, location=_LOCATION)
    return _genai_client


def _normalize_terms(terms: list[str] | None) -> list[str]:
    if not terms:
        return []
    normalized: list[str] = []
    seen: set[str] = set()
    for term in terms:
        value = str(term).strip()
        if not value:
            continue
        lowered = value.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        normalized.append(value)
    return normalized


def _describe_crop(jpeg_bytes: bytes) -> str:
    """Ask Gemini to produce a rich product description from a pre-cropped image.
    Returns an empty string on any failure so the caller can fall back to its own query."""
    try:
        client = _get_client()
        part = types.Part.from_bytes(data=jpeg_bytes, mime_type="image/jpeg")
        response = client.models.generate_content(
            model=_active_model,
            contents=[part, _IDENTIFY_PROMPT],
            config=types.GenerateContentConfig(
                safety_settings=_SAFETY,
                automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
            ),
        )
        description = response.text.strip()
        logger.info("Gemini crop description: '%s'", description)
        return description
    except Exception as exc:
        logger.warning("Gemini crop description failed: %s", exc)
        return ""


def _build_ignore_block(ignore_terms: list[str] | None) -> str:
    normalized = _normalize_terms(ignore_terms)
    if not normalized:
        return ""
    ignored = ", ".join(normalized)
    return (
        "Do not include any item that matches or clearly refers to these ignored "
        f"terms: {ignored}.\n\n"
    )


def _parse_items_with_boxes(text: str) -> list[dict]:
    """Parse Gemini response into list of {name, box} dicts. Tolerates both
    the new box format and the old plain-string format for backwards compat."""
    text = text.strip()
    match = re.search(r"\[.*\]", text, re.DOTALL)
    if not match:
        return []
    try:
        parsed = json.loads(match.group(0))
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    results = []
    for item in parsed:
        if isinstance(item, str) and item:
            results.append({"name": item, "box": None})
        elif isinstance(item, dict) and item.get("name"):
            box = item.get("box")
            if isinstance(box, list) and len(box) == 4:
                results.append({"name": str(item["name"]), "box": box})
            else:
                results.append({"name": str(item["name"]), "box": None})
    return results


def _guess_suffix(content_type: str | None, fallback_name: str) -> str:
    if content_type:
        suffix = mimetypes.guess_extension(content_type.split(";")[0].strip())
        if suffix:
            return suffix
    suffix = Path(fallback_name).suffix
    return suffix if suffix else ".img"


def _downscale_for_gemini(binary: bytes, mime: str, max_dimension: int) -> tuple[bytes, str]:
    """Downscale to at most max_dimension on the longest side, preserving aspect
    ratio. Only the copy sent to Gemini is affected — callers that crop against
    the original bytes (box coordinates are normalized 0-1000) are unaffected."""
    img = Image.open(io.BytesIO(binary))
    if max(img.size) <= max_dimension:
        return binary, mime
    img.thumbnail((max_dimension, max_dimension), Image.LANCZOS)
    if img.mode in ("RGBA", "LA", "P", "PA"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return buf.getvalue(), "image/jpeg"


def _load_image_part(
    *,
    image_url: str | None,
    image_data: str | None,
    image_mime_type: str | None,
    max_dimension: int | None = None,
) -> types.Part:
    if image_data:
        binary = base64.b64decode(image_data)
        mime = image_mime_type or "image/jpeg"
        if max_dimension:
            binary, mime = _downscale_for_gemini(binary, mime, max_dimension)
        return types.Part.from_bytes(data=binary, mime_type=mime)

    if image_url:
        req = urllib.request.Request(image_url, headers={"User-Agent": "ShopLensDemo/1.0"})
        with urllib.request.urlopen(req, timeout=20) as response:
            binary = response.read()
            mime = response.headers.get_content_type() or "image/jpeg"
        if max_dimension:
            binary, mime = _downscale_for_gemini(binary, mime, max_dimension)
        return types.Part.from_bytes(data=binary, mime_type=mime)

    raise ValueError("An image URL or base64 image payload is required")


# ── Image crop ────────────────────────────────────────────────────────────────

def _crop_product(image_bytes: bytes, box: list[int]) -> bytes:
    """Crop bounding box from image. box = [y_min, x_min, y_max, x_max] on 0-1000 scale."""
    img = Image.open(io.BytesIO(image_bytes))
    W, H = img.size
    y1, x1, y2, x2 = box
    pad = 0.05
    px1 = max(0, int((x1 / 1000 - pad) * W))
    py1 = max(0, int((y1 / 1000 - pad) * H))
    px2 = min(W, int((x2 / 1000 + pad) * W))
    py2 = min(H, int((y2 / 1000 + pad) * H))
    if px2 <= px1 or py2 <= py1:
        # Degenerate box — return full image
        px1, py1, px2, py2 = 0, 0, W, H
    crop = img.crop((px1, py1, px2, py2))
    if crop.mode in ("RGBA", "LA", "P", "PA"):
        crop = crop.convert("RGB")
    buf = io.BytesIO()
    crop.save(buf, format="JPEG", quality=85)
    return buf.getvalue()


# ── GCS upload ────────────────────────────────────────────────────────────────

def _upload_gcs(image_bytes: bytes) -> Optional[str]:
    """Upload image bytes to GCS and return the public URL, or None on failure."""
    if not _GCS_LENS_BUCKET:
        return None
    blob_name = f"lens-tmp/{uuid.uuid4().hex}.jpg"
    try:
        bucket = _get_gcs_client().bucket(_GCS_LENS_BUCKET)
        blob = bucket.blob(blob_name)
        blob.upload_from_string(image_bytes, content_type="image/jpeg")
        url = f"https://storage.googleapis.com/{_GCS_LENS_BUCKET}/{blob_name}"
        logger.info("GCS upload OK: %s", url)
        return url
    except Exception as exc:
        logger.warning("GCS upload failed: %s", exc)
        return None


def _delete_gcs(url: str) -> None:
    """Best-effort delete of a GCS object after Lens use."""
    try:
        blob_name = url.split(f"{_GCS_LENS_BUCKET}/", 1)[1]
        _get_gcs_client().bucket(_GCS_LENS_BUCKET).blob(blob_name).delete()
    except Exception:
        pass


def _search_shopping(query: str, country: str = "us", max_results: int = 5) -> list[dict]:
    """Text-based Google Shopping search via SerpAPI. Used as Lens fallback."""
    try:
        resp = _session.get(
            "https://serpapi.com/search",
            params={
                "engine":  "google_shopping",
                "q":       query,
                "api_key": _SERPAPI_KEY,
                "gl":      country or "us",
                "hl":      "en",
                "num":     max_results,
            },
            timeout=10,
        )
        data = resp.json()
        if "error" in data:
            logger.warning("Shopping error: %s", data["error"])
            if _is_serp_quota_error(data):
                _tls.serp_quota_exhausted = True
            return []
        results = data.get("shopping_results", [])
        products = []
        for r in results[:max_results]:
            name   = r.get("title", "")
            seller = r.get("source", "")
            price  = _parse_price(str(r.get("extracted_price") or r.get("price", "0")))
            products.append({
                "name":         _clean_product_name(name, seller),
                "price":        price,
                "image_url":    r.get("thumbnail", ""),
                "purchase_url": r.get("link") or r.get("product_link") or "",
                "seller":       seller,
                "product_id":   _make_product_id(seller, name),
                "category":     _infer_category(name, seller),
            })
        if products:
            logger.info("Shopping fallback matched '%s' → %d result(s)", query, len(products))
        else:
            logger.warning("Shopping fallback found nothing for '%s'", query)
        return products
    except Exception as exc:
        logger.warning("Shopping fallback failed for '%s': %s", query, exc)
        return []


# ── Product ID / category helpers (mirrors product-matcher) ──────────────────

_CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Furniture":          ["chair", "sofa", "couch", "desk", "table", "shelf", "wardrobe", "ottoman", "stool", "bookcase", "dresser", "nightstand", "bed frame"],
    "Clothing":           ["shirt", "jacket", "jeans", "dress", "hoodie", "shoe", "boot", "sneaker", "hat", "scarf", "coat", "pants", "shorts", "sweater", "blouse"],
    "Kitchen & Cookware": ["pan", "pot", "knife", "cutting board", "mug", "blender", "bowl", "skillet", "kettle", "spatula", "colander", "bakeware", "mixer"],
    "Accessories":        ["watch", "bag", "wallet", "necklace", "ring", "sunglasses", "bracelet", "earring", "purse", "handbag", "backpack", "tote"],
    "Electronics":        ["phone", "laptop", "tablet", "headphone", "speaker", "charger", "camera", "tv", "monitor", "keyboard", "mouse", "router", "earbud"],
    "Home Decor":         ["candle", "vase", "frame", "pillow", "rug", "lamp", "blanket", "curtain", "mirror", "diffuser", "plant pot", "throw", "wall art"],
    "Sports & Outdoors":  ["yoga", "gym", "bicycle", "tent", "bottle", "dumbbell", "mat", "ball", "racket", "hiking", "camping", "fitness", "weights"],
    "Books & Stationery": ["book", "notebook", "pen", "journal", "planner", "marker", "sketch", "pencil", "diary", "highlighter"],
}


def _infer_category(name: str, seller: str) -> str:
    text = (name + " " + seller).lower()
    for category, keywords in _CATEGORY_KEYWORDS.items():
        if any(kw in text for kw in keywords):
            return category
    return "General"


def _make_product_id(seller: str, name: str) -> str:
    raw    = f"{seller.lower()}-{name.lower()}"
    slug   = re.sub(r"[^a-z0-9]+", "-", raw)[:24].strip("-")
    digest = hashlib.sha1(raw.encode()).hexdigest()[:6]
    return f"{slug}-{digest}"


# ── Google Lens search ────────────────────────────────────────────────────────

_BLOCKED_DOMAINS = {
    "instagram.com", "pinterest.com", "pinterest.co.uk",
    "reddit.com", "facebook.com", "twitter.com", "x.com",
    "tiktok.com", "tumblr.com", "youtube.com", "youtu.be",
    "quora.com", "flickr.com", "imgur.com", "snapchat.com",
    "threads.net", "linkedin.com", "medium.com",
}


def _parse_price(raw: str) -> float:
    """Extract the first numeric price from any common format.
    Handles currency symbols, ranges ('From $X'), and non-USD currencies."""
    try:
        # Strip all currency symbols, then find the first decimal number
        cleaned = re.sub(r"[£€$¥₹₩₪]", "", str(raw))
        match   = re.search(r"\d[\d,]*(?:\.\d+)?", cleaned)
        if match:
            return float(match.group(0).replace(",", ""))
        return 0.0
    except (ValueError, TypeError):
        return 0.0


_ARTICLE_PATH_RE = re.compile(
    r"/(article|articles|blog|blogs|news|story|stories|post|posts|"
    r"editorial|guide|guides|review|reviews|how-to|listicle|magazine)/",
    re.IGNORECASE,
)


def _is_product_name(name: str) -> bool:
    """Return False if the name looks like a page title or question rather than a product."""
    if "?" in name:
        return False
    if len(name.split()) > 10:
        return False
    if len(name) > 100:
        return False
    return True


def _is_shopping_url(url: str) -> bool:
    """Return False if the URL is a social media, content platform, or article link."""
    try:
        parsed = urllib.parse.urlparse(url)
        host   = parsed.netloc.lower().lstrip("www.")
        if any(host == d or host.endswith("." + d) for d in _BLOCKED_DOMAINS):
            return False
        if _ARTICLE_PATH_RE.search(parsed.path):
            return False
        return True
    except Exception:
        return True


def _clean_product_name(name: str, seller: str) -> str:
    """Remove the seller name from the product title — it's shown separately in the UI."""
    if not seller or not name:
        return name
    s = re.escape(seller.strip())
    # "Seller - Product name" / "Seller | Product name" / "Seller: Product name"
    cleaned = re.sub(rf"^{s}\s*[-–:|]\s*", "", name, flags=re.IGNORECASE).strip()
    if cleaned and cleaned != name:
        return cleaned
    # "Product name - Seller" / "Product name | Seller"
    cleaned = re.sub(rf"\s*[-–:|]\s*{s}\s*$", "", name, flags=re.IGNORECASE).strip()
    if cleaned and cleaned != name:
        return cleaned
    # "Product name by Seller"
    cleaned = re.sub(rf"\s+by\s+{s}\s*$", "", name, flags=re.IGNORECASE).strip()
    return cleaned if cleaned else name


def _google_lens(image_url: str, query: str = "", country: str = "us", max_results: int = 5) -> list[dict]:
    """Call SerpAPI Google Lens and return up to max_results product matches
    from the visual_matches tab.

    Used to also fetch the products tab (type=products) concurrently, but it
    returned 0 results on every single call observed in production traffic
    (logged and confirmed across hundreds of calls, many item categories) —
    pure wasted SerpAPI quota and a wait on whichever of the two was slower.
    Dropped entirely rather than made conditional (see the
    analyzePerfomanceImprovement.md #2 regression for why "conditional but
    sequential" made things worse, not better — this is a different,
    unconditional removal, not that same change).
    """
    MAX = max_results
    results: list[dict] = []

    base_params: dict = {
        "engine":   "google_lens",
        "url":      image_url,
        "api_key":  _SERPAPI_KEY,
        "hl":       "en",
        "gl":       country or "us",
        "no_cache": "true",
    }
    if query:
        base_params["q"] = query

    def _fetch(type_value: str) -> dict:
        resp = _session.get(
            "https://serpapi.com/search",
            params={**base_params, "type": type_value},
            timeout=_LENS_TIMEOUT,
        )
        data = resp.json()
        if "error" in data:
            logger.warning("Lens [%s] error: %s", type_value, data["error"])
            if _is_serp_quota_error(data):
                _tls.serp_quota_exhausted = True
        else:
            logger.info("Lens [%s] keys: %s", type_value, list(data.keys()))
        return data

    def _build_result(r: dict, price: float) -> dict:
        seller = r.get("source") or ""
        name   = r.get("title") or ""
        return {
            "name":         _clean_product_name(name, seller),
            "price":        price,
            "image_url":    r.get("thumbnail") or "",
            "purchase_url": r.get("link") or "",
            "seller":       seller,
            "product_id":   _make_product_id(seller, name),
            "category":     _infer_category(name, seller),
        }

    try:
        data = _fetch("visual_matches")
    except Exception as exc:
        logger.warning("Lens visual_matches fetch failed: %s", exc)
        data = {}

    for r in data.get("visual_matches", []):
        if len(results) >= MAX:
            break
        name      = r.get("title", "")
        link      = r.get("link", "")
        if not name or not link:
            continue
        if not _is_product_name(name) or not _is_shopping_url(link):
            continue
        price_obj = r.get("price", {})
        price_val = price_obj.get("extracted_value", 0) if isinstance(price_obj, dict) else 0
        price     = _parse_price(str(price_val)) if price_val else 0.0
        logger.info("Lens match: '%s' price=%.2f url=%s", name, price, link)
        results.append(_build_result(r, price))
    logger.info("Lens (visual_matches): %d result(s)", len(results))

    if not results:
        logger.warning("Lens: no usable results for %s", image_url)
    return results


# ── Exception classifier ──────────────────────────────────────────────────────

def classify_exception(exc: Exception) -> tuple[int, str]:
    """Map an exception to (HTTP status code, error_code string)."""
    if isinstance(exc, ValueError):
        return 400, "INVALID_REQUEST"
    msg = str(exc).lower()
    if any(kw in msg for kw in ("timeout", "timed out", "connection", "network", "ssl", "remote end closed")):
        return 502, "UPSTREAM_ERROR"
    type_name = type(exc).__name__.lower()
    if any(kw in type_name for kw in ("google", "api", "grpc", "rpc", "transport")):
        return 502, "UPSTREAM_ERROR"
    return 500, "INTERNAL_ERROR"


# ── Single-crop identification (tap-to-identify, no Gemini *detection*) ──────
# Gemini is still used here — but only to describe the crop (color, material,
# brand, style) so Google Lens gets a richer query. What's skipped vs /analyze
# is the full-image bounding-box detection pass.

def _perceptual_cache_key(img_bytes: bytes, country: str) -> str:
    """Average hash of an 8×8 grayscale thumbnail — identical for the same object
    captured at slightly different crop positions, scales, or JPEG quality levels."""
    img = Image.open(io.BytesIO(img_bytes)).convert("L").resize((8, 8), Image.LANCZOS)
    pixels = list(img.getdata())
    mean = sum(pixels) / 64
    bits = "".join("1" if p >= mean else "0" for p in pixels)
    return format(int(bits, 2), "016x") + ":" + country


def identify_crop(
    *,
    image_data: str,
    image_mime_type: str | None = None,
    query: str = "",
    country: str = "us",
) -> tuple[list[dict], list[str]]:
    """Identify a pre-cropped image via Gemini description → GCS → Google Lens.
    Skips Gemini bounding-box detection (region already selected), but uses Gemini
    to produce a rich product description (color, material, brand, style) that
    improves Lens recall. Falls back to the caller-supplied query if Gemini fails.
    Results are cached for 30 minutes by perceptual hash + country — repeat taps on
    the same object return instantly without re-running Gemini or Lens."""
    _t_total_start = time.monotonic()
    _warnings: list[str] = []
    _tls.serp_quota_exhausted = False
    img_bytes = base64.b64decode(image_data)

    cache_key = _perceptual_cache_key(img_bytes, country or "us")
    if cache_key in _identify_cache:
        cached_products, cached_warnings = _identify_cache[cache_key]
        logger.info(
            "identify_crop cache hit | key=%s products=%d elapsed=0.00s",
            cache_key[:12], len(cached_products),
        )
        return cached_products, cached_warnings

    # Ensure JPEG (GCS / Lens work best with JPEG; PNG may be RGBA)
    img = Image.open(io.BytesIO(img_bytes))
    if img.mode in ("RGBA", "LA", "P", "PA"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    jpeg_bytes = buf.getvalue()

    _t_describe_upload_start = time.monotonic()
    if _IDENTIFY_SKIP_GEMINI:
        # Skip Gemini description — saves 3-6s per tap. Lens still works well
        # on the image alone; set IDENTIFY_SKIP_GEMINI=false to re-enable.
        logger.info("identify_crop: Gemini description skipped (IDENTIFY_SKIP_GEMINI=true)")
        gcs_url = _upload_gcs(jpeg_bytes)
        gemini_query = ""
    else:
        # Gemini description and GCS upload are independent — run concurrently.
        with ThreadPoolExecutor(max_workers=2) as _pool:
            _describe_future = _pool.submit(_describe_crop, jpeg_bytes)
            _upload_future = _pool.submit(_upload_gcs, jpeg_bytes)
            gemini_query = _describe_future.result()
            gcs_url = _upload_future.result()
    _t_describe_upload = time.monotonic() - _t_describe_upload_start

    effective_query = gemini_query or query

    if not gcs_url:
        msg = "identify_crop: GCS upload failed — visual search skipped"
        logger.warning(msg)
        _warnings.append(msg)
        logger.info(
            "TIMING | total=%.2fs describe_and_upload=%.2fs lens=0.00s shopping=0.00s",
            time.monotonic() - _t_total_start, _t_describe_upload,
        )
        return [], _warnings

    # Cleanup handled by the bucket's 1-day lifecycle rule, not an explicit
    # delete here, so it's off the request's critical path.
    _t_lens_start = time.monotonic()
    products = _google_lens(gcs_url, query=effective_query, country=country)
    _t_lens = time.monotonic() - _t_lens_start

    _t_shopping = 0.0
    if not products and effective_query and _SERPAPI_KEY:
        logger.info("Lens found nothing — trying Shopping fallback for '%s'", effective_query)
        _t_shopping_start = time.monotonic()
        products = _search_shopping(effective_query, country=country)
        _t_shopping = time.monotonic() - _t_shopping_start

    if getattr(_tls, "serp_quota_exhausted", False):
        logger.warning("SERP API quota exhausted — no product matches returned")
        _warnings.append("SERP_QUOTA_EXCEEDED")

    if not products:
        msg = f"No results found for '{effective_query}'" if effective_query else "No results found"
        logger.warning(msg)
        _warnings.append(msg)

    logger.info(
        "TIMING | total=%.2fs describe_and_upload=%.2fs lens=%.2fs shopping=%.2fs",
        time.monotonic() - _t_total_start, _t_describe_upload, _t_lens, _t_shopping,
    )
    _identify_cache[cache_key] = (products, _warnings)
    return products, _warnings


# ── Public API ────────────────────────────────────────────────────────────────

def analyze_media(
    *,
    gcs_video_uri: str | None = None,
    image_url: str | None = None,
    image_data: str | None = None,
    image_mime_type: str | None = None,
    transcript: str = "",
    ignore_terms: list[str] | None = None,
    country: str = "us",
    max_searches: int | None = None,
) -> tuple[list[str], list[dict], list[str]]:
    """Returns (item_names, products, warnings).

    item_names: generic labels detected by Gemini (used as fallback / for pubsub path).
    products:   visually matched products from Google Lens via GCS (empty for GCS video path).
    warnings:   non-fatal issues surfaced to the caller (e.g. Lens quota, GCS failures).
    """
    _t_total_start = time.monotonic()
    _warnings: list[str] = []
    client = _get_client()
    text_part = _PROMPT.format(
        ignore_block=_build_ignore_block(ignore_terms),
    )

    if gcs_video_uri:
        # Live-video path — no cropping/Lens available, return items only
        media_part = types.Part.from_uri(file_uri=gcs_video_uri, mime_type="video/mp4")
        _t_gemini_start = time.monotonic()
        response = client.models.generate_content(
            model=_active_model,
            contents=[media_part, text_part],
            config=types.GenerateContentConfig(
                safety_settings=_SAFETY,
                automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
            ),
        )
        _t_gemini = time.monotonic() - _t_gemini_start
        try:
            items_raw = _parse_items_with_boxes(response.text)
        except Exception as exc:
            logger.warning("Gemini parse failed: %s | raw=%s", exc, response.text)
            items_raw = []
        item_names = [r["name"] for r in items_raw]
        logger.info("analyze_media (video) detected %d item(s): %s", len(item_names), item_names)
        logger.info(
            "TIMING | total=%.2fs gemini=%.2fs items_phase=0.00s items=0 (video path, no Lens)",
            time.monotonic() - _t_total_start, _t_gemini,
        )
        return item_names, [], _warnings

    # Mobile/image path
    media_part = _load_image_part(
        image_url=image_url,
        image_data=image_data,
        image_mime_type=image_mime_type,
        max_dimension=1280,
    )
    _t_gemini_start = time.monotonic()
    response = client.models.generate_content(
        model=_active_model,
        contents=[media_part, text_part],
        config=types.GenerateContentConfig(
            safety_settings=_SAFETY,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        ),
    )
    _t_gemini = time.monotonic() - _t_gemini_start
    try:
        items_raw = _parse_items_with_boxes(response.text)
    except Exception as exc:
        logger.warning("Gemini parse failed: %s | raw=%s", exc, response.text)
        items_raw = []

    logger.info("Gemini raw response (first 500): %s", (response.text or "")[:500])
    item_names = [r["name"] for r in items_raw]
    logger.info("analyze_media detected %d item(s): %s", len(item_names), item_names)

    # Deduplicate Gemini items by normalised name before running Lens to avoid
    # wasting API calls on the same physical item detected multiple times.
    seen_keys: set[str] = set()
    unique_items: list[dict] = []
    for item in items_raw:
        key = re.sub(r"[^a-z0-9]", "", item["name"].lower())
        if key not in seen_keys:
            seen_keys.add(key)
            unique_items.append(item)
    if len(unique_items) < len(items_raw):
        logger.info("Deduped Gemini items: %d → %d", len(items_raw), len(unique_items))
    items_raw = unique_items

    # Cap SerpAPI (Lens) calls per run — user-configurable up to MAX_SEARCHES_PER_RUN.
    search_limit = clamp_max_searches(max_searches)
    if len(items_raw) > search_limit:
        logger.info("Capping Lens searches: %d detected → %d (limit=%d)", len(items_raw), search_limit, search_limit)
        items_raw = items_raw[:search_limit]

    # Decode raw image bytes once for cropping
    products: list[dict] = []
    _t_items_start = time.monotonic()
    _item_timings: dict[str, dict] = {}
    if image_data and _GCS_LENS_BUCKET and _SERPAPI_KEY:
        img_bytes = base64.b64decode(image_data)

        def _process_item(item: dict) -> tuple[list[dict], list[str], bool, dict]:
            _t_item_start = time.monotonic()
            _tls.serp_quota_exhausted = False
            item_warnings: list[str] = []
            name = item["name"]
            box  = item.get("box")

            _t_crop_start = time.monotonic()
            if box:
                crop = _crop_product(img_bytes, box)
                logger.info("Cropped '%s' box=%s → %d bytes", name, box, len(crop))
            else:
                # Gemini omitted a bounding box — fall back to the full image
                # rather than dropping the item from the (more accurate) Lens path.
                logger.warning("No bounding box for '%s' — using full image for Lens", name)
                item_warnings.append(f"No bounding box for '{name}' — used full image")
                crop = img_bytes
            _t_crop = time.monotonic() - _t_crop_start

            _t_upload_start = time.monotonic()
            gcs_url = _upload_gcs(crop)
            _t_upload = time.monotonic() - _t_upload_start
            if not gcs_url:
                msg = f"GCS upload failed for '{name}' — Lens skipped"
                logger.warning(msg)
                item_warnings.append(msg)
                timing = {"crop": _t_crop, "upload": _t_upload, "lens": 0.0, "shopping": 0.0,
                          "total": time.monotonic() - _t_item_start}
                return [], item_warnings, False, timing

            # One listing per detected object — total listings == number of
            # objects searched, matching the user-configured max_searches.
            # Cleanup handled by the bucket's 1-day lifecycle rule, not an
            # explicit delete here, so it's off the request's critical path.
            _t_lens_start = time.monotonic()
            matched = _google_lens(gcs_url, query=name, country=country, max_results=1)
            _t_lens = time.monotonic() - _t_lens_start

            _t_shopping = 0.0
            if matched:
                logger.info("Lens matched '%s' -> %d result(s)", name, len(matched))
            else:
                logger.warning("No Lens results for '%s' — trying Shopping fallback", name)
                if _SERPAPI_KEY:
                    _t_shopping_start = time.monotonic()
                    matched = _search_shopping(name, country=country, max_results=1)
                    _t_shopping = time.monotonic() - _t_shopping_start
                if matched:
                    logger.info("Shopping fallback matched '%s' → %d result(s)", name, len(matched))
                else:
                    msg = f"No results for '{name}' (Lens + Shopping both empty)"
                    logger.warning(msg)
                    item_warnings.append(msg)

            timing = {"crop": _t_crop, "upload": _t_upload, "lens": _t_lens, "shopping": _t_shopping,
                      "total": time.monotonic() - _t_item_start}
            return matched, item_warnings, getattr(_tls, "serp_quota_exhausted", False), timing


        quota_exhausted = False
        with ThreadPoolExecutor(max_workers=10) as pool:
            futures = {pool.submit(_process_item, item): item for item in items_raw}
            for future in as_completed(futures):
                result, item_warnings, item_quota, timing = future.result()
                _item_timings[futures[future]["name"]] = timing
                if item_quota:
                    quota_exhausted = True
                _warnings.extend(item_warnings)
                if result:
                    products.extend(result)

        # Deduplicate Lens results by product_id then by purchase URL
        seen_ids:  set[str] = set()
        seen_urls: set[str] = set()
        deduped:   list[dict] = []
        for p in products:
            pid = p.get("product_id", "")
            url = p.get("purchase_url", "")
            if (pid and pid in seen_ids) or (url and url in seen_urls):
                logger.info("Deduped product '%s' (%s)", p.get("name"), url)
                continue
            if pid: seen_ids.add(pid)
            if url: seen_urls.add(url)
            deduped.append(p)
        products = deduped

        if quota_exhausted:
            logger.warning("SERP API quota exhausted — no product matches returned")
            _warnings.append("SERP_QUOTA_EXCEEDED")

    elif not _GCS_LENS_BUCKET or not _SERPAPI_KEY:
        msg = "GCS_LENS_BUCKET or SERPAPI_KEY not set — visual matching disabled"
        logger.warning(msg)
        _warnings.append(msg)

    _t_items = time.monotonic() - _t_items_start
    _t_total = time.monotonic() - _t_total_start
    if _item_timings:
        slowest_name, slowest = max(_item_timings.items(), key=lambda kv: kv[1]["total"])
        logger.info(
            "TIMING | total=%.2fs gemini=%.2fs items_phase=%.2fs items=%d | "
            "slowest_item='%s' crop=%.2fs upload=%.2fs lens=%.2fs shopping=%.2fs item_total=%.2fs",
            _t_total, _t_gemini, _t_items, len(_item_timings), slowest_name,
            slowest["crop"], slowest["upload"], slowest["lens"], slowest["shopping"], slowest["total"],
        )
    else:
        logger.info(
            "TIMING | total=%.2fs gemini=%.2fs items_phase=%.2fs items=0",
            _t_total, _t_gemini, _t_items,
        )

    return item_names, products, _warnings


def analyze_media_stream(
    *,
    image_url: str | None = None,
    image_data: str | None = None,
    image_mime_type: str | None = None,
    ignore_terms: list[str] | None = None,
    country: str = "us",
    max_searches: int | None = None,
):
    """Generator version of analyze_media's image path, for streaming partial
    results to the client as each item's Lens search completes instead of
    making the whole request wait for the slowest one.

    Yields one dict per event:
    - {"type": "items", "items": [name, ...]}                            — once, right after Gemini detection
    - {"type": "match", "name": ..., "products": [...], "warnings": [...]} — once per item, as its Lens/Shopping search completes
    - {"type": "done", "warnings": [...]}                                 — once, at the end

    Video path isn't supported here — it already returns fast with no
    per-item Lens fan-out, so there's nothing to stream.
    """
    _t_total_start = time.monotonic()
    client = _get_client()
    text_part = _PROMPT.format(ignore_block=_build_ignore_block(ignore_terms))

    media_part = _load_image_part(
        image_url=image_url,
        image_data=image_data,
        image_mime_type=image_mime_type,
        max_dimension=1280,
    )
    _t_gemini_start = time.monotonic()
    response = client.models.generate_content(
        model=_active_model,
        contents=[media_part, text_part],
        config=types.GenerateContentConfig(
            safety_settings=_SAFETY,
            automatic_function_calling=types.AutomaticFunctionCallingConfig(disable=True),
        ),
    )
    _t_gemini = time.monotonic() - _t_gemini_start
    try:
        items_raw = _parse_items_with_boxes(response.text)
    except Exception as exc:
        logger.warning("Gemini parse failed: %s | raw=%s", exc, response.text)
        items_raw = []

    item_names = [r["name"] for r in items_raw]
    logger.info("analyze_media_stream detected %d item(s): %s", len(item_names), item_names)
    yield {"type": "items", "items": item_names}

    seen_keys: set[str] = set()
    unique_items: list[dict] = []
    for item in items_raw:
        key = re.sub(r"[^a-z0-9]", "", item["name"].lower())
        if key not in seen_keys:
            seen_keys.add(key)
            unique_items.append(item)
    items_raw = unique_items

    search_limit = clamp_max_searches(max_searches)
    if len(items_raw) > search_limit:
        items_raw = items_raw[:search_limit]

    final_warnings: list[str] = []

    if not (image_data and _GCS_LENS_BUCKET and _SERPAPI_KEY):
        if not _GCS_LENS_BUCKET or not _SERPAPI_KEY:
            msg = "GCS_LENS_BUCKET or SERPAPI_KEY not set — visual matching disabled"
            logger.warning(msg)
            final_warnings.append(msg)
        logger.info(
            "TIMING (stream) | total=%.2fs gemini=%.2fs items_phase=0.00s items=0",
            time.monotonic() - _t_total_start, _t_gemini,
        )
        yield {"type": "done", "warnings": final_warnings}
        return

    img_bytes = base64.b64decode(image_data)
    seen_ids:  set[str] = set()
    seen_urls: set[str] = set()

    def _process_item(item: dict) -> tuple[list[dict], list[str], bool]:
        _tls.serp_quota_exhausted = False
        item_warnings: list[str] = []
        name = item["name"]
        box  = item.get("box")
        if box:
            crop = _crop_product(img_bytes, box)
            logger.info("Cropped '%s' box=%s → %d bytes", name, box, len(crop))
        else:
            logger.warning("No bounding box for '%s' — using full image for Lens", name)
            item_warnings.append(f"No bounding box for '{name}' — used full image")
            crop = img_bytes
        gcs_url = _upload_gcs(crop)
        if not gcs_url:
            msg = f"GCS upload failed for '{name}' — Lens skipped"
            logger.warning(msg)
            item_warnings.append(msg)
            return [], item_warnings, False
        matched = _google_lens(gcs_url, query=name, country=country, max_results=1)
        if matched:
            logger.info("Lens matched '%s' -> %d result(s)", name, len(matched))
        else:
            logger.warning("No Lens results for '%s' — trying Shopping fallback", name)
            if _SERPAPI_KEY:
                matched = _search_shopping(name, country=country, max_results=1)
            if matched:
                logger.info("Shopping fallback matched '%s' → %d result(s)", name, len(matched))
            else:
                msg = f"No results for '{name}' (Lens + Shopping both empty)"
                logger.warning(msg)
                item_warnings.append(msg)
        return matched, item_warnings, getattr(_tls, "serp_quota_exhausted", False)

    quota_exhausted = False
    _t_items_start = time.monotonic()
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(_process_item, item): item for item in items_raw}
        for future in as_completed(futures):
            item = futures[future]
            result, item_warnings, item_quota = future.result()
            if item_quota:
                quota_exhausted = True
            final_warnings.extend(item_warnings)
            # Dedupe against everything already yielded this run, same rule
            # as analyze_media's post-hoc dedup, just applied incrementally.
            deduped: list[dict] = []
            for p in result:
                pid = p.get("product_id", "")
                url = p.get("purchase_url", "")
                if (pid and pid in seen_ids) or (url and url in seen_urls):
                    continue
                if pid: seen_ids.add(pid)
                if url: seen_urls.add(url)
                deduped.append(p)
            yield {"type": "match", "name": item["name"], "products": deduped, "warnings": item_warnings}

    if quota_exhausted:
        logger.warning("SERP API quota exhausted — no product matches returned")
        final_warnings.append("SERP_QUOTA_EXCEEDED")

    logger.info(
        "TIMING (stream) | total=%.2fs gemini=%.2fs items_phase=%.2fs items=%d",
        time.monotonic() - _t_total_start, _t_gemini, time.monotonic() - _t_items_start, len(items_raw),
    )
    yield {"type": "done", "warnings": final_warnings}


def analyze_segment(gcs_video_uri: str, transcript: str) -> list[str]:
    items, *_ = analyze_media(gcs_video_uri=gcs_video_uri, transcript=transcript)
    return items
