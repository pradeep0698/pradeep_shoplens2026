import hashlib
import logging
import os
import re
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from cachetools import TTLCache

logger = logging.getLogger(__name__)

_SERPAPI_KEY = os.environ.get("SERPAPI_KEY", "")

# Hard ceiling on SerpAPI calls per match_products() run, regardless of what the
# caller requests — protects the shared SerpAPI quota. Per-user profile
# preference (1-5) is clamped against this.
MAX_SEARCHES_PER_RUN = 5

# Deployment-level cap on how many results come back per item. The user's 1-5
# "search results per scan" profile dial only limits results-per-item when a
# run is searching MULTIPLE items (keeps a busy scan from flooding the
# shopper with cards); a single-item run ignores the dial and uses this
# instead, since only one search call runs either way — SerpAPI is billed per
# search, not per result row.
MAX_RESULTS_PER_ITEM = int(os.environ.get("MAX_RESULTS_PER_ITEM", "15"))

# A bare requests.Session retries nothing — one dropped connection or 5xx
# blip fails the whole call. Mirrors services/ai-analyzer/analyzer.py's
# _build_session: idempotent GETs are safe to retry, but NOT on read-timeout
# — a call that already read for the full timeout with no response is the
# slow-server case, not a blip, and retrying would just double the wait.
#
# `read=False` (the literal bool, NOT `0` or `None`) is required, not just
# cosmetic — verified empirically. `read=0`/`read=None` still route a
# read-timeout through urllib3's retry-accounting path, which re-raises it
# wrapped as `requests.exceptions.ConnectionError` even though zero retries
# actually happen — silently breaking any caller that catches
# `requests.exceptions.Timeout` specifically. Only `read=False` makes
# urllib3 re-raise the original, unwrapped exception.
def _build_session() -> requests.Session:
    retry = Retry(
        total=2, connect=2, read=False, status=2,
        backoff_factor=0.3,
        status_forcelist=frozenset({429, 502, 503, 504}),
        allowed_methods=frozenset({"GET"}),
        raise_on_status=False,
    )
    session = requests.Session()
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


_session = _build_session()

# A single `timeout=N` in requests applies N to BOTH the connect and read
# phases independently, so a hung TCP handshake could wait the full read
# timeout too before even starting the read phase's own wait. Splitting caps
# connect failures at 5s and makes a dead-connection failure distinguishable
# from a server that connected fine but never answered (see the 2026-07-03
# SerpAPI incident in services/ai-analyzer/analyzer.py's _serp_get docstring).
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


_cache: TTLCache = TTLCache(maxsize=500, ttl=1800)

# Currency has no dedicated field anywhere in the system — derived from
# country instead. Mirrors services/ai-analyzer/analyzer.py's mapping and the
# 19-country dropdown in mobile/lib/presentation/widgets/profile_form.dart.
_COUNTRY_CURRENCY: dict[str, str] = {
    "us": "USD", "gb": "GBP", "ca": "CAD", "au": "AUD", "de": "EUR",
    "fr": "EUR", "in": "INR", "jp": "JPY", "br": "BRL", "mx": "MXN",
    "es": "EUR", "it": "EUR", "nl": "EUR", "se": "SEK", "sg": "SGD",
    "kr": "KRW", "ae": "AED", "za": "ZAR", "nz": "NZD", "ie": "EUR",
}
DEFAULT_COUNTRY = "us"
DEFAULT_CURRENCY = "USD"


def normalize_country(country: str | None) -> str:
    value = (country or "").strip().lower()
    return value or DEFAULT_COUNTRY


def currency_for_country(country: str | None) -> str:
    return _COUNTRY_CURRENCY.get(normalize_country(country), DEFAULT_CURRENCY)

# Domains SerpAPI's "thumbnail" field actually points at (Google's own image
# CDN, for both the google_shopping and google_lens engines) — used to scope
# fetch_thumbnail() below so it can't be used as an arbitrary open proxy.
_ALLOWED_THUMBNAIL_HOSTS = (".gstatic.com", ".googleusercontent.com", ".google.com")
_THUMBNAIL_CACHE: TTLCache = TTLCache(maxsize=500, ttl=3600)


def fetch_thumbnail(url: str) -> Optional[tuple[bytes, str]]:
    """Fetches a product thumbnail server-side and returns (bytes, content_type)
    — used by GET /thumbnail. Google's image CDN never sends Access-Control-
    Allow-Origin, so a browser (Flutter web) silently blocks a direct
    cross-origin fetch of these URLs; routing through our own origin instead
    works because we control the CORS headers on the way back out."""
    cache_key = url
    if cache_key in _THUMBNAIL_CACHE:
        return _THUMBNAIL_CACHE[cache_key]

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not any(
        parsed.netloc.endswith(host) for host in _ALLOWED_THUMBNAIL_HOSTS
    ):
        logger.warning("Refusing to proxy thumbnail from disallowed host: %s", url)
        return None

    try:
        resp = _session.get(url, timeout=10)
        resp.raise_for_status()
    except Exception as exc:
        logger.warning("Thumbnail fetch failed for '%s': %s", url, exc)
        return None

    result = (resp.content, resp.headers.get("Content-Type", "image/jpeg"))
    _THUMBNAIL_CACHE[cache_key] = result
    return result

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


def _parse_price(raw: str) -> float:
    try:
        return float(str(raw).replace("$", "").replace(",", "").strip())
    except (ValueError, TypeError):
        return 0.0


def _rank_by_quality(candidates: list[dict], max_results: int) -> list[dict]:
    """Mirrors services/ai-analyzer/analyzer.py's _rank_by_quality: priced
    results (price > 0) first; unpriced ones (SerpAPI gave us no price data)
    only fill remaining slots, so a request with enough good matches doesn't
    surface $0.00 listings just because they came first in SerpAPI's own
    order. Preserves SerpAPI's relative order within each tier."""
    priced   = [c for c in candidates if c["price"] > 0]
    unpriced = [c for c in candidates if c["price"] <= 0]
    selected = priced[:max_results]
    if len(selected) < max_results:
        selected += unpriced[:max_results - len(selected)]
    return selected


def _parse_shopping_result(r: dict, fallback_name: str) -> dict:
    name   = r.get("title", fallback_name)
    seller = r.get("source", "")
    # SerpAPI often omits a direct retailer link; fall back to a Google Shopping
    # search URL for the exact product name so the button is always clickable.
    purchase_url = (
        r.get("link")
        or r.get("product_link")
        or "https://www.google.com/search?tbm=shop&q=" + urllib.parse.quote(name)
    )
    return {
        "name":         name,
        "price":        r.get("extracted_price") or _parse_price(r.get("price", "0")),
        "image_url":    r.get("thumbnail", ""),
        "purchase_url": purchase_url,
        "seller":       seller,
        "product_id":   _make_product_id(seller, name),
        "category":     _infer_category(name, seller),
    }


def _shopping_search(query: str, num: int, country: str = DEFAULT_COUNTRY) -> list[dict]:
    """Raw SerpAPI google_shopping call, parsed into our product shape.
    Shared by _search_product (single best match, for the image pipeline)
    and search_products (multiple results, for an explicit user search).

    `gl` (country) was missing entirely before this — every search ran
    region-blind regardless of the user's profile, unlike ai-analyzer's
    Lens/Shopping calls which have always passed it."""
    try:
        data = _serp_get(
            "https://serpapi.com/search",
            {
                "engine":  "google_shopping",
                "q":       query,
                "api_key": _SERPAPI_KEY,
                "gl":      normalize_country(country),
                "hl":      "en",
                "num":     num,
            },
            read_timeout=10,
            label="shopping",
        )
    except Exception as exc:
        logger.warning("SerpAPI request failed for '%s': %s", query, exc)
        return []

    if "error" in data:
        logger.warning("SerpAPI error for '%s': %s", query, data["error"])
        return []

    results = data.get("shopping_results", [])
    if not results:
        logger.warning("No shopping results for '%s'", query)
        return []

    candidates = [_parse_shopping_result(r, query) for r in results]
    return _rank_by_quality(candidates, num)


def _search_product(item: str, country: str = DEFAULT_COUNTRY, max_results: int = 1) -> list[dict]:
    """Returns up to max_results matches for item, best first. Cache key
    includes country and max_results — a US search and a UK search for the
    same item name are different results (different `gl`), and a request for
    more results than a cached entry holds needs a fresh fetch."""
    country = normalize_country(country)
    cache_key = f"{item.lower().strip()}::{country}::{max_results}"
    if cache_key in _cache:
        logger.info("Cache hit for: %s (%s)", item, country)
        return _cache[cache_key]

    results = _shopping_search(item, max(max_results, 3), country=country)
    if not results:
        _cache[cache_key] = []
        return []

    matched = results[:max_results]
    logger.info("SerpAPI matched '%s' -> %d result(s) (top: %s $%.2f)",
                item, len(matched), matched[0]["name"], matched[0]["price"])
    _cache[cache_key] = matched
    return matched


def search_products(query: str, max_results: int = 5, country: str = DEFAULT_COUNTRY) -> list[dict]:
    """Free-text Google Shopping search returning up to max_results distinct
    products — unlike _search_product (single best match per detected item,
    used by the image pipeline), this surfaces several options for an
    explicit user search query to pick from."""
    country = normalize_country(country)
    cache_key = f"q::{query.lower().strip()}::{max_results}::{country}"
    if cache_key in _cache:
        logger.info("Cache hit for query: %s (%s)", query, country)
        return _cache[cache_key]

    products = _shopping_search(query, max_results, country=country)
    _cache[cache_key] = products
    logger.info("SerpAPI search '%s' -> %d result(s)", query, len(products))
    return products


def _normalize_terms(terms: list[str] | None) -> list[str]:
    if not terms:
        return []
    normalized: list[str] = []
    seen: set[str] = set()
    for term in terms:
        value = " ".join(str(term).lower().split())
        if not value or value in seen:
            continue
        seen.add(value)
        normalized.append(value)
    return normalized


def _is_ignored(item: str, ignore_terms: list[str]) -> bool:
    normalized = " ".join(item.lower().split())
    return any(term in normalized for term in ignore_terms)


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


def _term_matches(term: str, name: str) -> bool:
    """Substring match with naive singular/plural tolerance — a preference
    term typed as "laptops" should match an item name containing "laptop"
    and vice versa. `term` is already lowercased by _normalize_terms; `name`
    is lowercased by the caller. Not exhaustive (won't handle "watches" ->
    "watch"-style -es plurals), but covers the common trailing-s case.

    Also tolerant of compound-word spacing (mirrors
    services/ai-analyzer/analyzer.py's _term_matches): a preference typed as
    "Smart Watch" must still match an item name containing "smartwatch", and
    vice versa — found via a real preference-ranking miss where "smartwatch"
    scored 0 against a "Smart Watch" preference and lost to items matching
    only a generic category keyword."""
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


def _item_score(item: str, preference_terms: list[str], shopping_categories: list[str]) -> int:
    """Higher score sorts first. `preference_terms`/`shopping_categories` are
    already lowercased by _normalize_terms; _CATEGORY_KEYWORDS keys are not,
    hence the explicit .lower() on the category name here.

    Additive, not lexicographic: a category hit and each matching preference
    term each contribute one point, mirroring services/ai-analyzer/analyzer.py's
    _preference_score. A prior (category_hit, preference_hit) tuple sort key
    let any category match rank above every preference-only match regardless
    of how many preference terms hit — summing avoids either dimension
    unconditionally dominating the other."""
    name = item.lower()
    category_hit = any(
        kw in name
        for cat in shopping_categories
        for cat_name, kws in _CATEGORY_KEYWORDS.items()
        if cat_name.lower() == cat
        for kw in kws
    )
    preference_matches = sum(1 for term in preference_terms if _term_matches(term, name))
    return (1 if category_hit else 0) + preference_matches


def _prioritize_items(
    items: list[str],
    preference_terms: list[str] | None,
    shopping_categories: list[str] | None,
) -> list[str]:
    """Orders `items` so preference/category matches come first — used before
    truncating to the SerpAPI-call cap so a busy frame spends its limited
    quota on what the user is likely to want, matching the same prioritization
    services/ai-analyzer/analyzer.py applies to its own item cap."""
    prefs = _normalize_terms(preference_terms)
    cats = _normalize_terms(shopping_categories)
    if not prefs and not cats:
        return items
    return sorted(items, key=lambda item: -_item_score(item, prefs, cats))


def match_products(
    detected_items: list[str],
    ignore_terms: list[str] | None = None,
    max_searches: int | None = None,
    country: str = DEFAULT_COUNTRY,
    preference_terms: list[str] | None = None,
    shopping_categories: list[str] | None = None,
) -> dict:
    country = normalize_country(country)
    normalized_ignore = _normalize_terms(ignore_terms)
    items = [
        item for item in detected_items
        if not (normalized_ignore and _is_ignored(item, normalized_ignore))
    ]

    search_limit = clamp_max_searches(max_searches)
    if len(items) > search_limit:
        items = _prioritize_items(items, preference_terms, shopping_categories)
        logger.info("Capping SerpAPI searches: %d items → %d (limit=%d)", len(items), search_limit, search_limit)
        items = items[:search_limit]

    results_per_item = _results_per_item(len(items), max_searches)
    logger.info("Results per item: %d (items=%d, dial=%s)", results_per_item, len(items), max_searches)

    # SerpAPI calls are I/O-bound — run them concurrently instead of one-by-one
    # (mirrors the ThreadPoolExecutor pattern in services/ai-analyzer/analyzer.py).
    results: dict[str, list[dict]] = {}
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(_search_product, item, country, results_per_item): item for item in items}
        for future in as_completed(futures):
            results[futures[future]] = future.result()

    matched: dict[str, dict] = {}
    unmatched: list[str] = []
    for item in items:
        products = results.get(item) or []
        if products:
            for product in products:
                pid = product["product_id"]
                if pid not in matched:
                    matched[pid] = {
                        "product_id":   product["product_id"],
                        "name":         product["name"],
                        "price":        product["price"],
                        "image_url":    product.get("image_url", ""),
                        "purchase_url": product.get("purchase_url", ""),
                        "seller":       product.get("seller", ""),
                        "category":     product.get("category", "General"),
                    }
        else:
            unmatched.append(item)

    return {
        "matched_products": list(matched.values()),
        "unmatched":        unmatched,
        "country":          country,
        "currency":         currency_for_country(country),
    }