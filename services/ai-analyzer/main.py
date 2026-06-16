import asyncio
import logging
import os
import time
import uuid
from contextvars import ContextVar

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from analyzer import analyze_media, classify_exception, identify_crop, get_active_model, set_active_model

# Per-request correlation id, propagated to every log line (including those
# emitted from analyzer.py and from threads spawned via asyncio.to_thread).
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

app = FastAPI(title="AI Stream Analyzer")

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


class ConfigRequest(BaseModel):
    model: str


@app.get("/config")
async def get_config() -> JSONResponse:
    return JSONResponse(content={"model": get_active_model()})


@app.post("/config")
async def update_config(request: ConfigRequest) -> JSONResponse:
    set_active_model(request.model)
    logger.info("Model switched to: %s", request.model)
    return JSONResponse(content={"model": get_active_model()})


class AnalyzeRequest(BaseModel):
    gcs_uri: str | None = None
    image_url: str | None = None
    image_data: str | None = None
    image_mime_type: str | None = None
    transcript: str = ""
    ignore_terms: list[str] = []
    query: str = ""
    country: str = "us"


@app.post("/analyze")
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
        # Run on a worker thread — analyze_media is fully synchronous (Vertex AI,
        # GCS, SerpAPI calls) and would otherwise block the entire event loop,
        # starving every other concurrent request on this instance.
        items, products, warnings = await asyncio.to_thread(
            analyze_media,
            gcs_video_uri=request.gcs_uri,
            image_url=request.image_url,
            image_data=request.image_data,
            image_mime_type=request.image_mime_type,
            transcript=request.transcript,
            ignore_terms=request.ignore_terms,
            country=request.country,
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


@app.post("/identify")
async def identify(request: AnalyzeRequest) -> JSONResponse:
    """Identify a manually cropped product image. Skips Gemini — sends the
    crop directly to GCS then Google Lens and returns the matched product."""
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


@app.get("/health")
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
