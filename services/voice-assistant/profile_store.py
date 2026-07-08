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


# Bucket key for preference/ignore terms recorded without a specific shopping
# category (e.g. "I like minimalist style") — applied regardless of which
# category a later search falls under, alongside that category's own bucket.
GENERAL_BUCKET = "_general"


def _coerce_categorized(value) -> dict[str, list[str]]:
    """Normalizes a Firestore preference_terms/ignore_terms value into the
    category-keyed shape. Old documents (pre category-scoping) stored a flat
    list — those become the general bucket on read so existing users' data
    isn't lost or misinterpreted; every write from here on persists the dict
    shape, so this is a lazy, on-read migration rather than a batch script."""
    if isinstance(value, dict):
        return {str(k): [str(t) for t in (v or [])] for k, v in value.items()}
    if isinstance(value, list) and value:
        return {GENERAL_BUCKET: [str(t) for t in value]}
    return {}


def get_profile(uid: str) -> dict:
    """Read UserProfiles/{uid}, returning an empty-shaped dict if it doesn't exist yet."""
    db = _get_db()
    snapshot = db.collection("UserProfiles").document(uid).get()
    data = snapshot.to_dict() if snapshot.exists else {}
    return {
        "shopping_categories": list(data.get("shopping_categories", [])),
        "preference_terms": _coerce_categorized(data.get("preference_terms", [])),
        "ignore_terms": _coerce_categorized(data.get("ignore_terms", [])),
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


def merge_categorized(
    existing: dict[str, list[str]], incoming: dict[str, list[str]]
) -> dict[str, list[str]]:
    """Per-bucket case-insensitive union — same semantics as
    _dedup_case_insensitive, applied independently to each category (plus
    GENERAL_BUCKET) so a term recorded under one category never spills into
    another's bucket."""
    merged: dict[str, list[str]] = {}
    for category in {*existing.keys(), *incoming.keys()}:
        bucket = _dedup_case_insensitive(existing.get(category, []), incoming.get(category, []))
        if bucket:
            merged[category] = bucket
    return merged


def _flatten_categorized(value: dict[str, list[str]]) -> list[str]:
    """Deduped flat list across all buckets — used at API/WS boundaries so the
    wire format stays the flat list the mobile client already expects."""
    flat: list[str] = []
    for bucket in value.values():
        flat = _dedup_case_insensitive(flat, bucket)
    return flat


def reconcile_confirmed_terms(confirmed: list[str], categorized: dict[str, list[str]]) -> dict[str, list[str]]:
    """Reconciles a flat, possibly user-trimmed list of surviving terms (from
    the mobile review screen's delete-only chips, which have no concept of
    category buckets) against the session's category-keyed map: a surviving
    term keeps whatever bucket it was already in. Anything in `confirmed` but
    not found in `categorized` (e.g. the in-memory session/grace period
    already expired by the time /finalize is called) falls into
    GENERAL_BUCKET rather than being dropped."""
    confirmed_lower = {t.lower(): t for t in confirmed}
    result: dict[str, list[str]] = {}
    matched_lower: set[str] = set()
    for category, terms in categorized.items():
        kept = [t for t in terms if t.lower() in confirmed_lower]
        if kept:
            result[category] = kept
            matched_lower.update(t.lower() for t in kept)
    leftover = [confirmed_lower[lower] for lower in confirmed_lower if lower not in matched_lower]
    if leftover:
        result[GENERAL_BUCKET] = _dedup_case_insensitive(result.get(GENERAL_BUCKET, []), leftover)
    return result


def _find_conflicts(preference_terms: dict[str, list[str]], ignore_terms: dict[str, list[str]]) -> list[str]:
    """Terms that ended up in both preference and ignore buckets for the same
    category (or both general) after merging — must be surfaced to the user to
    resolve, never silently dropped from either side."""
    conflicts: set[str] = set()
    for category in {*preference_terms.keys(), *ignore_terms.keys()}:
        pref_lower = {t.lower() for t in preference_terms.get(category, [])}
        ignore_lower = {t.lower() for t in ignore_terms.get(category, [])}
        conflicts |= pref_lower & ignore_lower
    return sorted(conflicts)


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


def _normalize_categorized_terms(values) -> dict[str, list[str]]:
    """Dedups each bucket of a category-keyed preference/ignore-terms value,
    coercing an old flat list into GENERAL_BUCKET first if needed."""
    categorized = _coerce_categorized(values)
    return {
        category: deduped
        for category, terms in categorized.items()
        if (deduped := _dedup_case_insensitive([], terms))
    }


def _normalize_categories(values: list[str] | None) -> list[str]:
    allowed = set(VOICE_CATEGORIES)
    return [category for category in _dedup_case_insensitive([], [str(v) for v in (values or [])]) if category in allowed]


def _ignored_category_names(ignore_terms: dict[str, list[str]]) -> set[str]:
    ignored = {term.strip().lower() for terms in ignore_terms.values() for term in terms if term.strip()}
    blocked: set[str] = set()
    for category, aliases in _CATEGORY_IGNORE_ALIASES.items():
        if ignored & aliases:
            blocked.add(category)
    return blocked


def normalize_reviewed_patch(patch: dict) -> dict:
    """Normalize the exact profile shape approved on the review screen.

    Unlike merge_and_save, this is not an append-only patch. The reviewed
    chips are authoritative for the three voice-managed fields.
    preference_terms/ignore_terms are expected already in the category-keyed
    shape (see _coerce_categorized) — callers reconciling a flat,
    client-submitted list (e.g. main.py's finalize handler) must do so before
    calling this.
    """
    ignore_terms = _normalize_categorized_terms(patch.get("ignore_terms"))
    ignore_lower = {term.lower() for terms in ignore_terms.values() for term in terms}

    preference_terms = {
        category: filtered
        for category, terms in _normalize_categorized_terms(patch.get("preference_terms")).items()
        if (filtered := [term for term in terms if term.lower() not in ignore_lower])
    }

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
    """Save the reviewed voice profile exactly, preserving unrelated fields.

    Firestore stores preference_terms/ignore_terms in the category-keyed
    shape; the returned dict flattens them back to plain lists so the
    external API response contract (what the mobile client parses) is
    unchanged."""
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

    return {
        "shopping_categories": normalized["shopping_categories"],
        "preference_terms": _flatten_categorized(normalized["preference_terms"]),
        "ignore_terms": _flatten_categorized(normalized["ignore_terms"]),
        "conflicts": normalized["conflicts"],
    }


def merge_and_save(uid: str, patch: dict) -> dict:
    """Merge a confirmed voice-derived patch into UserProfiles/{uid}.

    - shopping_categories: set union with existing.
    - preference_terms / ignore_terms: case-insensitive de-duped union, per
      category bucket (see merge_categorized) — a flat list in either
      `patch` or the existing Firestore doc is coerced into GENERAL_BUCKET
      first (see _coerce_categorized).
    - Conflicts (a term present in both buckets for the same category after
      merge) are returned, not auto-resolved — the caller must surface them
      to the user.

    Returns preference_terms/ignore_terms flattened to plain lists, matching
    save_reviewed_profile's external contract — Firestore itself still stores
    the category-keyed shape.
    """
    db = _get_db()
    ref = db.collection("UserProfiles").document(uid)
    snapshot = ref.get()
    existing = snapshot.to_dict() if snapshot.exists else {}

    existing_categories = set(existing.get("shopping_categories", []))
    incoming_categories = set(patch.get("shopping_categories", []))
    merged_categories = sorted(existing_categories | incoming_categories)

    merged_preference_terms = merge_categorized(
        _coerce_categorized(existing.get("preference_terms", [])),
        _coerce_categorized(patch.get("preference_terms", {})),
    )
    merged_ignore_terms = merge_categorized(
        _coerce_categorized(existing.get("ignore_terms", [])),
        _coerce_categorized(patch.get("ignore_terms", {})),
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
        "preference_terms": _flatten_categorized(merged_preference_terms),
        "ignore_terms": _flatten_categorized(merged_ignore_terms),
        "conflicts": conflicts,
    }
