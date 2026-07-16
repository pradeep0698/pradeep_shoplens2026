import asyncio
import json
import logging
import os
import time
import uuid
from contextvars import ContextVar

# Some networks (e.g. corporate TLS-inspecting proxies) re-sign outbound HTTPS
# with a root CA that's trusted by the OS but not by certifi's bundled CA list,
# which `requests`/`urllib3` use by default. This makes Python trust whatever
# the OS trusts instead — must run before firebase_admin/google-genai create
# any SSL context. Harmless on Cloud Run, where the OS trust store is the
# standard one anyway.
import truststore
truststore.inject_into_ssl()

from fastapi import FastAPI, HTTPException, Request, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import profile_store
from live_session import (
    SUPPORTED_LANGUAGES,
    _MIN_ASSISTANT_TURNS_BEFORE_FIRST_SEARCH,
    _SESSION_MAX_SECONDS,
    SessionState,
    _flatten_patch_for_client,
    _trace,
    apply_ready_to_finalize,
    apply_record_preference,
    apply_search_products,
    mint_ephemeral_token,
    run_voice_session,
    session_registry,
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
    title="Voice Preference Assistant",
    description=(
        "Gemini Live-powered voice assistant for managing user shopping preferences.\n\n"
        "**Authentication:** All `/voice/session/*` endpoints require a Firebase ID token in the "
        "`Authorization: Bearer {token}` header. Obtain a token via `user.getIdToken()` in the "
        "Firebase Auth SDK.\n\n"
        "**Session flow:**\n"
        "1. `POST /voice/session/start` — create session, get `session_id` and WebSocket URL "
        "(pass `resume_session_id` to resume a recently-disconnected session instead of starting fresh)\n"
        "2. Connect to `wss://{host}/voice/session/{session_id}/stream` — real-time voice exchange\n"
        "3. `POST /voice/session/finalize` — commit confirmed preference changes to Firestore, or "
        "`POST /voice/session/cancel` — discard the session without saving\n\n"
        "**WebSocket note:** The `/voice/session/{session_id}/stream` WebSocket endpoint is not "
        "testable via HTTP clients. Use the mobile app or a WebSocket client."
    ),
    version="1.0.0",
    openapi_tags=[
        {"name": "Voice Session", "description": "Voice preference session lifecycle"},
        {"name": "System", "description": "Health and diagnostics"},
    ],
)

_CORS = {"Access-Control-Allow-Origin": "*"}


def _resolved_live_provider_and_model() -> tuple[str, str]:
    """Cheap, side-effect-free (no client construction) lookup of which
    provider/model the live session will actually connect with — mirrors
    live_session._live_connect_target's selection logic for logging/health
    purposes only."""
    provider = os.environ.get("VOICE_LIVE_PROVIDER", "vertex").lower()
    if provider == "dev_api":
        return provider, os.environ.get("VOICE_MODEL_DEV_API", "models/gemini-2.5-flash-native-audio-latest")
    return provider, os.environ.get("VOICE_MODEL", "gemini-live-2.5-flash-native-audio")


@app.on_event("startup")
async def _log_startup_config() -> None:
    provider, model = _resolved_live_provider_and_model()
    logger.info(
        "voice-assistant starting | project_id=%s location=%s live_provider=%s model=%s session_max_seconds=%s",
        os.environ.get("PROJECT_ID") or "(unset)",
        os.environ.get("LOCATION", "us-central1"),
        provider,
        model,
        _SESSION_MAX_SECONDS,
    )


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    logger.exception(
        "Unhandled error %s %s | %s: %s", request.method, request.url.path, type(exc).__name__, exc,
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


def _require_uid(request: Request) -> str:
    try:
        return profile_store.verify_id_token(request.headers.get("authorization"))
    except ValueError as exc:
        raise HTTPException(status_code=401, detail=str(exc))


async def _get_owned_session(session_id: str, uid: str) -> SessionState:
    """Shared lookup for the /voice/session/token and /voice/tool/* REST
    endpoints — unlike the WS stream endpoint (which only trusts the opaque
    session_id minted by the already-authenticated start call), these REST
    endpoints are more exposed to casual replay, so ownership is checked
    explicitly here."""
    session = await session_registry.get(session_id)
    if session is None or session.uid != uid:
        raise HTTPException(status_code=404, detail="session not found")
    return session


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class SessionStartRequest(BaseModel):
    mode: str = Field(
        "preferences",
        description=(
            "Session mode: `'preferences'` for first-run onboarding or updating dietary restrictions/allergies; "
            "`'search'` for voice-driven product search within an active shopping session."
        ),
    )
    language: str | None = Field(
        None,
        description=(
            "Display name from SUPPORTED_LANGUAGES (e.g. 'Spanish'). Unknown values fall back to "
            "'English' for a fresh session. Omitted entirely (as opposed to explicitly 'English') means "
            "'don't change it' when resuming an existing session."
        ),
    )
    resume_session_id: str | None = Field(
        None,
        description=(
            "If set and the session is still within its post-disconnect grace "
            "period and owned by this user, resumes it (reusing its transcript/"
            "latest_patch) instead of starting a brand-new session. Falls back "
            "silently to a fresh session if the id is missing/expired/not owned "
            "by the caller — resume is always best-effort."
        ),
    )


class UserProfile(BaseModel):
    username: str | None = None
    allergies: list[str] = []
    dietary_restrictions: list[str] = []
    preference_terms: list[str] = []
    ignore_terms: list[str] = []


class SessionStartResponse(BaseModel):
    session_id: str = Field(..., description="Unique session identifier — use for WebSocket URL and finalize call")
    ws_url: str = Field(..., description="Relative WebSocket path: /voice/session/{session_id}/stream")
    profile: dict = Field(..., description="Current user profile from Firestore")
    direct_connect_allowed: bool = Field(
        ...,
        description=(
            "Server-side kill switch for the native-only direct client->Gemini Live transport. "
            "When false, clients must use the WS proxy regardless of platform/build flags."
        ),
    )


class SessionCancelRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")


class SessionEventRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")
    event_type: str = Field(..., description="Event type identifier (e.g. 'user_message', 'ui_action')")
    payload: dict = Field(default_factory=dict, description="Arbitrary event payload")


class PreferencePatch(BaseModel):
    shopping_categories: list[str] | None = Field(None, description="Shopping categories the user is interested in")
    preference_terms: list[str] | None = Field(None, description="Product attributes the user prefers")
    ignore_terms: list[str] | None = Field(None, description="Product names/terms to exclude from results")
    allergies: list[str] | None = Field(None, description="Food allergies")
    dietary_restrictions: list[str] | None = Field(None, description="Dietary restrictions (e.g. vegan, gluten-free)")
    max_searches_per_run: int | None = Field(None, description="Maximum SerpAPI searches per analyze call")


class SessionFinalizeRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")
    confirmed_patch: PreferencePatch = Field(
        ...,
        description="The preference changes confirmed by the user during the voice session to persist to Firestore",
    )

    model_config = {"json_schema_extra": {
        "examples": [{
            "session_id": "abc12345",
            "confirmed_patch": {
                "preference_terms": ["organic", "non-stick"],
                "ignore_terms": ["plastic"],
                "allergies": ["nuts"],
                "dietary_restrictions": ["vegan"],
                "max_searches_per_run": 5,
            }
        }]
    }}


class SessionTokenRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")


class RecordPreferenceRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")
    shopping_categories: list[str] = Field(default_factory=list)
    preference_terms: list[str] = Field(default_factory=list)
    ignore_terms: list[str] = Field(default_factory=list)


class SearchProductsRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")
    query: str = Field(..., description="Freetext shopping search query")
    category: str | None = Field(
        None, description="Best-guess shopping category for this search, used to scope which saved brand/style preferences apply"
    )


class ReadyToFinalizeRequest(BaseModel):
    session_id: str = Field(..., description="Session ID from /voice/session/start")
    summary: str = Field("", description="Human-readable confirmation sentence the model already spoke")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post(
    "/voice/session/start",
    tags=["Voice Session"],
    summary="Start a voice preference session",
    description=(
        "Creates a new Gemini Live session for the authenticated user. Returns a `session_id` "
        "and the relative WebSocket URL to connect to for real-time voice interaction.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Session created"},
        401: {"description": "Missing or invalid Firebase ID token"},
    },
)
async def start_session(http_request: Request, body: SessionStartRequest = SessionStartRequest()) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    uid = _require_uid(http_request)

    session = None
    resumed = False
    if body.resume_session_id:
        candidate = await session_registry.get(body.resume_session_id)
        if candidate is not None and candidate.uid == uid:
            candidate.disconnected_at = None
            if body.language in SUPPORTED_LANGUAGES and body.language != candidate.language:
                candidate.language = body.language
            session = candidate
            resumed = True
            logger.info("voice session %s resumed (uid=%s)", session.session_id, uid)

    if session is None:
        existing_profile = profile_store.get_profile(uid)
        mode = body.mode if body.mode == "search" else "preferences"
        language = body.language if body.language in SUPPORTED_LANGUAGES else "English"
        session = await session_registry.create(uid=uid, existing_profile=existing_profile, mode=mode, language=language)

    elapsed = time.monotonic() - start
    logger.info("voice session start uid=%s session_id=%s in %.2fs", uid, session.session_id, elapsed)
    _trace(session.session_id, "session_start", uid=uid, ms=round(elapsed * 1000), resumed=resumed)

    response = SessionStartResponse(
        session_id=session.session_id,
        ws_url=f"/voice/session/{session.session_id}/stream",
        # session.existing_profile (not the local `existing_profile` var above)
        # since that local is only assigned on the fresh-session branch — a
        # resumed session must report its own already-set profile instead.
        # preference_terms/ignore_terms are category-keyed internally (see
        # profile_store._coerce_categorized) — flattened back to plain lists
        # here since that's the shape the mobile client's profile model expects.
        profile=_flatten_patch_for_client(session.existing_profile),
        direct_connect_allowed=os.environ.get("VOICE_DIRECT_CONNECT_ENABLED", "false").lower() == "true",
    )
    return JSONResponse(content=response.model_dump(), headers={"X-Request-Id": req_id})


@app.post(
    "/voice/session/event",
    tags=["Voice Session"],
    summary="Send a session event",
    description=(
        "Posts a structured event to an active voice session. Currently logged but not "
        "acted upon server-side — reserved for future UI-to-session signalling.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Event received"},
        401: {"description": "Missing or invalid Firebase ID token"},
    },
)
async def session_event(request: SessionEventRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    uid = _require_uid(http_request)
    # Cap the logged payload — this is also how the mobile app's
    # client_diagnostics event (mic/recorder/turn-latency stats, see
    # voice_assistant_provider.dart's _flushDiagnostics) reaches Cloud Run
    # logs, so it must never grow large enough to get truncated mid-JSON.
    _trace(request.session_id, request.event_type, uid=uid, payload=json.dumps(request.payload)[:6000])
    return JSONResponse(content={"status": "received"}, headers={"X-Request-Id": req_id})


@app.post(
    "/voice/session/cancel",
    tags=["Voice Session"],
    summary="Cancel a voice session",
    description=(
        "Explicitly ends a voice session without saving anything — deletes the "
        "in-memory session immediately rather than leaving it in the resumable "
        "post-disconnect grace period. Call this when the user taps Cancel/"
        "closes the assistant sheet without confirming, as distinct from a "
        "dropped connection (which stays resumable — see resume_session_id on "
        "/voice/session/start).\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Session cancelled (or already gone — idempotent)"},
        401: {"description": "Missing or invalid Firebase ID token"},
    },
)
async def cancel_session(request: SessionCancelRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    uid = _require_uid(http_request)
    session = await session_registry.get(request.session_id)
    if session is not None and session.uid == uid:
        await session_registry.delete(request.session_id)
        logger.info("voice session %s cancelled uid=%s", request.session_id, uid)
    return JSONResponse(content={"status": "cancelled"}, headers={"X-Request-Id": req_id})


@app.post(
    "/voice/session/finalize",
    tags=["Voice Session"],
    summary="Finalize session and save preferences",
    description=(
        "Commits the confirmed preference changes from the voice session to Firestore, "
        "then closes the session. Call this after the WebSocket stream disconnects and the "
        "user has reviewed the proposed changes.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Preferences saved and session closed"},
        401: {"description": "Missing or invalid Firebase ID token"},
        500: {"description": "Firestore write failed"},
    },
)
async def finalize_session(request: SessionFinalizeRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    uid = _require_uid(http_request)
    confirmed = request.confirmed_patch.model_dump(exclude_none=True)
    # Mobile's review chips are flat and delete-only (no category concept) —
    # reconcile the surviving flat lists against the session's category-keyed
    # map (if the session is still resolvable within its disconnect grace
    # period) so a term keeps whatever category it was recorded under instead
    # of collapsing into the general bucket. Falls back gracefully (treats
    # the confirmed lists as general) if the session already expired.
    session = await session_registry.get(request.session_id)
    if session is not None and session.uid == uid:
        confirmed = {
            **confirmed,
            "preference_terms": profile_store.reconcile_confirmed_terms(
                confirmed.get("preference_terms", []), session.latest_patch["preference_terms"]
            ),
            "ignore_terms": profile_store.reconcile_confirmed_terms(
                confirmed.get("ignore_terms", []), session.latest_patch["ignore_terms"]
            ),
        }
    try:
        result = profile_store.save_reviewed_profile(uid, confirmed)
    except Exception as exc:
        elapsed = time.monotonic() - start
        logger.exception(
            "voice finalize FAILED after %.2fs | uid=%s session_id=%s | %s: %s",
            elapsed, uid, request.session_id, type(exc).__name__, exc,
        )
        _trace(request.session_id, "finalize_failed", ms=round(elapsed * 1000), error=f"{type(exc).__name__}: {exc}")
        return JSONResponse(
            content={"detail": str(exc), "error_code": "INTERNAL_ERROR"},
            status_code=500,
            headers={"X-Request-Id": req_id},
        )

    elapsed = time.monotonic() - start
    logger.info(
        "voice finalize OK in %.2fs | uid=%s session_id=%s conflicts=%d",
        elapsed, uid, request.session_id, len(result.get("conflicts", [])),
    )
    _trace(request.session_id, "finalize", ms=round(elapsed * 1000), conflicts=len(result.get("conflicts", [])))
    await session_registry.delete(request.session_id)
    return JSONResponse(content=result, headers={"X-Request-Id": req_id})


@app.post(
    "/voice/session/token",
    tags=["Voice Session"],
    summary="Mint an ephemeral Gemini Live token for direct client connection",
    description=(
        "Mints a short-lived, model/config-locked auth token for the native mobile app to open "
        "its own direct WebSocket connection to Gemini Live (Developer API), bypassing this "
        "backend for audio streaming. Tool-call side effects still route through the "
        "/voice/tool/* endpoints below.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Token minted"},
        401: {"description": "Missing or invalid Firebase ID token"},
        404: {"description": "Session not found or not owned by this user"},
        502: {"description": "Token minting failed"},
    },
)
async def mint_session_token(request: SessionTokenRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    uid = _require_uid(http_request)
    session = await _get_owned_session(request.session_id, uid)
    start = time.monotonic()
    try:
        token_data = await asyncio.to_thread(
            mint_ephemeral_token, session.existing_profile, session.mode, session.language, session.transcript
        )
    except Exception as exc:
        logger.exception("token mint failed for session %s: %s", request.session_id, exc)
        _trace(request.session_id, "token_mint_failed", ms=round((time.monotonic() - start) * 1000), error=f"{type(exc).__name__}: {exc}")
        raise HTTPException(status_code=502, detail="Failed to mint Gemini Live token")
    _trace(request.session_id, "token_mint", ms=round((time.monotonic() - start) * 1000), voice_model=token_data.get("model"))
    return JSONResponse(content=token_data, headers={"X-Request-Id": req_id})


@app.post(
    "/voice/tool/record_preference",
    tags=["Voice Tool"],
    summary="Apply a record_preference tool call (direct-connect transport)",
    description=(
        "Executes the same record_preference side effect the WS-proxy path runs internally — "
        "for the mobile app's direct client->Gemini connection, which routes tool-call side "
        "effects through REST instead of the WS relay.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Preference recorded"},
        401: {"description": "Missing or invalid Firebase ID token"},
        404: {"description": "Session not found or not owned by this user"},
    },
)
async def tool_record_preference(request: RecordPreferenceRequest, http_request: Request) -> JSONResponse:
    uid = _require_uid(http_request)
    start = time.monotonic()
    session = await _get_owned_session(request.session_id, uid)
    result = apply_record_preference(session, request.model_dump(exclude={"session_id"}))
    _trace(request.session_id, "tool_call", tool="record_preference", ms=round((time.monotonic() - start) * 1000), status=result.get("status", "?"))
    # result["patch"] is session.latest_patch — category-keyed internally
    # (see profile_store._coerce_categorized) — flatten back to plain lists,
    # the shape the mobile client's VoiceProfilePatch model expects.
    return JSONResponse(content={**result, "patch": _flatten_patch_for_client(result["patch"])})


@app.post(
    "/voice/tool/search_products",
    tags=["Voice Tool"],
    summary="Apply a search_products tool call (direct-connect transport)",
    description=(
        "Executes the same search_products side effect the WS-proxy path runs internally "
        "(Google Shopping, topped up with Amazon when short) — for the mobile app's direct "
        "client->Gemini connection.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Search complete"},
        401: {"description": "Missing or invalid Firebase ID token"},
        404: {"description": "Session not found or not owned by this user"},
    },
)
async def tool_search_products(request: SearchProductsRequest, http_request: Request) -> JSONResponse:
    uid = _require_uid(http_request)
    start = time.monotonic()
    session = await _get_owned_session(request.session_id, uid)
    # The direct Gemini connection holds the clarifying conversation itself,
    # so the backend relay never gets transcript turns to increment this
    # proxy-only guard. Reaching this authenticated endpoint means Gemini has
    # already chosen to call the configured search tool.
    session.assistant_turns_in_search_mode = max(
        session.assistant_turns_in_search_mode,
        _MIN_ASSISTANT_TURNS_BEFORE_FIRST_SEARCH,
    )
    result = await apply_search_products(session, request.query, request.category)
    _trace(request.session_id, "tool_call", tool="search_products", ms=round((time.monotonic() - start) * 1000), status=result.get("status", "?"))
    return JSONResponse(content=result)


@app.post(
    "/voice/tool/ready_to_finalize",
    tags=["Voice Tool"],
    summary="Apply a ready_to_finalize tool call (direct-connect transport)",
    description=(
        "Executes the same ready_to_finalize side effect the WS-proxy path runs internally — "
        "for the mobile app's direct client->Gemini connection.\n\n"
        "**Requires:** `Authorization: Bearer {firebase_id_token}`"
    ),
    responses={
        200: {"description": "Proposal packaged"},
        401: {"description": "Missing or invalid Firebase ID token"},
        404: {"description": "Session not found or not owned by this user"},
    },
)
async def tool_ready_to_finalize(request: ReadyToFinalizeRequest, http_request: Request) -> JSONResponse:
    uid = _require_uid(http_request)
    start = time.monotonic()
    session = await _get_owned_session(request.session_id, uid)
    result = apply_ready_to_finalize(session, request.summary.strip())
    _trace(request.session_id, "tool_call", tool="ready_to_finalize", ms=round((time.monotonic() - start) * 1000), status=result.get("status", "?"))
    return JSONResponse(content=result)


@app.websocket("/voice/session/{session_id}/stream")
async def voice_stream(websocket: WebSocket, session_id: str) -> None:
    """Real-time bidirectional voice stream via Gemini Live.

    Connect after calling POST /voice/session/start. The server sends audio
    chunks and text transcripts; the client sends PCM16 audio frames.
    Session closes automatically after inactivity or the configured max duration.
    """
    session = await session_registry.get(session_id)
    if session is None:
        await websocket.close(code=4004)
        return

    # Clear any pending disconnect grace timer now that a WS has actually
    # (re)attached to this session — see SessionState.disconnected_at.
    session.disconnected_at = None

    await websocket.accept()
    logger.info("voice session %s stream connected (uid=%s)", session_id, session.uid)
    try:
        await run_voice_session(websocket, session)
    except Exception as exc:
        logger.exception("voice session %s stream FAILED | %s: %s", session_id, type(exc).__name__, exc)
    finally:
        logger.info("voice session %s stream closed", session_id)


@app.get(
    "/health",
    tags=["System"],
    summary="Health check",
    response_description="Service liveness and active Gemini model",
)
async def health():
    provider, model = _resolved_live_provider_and_model()
    return {
        "status": "ok",
        "project_id_set": bool(os.environ.get("PROJECT_ID")),
        "voice_live_provider": provider,
        "voice_model": model,
    }


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
