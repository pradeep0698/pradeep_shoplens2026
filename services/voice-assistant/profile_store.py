import os
from typing import Optional

import firebase_admin
from firebase_admin import auth, credentials, firestore

_app: Optional[firebase_admin.App] = None


def _get_app() -> firebase_admin.App:
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
    return _app


def _get_db() -> firestore.Client:
    _get_app()
    return firestore.client()


def verify_id_token(authorization_header: str | None) -> str:
    """Verify a `Bearer <token>` Firebase ID token and return the caller's uid.
    Raises ValueError if the header is missing/malformed or the token is invalid."""
    if not authorization_header or not authorization_header.lower().startswith("bearer "):
        raise ValueError("Missing or malformed Authorization header")
    token = authorization_header.split(" ", 1)[1].strip()
    if not token:
        raise ValueError("Missing bearer token")
    _get_app()
    try:
        decoded = auth.verify_id_token(token)
    except auth.InvalidIdTokenError as exc:
        # Covers expired/revoked/malformed tokens — without this, an expired
        # token (the common case: the client just sat idle past an hour)
        # surfaces as an opaque 500 instead of a 401 the client can react to.
        raise ValueError(f"Invalid ID token: {exc}") from exc
    uid = decoded.get("uid")
    if not uid:
        raise ValueError("Token did not contain a uid")
    return uid


def get_profile(uid: str) -> dict:
    """Read UserProfiles/{uid}, returning an empty-shaped dict if it doesn't exist yet."""
    db = _get_db()
    snapshot = db.collection("UserProfiles").document(uid).get()
    data = snapshot.to_dict() if snapshot.exists else {}
    return {
        "shopping_categories": list(data.get("shopping_categories", [])),
        "preference_terms": list(data.get("preference_terms", [])),
        "ignore_terms": list(data.get("ignore_terms", [])),
    }


def _dedup_case_insensitive(existing: list[str], incoming: list[str]) -> list[str]:
    """Case-insensitive de-duplicated union, preserving the casing of whichever
    occurrence is seen first (existing entries win over incoming duplicates)."""
    merged: list[str] = []
    seen: set[str] = set()
    for term in [*existing, *incoming]:
        value = str(term).strip()
        if not value:
            continue
        lowered = value.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        merged.append(value)
    return merged


def _find_conflicts(preference_terms: list[str], ignore_terms: list[str]) -> list[str]:
    """Terms that ended up in both lists after merging — must be surfaced to the
    user to resolve, never silently dropped from either side."""
    pref_lower = {t.lower() for t in preference_terms}
    ignore_lower = {t.lower() for t in ignore_terms}
    return sorted(pref_lower & ignore_lower)


VOICE_CATEGORIES = [
    "Furniture",
    "Clothing",
    "Kitchen & Cookware",
    "Accessories",
    "Electronics",
    "Home Decor",
    "Sports & Outdoors",
    "Books & Stationery",
]

_CATEGORY_IGNORE_ALIASES: dict[str, set[str]] = {
    "Furniture": {"furniture", "chair", "chairs", "sofa", "sofas", "couch", "couches", "desk", "desks", "table", "tables"},
    "Clothing": {"clothing", "clothes", "apparel", "shirt", "shirts", "jacket", "jackets", "jeans", "dress", "dresses", "shoes", "sneakers"},
    "Kitchen & Cookware": {"kitchen", "cookware", "cooking", "pan", "pans", "pot", "pots", "appliance", "appliances"},
    "Accessories": {"accessories", "accessory", "watch", "watches", "bag", "bags", "jewelry", "jewellery", "wallet", "wallets"},
    "Electronics": {"electronics", "electronic", "phone", "phones", "laptop", "laptops", "tablet", "tablets", "headphones", "gadget", "gadgets", "tech"},
    "Home Decor": {"home decor", "decor", "decoration", "decorations", "candle", "candles", "vase", "vases", "rug", "rugs", "lamp", "lamps", "pillow", "pillows"},
    "Sports & Outdoors": {"sports", "sport", "outdoors", "outdoor", "gym", "fitness", "camping", "hiking", "yoga"},
    "Books & Stationery": {"books", "book", "stationery", "notebook", "notebooks", "pen", "pens", "journal", "journals", "planner", "planners"},
}


def _normalize_terms(values: list[str] | None) -> list[str]:
    return _dedup_case_insensitive([], [str(v) for v in (values or [])])


def _normalize_categories(values: list[str] | None) -> list[str]:
    allowed = set(VOICE_CATEGORIES)
    return [category for category in _dedup_case_insensitive([], [str(v) for v in (values or [])]) if category in allowed]


def _ignored_category_names(ignore_terms: list[str]) -> set[str]:
    ignored = {term.strip().lower() for term in ignore_terms if term.strip()}
    blocked: set[str] = set()
    for category, aliases in _CATEGORY_IGNORE_ALIASES.items():
        if ignored & aliases:
            blocked.add(category)
    return blocked


def normalize_reviewed_patch(patch: dict) -> dict:
    """Normalize the exact profile shape approved on the review screen.

    Unlike merge_and_save, this is not an append-only patch. The reviewed chips
    are authoritative for the three voice-managed fields.
    """
    ignore_terms = _normalize_terms(patch.get("ignore_terms"))
    ignore_lower = {term.lower() for term in ignore_terms}

    preference_terms = [
        term for term in _normalize_terms(patch.get("preference_terms"))
        if term.lower() not in ignore_lower
    ]

    blocked_categories = _ignored_category_names(ignore_terms)
    shopping_categories = [
        category for category in _normalize_categories(patch.get("shopping_categories"))
        if category not in blocked_categories and category.lower() not in ignore_lower
    ]

    return {
        "shopping_categories": shopping_categories,
        "preference_terms": preference_terms,
        "ignore_terms": ignore_terms,
        "conflicts": [],
    }


def save_reviewed_profile(uid: str, patch: dict) -> dict:
    """Save the reviewed voice profile exactly, preserving unrelated fields."""
    db = _get_db()
    ref = db.collection("UserProfiles").document(uid)
    normalized = normalize_reviewed_patch(patch)

    ref.set(
        {
            "shopping_categories": normalized["shopping_categories"],
            "preference_terms": normalized["preference_terms"],
            "ignore_terms": normalized["ignore_terms"],
        },
        merge=True,
    )

    return normalized


def merge_and_save(uid: str, patch: dict) -> dict:
    """Merge a confirmed voice-derived patch into UserProfiles/{uid}.

    - shopping_categories: set union with existing.
    - preference_terms / ignore_terms: case-insensitive de-duped union.
    - Conflicts (a term present in both lists after merge) are returned, not
      auto-resolved — the caller must surface them to the user.
    """
    db = _get_db()
    ref = db.collection("UserProfiles").document(uid)
    snapshot = ref.get()
    existing = snapshot.to_dict() if snapshot.exists else {}

    existing_categories = set(existing.get("shopping_categories", []))
    incoming_categories = set(patch.get("shopping_categories", []))
    merged_categories = sorted(existing_categories | incoming_categories)

    merged_preference_terms = _dedup_case_insensitive(
        existing.get("preference_terms", []), patch.get("preference_terms", [])
    )
    merged_ignore_terms = _dedup_case_insensitive(
        existing.get("ignore_terms", []), patch.get("ignore_terms", [])
    )

    conflicts = _find_conflicts(merged_preference_terms, merged_ignore_terms)

    ref.set(
        {
            "shopping_categories": merged_categories,
            "preference_terms": merged_preference_terms,
            "ignore_terms": merged_ignore_terms,
        },
        merge=True,
    )

    return {
        "shopping_categories": merged_categories,
        "preference_terms": merged_preference_terms,
        "ignore_terms": merged_ignore_terms,
        "conflicts": conflicts,
    }
