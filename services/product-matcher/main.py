import asyncio
import logging
import os
from typing import List

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

import requests as _requests
from matcher import clamp_max_searches, fetch_thumbnail, match_products, search_products, _search_product, _SERPAPI_KEY

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Product Matching Service")

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


class MatchRequest(BaseModel):
    items: List[str]
    ignore_terms: List[str] = []
    max_searches: int = 5


@app.post("/match")
async def match(request: MatchRequest) -> JSONResponse:
    result = await asyncio.to_thread(
        match_products, request.items, request.ignore_terms, request.max_searches
    )
    return JSONResponse(content=result)


class SearchRequest(BaseModel):
    query: str
    max_results: int = 5


@app.post("/search")
async def search(request: SearchRequest) -> JSONResponse:
    max_results = clamp_max_searches(request.max_results)
    products = await asyncio.to_thread(search_products, request.query, max_results)
    return JSONResponse(content={"products": products})


@app.get("/thumbnail")
async def thumbnail(url: str) -> Response:
    # Google's image CDN (where every product thumbnail we hand back points)
    # never sends Access-Control-Allow-Origin, so the browser blocks Flutter
    # web from fetching it directly. The mobile client routes thumbnails
    # through us instead — CORSMiddleware above adds the header on our way
    # back out, since this is now same-origin from the app's perspective.
    result = await asyncio.to_thread(fetch_thumbnail, url)
    if result is None:
        return Response(status_code=502)
    content, content_type = result
    return Response(
        content=content,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


@app.get("/debug/{item}")
async def debug(item: str) -> JSONResponse:
    result = _search_product(item)
    return JSONResponse(content={"item": item, "result": result})


@app.get("/debug-raw/{item}")
async def debug_raw(item: str) -> JSONResponse:
    resp = _requests.get(
        "https://serpapi.com/search",
        params={"engine": "google_shopping", "q": item, "api_key": _SERPAPI_KEY, "num": 1},
        timeout=10,
    )
    data = resp.json()
    first = (data.get("shopping_results") or [{}])[0]
    return JSONResponse(content={"keys": list(first.keys()), "first_result": first})


@app.get("/health")
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
