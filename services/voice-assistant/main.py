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
from pydantic import BaseModel

import profile_store
from live_session import _SESSION_MAX_SECONDS, run_voice_session, session_registry

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

app = FastAPI(title="Voice Preference Assistant")

_CORS = {"Access-Control-Allow-Origin": "*"}


@app.on_event("startup")
async def _log_startup_config() -> None:
    logger.info(
        "voice-assistant starting | project_id=%s location=%s model=%s session_max_seconds=%s",
        os.environ.get("PROJECT_ID") or "(unset)",
        os.environ.get("LOCATION", "us-central1"),
        os.environ.get("VOICE_MODEL", "gemini-live-2.5-flash"),
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


class SessionStartRequest(BaseModel):
    # "preferences" (forced first-run onboarding) or "search" (every other
    # voice session) — see live_session.py's SessionState.mode. Defaults to
    # "preferences" so a stale client that never sends a body keeps the old
    # behavior.
    mode: str = "preferences"


class SessionStartResponse(BaseModel):
    session_id: str
    ws_url: str
    profile: dict


@app.post("/voice/session/start")
async def start_session(http_request: Request, body: SessionStartRequest = SessionStartRequest()) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    uid = _require_uid(http_request)
    existing_profile = profile_store.get_profile(uid)
    mode = body.mode if body.mode == "search" else "preferences"
    session = await session_registry.create(uid=uid, existing_profile=existing_profile, mode=mode)

    elapsed = time.monotonic() - start
    logger.info("voice session start uid=%s session_id=%s in %.2fs", uid, session.session_id, elapsed)

    response = SessionStartResponse(
        session_id=session.session_id,
        ws_url=f"/voice/session/{session.session_id}/stream",
        profile=existing_profile,
    )
    return JSONResponse(content=response.model_dump(), headers={"X-Request-Id": req_id})


class SessionEventRequest(BaseModel):
    session_id: str
    event_type: str
    payload: dict = {}


@app.post("/voice/session/event")
async def session_event(request: SessionEventRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    uid = _require_uid(http_request)
    logger.info(
        "voice session event uid=%s session_id=%s event_type=%s", uid, request.session_id, request.event_type,
    )
    return JSONResponse(content={"status": "received"}, headers={"X-Request-Id": req_id})


class SessionFinalizeRequest(BaseModel):
    session_id: str
    confirmed_patch: dict


@app.post("/voice/session/finalize")
async def finalize_session(request: SessionFinalizeRequest, http_request: Request) -> JSONResponse:
    req_id = uuid.uuid4().hex[:8]
    _request_id_ctx.set(req_id)
    start = time.monotonic()

    uid = _require_uid(http_request)
    try:
        result = profile_store.save_reviewed_profile(uid, request.confirmed_patch)
    except Exception as exc:
        elapsed = time.monotonic() - start
        logger.exception(
            "voice finalize FAILED after %.2fs | uid=%s session_id=%s | %s: %s",
            elapsed, uid, request.session_id, type(exc).__name__, exc,
        )
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
    await session_registry.delete(request.session_id)
    return JSONResponse(content=result, headers={"X-Request-Id": req_id})


@app.websocket("/voice/session/{session_id}/stream")
async def voice_stream(websocket: WebSocket, session_id: str) -> None:
    session = await session_registry.get(session_id)
    if session is None:
        await websocket.close(code=4004)
        return

    await websocket.accept()
    logger.info("voice session %s stream connected (uid=%s)", session_id, session.uid)
    try:
        await run_voice_session(websocket, session)
    except Exception as exc:
        logger.exception("voice session %s stream FAILED | %s: %s", session_id, type(exc).__name__, exc)
    finally:
        logger.info("voice session %s stream closed", session_id)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "project_id_set": bool(os.environ.get("PROJECT_ID")),
        "voice_model": os.environ.get("VOICE_MODEL", "gemini-live-2.5-flash"),
    }


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
