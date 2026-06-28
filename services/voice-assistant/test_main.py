import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import main
import profile_store


@pytest.fixture
def client():
    return TestClient(main.app)


def test_start_session_requires_authorization_header(client):
    response = client.post("/voice/session/start")
    assert response.status_code == 401


def test_start_session_returns_session_id_and_profile(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(
        profile_store,
        "get_profile",
        lambda uid: {"shopping_categories": ["Clothing"], "preference_terms": [], "ignore_terms": []},
    )

    response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})

    assert response.status_code == 200
    body = response.json()
    assert "session_id" in body and body["session_id"]
    assert body["ws_url"] == f"/voice/session/{body['session_id']}/stream"
    assert body["profile"]["shopping_categories"] == ["Clothing"]


def test_finalize_session_requires_authorization_header(client):
    response = client.post("/voice/session/finalize", json={"session_id": "abc", "confirmed_patch": {}})
    assert response.status_code == 401


def test_finalize_session_saves_reviewed_patch_and_returns_result(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(
        profile_store,
        "save_reviewed_profile",
        lambda uid, patch: {
            "shopping_categories": patch.get("shopping_categories", []),
            "preference_terms": patch.get("preference_terms", []),
            "ignore_terms": patch.get("ignore_terms", []),
            "conflicts": [],
        },
    )

    response = client.post(
        "/voice/session/finalize",
        json={"session_id": "abc", "confirmed_patch": {"shopping_categories": ["Electronics"]}},
        headers={"Authorization": "Bearer faketoken"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["shopping_categories"] == ["Electronics"]
    assert body["conflicts"] == []


def test_start_session_defaults_to_preferences_mode_without_a_body(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.mode == "preferences"


def test_start_session_threads_search_mode_into_the_created_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post(
        "/voice/session/start", json={"mode": "search"}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.mode == "search"


def test_start_session_rejects_unknown_mode_value_by_falling_back_to_preferences(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post(
        "/voice/session/start", json={"mode": "not-a-real-mode"}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.mode == "preferences"


def test_start_session_defaults_to_english_without_a_language(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.language == "English"


def test_start_session_threads_language_into_the_created_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post(
        "/voice/session/start", json={"language": "Spanish"}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.language == "Spanish"


def test_start_session_rejects_unknown_language_value_by_falling_back_to_english(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post(
        "/voice/session/start", json={"language": "Klingon"}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    session = main.session_registry._sessions[response.json()["session_id"]]
    assert session.language == "English"


def test_session_event_requires_authorization_header(client):
    response = client.post("/voice/session/event", json={"session_id": "abc", "event_type": "stop"})
    assert response.status_code == 401


def test_session_event_acknowledges(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")

    response = client.post(
        "/voice/session/event",
        json={"session_id": "abc", "event_type": "user_stopped"},
        headers={"Authorization": "Bearer faketoken"},
    )

    assert response.status_code == 200
    assert response.json() == {"status": "received"}


def test_websocket_stream_closes_for_unknown_session(client):
    with pytest.raises(WebSocketDisconnect) as exc_info:
        with client.websocket_connect("/voice/session/unknown-session-id/stream"):
            pass
    assert exc_info.value.code == 4004


def test_health_reports_status_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
