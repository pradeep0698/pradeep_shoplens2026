import asyncio
import logging
import os
from typing import List

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import requests as _requests
from matcher import (
    clamp_max_searches,
    fetch_thumbnail,
    match_products,
    search_products_combined,
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

    model_config = {"json_schema_extra": {
        "examples": [{"items": ["stand mixer", "silicone spatula"], "ignore_terms": [], "max_searches": 5}]
    }}


class SearchRequest(BaseModel):
    query: str = Field(..., description="Freetext product search query")
    max_results: int = Field(5, ge=1, le=20, description="Maximum number of products to return")


class ProductItem(BaseModel):
    product_id: str
    name: str
    price: float | None = Field(None, description="Price in USD")
    image_url: str | None
    purchase_url: str | None
    seller: str | None
    category: str | None


class MatchResponse(BaseModel):
    matched_products: List[ProductItem]
    unmatched: List[str] = Field(..., description="Item names for which no product was found")


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
        match_products, request.items, request.ignore_terms, request.max_searches
    )
    return JSONResponse(content=result)


@app.post(
    "/search",
    tags=["Search"],
    summary="Search for products by query",
    description=(
        "Freetext product search for a given query. Tries Google Shopping first; if that "
        "returns nothing, falls back to Amazon (same SERPAPI_KEY, engine=amazon). Returns up "
        "to `max_results` products plus which provider answered."
    ),
)
async def search(request: SearchRequest) -> JSONResponse:
    max_results = clamp_max_searches(request.max_results)
    products, provider = await asyncio.to_thread(search_products_combined, request.query, max_results)
    return JSONResponse(content={"products": products, "provider": provider})


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
    description="Calls SerpAPI directly for the given item and returns the first `shopping_results` entry with all keys. Useful for inspecting what SerpAPI returns before our parsing logic runs.",
)
async def debug_raw(item: str) -> JSONResponse:
    resp = _requests.get(
        "https://serpapi.com/search",
        params={"engine": "google_shopping", "q": item, "api_key": _SERPAPI_KEY, "num": 1},
        timeout=10,
    )
    data = resp.json()
    first = (data.get("shopping_results") or [{}])[0]
    return JSONResponse(content={"keys": list(first.keys()), "first_result": first})


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
