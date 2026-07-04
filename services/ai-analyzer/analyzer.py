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
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from google import genai
from google.genai import types
from PIL import Image

logger = logging.getLogger(__name__)

_PROJECT      = os.environ.get("PROJECT_ID", "")
_LOCATION     = os.environ.get("LOCATION", "us-central1")
_DEFAULT_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-pro")
_GCS_LENS_BUCKET        = os.environ.get("GCS_LENS_BUCKET", "")
_SERPAPI_KEY            = os.environ.get("SERPAPI_KEY", "")
_LENS_TIMEOUT           = int(os.environ.get("LENS_TIMEOUT_SECONDS", "60"))
# Skip Gemini description on /identify by default — Lens works fine without it
# and Gemini adds 3-6s to every tap. Set to "false" to re-enable.
_IDENTIFY_SKIP_GEMINI   = os.environ.get("IDENTIFY_SKIP_GEMINI", "true").lower() not in ("0", "false", "no")

# Hard ceiling on SerpAPI (Lens) calls per analyze_media() run, regardless of
# what the caller requests — protects the shared SerpAPI quota from a single
# busy frame. Per-user profile preference (1-5) is clamped against this.
MAX_SEARCHES_PER_RUN = 5

# Deployment-level cap on how many results come back per item. The user's 1-5
# "search results per scan" profile dial only limits results-per-item when a
# run is searching MULTIPLE items (keeps a busy scan from flooding the
# shopper with cards); a single-item run — including every /identify tap,
# which is always exactly one object — ignores the dial and uses this
# instead, since only one search call runs either way. SerpAPI is billed per
# search, not per result row, so there's no cost reason to cap a lone search
# down to 1-5 results.
MAX_RESULTS_PER_ITEM = int(os.environ.get("MAX_RESULTS_PER_ITEM", "15"))

_tls = threading.local()


def clamp_max_searches(requested: int | None) -> int:
    if requested is None:
        return MAX_SEARCHES_PER_RUN
    return max(1, min(int(requested), MAX_SEARCHES_PER_RUN))


def _results_per_item(item_count: int, max_searches: int | None) -> int:
    """How many results to fetch for each item being searched this run.
    Multi-item runs stay dial-limited (clamped to MAX_RESULTS_PER_ITEM as a
    safety ceiling); a single-item run uses the deployment default directly,
    ignoring the dial."""
    if item_count > 1:
        return min(clamp_max_searches(max_searches), MAX_RESULTS_PER_ITEM)
    return MAX_RESULTS_PER_ITEM


# Currency has no dedicated field anywhere in the system — it's derived from
# country so a default/consistent value is always available without adding a
# new profile field. Mirrors the 19-country dropdown in
# mobile/lib/presentation/widgets/profile_form.dart. SerpAPI's google_shopping
# and google_lens engines have no currency param of their own — pricing already
# follows the `gl` (country) param, so this is purely a display/consistency
# label, not something that changes what SerpAPI returns.
_COUNTRY_CURRENCY: dict[str, str] = {
    "us": "USD", "gb": "GBP", "ca": "CAD", "au": "AUD", "de": "EUR",
    "fr": "EUR", "in": "INR", "jp": "JPY", "br": "BRL", "mx": "MXN",
    "es": "EUR", "it": "EUR", "nl": "EUR", "se": "SEK", "sg": "SGD",
    "kr": "KRW", "ae": "AED", "za": "ZAR", "nz": "NZD", "ie": "EUR",
}
DEFAULT_COUNTRY = "us"
DEFAULT_CURRENCY = "USD"


def normalize_country(country: str | None) -> str:
    """Empty/missing country defaults to 'us' — same default as
    AnalyzeRequest.country's Pydantic default, applied defensively here too
    since a client can send an empty string rather than omitting the field."""
    value = (country or "").strip().lower()
    return value or DEFAULT_COUNTRY


def currency_for_country(country: str | None) -> str:
    return _COUNTRY_CURRENCY.get(normalize_country(country), DEFAULT_CURRENCY)


def _is_serp_quota_error(data: dict) -> bool:
    err = data.get("error", "").lower()
    return "run out of searches" in err or "ran out of searches" in err


# A bare requests.Session retries nothing — one dropped connection or 5xx
# blip fails the whole call. SerpAPI GETs are idempotent, so retrying is
# safe. Deliberately NOT retrying on read-timeout: a call that already read
# for the full timeout with no response is the slow-server case, not a
# blip — retrying it would double the wait (e.g. 60s -> 120s) for a call
# that's likely to time out again. Only fast-failing connect errors and
# 429/5xx responses get retried.
#
# `read=False` (the literal bool, NOT `0` or `None`) is required here, not
# just cosmetic — verified empirically, since this bit urllib3 in production
# on 2026-07-03. `read=0`/`read=None` still route a read-timeout through
# urllib3's retry-accounting path, which re-raises it wrapped as
# `requests.exceptions.ConnectionError` (via urllib3's MaxRetryError) even
# though zero retries actually happen. That silently breaks any caller
# catching `requests.exceptions.Timeout` specifically (e.g. _google_lens's
# `_tls.lens_timed_out` flag, which gates the /identify recovery path) —
# those calls no longer matched and always fell through to the generic
# exception branch. Only `read=False` makes urllib3 re-raise the original,
# unwrapped exception instead of going through the retry/wrap machinery.
def _build_session() -> _req.Session:
    retry = Retry(
        total=2, connect=2, read=False, status=2,
        backoff_factor=0.3,
        status_forcelist=frozenset({429, 502, 503, 504}),
        allowed_methods=frozenset({"GET"}),
        raise_on_status=False,
    )
    session = _req.Session()
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


_session = _build_session()

# A single `timeout=N` in requests applies N to BOTH the connect and read
# phases independently — so a hung TCP handshake could previously wait the
# full LENS_TIMEOUT_SECONDS (up to 60s) before even getting to the read
# phase's own up-to-60s wait. Splitting the two caps connect failures at 5s
# instead, and (paired with the tracing below) lets us tell a dead-connection
# failure apart from a server that connected fine but never answered — which
# is what actually happened in the 2026-07-03 SerpAPI incident this was added
# for (that one was purely a read-phase hang; connect succeeded immediately).
_SERP_CONNECT_TIMEOUT = 5


def _serp_get(url: str, params: dict, read_timeout: float, label: str) -> dict:
    """Shared SerpAPI GET: connect/read timeout split, structured before/after
    tracing (api_key masked), and a readable log line when SerpAPI's response
    isn't valid JSON instead of an opaque JSONDecodeError downstream."""
    safe_params = {k: v for k, v in params.items() if k != "api_key"}
    t0 = time.monotonic()
    try:
        resp = _session.get(url, params=params, timeout=(_SERP_CONNECT_TIMEOUT, read_timeout))
    except Exception as exc:
        logger.warning(
            "SerpAPI [%s] request failed: type=%s elapsed=%.2fs params=%s error=%s",
            label, type(exc).__name__, time.monotonic() - t0, safe_params, exc,
        )
        raise
    elapsed = time.monotonic() - t0
    try:
        data = resp.json()
    except ValueError:
        logger.warning(
            "SerpAPI [%s] non-JSON response: status=%s elapsed=%.2fs body=%r",
            label, resp.status_code, elapsed, resp.text[:300],
        )
        raise
    logger.info(
        "SerpAPI [%s] status=%s elapsed=%.2fs params=%s",
        label, resp.status_code, elapsed, safe_params,
    )
    return data


def _probe_serp_quota() -> bool:
    """Check SerpAPI quota via the account endpoint (fast, no search cost).
    Returns True if quota is available, False if exhausted.
    Called after a Lens timeout to avoid chaining Gemini + Shopping hangs
    when the real cause is quota exhaustion."""
    try:
        data = _serp_get(
            "https://serpapi.com/account",
            {"api_key": _SERPAPI_KEY},
            read_timeout=3,
            label="account",
        )
        if "error" in data:
            # e.g. an invalid/revoked key — distinct from quota exhaustion.
            # `total_searches_left` is absent from this response shape, so
            # falling through to the .get(..., default) below would silently
            # misreport this as "quota OK — 1 searches left".
            logger.warning("SerpAPI quota probe returned an error: %s — assuming quota OK", data["error"])
            return True
        remaining = data.get("total_searches_left", 1)
        if remaining == 0:
            logger.warning("SerpAPI quota exhausted — 0 searches left")
            _tls.serp_quota_exhausted = True
            return False
        logger.info("SerpAPI quota probe OK — %d searches left", remaining)
        return True
    except Exception as exc:
        logger.warning("SerpAPI quota probe failed: %s — assuming quota OK", exc)
        return True

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
    "{preference_block}"
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


def _build_preference_block(
    preference_terms: list[str] | None,
    shopping_categories: list[str] | None,
) -> str:
    """User profile preferences/categories bias what Gemini lists FIRST — this
    matters because analyze_media() only spends its limited SerpAPI-search
    budget on the first `max_searches` items, so ordering directly affects
    which items actually get product matches. Never excludes anything; a
    non-preferred item is still a valid product, just not prioritized."""
    prefs = _normalize_terms(preference_terms)
    cats = _normalize_terms(shopping_categories)
    if not prefs and not cats:
        return ""
    lines = ["This user has stated shopping preferences — use them to ORDER your "
             "results (preferred items first in the returned array), but still "
             "include every qualifying item you find, preferred or not:\n"]
    if cats:
        lines.append(f"- Preferred categories: {', '.join(cats)}\n")
    if prefs:
        lines.append(f"- Preferred styles/brands/materials: {', '.join(prefs)}\n")
    lines.append("\n")
    return "".join(lines)


def _term_matches(term: str, name: str) -> bool:
    """Case-insensitive substring match with naive singular/plural tolerance —
    a preference term typed as "laptops" should match an item name containing
    "laptop" and vice versa. Handles the common English trailing-s plural
    without pulling in a stemming library; not exhaustive (won't handle
    "watches" -> "watch"-style -es plurals), but covers the common case.

    Also tolerant of compound-word spacing: a preference typed as "Smart
    Watch" must still match an item name containing "smartwatch" (Gemini's
    one-word phrasing), and vice versa — found via a real preference-ranking
    miss where "smartwatch" scored 0 against a "Smart Watch" preference and
    lost out to items matching only a generic category keyword. Comparing
    with whitespace stripped from both sides catches this without needing a
    dictionary of known compounds."""
    term = term.lower()
    if term in name:
        return True
    if term.endswith("s") and term[:-1] in name:
        return True
    if not term.endswith("s") and (term + "s") in name:
        return True
    term_compact = term.replace(" ", "")
    if term_compact and term_compact in name.replace(" ", ""):
        return True
    return False


def _preference_score(item: dict, preference_terms: list[str], shopping_categories: list[str]) -> int:
    """Higher score sorts first. Used to pick which detected items get a Lens
    search when there are more items than max_searches allows — without this,
    truncation is an arbitrary function of Gemini's listing order.

    Additive, not lexicographic: a category hit and each matching preference
    term each contribute one point. A previous version used a (category_hit,
    preference_hit) tuple sort key, which meant ANY category match — even with
    zero preference matches — ranked above EVERY item with a preference match
    but no category match. That silently made an explicit, specific user
    preference (e.g. "Smart watch") powerless against a generic category
    match (e.g. "Electronics" catching a laptop), which is backwards — a
    direct preference-term hit is at least as strong a signal as a category
    hit. Summing lets an item that matches on both outrank one that matches
    on only one, without either dimension being able to unconditionally
    dominate the other.

    Category matching goes through _CATEGORY_KEYWORDS (same keyword lists
    _infer_category uses) rather than a literal substring check — a category
    name like "Furniture" never appears verbatim in an item name like "wooden
    dining chair", so keyword lookup is required for this to match anything."""
    name = item["name"].lower()
    category_hit = any(
        kw in name for cat in shopping_categories for kw in _CATEGORY_KEYWORDS.get(cat, [])
    )
    preference_matches = sum(1 for term in preference_terms if _term_matches(term, name))
    return (1 if category_hit else 0) + preference_matches


def _prioritize_items(
    items_raw: list[dict],
    preference_terms: list[str] | None,
    shopping_categories: list[str] | None,
) -> list[dict]:
    prefs = _normalize_terms(preference_terms)
    cats = _normalize_terms(shopping_categories)
    if not prefs and not cats:
        return items_raw
    # Stable sort — preserves Gemini's relative ordering within each score tier.
    # Negate the score since sorted() is ascending and we want highest-first.
    return sorted(items_raw, key=lambda item: -_preference_score(item, prefs, cats))


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
        data = _serp_get(
            "https://serpapi.com/search",
            {
                "engine":  "google_shopping",
                "q":       query,
                "api_key": _SERPAPI_KEY,
                "gl":      country or "us",
                "hl":      "en",
                "num":     max_results,
            },
            read_timeout=10,
            label="shopping",
        )
        if "error" in data:
            logger.warning("Shopping error: %s", data["error"])
            if _is_serp_quota_error(data):
                _tls.serp_quota_exhausted = True
            return []
        candidates = []
        for r in data.get("shopping_results", []):
            name   = r.get("title", "")
            seller = r.get("source", "")
            link   = r.get("link") or r.get("product_link") or ""
            if not name or not link:
                continue
            if not _is_product_name(name) or not _is_shopping_url(link):
                continue
            price = _parse_price(str(r.get("extracted_price") or r.get("price", "0")))
            candidates.append({
                "name":         _clean_product_name(name, seller),
                "price":        price,
                "image_url":    r.get("thumbnail", ""),
                "purchase_url": link,
                "seller":       seller,
                "product_id":   _make_product_id(seller, name),
                "category":     _infer_category(name, seller),
            })
        products = _rank_by_quality(candidates, max_results)
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


_NON_PRODUCT_PATH_RE = re.compile(
    r"/(article|articles|blog|blogs|news|story|stories|post|posts|"
    r"editorial|guide|guides|review|reviews|how-to|listicle|magazine|"
    r"questionandanswer|question-and-answer|faq|qa|support|help|"
    r"shop|sch)/",
    re.IGNORECASE,
)

# eBay's own search-keyword query param — a /sch/ or bare-query hit with this
# present is a search-results page, not a single listing, even when the path
# itself looks plausible.
_SEARCH_QUERY_PARAM_RE = re.compile(r"(?:^|[?&])(_nkw|q|keywords|search)=", re.IGNORECASE)

# Found 2026-07-04: a real "SORRY, THIS ITEM IS SOLD!" listing passed the
# existing checks (no "?", under 10 words, under 100 chars) and was returned
# to a shopper as if it were purchasable.
_UNAVAILABLE_PHRASES = (
    "sold out", "item is sold", "no longer available", "out of stock",
    "currently unavailable", "listing has ended", "item not found",
)


def _is_product_name(name: str) -> bool:
    """Return False if the name looks like a page title, question, or a
    listing that isn't actually purchasable (sold out, no longer available)."""
    if "?" in name:
        return False
    if len(name.split()) > 10:
        return False
    if len(name) > 100:
        return False
    lowered = name.lower()
    if any(phrase in lowered for phrase in _UNAVAILABLE_PHRASES):
        return False
    return True


def _is_shopping_url(url: str) -> bool:
    """Return False if the URL is a social media, content platform, article,
    Q&A/support page, or a search/category-listing page rather than a single
    product. Found 2026-07-04: a Galaxus Q&A page
    (.../questionandanswer/...) and an eBay seller-storefront search
    (.../shop/...?_nkw=...) both passed the old, narrower check."""
    try:
        parsed = urllib.parse.urlparse(url)
        host   = parsed.netloc.lower().lstrip("www.")
        if any(host == d or host.endswith("." + d) for d in _BLOCKED_DOMAINS):
            return False
        if _NON_PRODUCT_PATH_RE.search(parsed.path):
            return False
        if _SEARCH_QUERY_PARAM_RE.search(parsed.query):
            return False
        return True
    except Exception:
        return True


def _rank_by_quality(candidates: list[dict], max_results: int) -> list[dict]:
    """Priced results (price > 0) first; unpriced ones (SerpAPI gave us no
    price data — a real listing, just missing a number) only fill remaining
    slots. Found 2026-07-04: a request with 15 valid candidates but only 3
    priced ones still showed all 12 $0.00 results, since the old code just
    took SerpAPI's own order. Preserves SerpAPI's relative order within each
    tier — this only re-groups by price, it doesn't re-rank within a tier."""
    priced   = [c for c in candidates if c["price"] > 0]
    unpriced = [c for c in candidates if c["price"] <= 0]
    selected = priced[:max_results]
    if len(selected) < max_results:
        selected += unpriced[:max_results - len(selected)]
    return selected


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


# Appended to every Lens visual_matches query to bias results toward
# purchasable listings (with a price and a link) instead of general visual
# lookalikes — informational pages, image galleries, etc.
_LENS_SHOPPING_HINT = "this is for shopping, include price and links"


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
    base_params["q"] = f"{query} {_LENS_SHOPPING_HINT}" if query else _LENS_SHOPPING_HINT

    def _fetch(type_value: str) -> dict:
        data = _serp_get(
            "https://serpapi.com/search",
            {**base_params, "type": type_value},
            read_timeout=_LENS_TIMEOUT,
            label=f"lens:{type_value}",
        )
        if "error" in data:
            logger.warning("Lens [%s] error: %s", type_value, data["error"])
            if _is_serp_quota_error(data):
                _tls.serp_quota_exhausted = True
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
    except _req.exceptions.Timeout as exc:
        logger.warning("Lens visual_matches fetch failed: %s", exc)
        _tls.lens_timed_out = True
        data = {}
    except Exception as exc:
        logger.warning("Lens visual_matches fetch failed: %s", exc)
        data = {}

    candidates: list[dict] = []
    for r in data.get("visual_matches", []):
        name = r.get("title", "")
        link = r.get("link", "")
        if not name or not link:
            continue
        if not _is_product_name(name) or not _is_shopping_url(link):
            continue
        price_obj = r.get("price", {})
        price_val = price_obj.get("extracted_value", 0) if isinstance(price_obj, dict) else 0
        price     = _parse_price(str(price_val)) if price_val else 0.0
        logger.info("Lens match: '%s' price=%.2f url=%s", name, price, link)
        candidates.append(_build_result(r, price))

    results  = _rank_by_quality(candidates, MAX)
    n_priced = sum(1 for c in candidates if c["price"] > 0)
    logger.info(
        "Lens (visual_matches): %d candidate(s) (%d priced, %d unpriced) -> %d selected",
        len(candidates), n_priced, len(candidates) - n_priced, len(results),
    )

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
    max_results: int = MAX_RESULTS_PER_ITEM,
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
    country = normalize_country(country)
    logger.info("PROFILE | country=%s currency=%s", country, currency_for_country(country))
    img_bytes = base64.b64decode(image_data)

    cache_key = _perceptual_cache_key(img_bytes, country)
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
    _tls.lens_timed_out = False
    _t_lens_start = time.monotonic()
    products = _google_lens(gcs_url, query=effective_query, country=country, max_results=max_results)
    _t_lens = time.monotonic() - _t_lens_start

    # If Lens timed out and Gemini was skipped (no query), probe SerpAPI quota
    # first — if exhausted, skip Gemini + Shopping entirely (both would hang).
    # Only if quota is confirmed available, run Gemini to get a description and
    # then fall through to the Shopping fallback below.
    _t_shopping = 0.0
    if (not products
            and not effective_query
            and getattr(_tls, "lens_timed_out", False)
            and not getattr(_tls, "serp_quota_exhausted", False)
            and _SERPAPI_KEY):
        if _probe_serp_quota():
            logger.info("identify_crop: Lens timed out with no query — running Gemini as recovery")
            _t_recovery_start = time.monotonic()
            effective_query = _describe_crop(jpeg_bytes)
            _t_describe_upload += time.monotonic() - _t_recovery_start
            if effective_query:
                logger.info("identify_crop: Gemini recovery → '%s', trying Shopping", effective_query)
        else:
            logger.warning("identify_crop: skipping Gemini + Shopping — SerpAPI quota exhausted")

    if not products and effective_query and _SERPAPI_KEY:
        logger.info("Lens found nothing — trying Shopping fallback for '%s'", effective_query)
        _t_shopping_start = time.monotonic()
        products = _search_shopping(effective_query, country=country, max_results=max_results)
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
    preference_terms: list[str] | None = None,
    shopping_categories: list[str] | None = None,
) -> tuple[list[str], list[dict], list[str]]:
    """Returns (item_names, products, warnings).

    item_names: generic labels detected by Gemini (used as fallback / for pubsub path).
    products:   visually matched products from Google Lens via GCS (empty for GCS video path).
    warnings:   non-fatal issues surfaced to the caller (e.g. Lens quota, GCS failures).
    """
    _t_total_start = time.monotonic()
    _warnings: list[str] = []
    country = normalize_country(country)
    client = _get_client()
    text_part = _PROMPT.format(
        ignore_block=_build_ignore_block(ignore_terms),
        preference_block=_build_preference_block(preference_terms, shopping_categories),
    )
    logger.info(
        "PROFILE | country=%s currency=%s preference_terms=%s shopping_categories=%s",
        country, currency_for_country(country), preference_terms or [], shopping_categories or [],
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
    # Prioritize items matching the user's preferences/categories BEFORE
    # truncating, so a busy frame spends its limited quota on what the user
    # is likely to want rather than on whatever Gemini happened to list first.
    search_limit = clamp_max_searches(max_searches)
    if len(items_raw) > search_limit:
        items_raw = _prioritize_items(items_raw, preference_terms, shopping_categories)
        logger.info("Capping Lens searches: %d detected → %d (limit=%d)", len(items_raw), search_limit, search_limit)
        items_raw = items_raw[:search_limit]

    results_per_item = _results_per_item(len(items_raw), max_searches)
    logger.info("Results per item: %d (items=%d, dial=%s)", results_per_item, len(items_raw), max_searches)

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

            # Up to results_per_item listings per detected object — dial-capped
            # when multiple objects are being searched, deployment-capped when
            # this is the only one. Cleanup handled by the bucket's 1-day
            # lifecycle rule, not an explicit delete here, so it's off the
            # request's critical path.
            _t_lens_start = time.monotonic()
            matched = _google_lens(gcs_url, query=name, country=country, max_results=results_per_item)
            _t_lens = time.monotonic() - _t_lens_start

            _t_shopping = 0.0
            if matched:
                logger.info("Lens matched '%s' -> %d result(s)", name, len(matched))
            else:
                logger.warning("No Lens results for '%s' — trying Shopping fallback", name)
                if _SERPAPI_KEY:
                    _t_shopping_start = time.monotonic()
                    matched = _search_shopping(name, country=country, max_results=results_per_item)
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
    preference_terms: list[str] | None = None,
    shopping_categories: list[str] | None = None,
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
    country = normalize_country(country)
    client = _get_client()
    text_part = _PROMPT.format(
        ignore_block=_build_ignore_block(ignore_terms),
        preference_block=_build_preference_block(preference_terms, shopping_categories),
    )
    logger.info(
        "PROFILE | country=%s currency=%s preference_terms=%s shopping_categories=%s",
        country, currency_for_country(country), preference_terms or [], shopping_categories or [],
    )

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
        items_raw = _prioritize_items(items_raw, preference_terms, shopping_categories)
        items_raw = items_raw[:search_limit]

    results_per_item = _results_per_item(len(items_raw), max_searches)

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
        yield {"type": "done", "warnings": final_warnings, "country": country, "currency": currency_for_country(country)}
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
        matched = _google_lens(gcs_url, query=name, country=country, max_results=results_per_item)
        if matched:
            logger.info("Lens matched '%s' -> %d result(s)", name, len(matched))
        else:
            logger.warning("No Lens results for '%s' — trying Shopping fallback", name)
            if _SERPAPI_KEY:
                matched = _search_shopping(name, country=country, max_results=results_per_item)
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
    yield {"type": "done", "warnings": final_warnings, "country": country, "currency": currency_for_country(country)}


def analyze_segment(gcs_video_uri: str, transcript: str) -> list[str]:
    items, *_ = analyze_media(gcs_video_uri=gcs_video_uri, transcript=transcript)
    return items
