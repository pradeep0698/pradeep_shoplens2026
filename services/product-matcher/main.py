import asyncio
import hashlib
import logging
import os
from typing import List

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import requests as _requests
from matcher import (
    currency_for_country,
    fetch_thumbnail,
    match_products,
    normalize_country,
    search_products,
    _search_product,
    _SERPAPI_KEY,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Product Matcher",
    description=(
        "SerpAPI-powered Google Shopping search and product matching service.\n\n"
        "Takes a list of detected item names and returns the best matching purchasable products. "
        "Also exposes a thumbnail proxy endpoint that adds CORS headers to Google's CDN images "
        "so the Flutter web client can render them.\n\n"
        "**Auth:** none required — CORS is open (`*`)."
    ),
    version="1.0.0",
    openapi_tags=[
        {"name": "Matching", "description": "Batch item-to-product matching"},
        {"name": "Search", "description": "Direct product search"},
        {"name": "Debug", "description": "Single-item SerpAPI debugging"},
        {"name": "System", "description": "Health and diagnostics"},
    ],
)

_CORS = {"Access-Control-Allow-Origin": "*"}


@app.on_event("startup")
async def _log_startup_config() -> None:
    # Fingerprint, not the key itself — a short SHA-256 prefix is safe to log
    # (irreversible, useless for auth) but still lets you confirm across
    # environments/deployments that the SERPAPI_KEY actually loaded is the one
    # you expect, without ever putting real credential material in Cloud
    # Logging. Length is logged too since 0 is an unambiguous misconfiguration.
    _key = os.environ.get("SERPAPI_KEY", "")
    _key_fp = hashlib.sha256(_key.encode()).hexdigest()[:8] if _key else "(empty)"
    logger.info(
        "product-matcher starting | serpapi_key_len=%d serpapi_key_fp=%s",
        len(_key), _key_fp,
    )
    if not _key:
        logger.error("SERPAPI_KEY is empty or unset — every SerpAPI call will fail")


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    logger.warning("Unhandled error %s %s: %s", request.method, request.url.path, exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"}, headers=_CORS)


@app.exception_handler(HTTPException)
async def _http(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail}, headers=_CORS)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "HEAD"],
    allow_headers=["Content-Type", "Accept", "Authorization", "X-Requested-With", "Origin"],
)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class MatchRequest(BaseModel):
    items: List[str] = Field(..., description="List of detected item/product names to search for")
    ignore_terms: List[str] = Field(default_factory=list, description="Terms to exclude from search results")
    max_searches: int = Field(5, ge=1, le=20, description="Maximum SerpAPI calls to make")
    country: str = Field(
        "us",
        description="Two-letter ISO country code for regional product search. Empty/unset defaults to 'us'. "
                     "Currency is derived from this — see the `currency` field on the response.",
    )
    preference_terms: List[str] = Field(
        default_factory=list,
        description="Free-text style/brand/material preferences from the user's profile. Used to prioritize "
                     "which items get a SerpAPI search when there are more items than max_searches allows.",
    )
    shopping_categories: List[str] = Field(
        default_factory=list,
        description="Preferred shopping categories from the user's profile. Same prioritization role as preference_terms.",
    )

    model_config = {"json_schema_extra": {
        "examples": [{
            "items": ["stand mixer", "silicone spatula"], "ignore_terms": [], "max_searches": 5,
            "country": "us", "preference_terms": [], "shopping_categories": [],
        }]
    }}


class SearchRequest(BaseModel):
    query: str = Field(..., description="Freetext product search query")
    max_results: int = Field(15, ge=1, le=20, description="Maximum number of products to return")
    country: str = Field("us", description="Two-letter ISO country code for regional product search. Empty/unset defaults to 'us'.")


class ProductItem(BaseModel):
    product_id: str
    name: str
    price: float | None = Field(None, description="Price in the currency returned alongside this response (USD unless `country` implies otherwise)")
    image_url: str | None
    purchase_url: str | None
    seller: str | None
    category: str | None


class MatchResponse(BaseModel):
    matched_products: List[ProductItem]
    unmatched: List[str] = Field(..., description="Item names for which no product was found")
    country: str = Field(..., description="Normalized country used for this request (defaults to 'us')")
    currency: str = Field(..., description="Currency derived from `country`")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post(
    "/match",
    tags=["Matching"],
    summary="Match items to products",
    description=(
        "For each item name in `items`, runs a Google Shopping search via SerpAPI and returns "
        "the best matching product. Items with no results appear in `unmatched`.\n\n"
        "This is the primary endpoint called by the AI Analyzer and Pub/Sub Worker."
    ),
    responses={
        200: {"description": "Matching complete — check `unmatched` for items with no results"},
        500: {"description": "SerpAPI error"},
    },
)
async def match(request: MatchRequest) -> JSONResponse:
    result = await asyncio.to_thread(
        match_products,
        request.items,
        request.ignore_terms,
        request.max_searches,
        request.country,
        request.preference_terms,
        request.shopping_categories,
    )
    return JSONResponse(content=result)


@app.post(
    "/search",
    tags=["Search"],
    summary="Search for products by query",
    description="Direct Google Shopping search for a freetext query. Returns up to `max_results` products.",
)
async def search(request: SearchRequest) -> JSONResponse:
    # Pydantic's Field(ge=1, le=20) on SearchRequest.max_results already fully
    # validates the range before this handler runs — do NOT reuse
    # clamp_max_searches here, that constant (MAX_SEARCHES_PER_RUN=5) is
    # specifically for /match's SerpAPI-call-count cap, not /search's result
    # count. Reusing it here silently overrode any requested max_results down
    # to 5 regardless of what the caller asked for.
    country = normalize_country(request.country)
    products = await asyncio.to_thread(search_products, request.query, request.max_results, country)
    return JSONResponse(content={"products": products, "country": country, "currency": currency_for_country(country)})


@app.get(
    "/thumbnail",
    tags=["Search"],
    summary="Proxy a product thumbnail image",
    description=(
        "Fetches a product thumbnail from Google's image CDN and re-serves it with "
        "`Access-Control-Allow-Origin: *`. Required because Google's CDN omits CORS headers, "
        "which blocks Flutter web from fetching thumbnails directly."
    ),
    responses={
        200: {"description": "Image bytes with CORS header"},
        502: {"description": "Failed to fetch from upstream CDN"},
    },
)
async def thumbnail(url: str = Query(..., description="Fully-qualified Google CDN image URL")) -> Response:
    result = await asyncio.to_thread(fetch_thumbnail, url)
    if result is None:
        return Response(status_code=502)
    content, content_type = result
    return Response(
        content=content,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@app.get(
    "/debug/{item}",
    tags=["Debug"],
    summary="Debug — match single item",
    description="Runs `_search_product` for a single item and returns the raw internal result. For development only.",
)
async def debug(item: str) -> JSONResponse:
    result = _search_product(item)
    return JSONResponse(content={"item": item, "result": result})


@app.get(
    "/debug-raw/{item}",
    tags=["Debug"],
    summary="Debug — raw SerpAPI response",
    description="Calls SerpAPI directly for the given item and returns the first result entry with all keys. Pass ?engine=amazon to inspect the Amazon Search API's organic_results shape instead of Google Shopping's shopping_results. Useful for inspecting what SerpAPI returns before our parsing logic runs.",
)
async def debug_raw(item: str, engine: str = Query("google_shopping", description="google_shopping or amazon")) -> JSONResponse:
    params: dict = {"engine": engine, "api_key": _SERPAPI_KEY}
    if engine == "amazon":
        params.update({"k": item, "amazon_domain": "amazon.com"})
    else:
        params.update({"q": item, "num": 1})
    resp = _requests.get("https://serpapi.com/search", params=params, timeout=10)
    data = resp.json()
    result_key = "organic_results" if engine == "amazon" else "shopping_results"
    first = (data.get(result_key) or [{}])[0]
    return JSONResponse(content={"engine": engine, "keys": list(first.keys()), "first_result": first})


@app.get(
    "/health",
    tags=["System"],
    summary="Health check",
    description="Returns `ok` when SERPAPI_KEY is set, `degraded` (503) when it's missing.",
    responses={
        200: {"description": "Service healthy"},
        503: {"description": "Missing required environment variable"},
    },
)
async def health():
    missing = [v for v in ["SERPAPI_KEY"] if not os.environ.get(v)]
    if missing:
        return JSONResponse(
            content={"status": "degraded", "missing_env": missing},
            status_code=503,
        )
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
