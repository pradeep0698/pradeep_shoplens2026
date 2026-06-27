import asyncio
import json
import time
import types as pytypes

import pytest

import live_session
import profile_store
from live_session import (
    SEARCH_PRODUCTS,
    SessionRegistry,
    SessionState,
    VOICE_CATEGORIES,
    _auto_save_and_close,
    _classify_clause,
    _dispatch_tool_call,
    _extract_patch_from_transcript,
    _filter_categories,
    _is_closing_phrase,
    _live_config,
    _match_mock_category,
    _next_mock_prompt,
    _on_user_turn,
    _profile_note,
    _pump_client_to_gemini,
    _pump_gemini_to_client,
    _run_mock_session,
    _run_pumps,
    _send_greeting_trigger,
    _send_timeout_nudge,
    _split_clauses,
    _strip_filler,
    _system_prompt,
    _watch_inactivity,
)


class _FakeWebSocket:
    def __init__(self, messages: list[dict]):
        self._messages = list(messages) + [{"type": "websocket.disconnect"}]
        self.sent_json: list[dict] = []

    async def receive(self) -> dict:
        return self._messages.pop(0)

    async def send_json(self, data: dict) -> None:
        self.sent_json.append(data)


def _text_message(text: str) -> dict:
    return {"bytes": None, "text": json.dumps({"type": "text", "text": text})}


class _FakeGeminiSession:
    def __init__(self):
        self.audio_calls: list = []
        self.text_calls: list = []
        self.activity_calls: list = []

    async def send_realtime_input(self, audio=None, text=None, activity_start=None, activity_end=None):
        if audio is not None:
            self.audio_calls.append(audio)
        if text is not None:
            self.text_calls.append(text)
        if activity_start is not None:
            self.activity_calls.append("start")
        if activity_end is not None:
            self.activity_calls.append("end")


class _HangingWebSocket:
    """A websocket whose receive() never resolves — simulates the client
    side going quiet, used to force _run_pumps to actually hit its timeout
    rather than ending early."""

    async def receive(self):
        await asyncio.Event().wait()

    async def send_json(self, data: dict) -> None:
        pass

    async def send_bytes(self, data: bytes) -> None:
        pass


class _HangingGeminiSession:
    """Combines a no-op send_realtime_input with a receive() that never
    yields anything — simulates Gemini having nothing more to relay once
    the client side has already finished, so _run_pumps can be tested for
    promptly stopping the other pump instead of waiting out the full budget."""

    async def send_realtime_input(self, audio=None, text=None, activity_start=None, activity_end=None):
        pass

    async def receive(self):
        await asyncio.Event().wait()
        return
        yield  # pragma: no cover - unreachable; makes this an async generator


class _FakeSessionClosed(Exception):
    """Sentinel raised once _FakeGeminiLiveSession's canned responses are
    exhausted. Mirrors the real SDK: receive() is a per-turn generator that
    ends right after a turn_complete message, so _pump_gemini_to_client calls
    it again for the next turn — this fake needs to stop that outer loop once
    there's nothing left to replay, instead of yielding the same list forever."""


class _FakeGeminiLiveSession:
    """Fake for the receive()/send_tool_response() side used by
    _pump_gemini_to_client. receive() mimics the real SDK (see
    google.genai.live.AsyncSession.receive): each call yields canned responses
    up to and including the next turn_complete message, then ends; a later
    call resumes from where it left off, and once the list is exhausted it
    raises _FakeSessionClosed instead of looping forever."""

    def __init__(self, responses: list):
        self._responses = list(responses)
        self._index = 0
        self.tool_responses: list = []

    async def receive(self):
        sent_any = False
        while self._index < len(self._responses):
            response = self._responses[self._index]
            self._index += 1
            sent_any = True
            yield response
            server_content = getattr(response, "server_content", None)
            if server_content is not None and getattr(server_content, "turn_complete", False):
                return
        if not sent_any:
            raise _FakeSessionClosed()

    async def send_tool_response(self, function_responses):
        self.tool_responses.append(function_responses)


def _server_content_response(
    *, interrupted=False, input_text=None, output_text=None, turn_complete=True,
    input_finished=None, output_finished=None,
):
    # finished defaults to turn_complete when not given explicitly, so tests
    # that only care about turn_complete-driven (fallback) flushing keep
    # working unchanged — pass input_finished/output_finished explicitly to
    # exercise the primary, turn_complete-independent flush path instead.
    if input_finished is None:
        input_finished = turn_complete
    if output_finished is None:
        output_finished = turn_complete
    return pytypes.SimpleNamespace(
        server_content=pytypes.SimpleNamespace(
            interrupted=interrupted,
            model_turn=None,
            input_transcription=pytypes.SimpleNamespace(text=input_text, finished=input_finished) if input_text else None,
            output_transcription=pytypes.SimpleNamespace(text=output_text, finished=output_finished) if output_text else None,
            turn_complete=turn_complete,
        ),
        tool_call=None,
    )


def _tool_call_response(name: str, args: dict, call_id: str = "call-1"):
    call = pytypes.SimpleNamespace(name=name, args=args, id=call_id)
    return pytypes.SimpleNamespace(
        server_content=None,
        tool_call=pytypes.SimpleNamespace(function_calls=[call]),
    )


def test_filter_categories_keeps_only_valid_enum_values():
    result = _filter_categories(["Electronics", "Not-A-Category", "Home Decor"])
    assert result == ["Electronics", "Home Decor"]


def test_filter_categories_handles_none_and_empty():
    assert _filter_categories(None) == []
    assert _filter_categories([]) == []


def test_filter_categories_requires_evidence_when_text_is_available():
    assert _filter_categories(["Sports & Outdoors"], "I like cotton materials") == []
    assert _filter_categories(["Clothing"], "I shop for clothes") == ["Clothing"]


def test_voice_categories_has_exactly_the_eight_fixed_values():
    assert VOICE_CATEGORIES == [
        "Furniture",
        "Clothing",
        "Kitchen & Cookware",
        "Accessories",
        "Electronics",
        "Home Decor",
        "Sports & Outdoors",
        "Books & Stationery",
    ]


@pytest.mark.asyncio
async def test_session_registry_create_and_get_roundtrip():
    registry = SessionRegistry()
    state = await registry.create(uid="user-1", existing_profile={"shopping_categories": []})

    fetched = await registry.get(state.session_id)

    assert fetched is not None
    assert fetched.uid == "user-1"


@pytest.mark.asyncio
async def test_session_registry_get_returns_none_for_unknown_id():
    registry = SessionRegistry()
    assert await registry.get("does-not-exist") is None


@pytest.mark.asyncio
async def test_session_registry_expires_and_evicts_stale_sessions(monkeypatch):
    monkeypatch.setattr(live_session, "_SESSION_MAX_SECONDS", 0)
    registry = SessionRegistry()
    state = await registry.create(uid="user-1", existing_profile={})
    state.created_at = time.monotonic() - 5

    assert await registry.get(state.session_id) is None


def test_profile_note_empty_profile_says_first_time():
    note = _profile_note({"shopping_categories": [], "preference_terms": [], "ignore_terms": []})
    assert "no saved preferences yet" in note


def test_profile_note_summarizes_existing_data():
    note = _profile_note({
        "shopping_categories": ["Clothing"],
        "preference_terms": ["Nike"],
        "ignore_terms": ["leather"],
    })
    assert "shops for Clothing" in note
    assert "likes Nike" in note
    assert "avoids leather" in note


def test_system_prompt_embeds_profile_note():
    prompt = _system_prompt(
        {"shopping_categories": ["Electronics"], "preference_terms": [], "ignore_terms": []}, "preferences"
    )
    assert "shops for Electronics" in prompt
    assert "ready_to_finalize" in prompt


def test_system_prompt_tells_model_to_mention_finishing_in_greeting():
    """The user has no way to end the conversation other than the model
    deciding to wrap up — the opening greeting should tell them they can say
    "I'm done" (or tap the done button) any time, mirroring the mock
    greeting in _run_mock_session."""
    prompt = _system_prompt({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    assert "i'm done" in prompt.lower()


def test_system_prompt_search_mode_uses_search_template_and_tool():
    prompt = _system_prompt({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "search")
    assert "search_products" in prompt
    assert "ready_to_finalize" not in prompt


def test_system_prompt_search_mode_asks_follow_up_before_searching_vague_request():
    """Every search_products call costs a real SerpAPI request — the prompt
    should steer the model to narrow down a bare/vague request with a
    follow-up before searching, instead of searching on the first mention."""
    prompt = _system_prompt({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "search")
    assert "follow-up" in prompt.lower()
    assert "distinguishing detail" in prompt.lower()


def test_system_prompt_search_mode_avoids_repeat_searches_for_rephrasing():
    prompt = _system_prompt({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "search")
    assert "rephrased" in prompt.lower()


def test_system_prompt_preferences_mode_follows_up_on_same_category_before_moving_on():
    prompt = _system_prompt({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    assert "same category" in prompt.lower()


def test_live_config_defaults_to_puck_voice():
    config = _live_config({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    assert config.speech_config.voice_config.prebuilt_voice_config.voice_name == "Puck"


def test_live_config_respects_voice_name_env_override(monkeypatch):
    monkeypatch.setattr(live_session, "_VOICE_NAME", "Kore")
    config = _live_config({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    assert config.speech_config.voice_config.prebuilt_voice_config.voice_name == "Kore"


def test_live_config_disables_automatic_activity_detection():
    """Turn boundaries are now driven by the client's hold-to-talk button
    (speech_start/speech_end -> activity_start/activity_end), not Gemini's
    own VAD over the resampled mic audio."""
    config = _live_config({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    assert config.realtime_input_config.automatic_activity_detection.disabled is True


def test_live_config_preferences_mode_uses_preference_tools():
    config = _live_config({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "preferences")
    names = {fn.name for tool in config.tools for fn in tool.function_declarations}
    assert names == {"ready_to_finalize", "record_preference"}


def test_live_config_search_mode_uses_search_tool():
    config = _live_config({"shopping_categories": [], "preference_terms": [], "ignore_terms": []}, "search")
    names = {fn.name for tool in config.tools for fn in tool.function_declarations}
    assert names == {"search_products"}


def test_search_products_tool_description_requires_a_distinguishing_detail():
    description = SEARCH_PRODUCTS.description.lower()
    assert "distinguishing detail" in description
    assert "bare category" in description


@pytest.mark.asyncio
async def test_send_greeting_trigger_sends_a_complete_hidden_turn():
    """Uses send_realtime_input (activity_start -> text -> activity_end), not
    send_client_content — see _send_greeting_trigger's docstring: mixing the
    two APIs in the same session silently breaks both the greeting and
    subsequent voice turns (confirmed against the real API)."""
    gemini = _FakeGeminiSession()

    await _send_greeting_trigger(gemini)

    assert gemini.activity_calls == ["start", "end"]
    assert len(gemini.text_calls) == 1
    assert "just opened the conversation" in gemini.text_calls[0]


@pytest.mark.asyncio
async def test_dispatch_ready_to_finalize_packages_existing_latest_patch():
    """ready_to_finalize must NOT re-run _extract_patch_from_transcript — that
    reads the (sometimes-wrong) transcribed caption, which would re-introduce
    caption errors into the final save. It just packages up whatever
    record_preference has already accumulated in latest_patch."""
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.latest_patch = {"shopping_categories": ["Clothing"], "preference_terms": ["Nike"], "ignore_terms": []}

    await _dispatch_tool_call("ready_to_finalize", {"summary": "Saving Clothing."}, session)

    assert session.finalize_proposal == {
        "shopping_categories": ["Clothing"],
        "preference_terms": ["Nike"],
        "ignore_terms": [],
        "summary": "Saving Clothing.",
    }


@pytest.mark.asyncio
async def test_dispatch_record_preference_merges_into_latest_patch():
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    result = await _dispatch_tool_call(
        "record_preference",
        {"shopping_categories": ["Clothing", "Not-A-Category"], "preference_terms": ["Nike"], "ignore_terms": ["leather"]},
        session,
    )

    assert result == {"status": "recorded"}
    assert session.latest_patch["shopping_categories"] == ["Clothing"]
    assert session.latest_patch["preference_terms"] == ["Nike"]
    assert session.latest_patch["ignore_terms"] == ["leather"]


@pytest.mark.asyncio
async def test_dispatch_record_preference_accumulates_and_dedupes_across_calls():
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _dispatch_tool_call("record_preference", {"preference_terms": ["Nike"]}, session)
    await _dispatch_tool_call("record_preference", {"shopping_categories": ["Clothing"], "preference_terms": ["nike", "Adidas"]}, session)

    assert session.latest_patch["shopping_categories"] == ["Clothing"]
    # "nike" deduped case-insensitively against the already-recorded "Nike".
    assert session.latest_patch["preference_terms"] == ["Nike", "Adidas"]


@pytest.mark.asyncio
async def test_dispatch_record_preference_ignore_term_removes_matching_category():
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.transcript.append({"role": "user", "text": "I shop for clothes"})

    await _dispatch_tool_call("record_preference", {"shopping_categories": ["Clothing"]}, session)
    await _dispatch_tool_call("record_preference", {"ignore_terms": ["clothes"]}, session)

    assert session.latest_patch["shopping_categories"] == []
    assert session.latest_patch["ignore_terms"] == ["clothes"]


@pytest.mark.asyncio
async def test_dispatch_search_products_calls_search_and_returns_products(monkeypatch):
    captured = {}

    async def fake_search(query, max_results):
        captured["query"] = query
        captured["max_results"] = max_results
        return [{"name": "Wireless Headphones", "price": 29.99}]

    monkeypatch.setattr(live_session, "_search_shopping", fake_search)
    session = SessionState(
        session_id="s1", uid="user-1", existing_profile={"max_searches_per_run": 3}, mode="search"
    )

    result = await _dispatch_tool_call("search_products", {"query": "wireless headphones"}, session)

    assert captured == {"query": "wireless headphones", "max_results": 3}
    assert result == {
        "status": "found",
        "query": "wireless headphones",
        "products": [{"name": "Wireless Headphones", "price": 29.99}],
    }


@pytest.mark.asyncio
async def test_dispatch_search_products_clamps_max_results_to_ceiling(monkeypatch):
    captured = {}

    async def fake_search(query, max_results):
        captured["max_results"] = max_results
        return []

    monkeypatch.setattr(live_session, "_search_shopping", fake_search)
    session = SessionState(
        session_id="s1", uid="user-1", existing_profile={"max_searches_per_run": 99}, mode="search"
    )

    result = await _dispatch_tool_call("search_products", {"query": "lamp"}, session)

    assert captured["max_results"] == 5
    assert result["status"] == "no_results"


@pytest.mark.asyncio
async def test_dispatch_search_products_ignores_blank_query():
    session = SessionState(session_id="s1", uid="user-1", existing_profile={}, mode="search")

    result = await _dispatch_tool_call("search_products", {"query": "   "}, session)

    assert result == {"status": "error", "query": "", "products": []}


@pytest.mark.asyncio
async def test_dispatch_unknown_tool_returns_unknown_status():
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    result = await _dispatch_tool_call("not_a_real_tool", {}, session)

    assert result == {"status": "unknown_tool"}


@pytest.mark.asyncio
async def test_pump_client_to_gemini_forwards_audio_bytes():
    ws = _FakeWebSocket([{"bytes": b"\x01\x02", "text": None}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert len(gemini.audio_calls) == 1
    assert gemini.audio_calls[0].data == b"\x01\x02"
    assert gemini.audio_calls[0].mime_type == "audio/pcm;rate=16000"


@pytest.mark.asyncio
async def test_pump_client_to_gemini_audio_format_frame_updates_declared_rate():
    """Regression guard: on web, record_web silently captures mic audio at
    whatever rate the browser's AudioContext settles on (never the requested
    16000) — the client reports the real rate via this frame so Gemini isn't
    told the wrong rate and fails to recognize speech."""
    ws = _FakeWebSocket([
        {"bytes": None, "text": json.dumps({"type": "audio_format", "sample_rate": 16000})},
        {"bytes": b"\x01\x02", "text": None},
    ])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert session.input_sample_rate == 16000
    assert gemini.audio_calls[0].mime_type == "audio/pcm;rate=16000"


@pytest.mark.asyncio
async def test_pump_client_to_gemini_ignores_malformed_audio_format_frame():
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "audio_format", "sample_rate": "not-a-number"})}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert session.input_sample_rate == 16000


@pytest.mark.asyncio
async def test_pump_client_to_gemini_forwards_text_frame_via_realtime_input(monkeypatch):
    """Typed text also goes through send_realtime_input (bracketed by
    activity_start/activity_end), not send_client_content — keeping the
    whole session on one API, since mixing the two silently breaks turns."""
    monkeypatch.setattr(
        live_session,
        "_extract_patch_from_transcript",
        lambda transcript, existing_profile: {
            "shopping_categories": [], "preference_terms": ["minimalist style"], "ignore_terms": [],
        },
    )
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "text", "text": "minimalist style"})}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.activity_calls == ["start", "end"]
    assert gemini.text_calls == ["minimalist style"]
    assert session.transcript == [{"role": "user", "text": "minimalist style"}]
    patch_frames = [m for m in ws.sent_json if m.get("type") == "preference_patch"]
    assert patch_frames[-1]["patch"]["preference_terms"] == ["minimalist style"]


@pytest.mark.asyncio
async def test_pump_client_to_gemini_ignores_blank_text():
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "text", "text": "   "})}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.text_calls == []
    assert session.transcript == []


@pytest.mark.asyncio
async def test_pump_client_to_gemini_closing_text_sends_finalize_proposal_without_model_turn():
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "text", "text": "I'm done"})}])
    gemini = _FakeGeminiSession()
    session = SessionState(
        session_id="s1",
        uid="user-1",
        existing_profile={"shopping_categories": ["Clothing"], "preference_terms": [], "ignore_terms": []},
    )

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.text_calls == []
    assert gemini.activity_calls == []
    assert session.finalize_proposal["shopping_categories"] == ["Clothing"]
    finalize_frames = [m for m in ws.sent_json if m.get("type") == "finalize_proposal"]
    assert len(finalize_frames) == 1


@pytest.mark.asyncio
async def test_pump_client_to_gemini_search_mode_ignores_closing_phrase_and_skips_extraction(monkeypatch):
    """Search mode has no review/save step — "I'm done" should just be sent
    to the model like any other turn, and typed text should never trigger
    the preference-extraction call or a preference_patch frame."""
    extraction_calls = []
    monkeypatch.setattr(
        live_session, "_extract_patch_from_transcript",
        lambda transcript, existing_profile: extraction_calls.append(1),
    )
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "text", "text": "I'm done"})}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={}, mode="search")

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.text_calls == ["I'm done"]
    assert gemini.activity_calls == ["start", "end"]
    assert session.finalize_proposal is None
    assert extraction_calls == []
    assert not any(m.get("type") == "preference_patch" for m in ws.sent_json)


@pytest.mark.asyncio
async def test_pump_client_to_gemini_forwards_speech_start_and_end_as_activity_markers():
    ws = _FakeWebSocket([
        {"bytes": None, "text": json.dumps({"type": "speech_start"})},
        {"bytes": b"\x01\x02", "text": None},
        {"bytes": None, "text": json.dumps({"type": "speech_end"})},
    ])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.activity_calls == ["start", "end"]
    assert len(gemini.audio_calls) == 1


@pytest.mark.asyncio
async def test_pump_client_to_gemini_ignores_non_text_control_frames():
    ws = _FakeWebSocket([{"bytes": None, "text": json.dumps({"type": "end_turn"})}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.text_calls == []
    assert gemini.audio_calls == []


@pytest.mark.asyncio
async def test_pump_client_to_gemini_ignores_malformed_text_frame():
    ws = _FakeWebSocket([{"bytes": None, "text": "not json"}])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _pump_client_to_gemini(ws, gemini, session)

    assert gemini.text_calls == []


# --- _on_user_turn / _extract_patch_from_transcript / _pump_gemini_to_client ---


@pytest.mark.asyncio
async def test_on_user_turn_records_transcript_without_running_extraction(monkeypatch):
    """Regression guard: _on_user_turn must NOT call _extract_patch_from_transcript
    anymore — voice turns rely solely on record_preference (Gemini's own
    understanding) for structured data now, since the text passed here can be
    a wrong caption even when Gemini understood correctly."""
    extraction_calls = []
    monkeypatch.setattr(
        live_session, "_extract_patch_from_transcript",
        lambda transcript, existing_profile: extraction_calls.append(1),
    )
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _on_user_turn(ws, session, "I shop for electronics")

    assert session.transcript == [{"role": "user", "text": "I shop for electronics"}]
    assert {"type": "transcript", "role": "user", "text": "I shop for electronics", "final": True} in ws.sent_json
    assert extraction_calls == []
    assert not any(m.get("type") == "preference_patch" for m in ws.sent_json)


def test_extract_patch_from_transcript_parses_and_filters_categories(monkeypatch):
    class _FakeResponse:
        text = json.dumps({
            "shopping_categories": ["Clothing", "NotACategory"],
            "preference_terms": ["Nike"],
            "ignore_terms": ["leather"],
        })

    class _FakeModels:
        @staticmethod
        def generate_content(**kwargs):
            return _FakeResponse()

    class _FakeClient:
        models = _FakeModels()

    monkeypatch.setattr(live_session, "_get_client", lambda: _FakeClient())

    result = _extract_patch_from_transcript([{"role": "user", "text": "I like Nike, avoid leather"}], {})

    assert result == {
        "shopping_categories": ["Clothing"],
        "preference_terms": ["Nike"],
        "ignore_terms": ["leather"],
    }


def test_extract_patch_from_transcript_falls_back_to_existing_profile_on_error(monkeypatch):
    class _BrokenModels:
        @staticmethod
        def generate_content(**kwargs):
            raise RuntimeError("boom")

    class _BrokenClient:
        models = _BrokenModels()

    monkeypatch.setattr(live_session, "_get_client", lambda: _BrokenClient())
    existing = {"shopping_categories": ["Clothing"], "preference_terms": [], "ignore_terms": []}

    result = _extract_patch_from_transcript([], existing)

    assert result == existing


@pytest.mark.asyncio
async def test_pump_gemini_to_client_forwards_interrupted_flag():
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([_server_content_response(interrupted=True)])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert {"type": "interrupted"} in ws.sent_json


@pytest.mark.asyncio
async def test_pump_gemini_to_client_clears_pending_buffers_on_interrupt():
    """Regression guard: a barge-in mid-turn must not let that turn's
    already-buffered fragments bleed into the next turn's transcript."""
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.pending_input_transcript = "stale user fragment"
    session.pending_output_transcript = "stale model fragment"
    gemini = _FakeGeminiLiveSession([_server_content_response(interrupted=True, turn_complete=False)])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.pending_input_transcript == ""
    assert session.pending_output_transcript == ""


@pytest.mark.asyncio
async def test_pump_gemini_to_client_records_output_transcription():
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([_server_content_response(output_text="Hi there!")])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [{"role": "model", "text": "Hi there!"}]
    assert {"type": "transcript", "role": "model", "text": "Hi there!", "final": True} in ws.sent_json


@pytest.mark.asyncio
async def test_pump_gemini_to_client_buffers_output_fragments_until_turn_complete():
    """Regression guard: Gemini streams output_transcription as many small
    fragments rather than one block per turn — without buffering, each
    fragment became its own transcript bubble client-side."""
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([
        _server_content_response(output_text="Hi ", turn_complete=False),
        _server_content_response(output_text="there!", turn_complete=True),
    ])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [{"role": "model", "text": "Hi there!"}]
    transcript_frames = [m for m in ws.sent_json if m.get("type") == "transcript"]
    assert len(transcript_frames) == 1
    assert transcript_frames[0]["text"] == "Hi there!"


@pytest.mark.asyncio
async def test_pump_gemini_to_client_buffers_input_fragments_until_turn_complete(monkeypatch):
    monkeypatch.setattr(
        live_session,
        "_extract_patch_from_transcript",
        lambda transcript, existing_profile: {
            "shopping_categories": [], "preference_terms": [], "ignore_terms": [],
        },
    )
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([
        _server_content_response(input_text="I like ", turn_complete=False),
        _server_content_response(input_text="sneakers", turn_complete=True),
    ])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [{"role": "user", "text": "I like sneakers"}]
    transcript_frames = [m for m in ws.sent_json if m.get("type") == "transcript"]
    assert len(transcript_frames) == 1


@pytest.mark.asyncio
async def test_pump_gemini_to_client_flushes_input_on_finished_even_without_turn_complete():
    """Regression guard: the SDK's own docs say input_transcription has no
    ordering relationship with turn_complete — flushing only on turn_complete
    grabbed whatever happened to be buffered at an unrelated moment,
    producing a coherent-but-wrong transcript. Transcription.finished is the
    real per-stream completion signal and must flush on its own."""
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([
        _server_content_response(input_text="I mostly like clothing and skincare", turn_complete=False, input_finished=True),
    ])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [{"role": "user", "text": "I mostly like clothing and skincare"}]


@pytest.mark.asyncio
async def test_pump_gemini_to_client_does_not_flush_on_turn_complete_alone_if_not_finished():
    """The flip side of the regression guard above: turn_complete firing
    must NOT, by itself, flush a fragment that was never marked finished —
    there's no guaranteed ordering between transcription and turn_complete
    per the SDK's docs, so a turn_complete-triggered fallback could itself
    flush an incomplete/wrong fragment early, recreating the exact bug this
    fixes. There is deliberately no such fallback."""
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([
        _server_content_response(output_text="partial", turn_complete=True, output_finished=False),
    ])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == []
    assert session.pending_output_transcript == "partial"


@pytest.mark.asyncio
async def test_pump_gemini_to_client_input_transcription_records_without_extraction(monkeypatch):
    """A completed voice turn still records the (possibly-wrong) caption into
    the transcript for display, but no longer runs structured extraction
    against it — record_preference tool calls are the only source of
    structured data for voice now (see _on_user_turn)."""
    extraction_calls = []
    monkeypatch.setattr(
        live_session, "_extract_patch_from_transcript",
        lambda transcript, existing_profile: extraction_calls.append(1),
    )
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([_server_content_response(input_text="I like clothes")])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [{"role": "user", "text": "I like clothes"}]
    assert extraction_calls == []
    assert session.latest_patch == {"shopping_categories": [], "preference_terms": [], "ignore_terms": []}


@pytest.mark.asyncio
async def test_pump_gemini_to_client_closing_voice_transcript_sends_finalize_proposal():
    ws = _FakeWebSocket([])
    session = SessionState(
        session_id="s1",
        uid="user-1",
        existing_profile={"shopping_categories": ["Clothing"], "preference_terms": [], "ignore_terms": []},
    )
    gemini = _FakeGeminiLiveSession([_server_content_response(input_text="I'm done")])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.finalize_proposal["shopping_categories"] == ["Clothing"]
    finalize_frames = [m for m in ws.sent_json if m.get("type") == "finalize_proposal"]
    assert len(finalize_frames) == 1


@pytest.mark.asyncio
async def test_pump_gemini_to_client_search_mode_closing_voice_transcript_does_not_finalize():
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={}, mode="search")
    gemini = _FakeGeminiLiveSession([_server_content_response(input_text="I'm done")])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.finalize_proposal is None
    assert not any(m.get("type") == "finalize_proposal" for m in ws.sent_json)


@pytest.mark.asyncio
async def test_pump_gemini_to_client_ready_to_finalize_tool_call_sends_proposal():
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.latest_patch = {"shopping_categories": [], "preference_terms": ["Nike"], "ignore_terms": []}
    gemini = _FakeGeminiLiveSession([_tool_call_response("ready_to_finalize", {"summary": "Saving your style."})])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.finalize_proposal["summary"] == "Saving your style."
    assert session.finalize_proposal["preference_terms"] == ["Nike"]
    proposal_frames = [m for m in ws.sent_json if m.get("type") == "finalize_proposal"]
    assert len(proposal_frames) == 1
    assert len(gemini.tool_responses) == 1


@pytest.mark.asyncio
async def test_pump_gemini_to_client_record_preference_tool_call_sends_patch():
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    gemini = _FakeGeminiLiveSession([_tool_call_response("record_preference", {"preference_terms": ["Nike"]})])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.latest_patch["preference_terms"] == ["Nike"]
    patch_frames = [m for m in ws.sent_json if m.get("type") == "preference_patch"]
    assert len(patch_frames) == 1
    assert patch_frames[0]["patch"]["preference_terms"] == ["Nike"]


@pytest.mark.asyncio
async def test_pump_gemini_to_client_search_products_tool_call_sends_product_results(monkeypatch):
    async def fake_search(query, max_results):
        return [{"name": "Wireless Headphones", "price": 29.99}]

    monkeypatch.setattr(live_session, "_search_shopping", fake_search)
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={}, mode="search")
    gemini = _FakeGeminiLiveSession([_tool_call_response("search_products", {"query": "wireless headphones"})])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    result_frames = [m for m in ws.sent_json if m.get("type") == "product_results"]
    assert len(result_frames) == 1
    assert result_frames[0]["query"] == "wireless headphones"
    assert result_frames[0]["products"] == [{"name": "Wireless Headphones", "price": 29.99}]
    assert len(gemini.tool_responses) == 1


@pytest.mark.asyncio
async def test_pump_gemini_to_client_relays_a_second_turn_after_the_first_completes():
    """Regression guard: gemini_session.receive() ends after each turn_complete
    by SDK design (see _FakeGeminiLiveSession docstring) — _pump_gemini_to_client
    must call receive() again to pick up the next turn, or every turn after the
    first one silently never reaches the client."""
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    first_turn = pytypes.SimpleNamespace(
        server_content=pytypes.SimpleNamespace(
            interrupted=False, model_turn=None, input_transcription=None,
            output_transcription=pytypes.SimpleNamespace(text="First reply", finished=True),
            turn_complete=True,
        ),
        tool_call=None,
    )
    second_turn = pytypes.SimpleNamespace(
        server_content=pytypes.SimpleNamespace(
            interrupted=False, model_turn=None, input_transcription=None,
            output_transcription=pytypes.SimpleNamespace(text="Second reply", finished=True),
            turn_complete=True,
        ),
        tool_call=None,
    )
    gemini = _FakeGeminiLiveSession([first_turn, second_turn])

    with pytest.raises(_FakeSessionClosed):
        await _pump_gemini_to_client(ws, gemini, session)

    assert session.transcript == [
        {"role": "model", "text": "First reply"},
        {"role": "model", "text": "Second reply"},
    ]


# --- Mock-only heuristics ----------------------------------------------------


def test_is_closing_phrase_matches_bare_no():
    assert _is_closing_phrase("No") is True
    assert _is_closing_phrase("that's all") is True
    assert _is_closing_phrase("  Done.  ") is True


def test_is_closing_phrase_does_not_match_no_with_content():
    assert _is_closing_phrase("no plastic items") is False
    assert _is_closing_phrase("avoid leather") is False


def test_split_clauses_splits_on_and_and_commas():
    assert _split_clauses("skincare and cooking appliances") == ["skincare", "cooking appliances"]
    assert _split_clauses("Nike, minimalist, no leather") == ["Nike", "minimalist", "no leather"]


def test_strip_filler_removes_leading_phrase():
    assert _strip_filler("show me skincare") == "skincare"
    assert _strip_filler("i like minimalist design") == "minimalist design"
    assert _strip_filler("plain text") == "plain text"


def test_match_mock_category_matches_by_keyword_not_literal_name():
    assert _match_mock_category("cooking appliances") == "Kitchen & Cookware"
    assert _match_mock_category("skincare") is None


def test_classify_clause_routes_category_ignore_and_preference():
    assert _classify_clause("cooking appliances") == ("category", "Kitchen & Cookware")
    assert _classify_clause("no plastic items") == ("ignore", "plastic items")
    assert _classify_clause("avoid leather") == ("ignore", "leather")
    assert _classify_clause("minimalist style") == ("preference", "minimalist style")


@pytest.mark.asyncio
async def test_run_mock_session_splits_compound_message_into_separate_buckets():
    ws = _FakeWebSocket([_text_message("Show me skincare and cooking appliances")])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.latest_patch["shopping_categories"] == ["Kitchen & Cookware"]
    assert session.latest_patch["preference_terms"] == ["skincare"]


@pytest.mark.asyncio
async def test_run_mock_session_bare_no_triggers_finalize_when_content_exists():
    ws = _FakeWebSocket([_text_message("Nike sneakers"), _text_message("No")])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.finalize_proposal is not None
    assert session.finalize_proposal["preference_terms"] == ["Nike sneakers"]
    finalize_frames = [m for m in ws.sent_json if m.get("type") == "finalize_proposal"]
    assert len(finalize_frames) == 1


@pytest.mark.asyncio
async def test_run_mock_session_bare_no_without_content_does_not_finalize():
    ws = _FakeWebSocket([_text_message("No")])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.finalize_proposal is None
    assert not any(m.get("type") == "finalize_proposal" for m in ws.sent_json)


@pytest.mark.asyncio
async def test_run_mock_session_exclusion_phrase_goes_to_ignore_terms():
    ws = _FakeWebSocket([_text_message("no plastic items")])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.latest_patch["ignore_terms"] == ["plastic items"]
    assert session.latest_patch["preference_terms"] == []


@pytest.mark.asyncio
async def test_run_mock_session_accepts_more_than_two_turns():
    ws = _FakeWebSocket([
        _text_message("Nike"),
        _text_message("minimalist"),
        _text_message("Adidas"),
        _text_message("that's all"),
    ])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.finalize_proposal is not None
    assert set(session.finalize_proposal["preference_terms"]) == {"Nike", "minimalist", "Adidas"}


def test_split_clauses_splits_on_sentence_boundaries():
    text = "household essentials. I usually look for affordable options"
    assert _split_clauses(text) == ["household essentials", "I usually look for affordable options"]


def test_strip_filler_handles_longer_shopping_phrases():
    assert _strip_filler("I'm mostly shopping for clothes") == "clothes"
    assert _strip_filler("i usually look for affordable options") == "affordable options"


def test_next_mock_prompt_asks_about_ignore_terms_first():
    patch = {"shopping_categories": ["Clothing"], "preference_terms": [], "ignore_terms": []}
    assert "avoid" in _next_mock_prompt(patch).lower()


def test_next_mock_prompt_asks_about_categories_when_nothing_captured():
    patch = {"shopping_categories": [], "preference_terms": [], "ignore_terms": ["leather"]}
    assert "shopping for" in _next_mock_prompt(patch).lower()


def test_next_mock_prompt_falls_back_to_generic_anything_else():
    patch = {"shopping_categories": ["Clothing"], "preference_terms": ["Nike"], "ignore_terms": ["leather"]}
    assert "anything else" in _next_mock_prompt(patch).lower()


@pytest.mark.asyncio
async def test_run_mock_session_splits_multi_sentence_message_with_filler():
    ws = _FakeWebSocket([_text_message(
        "I'm mostly shopping for clothes, electronics, and household essentials. "
        "I usually look for affordable options, sales, and products with strong reviews."
    )])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _run_mock_session(ws, session)

    assert session.latest_patch["shopping_categories"] == ["Clothing", "Electronics"]
    assert set(session.latest_patch["preference_terms"]) == {
        "household essentials", "affordable options", "sales", "products with strong reviews",
    }


# --- _run_pumps / _send_timeout_nudge / _auto_save_and_close -----------------


@pytest.mark.asyncio
async def test_run_pumps_returns_true_promptly_when_client_disconnects():
    """Regression guard: _pump_gemini_to_client has no natural end of its
    own (it only stops via cancellation), so a plain asyncio.gather() of
    both pumps would never notice the client side finishing and would just
    block until the timeout regardless. _run_pumps must stop the other pump
    as soon as either one ends, well before the budget runs out."""
    ws = _FakeWebSocket([])  # immediately disconnects
    gemini = _HangingGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    start = time.monotonic()
    finished = await _run_pumps(ws, gemini, session, timeout=5.0)
    elapsed = time.monotonic() - start

    assert finished is True
    assert elapsed < 1.0


@pytest.mark.asyncio
async def test_run_pumps_returns_false_when_neither_side_finishes_in_time():
    ws = _HangingWebSocket()
    gemini = _HangingGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    finished = await _run_pumps(ws, gemini, session, timeout=0.05)

    assert finished is False


@pytest.mark.asyncio
async def test_send_timeout_nudge_sends_activity_bracketed_text():
    gemini = _FakeGeminiSession()

    await _send_timeout_nudge(gemini)

    assert gemini.activity_calls == ["start", "end"]
    assert len(gemini.text_calls) == 1
    assert "gone quiet" in gemini.text_calls[0]


@pytest.mark.asyncio
async def test_auto_save_and_close_sends_timeout_without_saving(monkeypatch):
    calls = []
    monkeypatch.setattr(profile_store, "merge_and_save", lambda uid, patch: calls.append((uid, patch)))
    monkeypatch.setattr(profile_store, "save_reviewed_profile", lambda uid, patch: calls.append((uid, patch)))
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.finalize_proposal = {
        "shopping_categories": ["Clothing"],
        "preference_terms": [],
        "ignore_terms": [],
        "summary": "Saving clothing.",
    }

    await _auto_save_and_close(ws, session)

    assert calls == []
    assert ws.sent_json == [{"type": "session_timeout"}]


@pytest.mark.asyncio
async def test_auto_save_and_close_timeout_is_idempotent(monkeypatch):
    monkeypatch.setattr(profile_store, "merge_and_save", lambda uid, patch: pytest.fail("must not save"))
    monkeypatch.setattr(profile_store, "save_reviewed_profile", lambda uid, patch: pytest.fail("must not save"))
    ws = _FakeWebSocket([])
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await _auto_save_and_close(ws, session)
    await _auto_save_and_close(ws, session)

    assert ws.sent_json == [{"type": "session_timeout"}]


# --- _watch_inactivity --------------------------------------------------------


@pytest.mark.asyncio
async def test_watch_inactivity_nudges_once_after_silence_threshold(monkeypatch):
    """Regression guard: the nudge/auto-save logic used to be keyed off total
    elapsed session time, which fired mid-conversation for any real exchange
    that ran long. It must instead be driven purely by genuine silence."""
    monkeypatch.setattr(live_session, "_INACTIVITY_NUDGE_SECONDS", 0.05)
    monkeypatch.setattr(live_session, "_INACTIVITY_CLOSE_GRACE_SECONDS", 10)
    monkeypatch.setattr(live_session, "_INACTIVITY_POLL_SECONDS", 0.01)
    ws = _FakeWebSocket([])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(_watch_inactivity(ws, gemini, session), timeout=0.2)

    assert gemini.activity_calls == ["start", "end"]
    assert len(gemini.text_calls) == 1


@pytest.mark.asyncio
async def test_watch_inactivity_does_not_nudge_while_activity_keeps_resetting_clock(monkeypatch):
    monkeypatch.setattr(live_session, "_INACTIVITY_NUDGE_SECONDS", 0.05)
    monkeypatch.setattr(live_session, "_INACTIVITY_POLL_SECONDS", 0.01)
    ws = _FakeWebSocket([])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    task = asyncio.ensure_future(_watch_inactivity(ws, gemini, session))
    try:
        for _ in range(10):
            await asyncio.sleep(0.02)
            session.last_activity_at = time.monotonic()
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    assert gemini.activity_calls == []


@pytest.mark.asyncio
async def test_watch_inactivity_times_out_after_nudge_grace_period_without_saving(monkeypatch):
    monkeypatch.setattr(live_session, "_INACTIVITY_NUDGE_SECONDS", 0.02)
    monkeypatch.setattr(live_session, "_INACTIVITY_CLOSE_GRACE_SECONDS", 0.02)
    monkeypatch.setattr(live_session, "_INACTIVITY_POLL_SECONDS", 0.01)
    monkeypatch.setattr(profile_store, "merge_and_save", lambda uid, patch: pytest.fail("must not save"))
    monkeypatch.setattr(profile_store, "save_reviewed_profile", lambda uid, patch: pytest.fail("must not save"))
    ws = _FakeWebSocket([])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})

    await asyncio.wait_for(_watch_inactivity(ws, gemini, session), timeout=1.0)

    assert session.auto_saved is True
    assert gemini.activity_calls == ["start", "end"]  # nudged once before giving up
    assert ws.sent_json == [{"type": "session_timeout"}]


@pytest.mark.asyncio
async def test_watch_inactivity_does_not_save_when_proposal_exists(monkeypatch):
    """If the user already verbally confirmed (finalize_proposal set), there's
    nothing left to nudge for — auto-save right away, skipping the nudge."""
    monkeypatch.setattr(live_session, "_INACTIVITY_NUDGE_SECONDS", 10)
    monkeypatch.setattr(live_session, "_INACTIVITY_POLL_SECONDS", 0.01)
    monkeypatch.setattr(profile_store, "merge_and_save", lambda uid, patch: pytest.fail("must not save"))
    monkeypatch.setattr(profile_store, "save_reviewed_profile", lambda uid, patch: pytest.fail("must not save"))
    ws = _FakeWebSocket([])
    gemini = _FakeGeminiSession()
    session = SessionState(session_id="s1", uid="user-1", existing_profile={})
    session.finalize_proposal = {
        "shopping_categories": [], "preference_terms": [], "ignore_terms": [], "summary": "done",
    }

    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(_watch_inactivity(ws, gemini, session), timeout=0.05)

    assert gemini.activity_calls == []
    assert session.auto_saved is False
    assert ws.sent_json == []
