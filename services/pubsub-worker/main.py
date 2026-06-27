import base64
import json
import logging
import os
import time

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Pub/Sub Segment Worker",
    description=(
        "Internal Cloud Run service that processes GCS Pub/Sub push notifications for new HLS "
        "video segments from the live stream.\n\n"
        "**This service is not publicly accessible in production.** It is triggered exclusively "
        "by Google Cloud Pub/Sub push delivery from the `video-segments-sub` subscription.\n\n"
        "**Pipeline per segment:**\n"
        "1. Decode the Pub/Sub message to extract the GCS object path\n"
        "2. `POST ai-analyzer/analyze` — Gemini detects shoppable items in the video segment\n"
        "3. `POST product-matcher/match` — SerpAPI finds matching purchasable products\n"
        "4. `POST state-manager/session/{id}/products` — save results to the active session\n\n"
        "**Testing:** Use the `/pubsub` endpoint with a simulated Pub/Sub push body (base64-encoded GCS event)."
    ),
    version="1.0.0",
    openapi_tags=[
        {"name": "Pub/Sub", "description": "Pub/Sub push webhook — internal use only"},
        {"name": "System", "description": "Health and diagnostics"},
    ],
)

AI_ANALYZER_URL = os.environ.get("AI_ANALYZER_URL", "")
PRODUCT_MATCHER_URL = os.environ.get("PRODUCT_MATCHER_URL", "")
STATE_MANAGER_URL = os.environ.get("STATE_MANAGER_URL", "")
SESSION_ID = os.environ.get("SESSION_ID", "live-session-001")

AI_ANALYZER_TIMEOUT = float(os.environ.get("AI_ANALYZER_TIMEOUT_SECONDS", "120"))

_HLS_EXTENSIONS = {".m3u8", ".ts"}


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class PubSubAttributes(BaseModel):
    eventType: str | None = Field(None, description="GCS event type (e.g. OBJECT_FINALIZE)")
    bucketId: str | None = Field(None, description="GCS bucket name from notification attributes")
    objectId: str | None = Field(None, description="GCS object path from notification attributes")


class PubSubMessage(BaseModel):
    data: str = Field(..., description="Base64-encoded GCS storage event JSON")
    messageId: str | None = Field(None, description="Pub/Sub message ID")
    publishTime: str | None = Field(None, description="ISO 8601 publish timestamp")
    attributes: dict = Field(default_factory=dict, description="GCS notification attributes")


class PubSubPushBody(BaseModel):
    message: PubSubMessage
    subscription: str = Field(..., description="Full Pub/Sub subscription name")

    model_config = {"json_schema_extra": {
        "examples": [{
            "message": {
                "data": "eyJidWNrZXQiOiAic2hvcGxlbnMtZGV2LWhscy1zZWdtZW50cyIsICJuYW1lIjogImxpdmUvc2VnbWVudDAwMS50cyJ9",
                "messageId": "test-001",
                "publishTime": "2026-01-01T00:00:00Z",
                "attributes": {"eventType": "OBJECT_FINALIZE", "objectId": "live/segment001.ts"},
            },
            "subscription": "projects/shoplens-dev-499700/subscriptions/video-segments-sub",
        }]
    }}


class PubSubResponse(BaseModel):
    status: str = Field(..., description="'pipeline_complete' | 'skipped' | 'no_items_detected' | 'no_products_matched'")
    segment_url: str | None = None
    items_detected: int | None = None
    products_matched: int | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _decode_pubsub_message(body: dict) -> dict:
    message = body.get("message", {})
    data_b64 = message.get("data", "")
    if not data_b64:
        raise ValueError("Pub/Sub message contains no data field")
    decoded = base64.b64decode(data_b64).decode("utf-8")
    return json.loads(decoded)


def _extract_segment_url(event: dict, attributes: dict) -> str:
    bucket = event.get("bucket") or attributes.get("bucketId", "")
    name = event.get("name") or attributes.get("objectId", "")
    if not bucket or not name:
        raise ValueError(f"Cannot determine GCS object from event={event} attributes={attributes}")
    return f"gs://{bucket}/{name}"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post(
    "/pubsub",
    tags=["Pub/Sub"],
    summary="Pub/Sub push webhook",
    description=(
        "Receives a Pub/Sub push message from the `video-segments-sub` subscription. "
        "Decodes the base64 GCS event, extracts the segment URI, and runs the full "
        "analyze → match → save pipeline.\n\n"
        "Non-HLS files (not `.ts` or `.m3u8`) are skipped immediately with `status: skipped`."
    ),
    responses={
        200: {"description": "Pipeline result or skip reason"},
        400: {"description": "Malformed Pub/Sub message"},
        502: {"description": "Upstream service (ai-analyzer or product-matcher) failed"},
    },
)
async def pubsub_webhook(request: Request) -> JSONResponse:
    body = await request.json()

    message = body.get("message", {})
    attributes = message.get("attributes", {})

    try:
        event = _decode_pubsub_message(body)
    except (ValueError, json.JSONDecodeError) as exc:
        logger.error("Failed to decode Pub/Sub message: %s", exc)
        raise HTTPException(status_code=400, detail=str(exc))

    try:
        segment_url = _extract_segment_url(event, attributes)
    except ValueError as exc:
        logger.error("Segment URL extraction failed: %s", exc)
        raise HTTPException(status_code=400, detail=str(exc))

    object_name = event.get("name") or attributes.get("objectId", "")
    ext = os.path.splitext(object_name)[1].lower()
    if ext not in _HLS_EXTENSIONS:
        logger.info("Skipping non-HLS file: %s (extension=%r)", segment_url, ext)
        return JSONResponse(content={"status": "skipped"})

    logger.info("New video segment ready: %s", segment_url)

    async with httpx.AsyncClient(timeout=30.0) as client:
        ai_start = time.monotonic()
        try:
            ai_response = await client.post(
                f"{AI_ANALYZER_URL}/analyze",
                json={"gcs_uri": segment_url, "transcript": ""},
                timeout=AI_ANALYZER_TIMEOUT,
            )
            ai_response.raise_for_status()
        except Exception as exc:
            logger.error(
                "ai-analyzer call failed after %.2fs (%s): %s",
                time.monotonic() - ai_start, type(exc).__name__, exc,
            )
            raise HTTPException(status_code=502, detail=f"ai-analyzer request failed: {exc}")

        items = ai_response.json().get("items", [])
        logger.info(
            "ai-analyzer responded in %.2fs with %d item(s): %s",
            time.monotonic() - ai_start, len(items), items,
        )

        if not items:
            logger.warning("No items detected for segment: %s", segment_url)
            return JSONResponse(content={"status": "no_items_detected"})

        try:
            match_response = await client.post(
                f"{PRODUCT_MATCHER_URL}/match",
                json={"items": items},
            )
            match_response.raise_for_status()
        except Exception as exc:
            logger.error("product-matcher call failed: %s", exc)
            raise HTTPException(status_code=502, detail=f"product-matcher request failed: {exc}")

        matched_products = match_response.json().get("matched_products", [])
        logger.info("product-matcher returned %d matched product(s)", len(matched_products))

        if not matched_products:
            logger.warning("No products matched for segment: %s", segment_url)
            return JSONResponse(content={"status": "no_products_matched"})

        try:
            state_response = await client.post(
                f"{STATE_MANAGER_URL}/session/{SESSION_ID}/products",
                json={"products": matched_products},
            )
            state_response.raise_for_status()
        except Exception as exc:
            logger.error("state-manager call failed: %s", exc)
            raise HTTPException(status_code=502, detail=f"state-manager request failed: {exc}")

    return JSONResponse(content={
        "segment_url": segment_url,
        "items_detected": len(items),
        "products_matched": len(matched_products),
        "status": "pipeline_complete",
    })


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
