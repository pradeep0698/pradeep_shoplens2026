import asyncio
import json
import logging
import os
import threading
import time
import uuid
from contextvars import ContextVar

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from analyzer import (
    analyze_media,
    analyze_media_stream,
    classify_exception,
    identify_crop,
    get_active_model,
    set_active_model,
)

_request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


class _RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = _request_id_ctx.get()
        return True


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [req=%(request_id)s] %(name)s: %(message)s",
)
for _handler in logging.getLogger().handlers:
    _handler.addFilter(_RequestIdFilter())

logger = logging.getLogger(__name__)

app = FastAPI(
    title="AI Analyzer",
    description=(
        "Gemini-powered image and video analysis service. Accepts an image (base64 or URL) "
        "or a GCS video segment URI, runs Gemini to detect shoppable items, searches Google "
        "Shopping via SerpAPI, and returns structured product results.\n\n"
        "**Auth:** none required — CORS is open (`*`).\n\n"
        "**Typical flow:** `POST /analyze` → items + products in one call. "
        "Use `POST /analyze/stream` for progressive results (one NDJSON line per item as it resolves). "
        "Use `POST /identify` when the client has already cropped to a single product."
    ),
    version="1.0.0",
    openapi_tags=[
        {"name": "Analysis", "description": "Image and video analysis — detect items and match products"},
        {"name": "Config", "description": "Active Gemini model management"},
        {"name": "System", "description": "Health and diagnostics"},
    ],
)

_CORS = {"Access-Control-Allow-Origin": "*"}


@app.on_event("startup")
async def _log_startup_config() -> None:
    logger.info(
        "ai-analyzer starting | project_id=%s location=%s model=%s "
        "gcs_lens_bucket=%s serpapi_key=%s",
        os.environ.get("PROJECT_ID") or "(unset)",
        os.environ.get("LOCATION", "us-central1"),
        get_active_model(),
        os.environ.get("GCS_LENS_BUCKET") or "(unset)",
        "set" if os.environ.get("SERPAPI_KEY") else "(unset)",
    )


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    logger.exception(
        "Unhandled error %s %s | %s: %s",
        request.method, request.url.path, type(exc).__name__, exc,
    )
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error", "error_code": "INTERNAL_ERROR"},
        headers=_CORS,
    )


@app.exception_handler(HTTPException)
async def _http(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail, "error_code": "REQUEST_ERROR"},
        headers=_CORS,
    )


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH", "HEAD"],
    allow_headers=["Content-Type", "Accept", "Authorization", "X-Requested-With", "Origin"],
)


# ---------------------------------------------------------------------------
# Shared models
# ---------------------------------------------------------------------------

class ConfigRequest(BaseModel):
    model: str = Field(..., description="Gemini model ID to activate (e.g. gemini-2.5-flash, gemini-2.5-pro)")


class MlKitLabel(BaseModel):
    text: str = Field(..., description="Label text returned by ML Kit on-device classifier")


class MlKitContext(BaseModel):
    route: str = Field(..., description="Routing decision: 'on_device_confident' or 'gemini_fallback'")
    trigger: str = Field(..., description="What triggered the request: 'tap' or 'auto'")
    on_device_confidence: float | None = Field(None, ge=0.0, le=1.0, description="ML Kit confidence score (0.0–1.0)")
    detected_objects_count: int | None = Field(None, ge=0, description="Number of objects detected on-device")
    detected_labels: list[MlKitLabel] = Field(default_factory=list, description="Top labels from ML Kit on-device detection")


class AnalyzeRequest(BaseModel):
    gcs_uri: str | None = Field(
        None,
        description="GCS URI of a video segment to analyze (e.g. gs://bucket/live/seg001.ts). Mutually exclusive with image_url/image_data.",
    )
    image_url: str | None = Field(
        None,
        description="Publicly accessible image URL. Mutually exclusive with gcs_uri/image_data.",
    )
    image_data: str | None = Field(
        None,
        description="Base64-encoded image bytes. Required for /identify. Mutually exclusive with gcs_uri/image_url.",
    )
    image_mime_type: str | None = Field(
        None,
        description="MIME type for image_data (e.g. image/jpeg, image/webp, image/png).",
    )
    transcript: str = Field("", description="Optional transcript text to supplement Gemini's visual analysis")
    ignore_terms: list[str] = Field(default_factory=list, description="Product names to exclude from matching results")
    query: str = Field("", description="Optional freetext query to bias Google Shopping search")
    country: str = Field("us", description="Two-letter ISO country code for regional product search")
    max_searches: int = Field(5, ge=1, le=20, description="Maximum number of SerpAPI searches to execute")
    mlkit_context: MlKitContext | None = Field(
        None,
        description="On-device ML Kit detection context forwarded from the mobile app. Used for log-based routing analysis only — does not affect Gemini behaviour.",
    )

    model_config = {"json_schema_extra": {
        "examples": [{
            "image_url": "https://example.com/product.jpg",
            "transcript": "",
            "ignore_terms": [],
            "query": "",
            "country": "us",
            "max_searches": 5,
        }]
    }}


class ProductItem(BaseModel):
    product_id: str
    name: str
    price: float | None
    image_url: str | None
    purchase_url: str | None
    seller: str | None
    category: str | None


class AnalyzeResponse(BaseModel):
    items: list[str] = Field(..., description="Detected product/item names from Gemini")
    products: list[ProductItem] = Field(..., description="Matched products from Google Shopping")
    warnings: list[str] = Field(..., description="Non-fatal warnings (e.g. items with no search results)")
    gcs_uri: str | None
    image_url: str | None


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get(
    "/config",
    tags=["Config"],
    summary="Get active Gemini model",
    response_description="Currently active model ID",
)
async def get_config() -> JSONResponse:
    return JSONResponse(content={"model": get_active_model()})


@app.post(
    "/config",
    tags=["Config"],
    summary="Set active Gemini model",
    response_description="Newly active model ID",
)
async def update_config(request: ConfigRequest) -> JSONResponse:
    set_active_model(request.model)
    logger.info("Model switched to: %s", request.model)
    return JSONResponse(content={"model": get_active_model()})


@app.post(
    "/analyze",
    tags=["Analysis"],
    summary="Analyze image or video segment",
    description=(
        "Runs Gemini on the provided image or GCS video segment to detect shoppable items, "
        "then searches Google Shopping for each detected item via SerpAPI.\n\n"
        "Provide exactly one of: `gcs_uri`, `image_url`, or `image_data`.\n\n"
        "Returns all results at once. For progressive streaming use `POST /analyze/stream`."
    ),
    responses={
        200: {"description": "Detection and matching succeeded"},
        400: {"description": "No media input provided"},
        500: {"description": "Gemini or SerpAPI error"},
    },
)
async def analyze(request: AnalyzeRequest) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    if not any([request.gcs_uri, request.image_url, request.image_data]):
        logger.warning("Rejecting /analyze: none of gcs_uri, image_url, image_data provided")
        return JSONResponse(
            content={"detail": "Provide gcs_uri, image_url, or image_data.", "error_code": "INVALID_REQUEST"},
            status_code=400,
            headers={"X-Request-Id": req_id},
        )

    if request.mlkit_context:
        ctx = request.mlkit_context
        logger.info(
            "MLKIT | route=%s trigger=%s confidence=%.2f objects=%d labels=%s",
            ctx.route,
            ctx.trigger,
            ctx.on_device_confidence or 0.0,
            ctx.detected_objects_count or 0,
            [l.text for l in ctx.detected_labels],
        )

    logger.info(
        "analyze start | gcs_uri=%s image_url=%s image_data_b64_len=%d "
        "ignore_terms=%d country=%s",
        request.gcs_uri,
        request.image_url,
        len(request.image_data) if request.image_data else 0,
        len(request.ignore_terms),
        request.country,
    )
    try:
        items, products, warnings = await asyncio.to_thread(
            analyze_media,
            gcs_video_uri=request.gcs_uri,
            image_url=request.image_url,
            image_data=request.image_data,
            image_mime_type=request.image_mime_type,
            transcript=request.transcript,
            ignore_terms=request.ignore_terms,
            country=request.country,
            max_searches=request.max_searches,
        )
    except Exception as exc:
        elapsed = time.monotonic() - start
        status_code, error_code = classify_exception(exc)
        logger.exception(
            "analyze FAILED after %.2fs | %s: %s | error_code=%s status=%d",
            elapsed, type(exc).__name__, exc, error_code, status_code,
        )
        return JSONResponse(
            content={"detail": str(exc), "error_code": error_code},
            status_code=status_code,
            headers={"X-Request-Id": req_id},
        )

    elapsed = time.monotonic() - start
    logger.info(
        "analyze done in %.2fs | items=%d products=%d warnings=%s", elapsed, len(items), len(products), warnings,
    )
    return JSONResponse(
        content={
            "items": items,
            "products": products,
            "warnings": warnings,
            "gcs_uri": request.gcs_uri,
            "image_url": request.image_url,
        },
        headers={"X-Request-Id": req_id},
    )


@app.post(
    "/analyze/stream",
    tags=["Analysis"],
    summary="Analyze image — streaming NDJSON",
    description=(
        "Same detection + matching pipeline as `POST /analyze`, but streams one NDJSON line "
        "per event as it completes rather than waiting for all items.\n\n"
        "**Event types** (each line is a JSON object):\n"
        "- `{\"type\": \"items\", \"items\": [...]}` — emitted once after Gemini detection\n"
        "- `{\"type\": \"match\", \"name\": \"...\", \"products\": [...], \"warnings\": [...]}` — once per item\n"
        "- `{\"type\": \"done\", \"warnings\": [...]}` — stream end\n"
        "- `{\"type\": \"error\", \"detail\": \"...\", \"error_code\": \"...\"}` — on failure\n\n"
        "**Does not support `gcs_uri`** — video segments have no per-item fan-out to stream. "
        "Provide `image_url` or `image_data`."
    ),
    responses={
        200: {"description": "NDJSON stream", "content": {"application/x-ndjson": {}}},
        400: {"description": "No image input provided"},
    },
)
async def analyze_stream(request: AnalyzeRequest) -> StreamingResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)

    if not request.image_url and not request.image_data:
        logger.warning("Rejecting /analyze/stream: neither image_url nor image_data provided")
        raise HTTPException(status_code=400, detail="Provide image_url or image_data.")

    if request.mlkit_context:
        ctx = request.mlkit_context
        logger.info(
            "MLKIT | route=%s trigger=%s confidence=%.2f objects=%d labels=%s",
            ctx.route,
            ctx.trigger,
            ctx.on_device_confidence or 0.0,
            ctx.detected_objects_count or 0,
            [l.text for l in ctx.detected_labels],
        )

    logger.info(
        "analyze/stream start | image_url=%s image_data_b64_len=%d ignore_terms=%d country=%s",
        request.image_url,
        len(request.image_data) if request.image_data else 0,
        len(request.ignore_terms),
        request.country,
    )

    loop = asyncio.get_event_loop()
    queue: asyncio.Queue = asyncio.Queue()
    _sentinel = object()

    def _produce() -> None:
        _request_id_ctx.set(req_id)
        try:
            for event in analyze_media_stream(
                image_url=request.image_url,
                image_data=request.image_data,
                image_mime_type=request.image_mime_type,
                ignore_terms=request.ignore_terms,
                country=request.country,
                max_searches=request.max_searches,
            ):
                asyncio.run_coroutine_threadsafe(queue.put(event), loop)
        except Exception as exc:
            status_code, error_code = classify_exception(exc)
            logger.exception(
                "analyze/stream producer FAILED | %s: %s | error_code=%s status=%d",
                type(exc).__name__, exc, error_code, status_code,
            )
            asyncio.run_coroutine_threadsafe(
                queue.put({"type": "error", "detail": str(exc), "error_code": error_code}), loop,
            )
        finally:
            asyncio.run_coroutine_threadsafe(queue.put(_sentinel), loop)

    threading.Thread(target=_produce, daemon=True).start()

    async def _event_stream():
        while True:
            event = await queue.get()
            if event is _sentinel:
                break
            yield json.dumps(event) + "\n"

    return StreamingResponse(
        _event_stream(),
        media_type="application/x-ndjson",
        headers={"X-Request-Id": req_id, **_CORS},
    )


@app.post(
    "/identify",
    tags=["Analysis"],
    summary="Identify a cropped product image",
    description=(
        "Skips Gemini bounding-box detection — the crop is already selected by ML Kit on-device. "
        "Still calls Gemini once to produce a rich text description (color, material, brand, style) "
        "that improves Google Lens recall, then uploads to GCS and runs Lens. "
        "Faster than /analyze because there is one Gemini call instead of N (one per detected object).\n\n"
        "Requires `image_data` (base64). `image_url` is not supported."
    ),
    responses={
        200: {"description": "Product identification succeeded"},
        400: {"description": "image_data not provided"},
    },
)
async def identify(request: AnalyzeRequest) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    if not request.image_data:
        logger.warning("Rejecting /identify: image_data not provided")
        return JSONResponse(
            content={"detail": "Provide image_data.", "error_code": "INVALID_REQUEST"},
            status_code=400,
            headers={"X-Request-Id": req_id},
        )

    if request.mlkit_context:
        ctx = request.mlkit_context
        logger.info(
            "MLKIT | route=%s trigger=%s confidence=%.2f objects=%d labels=%s",
            ctx.route,
            ctx.trigger,
            ctx.on_device_confidence or 0.0,
            ctx.detected_objects_count or 0,
            [l.text for l in ctx.detected_labels],
        )

    logger.info(
        "identify start | image_data_b64_len=%d query=%r country=%s",
        len(request.image_data), request.query, request.country,
    )
    try:
        products, warnings = await asyncio.to_thread(
            identify_crop,
            image_data=request.image_data,
            image_mime_type=request.image_mime_type,
            query=request.query,
            country=request.country,
        )
    except Exception as exc:
        elapsed = time.monotonic() - start
        status_code, error_code = classify_exception(exc)
        logger.exception(
            "identify FAILED after %.2fs | %s: %s | error_code=%s status=%d",
            elapsed, type(exc).__name__, exc, error_code, status_code,
        )
        return JSONResponse(
            content={"detail": str(exc), "error_code": error_code},
            status_code=status_code,
            headers={"X-Request-Id": req_id},
        )

    elapsed = time.monotonic() - start
    logger.info("identify done in %.2fs | products=%d warnings=%s", elapsed, len(products), warnings)
    try:
        return JSONResponse(content={"items": [], "products": products, "warnings": warnings}, headers={"X-Request-Id": req_id})
    except Exception as enc_err:
        logger.exception(
            "identify response serialization FAILED | %s: %s | products=%s",
            type(enc_err).__name__, enc_err, products,
        )
        return JSONResponse(
            content={"items": [], "products": [], "warnings": warnings},
            status_code=200,
            headers={"X-Request-Id": req_id},
        )


@app.get(
    "/health",
    tags=["System"],
    summary="Health check",
    response_description="Service liveness and env var presence",
)
async def health():
    import os
    return {
        "status": "ok",
        "gcs_lens_bucket_set": bool(os.environ.get("GCS_LENS_BUCKET")),
        "serpapi_key_set": bool(os.environ.get("SERPAPI_KEY")),
        "project_id_set": bool(os.environ.get("PROJECT_ID")),
    }


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
