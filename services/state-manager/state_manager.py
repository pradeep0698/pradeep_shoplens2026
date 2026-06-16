import os
from typing import Optional

import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud.firestore_v1 import SERVER_TIMESTAMP

_app: Optional[firebase_admin.App] = None


def _get_db() -> firestore.Client:
    global _app
    if _app is None:
        project_id = os.environ.get("FIRESTORE_PROJECT_ID") or os.environ.get("PROJECT_ID")
        options = {"projectId": project_id} if project_id else {}
        cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        if cred_path:
            cred = credentials.Certificate(cred_path)
            _app = firebase_admin.initialize_app(cred, options=options)
        else:
            _app = firebase_admin.initialize_app(options=options)
    return firestore.client()


def update_session(session_id: str, products: list[dict]) -> None:
    db = _get_db()
    ref = db.collection("LiveShoppingSessions").document(session_id)
    ref.set({
        "products": products,
        "last_updated": SERVER_TIMESTAMP,
    })


def get_session(session_id: str) -> Optional[dict]:
    db = _get_db()
    doc = db.collection("LiveShoppingSessions").document(session_id).get()
    if not doc.exists:
        return None
    data = doc.to_dict()
    ts = data.get("last_updated")
    if ts is not None:
        try:
            data["last_updated"] = {
                "seconds": int(ts.timestamp()),
                "nanoseconds": getattr(ts, "nanosecond", 0),
            }
        except (AttributeError, TypeError):
            data["last_updated"] = None
    return data


def clear_session(session_id: str) -> None:
    db = _get_db()
    ref = db.collection("LiveShoppingSessions").document(session_id)
    ref.set({
        "products": [],
        "last_updated": SERVER_TIMESTAMP,
    })
