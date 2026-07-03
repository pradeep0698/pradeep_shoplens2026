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


def test_cancel_session_requires_authorization_header(client):
    response = client.post("/voice/session/cancel", json={"session_id": "abc"})
    assert response.status_code == 401


def test_cancel_session_deletes_the_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    start_response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})
    session_id = start_response.json()["session_id"]
    assert session_id in main.session_registry._sessions

    response = client.post(
        "/voice/session/cancel", json={"session_id": session_id}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    assert response.json() == {"status": "cancelled"}
    assert session_id not in main.session_registry._sessions


def test_cancel_session_is_idempotent_for_unknown_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")

    response = client.post(
        "/voice/session/cancel", json={"session_id": "does-not-exist"}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    assert response.json() == {"status": "cancelled"}


def test_cancel_session_does_not_delete_a_different_users_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    start_response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})
    session_id = start_response.json()["session_id"]

    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-2")
    response = client.post(
        "/voice/session/cancel", json={"session_id": session_id}, headers={"Authorization": "Bearer faketoken"}
    )

    assert response.status_code == 200
    assert session_id in main.session_registry._sessions


def test_start_session_resumes_an_owned_disconnected_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    start_response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})
    session_id = start_response.json()["session_id"]
    session = main.session_registry._sessions[session_id]
    import time as _time
    session.transcript.append({"role": "user", "text": "I like minimalist furniture"})
    session.latest_patch["preference_terms"] = ["minimalist"]
    session.disconnected_at = _time.monotonic() - 10  # disconnected 10s ago, still within the grace period

    resume_response = client.post(
        "/voice/session/start",
        json={"resume_session_id": session_id},
        headers={"Authorization": "Bearer faketoken"},
    )

    assert resume_response.status_code == 200
    assert resume_response.json()["session_id"] == session_id
    resumed_session = main.session_registry._sessions[session_id]
    assert resumed_session.transcript == [{"role": "user", "text": "I like minimalist furniture"}]
    assert resumed_session.latest_patch["preference_terms"] == ["minimalist"]
    assert resumed_session.disconnected_at is None


def test_start_session_falls_back_to_fresh_session_for_unknown_resume_id(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    response = client.post(
        "/voice/session/start",
        json={"resume_session_id": "does-not-exist"},
        headers={"Authorization": "Bearer faketoken"},
    )

    assert response.status_code == 200
    session_id = response.json()["session_id"]
    assert session_id != "does-not-exist"
    assert session_id in main.session_registry._sessions


def test_start_session_does_not_resume_a_different_users_session(client, monkeypatch):
    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-1")
    monkeypatch.setattr(profile_store, "get_profile", lambda uid: {})

    import time as _time
    start_response = client.post("/voice/session/start", headers={"Authorization": "Bearer faketoken"})
    other_session_id = start_response.json()["session_id"]
    main.session_registry._sessions[other_session_id].disconnected_at = _time.monotonic() - 10

    monkeypatch.setattr(profile_store, "verify_id_token", lambda header: "user-2")
    response = client.post(
        "/voice/session/start",
        json={"resume_session_id": other_session_id},
        headers={"Authorization": "Bearer faketoken"},
    )

    assert response.status_code == 200
    assert response.json()["session_id"] != other_session_id


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
