import logging
import os
from typing import List

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from state_manager import clear_session, get_session, update_session

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Live State Management Service")

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


class UpdateRequest(BaseModel):
    products: List[dict]


@app.post("/session/{session_id}/products")
async def update(session_id: str, request: UpdateRequest) -> JSONResponse:
    update_session(session_id, request.products)
    return JSONResponse(content={"status": "updated", "session_id": session_id})


@app.get("/session/{session_id}")
async def get(session_id: str) -> JSONResponse:
    data = get_session(session_id)
    if data is None:
        raise HTTPException(status_code=404, detail=f"Session '{session_id}' not found")
    return JSONResponse(content=data)


@app.delete("/session/{session_id}")
async def clear(session_id: str) -> JSONResponse:
    clear_session(session_id)
    return JSONResponse(content={"status": "cleared", "session_id": session_id})


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
