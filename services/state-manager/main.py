import asyncio
import logging
import os
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from state_manager import clear_session, get_session, update_session

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="State Manager",
    description=(
        "Firestore-backed session state service. Stores the matched products for an active "
        "shopping session so the frontend and mobile clients can poll for live results.\n\n"
        "**Auth:** none required — CORS is open (`*`).\n\n"
        "**Session lifecycle:** The Pub/Sub Worker calls `POST /session/{id}/products` as each "
        "HLS segment is processed. The frontend polls `GET /session/{id}` to display results in real-time."
    ),
    version="1.0.0",
    openapi_tags=[
        {"name": "Session", "description": "Session product state — read, write, delete"},
        {"name": "System", "description": "Health and diagnostics"},
    ],
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "HEAD"],
    allow_headers=["Content-Type", "Accept", "Authorization", "X-Requested-With", "Origin"],
)

_CORS = {"Access-Control-Allow-Origin": "*"}


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    logger.exception("Unhandled error %s %s: %s", request.method, request.url.path, exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"}, headers=_CORS)


@app.exception_handler(HTTPException)
async def _http(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail}, headers=_CORS)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class ProductItem(BaseModel):
    product_id: str = Field(..., description="Unique product identifier from SerpAPI")
    name: str = Field(..., description="Human-readable product name")
    price: Optional[float] = Field(None, description="Price in USD")
    image_url: Optional[str] = Field(None, description="Product image URL (Google CDN)")
    purchase_url: Optional[str] = Field(None, description="Link to purchase this product")
    seller: Optional[str] = Field(None, description="Retailer name")
    category: Optional[str] = Field(None, description="Product category")


class UpdateRequest(BaseModel):
    products: List[ProductItem] = Field(..., description="Products to merge into the session")

    model_config = {"json_schema_extra": {
        "examples": [{
            "products": [{
                "product_id": "abc123",
                "name": "KitchenAid Stand Mixer",
                "price": 449.99,
                "image_url": "https://example.com/mixer.jpg",
                "purchase_url": "https://example.com/buy/mixer",
                "seller": "Best Buy",
                "category": "Kitchen Appliances",
            }]
        }]
    }}


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post(
    "/session/{session_id}/products",
    tags=["Session"],
    summary="Save products to session",
    description=(
        "Merges the provided products into the Firestore document for `session_id`. "
        "Called by the Pub/Sub Worker after each HLS segment is processed."
    ),
    responses={
        200: {"description": "Session updated"},
    },
)
async def update(session_id: str, request: UpdateRequest) -> JSONResponse:
    await asyncio.to_thread(update_session, session_id, [p.model_dump() for p in request.products])
    return JSONResponse(content={"status": "updated", "session_id": session_id})


@app.get(
    "/session/{session_id}",
    tags=["Session"],
    summary="Get session products",
    description=(
        "Returns the current product list for `session_id` from Firestore. "
        "Polled by the frontend to display live shopping results."
    ),
    responses={
        200: {"description": "Session data"},
        404: {"description": "Session not found"},
    },
)
async def get(session_id: str) -> JSONResponse:
    data = await asyncio.to_thread(get_session, session_id)
    if data is None:
        raise HTTPException(status_code=404, detail=f"Session '{session_id}' not found")
    return JSONResponse(content=data)


@app.delete(
    "/session/{session_id}",
    tags=["Session"],
    summary="Clear session",
    description="Deletes all products from the Firestore session document. Does not fail if the session doesn't exist.",
    responses={
        200: {"description": "Session cleared"},
    },
)
async def clear(session_id: str) -> JSONResponse:
    await asyncio.to_thread(clear_session, session_id)
    return JSONResponse(content={"status": "cleared", "session_id": session_id})


@app.get(
    "/health",
    tags=["System"],
    summary="Health check",
)
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
