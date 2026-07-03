#!/usr/bin/env python3
"""
Generate rich, example-filled OpenAPI 3.0 specs + a Swagger UI viewer for
docs/postman/apiSpecs/.

Usage (from repo root):
    python docs/postman/generate_api_specs_detailed.py
    python docs/postman/generate_api_specs_detailed.py --service ai-analyzer

Unlike docs/postman/generate_openapi_specs.py (raw FastAPI introspection,
used for docs/api-specs/), this script starts from that same raw output and
enriches it:
  - Response schemas + realistic examples for every documented status code.
    FastAPI can only auto-generate a response schema from a `response_model=`
    argument; none of these services declare one (they return `JSONResponse`
    directly), so every 200/400/401/403/404/500/502 body here is added by
    hand from the actual code path that constructs it — not guessed.
  - Named request-body examples (one per real use case: image URL vs base64
    vs GCS video URI, etc).
  - A `servers` block per environment (cookshop-dev-rajan-prod, shoplens-dev,
    local) — FastAPI's default openapi() omits this entirely.
  - A `firebaseAuth` security scheme applied to Voice Assistant's three
    protected routes (auth is checked manually in code via a header read,
    not through FastAPI's Security/Depends system, so FastAPI has no way to
    know about it on its own).

Run this after changing any service's routes, Pydantic models, or response
shapes — see docs/postman/apiSpecs/README.md and the /update-api-specs skill.
Requires each service's own requirements.txt deps installed (fastapi,
pydantic, etc.) but NOT real GCP credentials — see generate_local() in
generate_openapi_specs.py for why.
"""
import argparse
import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from generate_openapi_specs import CLOUD_RUN_URLS, LOCAL_PORTS, SERVICES, generate_local  # noqa: E402

OUT_DIR = Path(__file__).parent / "apiSpecs"


def servers_for(service: str) -> list:
    pubsub_note = (
        " (requires an authenticated Cloud Run invoker — not publicly callable)"
        if service == "pubsub-worker" else ""
    )
    return [
        {"url": CLOUD_RUN_URLS["cookshop-dev"][service], "description": "cookshop-dev-rajan-prod (live, public)"},
        {"url": CLOUD_RUN_URLS["shoplens-dev"][service], "description": f"shoplens-dev{pubsub_note}"},
        {"url": f"http://localhost:{LOCAL_PORTS[service]}", "description": "local (uvicorn main:app)"},
    ]


# ---------------------------------------------------------------------------
# Shared error-shape schemas.
#
# state-manager and product-matcher's exception handlers return {"detail": ...}
# only. ai-analyzer and voice-assistant additionally wrap a machine-readable
# `error_code`. pubsub-worker declares no custom exception handler, so its
# errors fall through to FastAPI's default HTTPException shape — same as
# ErrorDetail.
# ---------------------------------------------------------------------------

ERROR_DETAIL = {
    "type": "object",
    "properties": {"detail": {"type": "string", "description": "Human-readable error message"}},
    "required": ["detail"],
}

ERROR_DETAIL_WITH_CODE = {
    "type": "object",
    "properties": {
        "detail": {"type": "string", "description": "Human-readable error message"},
        "error_code": {
            "type": "string",
            "description": "Machine-readable error classification — see analyzer.classify_exception()",
            "enum": ["INVALID_REQUEST", "UPSTREAM_ERROR", "INTERNAL_ERROR", "REQUEST_ERROR"],
        },
    },
    "required": ["detail", "error_code"],
}


def _resp(description: str, schema: dict = None, example: dict = None, content_type: str = "application/json") -> dict:
    r = {"description": description}
    if schema is not None:
        content = {"schema": schema}
        if example is not None:
            content["example"] = example
        r["content"] = {content_type: content}
    return r


def _req_examples(examples: dict) -> dict:
    """examples: {key: (summary, value)}"""
    return {k: {"summary": summary, "value": value} for k, (summary, value) in examples.items()}


# ===========================================================================
# ai-analyzer
# ===========================================================================

def enrich_ai_analyzer(spec: dict) -> dict:
    schemas = spec["components"]["schemas"]

    schemas["ProductItem"] = {
        "type": "object",
        "description": "A matched, purchasable product returned by Google Shopping search.",
        "properties": {
            "product_id": {"type": "string", "description": "Stable slug+hash id derived from seller+name", "example": "walmart-beautiful-3-5-qt-ecca45"},
            "name": {"type": "string", "example": "Beautiful 3.5 Qt Stand Mixer"},
            "price": {"type": "number", "nullable": True, "description": "Price in USD", "example": 64.96},
            "image_url": {"type": "string", "nullable": True, "description": "Google CDN thumbnail — proxy through product-matcher's GET /thumbnail for CORS", "example": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-"},
            "purchase_url": {"type": "string", "nullable": True, "example": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123"},
            "seller": {"type": "string", "nullable": True, "example": "Walmart"},
            "category": {"type": "string", "nullable": True, "description": "Inferred from name/seller keywords — see matcher._infer_category", "example": "Kitchen & Cookware"},
        },
        "required": ["product_id", "name", "price", "image_url", "purchase_url", "seller", "category"],
    }
    schemas["AnalyzeResponse"] = {
        "type": "object",
        "properties": {
            "items": {"type": "array", "items": {"type": "string"}, "description": "Detected product/item names from Gemini"},
            "products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}},
            "warnings": {"type": "array", "items": {"type": "string"}, "description": "Non-fatal warnings, e.g. items with no search results"},
            "gcs_uri": {"type": "string", "nullable": True, "description": "Echoes the request's gcs_uri, if provided"},
            "image_url": {"type": "string", "nullable": True, "description": "Echoes the request's image_url, if provided"},
        },
        "required": ["items", "products", "warnings", "gcs_uri", "image_url"],
    }
    schemas["IdentifyResponse"] = {
        "type": "object",
        "properties": {
            "items": {"type": "array", "items": {"type": "string"}, "description": "Always empty for /identify — detection is skipped, the crop is already selected"},
            "products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}},
            "warnings": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["items", "products", "warnings"],
    }
    schemas["ErrorDetail"] = ERROR_DETAIL_WITH_CODE
    schemas["ConfigResponse"] = {
        "type": "object",
        "properties": {"model": {"type": "string", "example": "gemini-2.5-pro"}},
        "required": ["model"],
    }
    schemas["HealthResponse"] = {
        "type": "object",
        "properties": {
            "status": {"type": "string", "example": "ok"},
            "gcs_lens_bucket_set": {"type": "boolean"},
            "serpapi_key_set": {"type": "boolean"},
            "project_id_set": {"type": "boolean"},
        },
        "required": ["status", "gcs_lens_bucket_set", "serpapi_key_set", "project_id_set"],
    }

    p = spec["paths"]

    p["/config"]["get"]["responses"]["200"] = _resp(
        "Currently active model ID", {"$ref": "#/components/schemas/ConfigResponse"}, {"model": "gemini-2.5-pro"},
    )

    p["/config"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "switch_to_flash": ("Switch to Gemini 2.5 Flash", {"model": "gemini-2.5-flash"}),
        "switch_to_pro": ("Switch to Gemini 2.5 Pro (default)", {"model": "gemini-2.5-pro"}),
    })
    p["/config"]["post"]["responses"]["200"] = _resp(
        "Newly active model ID", {"$ref": "#/components/schemas/ConfigResponse"}, {"model": "gemini-2.5-flash"},
    )

    p["/analyze"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "image_url": ("Analyze a public image URL", {
            "image_url": "https://picsum.photos/id/1080/640/480.jpg",
            "transcript": "", "ignore_terms": [], "query": "", "country": "us", "max_searches": 5,
        }),
        "image_data_base64": ("Analyze a base64-encoded image", {
            "image_data": "<base64-encoded JPEG/PNG/WebP bytes>", "image_mime_type": "image/jpeg",
            "transcript": "", "ignore_terms": [], "query": "", "country": "us", "max_searches": 5,
        }),
        "gcs_video_uri": ("Analyze a live-stream HLS segment (called by Pub/Sub Worker)", {
            "gcs_uri": "gs://shoplens2026-dev-hls-segments/live/segment001.ts",
            "transcript": "And here you can see the stand mixer being used to knead the dough",
            "ignore_terms": [], "query": "", "country": "us", "max_searches": 5,
        }),
        "with_mlkit_context": ("Analyze with on-device ML Kit context forwarded for log-based routing analysis", {
            "image_url": "https://picsum.photos/id/1080/640/480.jpg",
            "transcript": "", "ignore_terms": [], "query": "", "country": "us", "max_searches": 5,
            "mlkit_context": {
                "route": "gemini_fallback", "trigger": "auto", "on_device_confidence": 0.41,
                "detected_objects_count": 2, "detected_labels": [{"text": "Furniture"}, {"text": "Chair"}],
            },
        }),
    })
    p["/analyze"]["post"]["responses"].update({
        "200": _resp("Detection and matching succeeded", {"$ref": "#/components/schemas/AnalyzeResponse"}, {
            "items": ["stand mixer"],
            "products": [{
                "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
                "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "seller": "Walmart", "category": "Kitchen & Cookware",
            }],
            "warnings": [], "gcs_uri": None, "image_url": "https://picsum.photos/id/1080/640/480.jpg",
        }),
        "400": _resp("No media input provided", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Provide gcs_uri, image_url, or image_data.", "error_code": "INVALID_REQUEST"}),
        "500": _resp("Gemini or SerpAPI error", {"$ref": "#/components/schemas/ErrorDetail"}, {
            "detail": "403 PERMISSION_DENIED. {'error': {'code': 403, 'message': \"Unable to open file: gs://bucket/segment.ts, mode=Read_Mode, status=PERMISSION_DENIED: ...\", 'status': 'PERMISSION_DENIED'}}",
            "error_code": "INTERNAL_ERROR",
        }),
        "502": _resp("Upstream Gemini/GCS/SerpAPI call timed out or failed at the network layer", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Connection timed out while contacting Vertex AI", "error_code": "UPSTREAM_ERROR"}),
    })

    p["/analyze/stream"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "image_url": ("Stream analysis of a public image URL", {
            "image_url": "https://picsum.photos/id/1080/640/480.jpg",
            "transcript": "", "ignore_terms": [], "query": "", "country": "us", "max_searches": 5,
        }),
    })
    p["/analyze/stream"]["post"]["responses"].update({
        "200": _resp(
            "NDJSON stream — one JSON object per line. `type` is one of `items`, `match`, `done`, `error`.",
            {
                "type": "object",
                "description": "One of 4 shapes depending on `type`",
                "oneOf": [
                    {"type": "object", "properties": {"type": {"const": "items"}, "items": {"type": "array", "items": {"type": "string"}}}, "required": ["type", "items"]},
                    {"type": "object", "properties": {"type": {"const": "match"}, "name": {"type": "string"}, "products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}}, "warnings": {"type": "array", "items": {"type": "string"}}}, "required": ["type", "name", "products", "warnings"]},
                    {"type": "object", "properties": {"type": {"const": "done"}, "warnings": {"type": "array", "items": {"type": "string"}}}, "required": ["type", "warnings"]},
                    {"type": "object", "properties": {"type": {"const": "error"}, "detail": {"type": "string"}, "error_code": {"type": "string"}}, "required": ["type", "detail", "error_code"]},
                ],
            },
            {"type": "match", "name": "stand mixer", "products": [{
                "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
                "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "seller": "Walmart", "category": "Kitchen & Cookware",
            }], "warnings": []},
            content_type="application/x-ndjson",
        ),
        "400": _resp("Neither image_url nor image_data provided (gcs_uri is not supported here)",
                      {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Provide image_url or image_data.", "error_code": "REQUEST_ERROR"}),
    })

    p["/identify"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "cropped_image_with_mlkit_context": ("Identify an ML-Kit-cropped product image", {
            "image_data": "<base64-encoded JPEG bytes of the on-device crop>", "image_mime_type": "image/jpeg",
            "query": "", "ignore_terms": [], "country": "us", "max_searches": 5,
            "mlkit_context": {
                "route": "on_device_confident", "trigger": "tap", "on_device_confidence": 0.92,
                "detected_objects_count": 1, "detected_labels": [{"text": "Kitchen Appliance"}],
            },
        }),
    })
    p["/identify"]["post"]["responses"].update({
        "200": _resp("Product identification succeeded", {"$ref": "#/components/schemas/IdentifyResponse"}, {
            "items": [], "products": [{
                "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
                "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "seller": "Walmart", "category": "Kitchen & Cookware",
            }], "warnings": [],
        }),
        "400": _resp("image_data not provided — /identify does not accept image_url", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Provide image_data.", "error_code": "INVALID_REQUEST"}),
    })

    p["/health"]["get"]["responses"]["200"] = _resp(
        "Service liveness and env var presence", {"$ref": "#/components/schemas/HealthResponse"},
        {"status": "ok", "gcs_lens_bucket_set": True, "serpapi_key_set": True, "project_id_set": True},
    )

    for path in ("/analyze", "/analyze/stream", "/identify", "/config"):
        for method in p.get(path, {}):
            if "422" in p[path][method].get("responses", {}):
                p[path][method]["responses"]["422"]["description"] = "Request body failed Pydantic validation (e.g. wrong type, missing required field)"

    return spec


# ===========================================================================
# product-matcher
# ===========================================================================

def enrich_product_matcher(spec: dict) -> dict:
    schemas = spec["components"]["schemas"]

    schemas["ProductItem"] = {
        "type": "object",
        "properties": {
            "product_id": {"type": "string", "example": "walmart-beautiful-3-5-qt-ecca45"},
            "name": {"type": "string", "example": "Beautiful 3.5 Qt Stand Mixer"},
            "price": {"type": "number", "nullable": True, "description": "Price in USD", "example": 64.96},
            "image_url": {"type": "string", "nullable": True, "example": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-"},
            "purchase_url": {"type": "string", "nullable": True, "example": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123"},
            "seller": {"type": "string", "nullable": True, "example": "Walmart"},
            "category": {"type": "string", "nullable": True, "example": "Kitchen & Cookware"},
        },
        "required": ["product_id", "name", "image_url", "purchase_url", "seller", "category"],
    }
    schemas["MatchResponse"] = {
        "type": "object",
        "properties": {
            "matched_products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}},
            "unmatched": {"type": "array", "items": {"type": "string"}, "description": "Item names for which SerpAPI returned no results"},
        },
        "required": ["matched_products", "unmatched"],
    }
    schemas["SearchResponse"] = {
        "type": "object",
        "properties": {"products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}}},
        "required": ["products"],
    }
    schemas["DebugResponse"] = {
        "type": "object",
        "properties": {
            "item": {"type": "string"},
            "result": {"anyOf": [{"$ref": "#/components/schemas/ProductItem"}, {"type": "null"}], "description": "null if SerpAPI returned no shopping results for this item"},
        },
        "required": ["item", "result"],
    }
    schemas["DebugRawResponse"] = {
        "type": "object",
        "description": "Unmodified passthrough of SerpAPI's first google_shopping shopping_results entry — shape depends entirely on what SerpAPI currently returns.",
        "properties": {
            "keys": {"type": "array", "items": {"type": "string"}, "description": "All top-level keys present in SerpAPI's raw result"},
            "first_result": {"type": "object", "additionalProperties": True, "description": "Common keys: position, title, link, product_link, product_id, source, price, extracted_price, rating, reviews, thumbnail, delivery"},
        },
        "required": ["keys", "first_result"],
    }
    schemas["ErrorDetail"] = ERROR_DETAIL
    schemas["HealthResponse"] = {
        "type": "object",
        "properties": {"status": {"type": "string", "enum": ["ok"]}},
        "required": ["status"],
    }
    schemas["DegradedHealthResponse"] = {
        "type": "object",
        "properties": {
            "status": {"type": "string", "enum": ["degraded"]},
            "missing_env": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["status", "missing_env"],
    }

    p = spec["paths"]

    p["/match"]["post"]["responses"].update({
        "200": _resp("Matching complete — check `unmatched` for items with no results", {"$ref": "#/components/schemas/MatchResponse"}, {
            "matched_products": [{
                "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
                "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "seller": "Walmart", "category": "Kitchen & Cookware",
            }],
            "unmatched": [],
        }),
        "500": _resp("SerpAPI error", {"$ref": "#/components/schemas/ErrorDetail"}, {"detail": "Internal server error"}),
    })

    p["/search"]["post"]["responses"]["200"] = _resp(
        "Up to max_results products for the query", {"$ref": "#/components/schemas/SearchResponse"}, {
            "products": [{
                "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
                "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "seller": "Walmart", "category": "Kitchen & Cookware",
            }],
        },
    )

    p["/thumbnail"]["get"]["responses"].update({
        "200": _resp("Image bytes with CORS header — Content-Type mirrors the upstream CDN response (e.g. image/jpeg)", content_type="image/*"),
        "502": {"description": "Failed to fetch from upstream CDN, or the URL's host isn't on the allowed thumbnail-CDN list — empty body"},
    })

    p["/debug/{item}"]["get"]["responses"]["200"] = _resp(
        "Single-item debug lookup", {"$ref": "#/components/schemas/DebugResponse"},
        {"item": "stand mixer", "result": {
            "product_id": "walmart-beautiful-3-5-qt-ecca45", "name": "Beautiful 3.5 Qt Stand Mixer",
            "price": 64.96, "image_url": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
            "purchase_url": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
            "seller": "Walmart", "category": "Kitchen & Cookware",
        }},
    )

    p["/debug-raw/{item}"]["get"]["responses"]["200"] = _resp(
        "Raw SerpAPI shopping_results[0], unmodified", {"$ref": "#/components/schemas/DebugRawResponse"},
        {
            "keys": ["position", "title", "product_link", "product_id", "source", "price", "extracted_price", "thumbnail", "rating", "reviews"],
            "first_result": {
                "position": 1, "title": "Beautiful 3.5 Qt Stand Mixer", "source": "Walmart",
                "price": "$64.96", "extracted_price": 64.96,
                "product_link": "https://www.walmart.com/ip/Beautiful-3-5-Qt-Stand-Mixer/expr123",
                "thumbnail": "https://encrypted-tbn1.gstatic.com/shopping?q=tbn:ANd9GcSqMqBie2aAONKedRN2VEXA1q2-",
                "rating": 4.6, "reviews": 812,
            },
        },
    )

    p["/health"]["get"]["responses"].update({
        "200": _resp("Service healthy", {"$ref": "#/components/schemas/HealthResponse"}, {"status": "ok"}),
        "503": _resp("Missing required environment variable", {"$ref": "#/components/schemas/DegradedHealthResponse"},
                      {"status": "degraded", "missing_env": ["SERPAPI_KEY"]}),
    })

    for path, method in (("/match", "post"), ("/search", "post")):
        if "422" in p[path][method].get("responses", {}):
            p[path][method]["responses"]["422"]["description"] = "Request body failed Pydantic validation"

    return spec


# ===========================================================================
# state-manager
# ===========================================================================

def enrich_state_manager(spec: dict) -> dict:
    schemas = spec["components"]["schemas"]

    schemas["SessionData"] = {
        "type": "object",
        "description": "Raw Firestore document body for LiveShoppingSessions/{session_id}",
        "properties": {
            "products": {"type": "array", "items": {"$ref": "#/components/schemas/ProductItem"}},
            "last_updated": {
                "type": "object", "nullable": True,
                "description": "Firestore server timestamp, converted to epoch seconds/nanoseconds",
                "properties": {"seconds": {"type": "integer"}, "nanoseconds": {"type": "integer"}},
            },
        },
        "required": ["products"],
    }
    schemas["UpdateResponse"] = {
        "type": "object",
        "properties": {"status": {"type": "string", "enum": ["updated"]}, "session_id": {"type": "string"}},
        "required": ["status", "session_id"],
    }
    schemas["ClearResponse"] = {
        "type": "object",
        "properties": {"status": {"type": "string", "enum": ["cleared"]}, "session_id": {"type": "string"}},
        "required": ["status", "session_id"],
    }
    schemas["ErrorDetail"] = ERROR_DETAIL
    schemas["HealthResponse"] = {"type": "object", "properties": {"status": {"type": "string", "enum": ["ok"]}}, "required": ["status"]}

    p = spec["paths"]

    p["/session/{session_id}/products"]["post"]["responses"]["200"] = _resp(
        "Session updated", {"$ref": "#/components/schemas/UpdateResponse"},
        {"status": "updated", "session_id": "live-session-001"},
    )

    p["/session/{session_id}"]["get"]["responses"].update({
        "200": _resp("Session data", {"$ref": "#/components/schemas/SessionData"}, {
            "products": [{
                "product_id": "abc123", "name": "KitchenAid Stand Mixer", "price": 449.99,
                "image_url": "https://example.com/mixer.jpg", "purchase_url": "https://example.com/buy/mixer",
                "seller": "Best Buy", "category": "Kitchen Appliances",
            }],
            "last_updated": {"seconds": 1751500000, "nanoseconds": 123000000},
        }),
        "404": _resp("Session not found", {"$ref": "#/components/schemas/ErrorDetail"}, {"detail": "Session 'live-session-999' not found"}),
    })

    p["/session/{session_id}"]["delete"]["responses"]["200"] = _resp(
        "Session cleared", {"$ref": "#/components/schemas/ClearResponse"},
        {"status": "cleared", "session_id": "live-session-001"},
    )

    p["/health"]["get"]["responses"]["200"] = _resp("Healthy", {"$ref": "#/components/schemas/HealthResponse"}, {"status": "ok"})

    if "422" in p["/session/{session_id}/products"]["post"].get("responses", {}):
        p["/session/{session_id}/products"]["post"]["responses"]["422"]["description"] = "Request body failed Pydantic validation"

    return spec


# ===========================================================================
# voice-assistant
# ===========================================================================

FIREBASE_SECURITY_SCHEME = {
    "type": "http",
    "scheme": "bearer",
    "bearerFormat": "Firebase ID Token",
    "description": (
        "Firebase ID token obtained client-side via `user.getIdToken()` (Firebase Auth SDK). "
        "Sent as `Authorization: Bearer <token>`. Verified manually in code "
        "(profile_store.verify_id_token) rather than via FastAPI's Security/Depends system."
    ),
}


def enrich_voice_assistant(spec: dict) -> dict:
    schemas = spec["components"]["schemas"]

    schemas["UserProfile"] = {
        "type": "object",
        "properties": {
            "shopping_categories": {"type": "array", "items": {"type": "string"}},
            "preference_terms": {"type": "array", "items": {"type": "string"}},
            "ignore_terms": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["shopping_categories", "preference_terms", "ignore_terms"],
    }
    schemas["SessionStartResponse"] = {
        "type": "object",
        "properties": {
            "session_id": {"type": "string", "description": "Use for the WebSocket URL and the finalize call", "example": "a1b2c3d4"},
            "ws_url": {"type": "string", "description": "Relative WebSocket path", "example": "/voice/session/a1b2c3d4/stream"},
            "profile": {"$ref": "#/components/schemas/UserProfile"},
        },
        "required": ["session_id", "ws_url", "profile"],
    }
    schemas["SessionEventResponse"] = {
        "type": "object", "properties": {"status": {"type": "string", "enum": ["received"]}}, "required": ["status"],
    }
    schemas["SessionFinalizeResponse"] = {
        "type": "object",
        "description": "The normalized, saved preference set. `conflicts` lists any term present in both preference_terms and ignore_terms after merging — surface these to the user rather than silently resolving them.",
        "properties": {
            "shopping_categories": {"type": "array", "items": {"type": "string"}},
            "preference_terms": {"type": "array", "items": {"type": "string"}},
            "ignore_terms": {"type": "array", "items": {"type": "string"}},
            "conflicts": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["shopping_categories", "preference_terms", "ignore_terms", "conflicts"],
    }
    schemas["ErrorDetail"] = ERROR_DETAIL_WITH_CODE
    schemas["HealthResponse"] = {
        "type": "object",
        "properties": {
            "status": {"type": "string", "enum": ["ok"]},
            "project_id_set": {"type": "boolean"},
            "voice_model": {"type": "string", "example": "gemini-live-2.5-flash"},
        },
        "required": ["status", "project_id_set", "voice_model"],
    }

    spec.setdefault("components", {}).setdefault("securitySchemes", {})["firebaseAuth"] = FIREBASE_SECURITY_SCHEME

    p = spec["paths"]

    p["/voice/session/start"]["post"]["security"] = [{"firebaseAuth": []}]
    p["/voice/session/start"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "preferences_onboarding": ("First-run preferences onboarding", {"mode": "preferences", "language": "English"}),
        "search_mode": ("Voice-driven product search within an active session", {"mode": "search", "language": "Spanish"}),
    })
    p["/voice/session/start"]["post"]["responses"].update({
        "200": _resp("Session created", {"$ref": "#/components/schemas/SessionStartResponse"}, {
            "session_id": "a1b2c3d4",
            "ws_url": "/voice/session/a1b2c3d4/stream",
            "profile": {"shopping_categories": ["Kitchen & Cookware"], "preference_terms": ["organic"], "ignore_terms": ["plastic"]},
        }),
        "401": _resp("Missing or invalid Firebase ID token", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Missing or malformed Authorization header", "error_code": "REQUEST_ERROR"}),
    })

    p["/voice/session/event"]["post"]["security"] = [{"firebaseAuth": []}]
    p["/voice/session/event"]["post"]["requestBody"]["content"]["application/json"]["examples"] = _req_examples({
        "ui_action": ("Notify the session of a UI action", {
            "session_id": "a1b2c3d4", "event_type": "ui_action", "payload": {"action": "opened_review_screen"},
        }),
    })
    p["/voice/session/event"]["post"]["responses"].update({
        "200": _resp("Event received", {"$ref": "#/components/schemas/SessionEventResponse"}, {"status": "received"}),
        "401": _resp("Missing or invalid Firebase ID token", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Missing or malformed Authorization header", "error_code": "REQUEST_ERROR"}),
    })

    p["/voice/session/finalize"]["post"]["security"] = [{"firebaseAuth": []}]
    p["/voice/session/finalize"]["post"]["responses"].update({
        "200": _resp("Preferences saved and session closed", {"$ref": "#/components/schemas/SessionFinalizeResponse"}, {
            "shopping_categories": ["Kitchen & Cookware"],
            "preference_terms": ["organic", "non-stick"],
            "ignore_terms": ["plastic"],
            "conflicts": [],
        }),
        "401": _resp("Missing or invalid Firebase ID token", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Missing or malformed Authorization header", "error_code": "REQUEST_ERROR"}),
        "500": _resp("Firestore write failed", {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "504 Deadline Exceeded", "error_code": "INTERNAL_ERROR"}),
    })

    p["/health"]["get"]["responses"]["200"] = _resp(
        "Service liveness and active Gemini Live model", {"$ref": "#/components/schemas/HealthResponse"},
        {"status": "ok", "project_id_set": True, "voice_model": "gemini-live-2.5-flash"},
    )

    for path in ("/voice/session/start", "/voice/session/event", "/voice/session/finalize"):
        if "422" in p[path]["post"].get("responses", {}):
            p[path]["post"]["responses"]["422"]["description"] = "Request body failed Pydantic validation"

    return spec


# ===========================================================================
# pubsub-worker
# ===========================================================================

def enrich_pubsub_worker(spec: dict) -> dict:
    spec.setdefault("components", {}).setdefault("schemas", {})
    schemas = spec["components"]["schemas"]

    schemas["PubSubMessage"] = {
        "type": "object",
        "properties": {
            "data": {"type": "string", "description": "Base64-encoded GCS storage event JSON, e.g. {\"bucket\": \"...\", \"name\": \"live/segment001.ts\"}"},
            "messageId": {"type": "string", "nullable": True},
            "publishTime": {"type": "string", "nullable": True, "format": "date-time"},
            "attributes": {
                "type": "object",
                "description": "GCS notification attributes",
                "properties": {
                    "eventType": {"type": "string", "example": "OBJECT_FINALIZE"},
                    "bucketId": {"type": "string"},
                    "objectId": {"type": "string"},
                },
            },
        },
        "required": ["data"],
    }
    schemas["PubSubPushBody"] = {
        "type": "object",
        "description": "Standard Google Cloud Pub/Sub push subscription payload shape",
        "properties": {
            "message": {"$ref": "#/components/schemas/PubSubMessage"},
            "subscription": {"type": "string", "description": "Full Pub/Sub subscription resource name"},
        },
        "required": ["message", "subscription"],
    }
    schemas["PubSubResponse"] = {
        "type": "object",
        "properties": {
            "status": {"type": "string", "enum": ["pipeline_complete", "skipped", "no_items_detected", "no_products_matched"]},
            "segment_url": {"type": "string", "nullable": True},
            "items_detected": {"type": "integer", "nullable": True},
            "products_matched": {"type": "integer", "nullable": True},
        },
        "required": ["status"],
    }
    schemas["ErrorDetail"] = ERROR_DETAIL
    schemas["HealthResponse"] = {"type": "object", "properties": {"status": {"type": "string", "enum": ["ok"]}}, "required": ["status"]}

    p = spec["paths"]
    op = p["/pubsub"]["post"]
    op["requestBody"] = {
        "required": True,
        "content": {
            "application/json": {
                "schema": {"$ref": "#/components/schemas/PubSubPushBody"},
                "examples": _req_examples({
                    "hls_segment_finalized": ("New HLS segment written to GCS", {
                        "message": {
                            "data": "eyJidWNrZXQiOiAic2hvcGxlbnMtZGV2LWhscy1zZWdtZW50cyIsICJuYW1lIjogImxpdmUvc2VnbWVudDAwMS50cyJ9",
                            "messageId": "test-001",
                            "publishTime": "2026-01-01T00:00:00Z",
                            "attributes": {"eventType": "OBJECT_FINALIZE", "objectId": "live/segment001.ts"},
                        },
                        "subscription": "projects/shoplens2026-dev/subscriptions/video-segments-sub",
                    }),
                    "non_hls_file_skipped": ("A non-.ts/.m3u8 file — skipped immediately", {
                        "message": {
                            "data": "eyJidWNrZXQiOiAic2hvcGxlbnMtZGV2LWhscy1zZWdtZW50cyIsICJuYW1lIjogImxpdmUvdGh1bWJuYWlsLmpwZyJ9",
                            "messageId": "test-002",
                            "publishTime": "2026-01-01T00:00:05Z",
                            "attributes": {"eventType": "OBJECT_FINALIZE", "objectId": "live/thumbnail.jpg"},
                        },
                        "subscription": "projects/shoplens2026-dev/subscriptions/video-segments-sub",
                    }),
                }),
            },
        },
    }
    op["responses"].update({
        "200": _resp("Pipeline result or skip reason", {"$ref": "#/components/schemas/PubSubResponse"}, {
            "segment_url": "gs://shoplens2026-dev-hls-segments/live/segment001.ts",
            "items_detected": 1, "products_matched": 1, "status": "pipeline_complete",
        }),
        "400": _resp("Malformed Pub/Sub message (missing data field, or bucket/name undeterminable)",
                      {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "Pub/Sub message contains no data field"}),
        "502": _resp("Upstream service (ai-analyzer, product-matcher, or state-manager) request failed",
                      {"$ref": "#/components/schemas/ErrorDetail"},
                      {"detail": "ai-analyzer request failed: All connection attempts failed"}),
    })

    p["/health"]["get"]["responses"]["200"] = _resp("Healthy", {"$ref": "#/components/schemas/HealthResponse"}, {"status": "ok"})

    return spec


ENRICHERS = {
    "ai-analyzer": enrich_ai_analyzer,
    "product-matcher": enrich_product_matcher,
    "state-manager": enrich_state_manager,
    "voice-assistant": enrich_voice_assistant,
    "pubsub-worker": enrich_pubsub_worker,
}

SERVICE_TITLES = {
    "ai-analyzer": "AI Analyzer",
    "product-matcher": "Product Matcher",
    "state-manager": "State Manager",
    "voice-assistant": "Voice Assistant",
    "pubsub-worker": "Pub/Sub Worker",
}

INDEX_HTML = """<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>ShopLens API Specs</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
  <style>body {{ margin: 0; }} .topbar {{ display: none !important; }}</style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.onload = () => {{
      window.ui = SwaggerUIBundle({{
        urls: [
{url_entries}
        ],
        "urls.primaryName": "{primary}",
        dom_id: "#swagger-ui",
        presets: [SwaggerUIBundle.presets.apis],
        layout: "BaseLayout",
        deepLinking: true,
      }});
    }};
  </script>
</body>
</html>
"""


def write_index_html():
    url_entries = ",\n".join(
        f'          {{url: "./{s}.openapi.json", name: "{SERVICE_TITLES[s]}"}}' for s in SERVICES
    )
    html = INDEX_HTML.format(url_entries=url_entries, primary=SERVICE_TITLES["ai-analyzer"])
    (OUT_DIR / "index.html").write_text(html, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--service", choices=SERVICES, default=None, help="Generate spec for a single service only")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    targets = [args.service] if args.service else SERVICES

    for service in targets:
        print(f"  {service} ... ", end="", flush=True)
        try:
            spec = generate_local(service)
            spec.setdefault("components", {}).setdefault("schemas", {})
            spec["servers"] = servers_for(service)
            spec = ENRICHERS[service](spec)

            out_path = OUT_DIR / f"{service}.openapi.json"
            out_path.write_text(json.dumps(spec, indent=2))
            print(f"OK -> {out_path.relative_to(Path(__file__).parent.parent.parent)}")
        except Exception as exc:
            print(f"FAILED: {exc}")
            raise

    write_index_html()
    print(f"\nDetailed specs + Swagger UI written to {OUT_DIR}/")
    print(f"Open {OUT_DIR / 'index.html'} in a browser to visualize (needs internet access to load Swagger UI's JS/CSS from a CDN).")


if __name__ == "__main__":
    main()
