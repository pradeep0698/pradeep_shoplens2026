import hashlib
import logging
import os
import re
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import requests
from cachetools import TTLCache

logger = logging.getLogger(__name__)

_SERPAPI_KEY = os.environ.get("SERPAPI_KEY", "")

# Hard ceiling on SerpAPI calls per match_products() run, regardless of what the
# caller requests — protects the shared SerpAPI quota. Per-user profile
# preference (1-5) is clamped against this.
MAX_SEARCHES_PER_RUN = 5

_session = requests.Session()

_cache: TTLCache = TTLCache(maxsize=500, ttl=1800)

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


def _search_product(item: str) -> Optional[dict]:
    cache_key = item.lower().strip()
    if cache_key in _cache:
        logger.info("Cache hit for: %s", item)
        return _cache[cache_key]

    try:
        resp = _session.get(
            "https://serpapi.com/search",
            params={
                "engine":  "google_shopping",
                "q":       item,
                "api_key": _SERPAPI_KEY,
                "num":     3,
            },
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:
        logger.warning("SerpAPI request failed for '%s': %s", item, exc)
        _cache[cache_key] = None
        return None

    if "error" in data:
        logger.warning("SerpAPI error for '%s': %s", item, data["error"])
        _cache[cache_key] = None
        return None

    results = data.get("shopping_results", [])
    if not results:
        logger.warning("No shopping results for '%s'", item)
        _cache[cache_key] = None
        return None

    r = results[0]
    name   = r.get("title", item)
    seller = r.get("source", "")
    # SerpAPI often omits a direct retailer link; fall back to a Google Shopping
    # search URL for the exact product name so the button is always clickable.
    purchase_url = (
        r.get("link")
        or r.get("product_link")
        or "https://www.google.com/search?tbm=shop&q=" + urllib.parse.quote(name)
    )
    product = {
        "name":         name,
        "price":        r.get("extracted_price") or _parse_price(r.get("price", "0")),
        "image_url":    r.get("thumbnail", ""),
        "purchase_url": purchase_url,
        "seller":       seller,
        "product_id":   _make_product_id(seller, name),
        "category":     _infer_category(name, seller),
    }

    logger.info("SerpAPI matched '%s' -> %s ($%.2f)", item, name, product["price"])
    _cache[cache_key] = product
    return product


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


def match_products(
    detected_items: list[str],
    ignore_terms: list[str] | None = None,
    max_searches: int | None = None,
) -> dict:
    normalized_ignore = _normalize_terms(ignore_terms)
    items = [
        item for item in detected_items
        if not (normalized_ignore and _is_ignored(item, normalized_ignore))
    ]

    search_limit = clamp_max_searches(max_searches)
    if len(items) > search_limit:
        logger.info("Capping SerpAPI searches: %d items → %d (limit=%d)", len(items), search_limit, search_limit)
        items = items[:search_limit]

    # SerpAPI calls are I/O-bound — run them concurrently instead of one-by-one
    # (mirrors the ThreadPoolExecutor pattern in services/ai-analyzer/analyzer.py).
    results: dict[str, Optional[dict]] = {}
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {pool.submit(_search_product, item): item for item in items}
        for future in as_completed(futures):
            results[futures[future]] = future.result()

    matched: dict[str, dict] = {}
    unmatched: list[str] = []
    for item in items:
        product = results.get(item)
        if product is not None:
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
    }