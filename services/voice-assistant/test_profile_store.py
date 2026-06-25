import pytest
from firebase_admin import auth

import profile_store


class _FakeSnapshot:
    def __init__(self, data: dict | None):
        self._data = data
        self.exists = data is not None

    def to_dict(self) -> dict | None:
        return self._data


class _FakeDocRef:
    def __init__(self, store: dict, key: str):
        self._store = store
        self._key = key

    def get(self) -> _FakeSnapshot:
        return _FakeSnapshot(self._store.get(self._key))

    def set(self, data: dict, merge: bool = False) -> None:
        if merge and self._key in self._store:
            self._store[self._key] = {**self._store[self._key], **data}
        else:
            self._store[self._key] = dict(data)


class _FakeCollection:
    def __init__(self, store: dict):
        self._store = store

    def document(self, key: str) -> _FakeDocRef:
        return _FakeDocRef(self._store, key)


class _FakeDb:
    def __init__(self):
        self._collections: dict[str, dict] = {}

    def collection(self, name: str) -> _FakeCollection:
        return _FakeCollection(self._collections.setdefault(name, {}))


def test_verify_id_token_raises_value_error_on_missing_header():
    with pytest.raises(ValueError):
        profile_store.verify_id_token(None)


def test_verify_id_token_converts_expired_token_error_to_value_error(monkeypatch):
    """Regression guard: an expired/revoked/malformed token used to fall
    through as a raw firebase_admin exception, surfacing as an opaque 500
    instead of the 401 main.py's _require_uid maps ValueError to."""
    monkeypatch.setattr(profile_store, "_get_app", lambda: None)

    def _raise_expired(token):
        raise auth.ExpiredIdTokenError("Token expired", cause=None)

    monkeypatch.setattr(auth, "verify_id_token", _raise_expired)

    with pytest.raises(ValueError):
        profile_store.verify_id_token("Bearer some-expired-token")


def test_dedup_case_insensitive_preserves_existing_casing():
    result = profile_store._dedup_case_insensitive(["Nike", "Wood"], ["nike", "minimalist"])
    assert result == ["Nike", "Wood", "minimalist"]


def test_dedup_case_insensitive_drops_blank_terms():
    result = profile_store._dedup_case_insensitive(["Nike"], ["  ", "Adidas"])
    assert result == ["Nike", "Adidas"]


def test_find_conflicts_detects_overlap_case_insensitively():
    conflicts = profile_store._find_conflicts(["Floral", "minimalist"], ["floral", "leather"])
    assert conflicts == ["floral"]


def test_find_conflicts_empty_when_no_overlap():
    assert profile_store._find_conflicts(["minimalist"], ["leather"]) == []


def test_normalize_reviewed_patch_lets_ignore_terms_win():
    result = profile_store.normalize_reviewed_patch({
        "shopping_categories": ["Clothing", "Electronics"],
        "preference_terms": ["Cotton", "leather"],
        "ignore_terms": ["Leather", "clothes"],
    })

    assert result == {
        "shopping_categories": ["Electronics"],
        "preference_terms": ["Cotton"],
        "ignore_terms": ["Leather", "clothes"],
        "conflicts": [],
    }


def test_save_reviewed_profile_replaces_voice_fields_exactly(monkeypatch):
    fake_db = _FakeDb()
    fake_db._collections["UserProfiles"] = {
        "user-1": {
            "shopping_categories": ["Clothing", "Home Decor"],
            "preference_terms": ["Nike", "minimalist"],
            "ignore_terms": ["leather"],
            "country": "US",
        }
    }
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    result = profile_store.save_reviewed_profile(
        "user-1",
        {
            "shopping_categories": ["Home Decor"],
            "preference_terms": ["minimalist"],
            "ignore_terms": [],
        },
    )

    assert result["shopping_categories"] == ["Home Decor"]
    assert result["preference_terms"] == ["minimalist"]
    saved = fake_db._collections["UserProfiles"]["user-1"]
    assert saved["shopping_categories"] == ["Home Decor"]
    assert saved["preference_terms"] == ["minimalist"]
    assert saved["ignore_terms"] == []
    assert saved["country"] == "US"


def test_merge_and_save_unions_categories_and_terms(monkeypatch):
    fake_db = _FakeDb()
    fake_db._collections["UserProfiles"] = {
        "user-1": {
            "shopping_categories": ["Home Decor"],
            "preference_terms": ["Nike"],
            "ignore_terms": ["leather"],
        }
    }
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    result = profile_store.merge_and_save(
        "user-1",
        {
            "shopping_categories": ["Electronics"],
            "preference_terms": ["nike", "minimalist"],
            "ignore_terms": ["floral"],
        },
    )

    assert result["shopping_categories"] == ["Electronics", "Home Decor"]
    assert result["preference_terms"] == ["Nike", "minimalist"]
    assert result["ignore_terms"] == ["leather", "floral"]
    assert result["conflicts"] == []

    saved = fake_db._collections["UserProfiles"]["user-1"]
    assert saved["shopping_categories"] == ["Electronics", "Home Decor"]


def test_merge_and_save_surfaces_conflict_without_dropping_terms(monkeypatch):
    fake_db = _FakeDb()
    fake_db._collections["UserProfiles"] = {
        "user-1": {"shopping_categories": [], "preference_terms": ["leather"], "ignore_terms": []}
    }
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    result = profile_store.merge_and_save(
        "user-1", {"shopping_categories": [], "preference_terms": [], "ignore_terms": ["Leather"]}
    )

    assert "leather" in result["preference_terms"][0].lower() or "Leather" in result["preference_terms"]
    assert result["conflicts"] == ["leather"]


def test_merge_and_save_handles_new_profile(monkeypatch):
    fake_db = _FakeDb()
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    result = profile_store.merge_and_save(
        "new-user", {"shopping_categories": ["Clothing"], "preference_terms": ["denim"], "ignore_terms": []}
    )

    assert result["shopping_categories"] == ["Clothing"]
    assert result["preference_terms"] == ["denim"]
    assert result["conflicts"] == []


def test_merge_and_save_is_idempotent(monkeypatch):
    fake_db = _FakeDb()
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    patch = {"shopping_categories": ["Clothing"], "preference_terms": ["denim"], "ignore_terms": []}
    first = profile_store.merge_and_save("user-2", patch)
    second = profile_store.merge_and_save("user-2", patch)

    assert first == second


def test_get_profile_returns_empty_shape_for_missing_doc(monkeypatch):
    fake_db = _FakeDb()
    monkeypatch.setattr(profile_store, "_get_db", lambda: fake_db)

    profile = profile_store.get_profile("nobody")

    assert profile == {"shopping_categories": [], "preference_terms": [], "ignore_terms": []}
