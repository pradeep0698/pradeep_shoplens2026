import asyncio
import json
import logging
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from fastapi import WebSocket
from google import genai
from google.genai import types

import profile_store

logger = logging.getLogger(__name__)

_PROJECT = os.environ.get("PROJECT_ID", "")
# "global" — Vertex AI's Gemini Live API GA is only reachable at the global
# endpoint as of June 2026, not regional ones like us-central1 (confirmed by
# testing every region; only global worked).
_LOCATION = os.environ.get("LOCATION", "global")
_VOICE_MODEL = os.environ.get("VOICE_MODEL", "gemini-live-2.5-flash-native-audio")
# Cheap text-only model for the separate structured-extraction call (see
# _extract_patch_from_transcript) — deliberately not the Live model.
_EXTRACTION_MODEL = os.environ.get("EXTRACTION_MODEL", "gemini-2.5-flash")
# One of gemini-live-2.5-flash's 8 prebuilt voices (Puck, Charon, Kore, Fenrir,
# Aoede, Leda, Orus, Zephyr) — Puck is also Gemini Live's own default, but set
# it explicitly so the choice is intentional and swappable via env var alone.
_VOICE_NAME = os.environ.get("VOICE_NAME", "Puck")
# Pure cost/runaway-session backstop now — decoupled from the nudge/auto-save
# logic below, which is driven by genuine inactivity instead, so a real,
# actively-engaged conversation should essentially never hit this.
_SESSION_MAX_SECONDS = int(os.environ.get("SESSION_MAX_SECONDS", "600"))
_SESSION_CONTEXT_WINDOW_TOKENS = int(os.environ.get("SESSION_CONTEXT_WINDOW_TOKENS", "32000"))
# How long the conversation must be genuinely silent (see SessionState.last_
# activity_at) before nudging the model to check in / wrap up, and how much
# further silence after that nudge before giving up and auto-saving.
_INACTIVITY_NUDGE_SECONDS = int(os.environ.get("INACTIVITY_NUDGE_SECONDS", "45"))
_INACTIVITY_CLOSE_GRACE_SECONDS = int(os.environ.get("INACTIVITY_CLOSE_GRACE_SECONDS", "20"))
# Internal poll granularity for the inactivity watchdog — not worth exposing
# as an env var.
_INACTIVITY_POLL_SECONDS = 1.0

# TEMPORARY: scripted fake conversation, used while no billed GCP project is
# reachable for the real Vertex AI Live API call. Exercises the full WS
# protocol/UI without calling Vertex AI at all. Remove once real access is
# restored — see plan risk "Local TLS workarounds are machine-specific".
_MOCK_GEMINI = os.environ.get("VOICE_ASSISTANT_MOCK_GEMINI", "false").lower() == "true"

# Must match the 8 fixed category checkboxes in mobile/lib/presentation/widgets/profile_form.dart
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

SYSTEM_PROMPT_TEMPLATE = (
    "You are a friendly shopping preference coach having a natural spoken "
    "conversation with the user to learn their shopping preferences. Your ONLY "
    "job is to be a good conversational partner — a separate system handles "
    "extracting structured data from the transcript, so you never need to report "
    "categories or terms yourself. Always respond out loud on every turn — never "
    "go silent, even when you're also calling a tool. Ask ONE follow-up question "
    "at a time. Prioritize stable, durable preferences over one-off intents — "
    "e.g. \"I'm shopping for a gift\" is transient, while \"I always avoid "
    "leather\" is durable. {profile_note} Once the user has shared at least one "
    "stable category, brand/style preference, or exclusion, and seems satisfied, "
    "summarize what you heard in one or two sentences and ask them to confirm "
    "out loud. Only after they confirm, call ready_to_finalize with that summary "
    "— do not call it before the user has verbally confirmed. If the user "
    "mentions a budget or price ceiling, acknowledge it verbally but mention "
    "that budgets aren't supported yet."
)

SYSTEM_PROMPT_TEMPLATE = (
    "You are ShopLens AI, a warm shopping assistant having a natural spoken "
    "conversation to learn the user's durable shopping preferences. Always "
    "respond out loud on every turn, even when you call a tool. Keep replies "
    "brief and human: acknowledge what they said in a few words, then ask one "
    "specific follow-up that naturally fits the last answer. Vary your "
    "phrasing and avoid checklist language like 'anything else' on repeated "
    "turns. Prefer stable preferences over one-off shopping errands: 'I avoid "
    "leather' is stable; 'a gift for my mom' is transient. {profile_note} "
    "Whenever the user states a shopping category, a brand/style/material "
    "preference, or something to exclude, call record_preference right away "
    "with exactly what you understood — do this throughout the conversation "
    "every time something new comes up, not just once at the end. Trust your "
    "own understanding of their speech over the caption shown on screen, "
    "which can sometimes be wrong even when you understood correctly — never "
    "read the caption back, just record what you actually heard. When you "
    "have enough to save, summarize in one conversational sentence and ask "
    "whether it sounds right — by then record_preference should already "
    "reflect everything, so the summary doesn't need to list categories/terms "
    "again. If the user clearly confirms, call ready_to_finalize with that "
    "same summary. Do not call ready_to_finalize before confirmation. If the "
    "user mentions a budget, acknowledge it naturally and say budget "
    "filtering is not supported yet. The very first message you receive each "
    "session is a hidden cue telling you the user just opened the "
    "conversation and hasn't said anything yet — when you see it, speak first "
    "with a short warm greeting and ask what they like shopping for or want "
    "to avoid; never read that cue back to the user. As part of that opening "
    "greeting only, briefly mention they can say 'I'm done' (or tap the done "
    "button) any time they want to stop and review what's been captured — "
    "keep it to a short phrase, not a separate sentence."
)


def _profile_note(existing_profile: dict) -> str:
    """Summarizes the user's already-saved profile for the system prompt — fetched
    server-side before the Gemini Live session opens, rather than via a
    get_current_profile tool call. A tool call that exists only to fetch data
    (no user-facing speech) reliably became the model's entire turn with no
    spoken output, since Gemini Live doesn't resume speaking once turn_complete
    fires for a turn that was just a function call (confirmed by direct testing
    against the real API) — baking the profile into the prompt avoids that turn
    entirely."""
    categories = existing_profile.get("shopping_categories") or []
    preferences = existing_profile.get("preference_terms") or []
    exclusions = existing_profile.get("ignore_terms") or []
    if not (categories or preferences or exclusions):
        return "The user has no saved preferences yet — this is their first time."
    parts = []
    if categories:
        parts.append("shops for " + ", ".join(categories))
    if preferences:
        parts.append("likes " + ", ".join(preferences))
    if exclusions:
        parts.append("avoids " + ", ".join(exclusions))
    return (
        "The user's existing saved profile: " + "; ".join(parts) + ". Don't "
        "re-ask about these unless the user brings them up."
    )


def _system_prompt(existing_profile: dict) -> str:
    return SYSTEM_PROMPT_TEMPLATE.format(profile_note=_profile_note(existing_profile))


def _category_schema() -> types.Schema:
    return types.Schema(
        type="ARRAY",
        items=types.Schema(type="STRING", enum=VOICE_CATEGORIES),
        description="Subset of the user's fixed shopping categories.",
    )


READY_TO_FINALIZE = types.FunctionDeclaration(
    name="ready_to_finalize",
    description=(
        "Call this ONLY after the user has explicitly confirmed out loud that "
        "the summarized preferences are correct and ready to save. You only "
        "provide the human-readable summary you already spoke out loud — the "
        "categories/terms themselves should already be recorded via "
        "record_preference by this point. This still does not save anything; "
        "the human must tap Confirm in the app."
    ),
    parameters=types.Schema(
        type="OBJECT",
        properties={
            "summary": types.Schema(type="STRING", description="The human-readable confirmation sentence you spoke."),
        },
        required=["summary"],
    ),
)

RECORD_PREFERENCE = types.FunctionDeclaration(
    name="record_preference",
    description=(
        "Call this immediately whenever the user states a shopping category, a "
        "brand/style/material preference, or something to exclude — even "
        "mid-conversation, not just once at the end. Use your own understanding "
        "of what they said; the caption shown on screen can sometimes be wrong "
        "even when you understood correctly, so don't rely on it or repeat it "
        "back verbatim — use your own understanding."
    ),
    parameters=types.Schema(
        type="OBJECT",
        properties={
            "shopping_categories": _category_schema(),
            "preference_terms": types.Schema(
                type="ARRAY", items=types.Schema(type="STRING"),
                description="Things the user likes (brand, style, material, color).",
            ),
            "ignore_terms": types.Schema(
                type="ARRAY", items=types.Schema(type="STRING"),
                description="Things the user wants excluded.",
            ),
        },
    ),
)

VOICE_TOOLS = [types.Tool(function_declarations=[READY_TO_FINALIZE, RECORD_PREFERENCE])]


def _filter_categories(values: list[str] | None) -> list[str]:
    """Defense in depth: drop any category the model returns outside the fixed
    8-value enum, in case structured-output constraints are ever bypassed."""
    if not values:
        return []
    allowed = set(VOICE_CATEGORIES)
    return [v for v in values if v in allowed]


@dataclass
class SessionState:
    session_id: str
    uid: str
    existing_profile: dict
    created_at: float = field(default_factory=time.monotonic)
    latest_patch: dict = field(default_factory=lambda: {"shopping_categories": [], "preference_terms": [], "ignore_terms": []})
    finalize_proposal: Optional[dict] = None
    # Accumulated {role, text} turns — the input to _extract_patch_from_transcript.
    transcript: list[dict] = field(default_factory=list)
    # Declared by the client via an "audio_format" control frame right after
    # connecting — on web, record_web silently captures at whatever rate the
    # browser's AudioContext settles on (never 16000 in practice), so this
    # must not be hardcoded or Gemini receives mislabeled audio and never
    # recognizes speech. Defaults to 16000 for older clients that never send it.
    input_sample_rate: int = 16000
    # Gemini streams transcription in fragments, not one block per turn — these
    # accumulate fragments until that stream's Transcription.finished fires
    # (NOT server_content.turn_complete, which the SDK explicitly documents
    # has no ordering relationship with transcription — see _pump_gemini_to_client),
    # so each user/model turn becomes exactly one transcript frame instead of
    # several small (or, worse, stale/mismatched) ones.
    pending_input_transcript: str = ""
    pending_output_transcript: str = ""
    # Last time something actually happened (greeting sent, user started
    # speaking/typing, a turn completed) — drives _watch_inactivity's nudge/
    # auto-save timing instead of total conversation length, so an actively
    # engaged conversation is never cut off just for running long.
    last_activity_at: float = field(default_factory=time.monotonic)
    # Guards _auto_save_and_close against being reached twice (the inactivity
    # watchdog and the hard SESSION_MAX_SECONDS ceiling race independently).
    auto_saved: bool = False

    def is_expired(self) -> bool:
        return (time.monotonic() - self.created_at) > _SESSION_MAX_SECONDS


class SessionRegistry:
    """In-memory session registry. Sessions are short-lived (capped at
    SESSION_MAX_SECONDS) and ephemeral by design — no Firestore persistence,
    since a dropped connection means the Gemini Live session is gone regardless."""

    def __init__(self) -> None:
        self._sessions: dict[str, SessionState] = {}
        self._lock = asyncio.Lock()

    async def create(self, uid: str, existing_profile: dict) -> SessionState:
        session_id = uuid.uuid4().hex
        state = SessionState(session_id=session_id, uid=uid, existing_profile=existing_profile)
        async with self._lock:
            self._sessions[session_id] = state
        return state

    async def get(self, session_id: str) -> Optional[SessionState]:
        async with self._lock:
            state = self._sessions.get(session_id)
        if state is None:
            return None
        if state.is_expired():
            await self.delete(session_id)
            return None
        return state

    async def delete(self, session_id: str) -> None:
        async with self._lock:
            self._sessions.pop(session_id, None)


session_registry = SessionRegistry()

_genai_client: Optional[genai.Client] = None


def _get_client() -> genai.Client:
    global _genai_client
    if _genai_client is None:
        _genai_client = genai.Client(vertexai=True, project=_PROJECT, location=_LOCATION)
    return _genai_client


def _live_config(existing_profile: dict) -> types.LiveConnectConfig:
    return types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        tools=VOICE_TOOLS,
        system_instruction=types.Content(parts=[types.Part(text=_system_prompt(existing_profile))]),
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=_VOICE_NAME)
            )
        ),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        # Server-side VAD was unreliable over the resampled/web-captured mic
        # audio — the client now drives turn boundaries explicitly via a
        # hold-to-talk button (speech_start/speech_end frames -> activity_start/
        # activity_end below), so disable Gemini's own activity detection.
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(disabled=True)
        ),
        context_window_compression=types.ContextWindowCompressionConfig(
            trigger_tokens=_SESSION_CONTEXT_WINDOW_TOKENS,
            sliding_window=types.SlidingWindow(),
        ),
    )


async def _send_greeting_trigger(gemini_session) -> None:
    """Sends a hidden turn right after connecting so Gemini speaks the opening
    greeting itself — a real, spoken, transcribed turn — instead of the old
    static assistant_greeting string the model never actually said or heard.
    Not recorded into session.transcript or sent to the client: the model's
    spoken reply (relayed normally via _pump_gemini_to_client) is the only
    thing the user sees/hears.

    Uses send_realtime_input(text=...) bracketed by activity_start/activity_end
    rather than send_client_content — the SDK's own docstring warns that
    interleaving send_client_content with send_realtime_input "is not
    recommended and can lead to unexpected results", and this session's only
    other input channel (mic audio turns) is exclusively send_realtime_input
    (manual activity detection is enabled in _live_config). Mixing the two
    here was confirmed to silently break both the greeting and subsequent
    voice turns — no exception, just no response."""
    await gemini_session.send_realtime_input(activity_start=types.ActivityStart())
    await gemini_session.send_realtime_input(
        text="(The user just opened the conversation and hasn't said anything yet.)"
    )
    await gemini_session.send_realtime_input(activity_end=types.ActivityEnd())


_EXTRACTION_RESPONSE_SCHEMA = types.Schema(
    type="OBJECT",
    properties={
        "shopping_categories": _category_schema(),
        "preference_terms": types.Schema(type="ARRAY", items=types.Schema(type="STRING")),
        "ignore_terms": types.Schema(type="ARRAY", items=types.Schema(type="STRING")),
    },
)

_EXTRACTION_PROMPT = (
    "You are extracting structured shopping preferences from a conversation "
    "transcript between a shopping assistant and a user. Read the full "
    "transcript and the user's existing saved profile below, then return ONLY "
    "stable, durable preferences the user clearly stated — not one-off, "
    "transient requests (e.g. \"a gift for my mom\" is transient; \"I always "
    "avoid leather\" is durable).\n\n"
    "Rules:\n"
    "- shopping_categories must be a subset of the 8 fixed categories — only "
    "include a category if the transcript clearly indicates the user shops "
    "for that kind of product. Match by meaning, not literal wording (e.g. "
    "\"cooking appliances\" means Kitchen & Cookware).\n"
    "- preference_terms are free-text things the user LIKES (brand, style, "
    "material, color words).\n"
    "- ignore_terms are free-text things the user wants EXCLUDED. A statement "
    "like \"no plastic\" or \"avoid leather\" is an exclusion, never a "
    "preference — never put the same concept in both lists.\n"
    "- If a concept doesn't match any of the 8 categories, keep it as a "
    "preference_term instead of forcing a category match.\n"
    "- Merge with the existing profile rather than discarding it, unless the "
    "transcript clearly contradicts something already saved.\n"
    "- If nothing new and stable was said, return the existing profile unchanged."
)


def _extract_patch_from_transcript(transcript: list[dict], existing_profile: dict) -> dict:
    """Synchronous Gemini text call — callers must run this via asyncio.to_thread
    to avoid blocking the event loop. Deliberately separate from the Live
    conversation (a different, cheap text model — see _EXTRACTION_MODEL) so the
    Live model can focus purely on holding a natural conversation; this call
    does the precise category/term extraction the mock's heuristics
    approximated locally (see plan §4b/§5b)."""
    client = _get_client()
    transcript_text = "\n".join(f"{turn['role']}: {turn['text']}" for turn in transcript) or "(no conversation yet)"
    prompt = (
        f"{_EXTRACTION_PROMPT}\n\n"
        f"Existing profile: {json.dumps(existing_profile)}\n\n"
        f"Transcript:\n{transcript_text}"
    )
    try:
        response = client.models.generate_content(
            model=_EXTRACTION_MODEL,
            contents=[prompt],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                response_schema=_EXTRACTION_RESPONSE_SCHEMA,
            ),
        )
        data = json.loads(response.text)
    except Exception as exc:
        logger.warning("Extraction call failed, keeping existing profile: %s", exc)
        return dict(existing_profile)
    return {
        "shopping_categories": _filter_categories(data.get("shopping_categories")),
        "preference_terms": list(data.get("preference_terms") or []),
        "ignore_terms": list(data.get("ignore_terms") or []),
    }


async def _dispatch_tool_call(name: str, args: dict, session: SessionState) -> dict:
    if name == "ready_to_finalize":
        summary = str(args.get("summary", "")).strip()
        # Package up whatever record_preference has already accumulated —
        # deliberately NOT re-running _extract_patch_from_transcript here,
        # since that reads the (sometimes-wrong) transcribed caption rather
        # than Gemini's own understanding, and would re-introduce exactly the
        # kind of caption error record_preference exists to avoid, right at
        # the last moment before saving.
        session.finalize_proposal = {**session.latest_patch, "summary": summary}
        return {"status": "proposal_ready"}

    if name == "record_preference":
        # Uses Gemini's own real-time audio understanding, not the separately
        # transcribed caption — see RECORD_PREFERENCE's description. Same
        # dedup logic as the final Firestore merge (profile_store.merge_and_save).
        categories = _filter_categories(args.get("shopping_categories"))
        session.latest_patch["shopping_categories"] = sorted({*session.latest_patch["shopping_categories"], *categories})
        session.latest_patch["preference_terms"] = profile_store._dedup_case_insensitive(
            session.latest_patch["preference_terms"], [str(t) for t in (args.get("preference_terms") or [])]
        )
        session.latest_patch["ignore_terms"] = profile_store._dedup_case_insensitive(
            session.latest_patch["ignore_terms"], [str(t) for t in (args.get("ignore_terms") or [])]
        )
        return {"status": "recorded"}

    logger.warning("Unknown tool call from Gemini Live session: %s", name)
    return {"status": "unknown_tool"}


async def _on_user_turn(websocket: WebSocket, session: SessionState, text: str) -> None:
    """Records a completed user turn (typed or transcribed-from-voice) and
    echoes it as a transcript frame. Does NOT run structured extraction here
    anymore — for voice turns, `text` comes from input_transcription, which
    can be wrong even when Gemini understood the audio correctly, so
    record_preference (using Gemini's own understanding) is the only source
    of structured data for voice now. Typed text has no STT step and is still
    safe to extract directly — see the text branch in _pump_client_to_gemini."""
    session.transcript.append({"role": "user", "text": text})
    await websocket.send_json({"type": "transcript", "role": "user", "text": text, "final": True})


async def _pump_client_to_gemini(websocket: WebSocket, gemini_session, session: SessionState) -> None:
    """Forward binary audio frames and JSON control frames from the client to
    Gemini. Typed text turns are recorded into the transcript here directly —
    input_audio_transcription only fires for actual audio input, not for text
    sent via send_realtime_input(text=...)."""
    while True:
        message = await websocket.receive()
        if message.get("type") == "websocket.disconnect":
            return
        if "bytes" in message and message["bytes"] is not None:
            await gemini_session.send_realtime_input(
                audio=types.Blob(
                    data=message["bytes"],
                    mime_type=f"audio/pcm;rate={session.input_sample_rate}",
                )
            )
        elif "text" in message and message["text"] is not None:
            try:
                frame = json.loads(message["text"])
            except (TypeError, ValueError):
                logger.warning("Ignoring malformed text frame from client: %s", message["text"])
                continue
            if frame.get("type") == "text":
                text = str(frame.get("text", "")).strip()
                if text:
                    # send_realtime_input, not send_client_content — see
                    # _send_greeting_trigger's docstring for why mixing the two
                    # APIs in one session silently breaks both.
                    await gemini_session.send_realtime_input(activity_start=types.ActivityStart())
                    await gemini_session.send_realtime_input(text=text)
                    await gemini_session.send_realtime_input(activity_end=types.ActivityEnd())
                    session.last_activity_at = time.monotonic()
                    await _on_user_turn(websocket, session, text)
                    # Typed text is verbatim (no STT step), unlike voice
                    # turns — safe to extract structured data from it directly.
                    patch = await asyncio.to_thread(
                        _extract_patch_from_transcript, session.transcript, session.existing_profile
                    )
                    session.latest_patch = patch
                    await websocket.send_json({"type": "preference_patch", "patch": patch})
            elif frame.get("type") == "audio_format":
                try:
                    session.input_sample_rate = int(frame.get("sample_rate", 16000))
                except (TypeError, ValueError):
                    logger.warning("Ignoring malformed audio_format frame: %s", frame)
            elif frame.get("type") == "speech_start":
                # Marks the start of a manual (hold-to-talk) turn — required
                # since automatic_activity_detection is disabled in _live_config.
                session.last_activity_at = time.monotonic()
                await gemini_session.send_realtime_input(activity_start=types.ActivityStart())
            elif frame.get("type") == "speech_end":
                await gemini_session.send_realtime_input(activity_end=types.ActivityEnd())
            else:
                logger.debug("Received control frame from client: %s", frame)


async def _flush_pending_input(websocket: WebSocket, session: SessionState) -> None:
    if not session.pending_input_transcript:
        return
    text = session.pending_input_transcript
    session.pending_input_transcript = ""
    session.last_activity_at = time.monotonic()
    # Voice path — text sent via send_realtime_input(text=...) is recorded in
    # _on_user_turn instead, since this event never fires for that case.
    await _on_user_turn(websocket, session, text)


async def _flush_pending_output(websocket: WebSocket, session: SessionState) -> None:
    if not session.pending_output_transcript:
        return
    text = session.pending_output_transcript
    session.pending_output_transcript = ""
    session.last_activity_at = time.monotonic()
    session.transcript.append({"role": "model", "text": text})
    await websocket.send_json({"type": "transcript", "role": "model", "text": text, "final": True})


async def _pump_gemini_to_client(websocket: WebSocket, gemini_session, session: SessionState) -> None:
    """Forward Gemini's audio/transcript/tool-call traffic back to the client.

    gemini_session.receive() is a per-turn generator by SDK design — it ends
    right after yielding the message with server_content.turn_complete (see
    google.genai.live.AsyncSession.receive), it is NOT a single continuous
    stream for the whole session. Looping receive() itself in an outer while
    is what lets this function keep relaying every subsequent turn instead of
    silently going quiet after the first one (confirmed by direct testing
    against the real API — without this, only turn one's audio/text ever
    reached the client)."""
    while True:
        async for response in gemini_session.receive():
            server_content = getattr(response, "server_content", None)
            if server_content is not None:
                if getattr(server_content, "interrupted", False):
                    # Barge-in cuts the turn short — any fragments already
                    # buffered (from either side) belong to the cut-off turn
                    # and must not bleed into the next turn's transcript.
                    session.pending_input_transcript = ""
                    session.pending_output_transcript = ""
                    await websocket.send_json({"type": "interrupted"})

                model_turn = getattr(server_content, "model_turn", None)
                if model_turn is not None:
                    for part in model_turn.parts or []:
                        if getattr(part, "inline_data", None) is not None:
                            await websocket.send_bytes(part.inline_data.data)

                # Gemini streams transcription as many small fragments rather than
                # one block per turn — accumulate them and flush on that
                # stream's own Transcription.finished flag, NEVER on
                # server_content.turn_complete: the SDK's own docstring for
                # input_transcription/output_transcription explicitly says
                # "doesn't imply any ordering between transcription and model
                # turn". A turn_complete-based fallback flush was tried and
                # removed — it could itself fire while a fragment's `finished`
                # was still False (no ordering guarantee, by the same docs),
                # flushing an incomplete/wrong fragment early and recreating
                # the exact bug this is fixing. `finished` is the only signal
                # used now; if the real API ever fails to send it, the
                # symptom is "no transcript text appears" — an obvious,
                # easy-to-diagnose failure, not a silently wrong one.
                input_transcription = getattr(server_content, "input_transcription", None)
                if input_transcription is not None and input_transcription.text:
                    session.pending_input_transcript += input_transcription.text
                if input_transcription is not None and getattr(input_transcription, "finished", False):
                    await _flush_pending_input(websocket, session)
                output_transcription = getattr(server_content, "output_transcription", None)
                if output_transcription is not None and output_transcription.text:
                    session.pending_output_transcript += output_transcription.text
                if output_transcription is not None and getattr(output_transcription, "finished", False):
                    await _flush_pending_output(websocket, session)

            tool_call = getattr(response, "tool_call", None)
            if tool_call is not None:
                function_responses = []
                for call in tool_call.function_calls or []:
                    result = await _dispatch_tool_call(call.name, dict(call.args or {}), session)
                    function_responses.append(
                        types.FunctionResponse(id=call.id, name=call.name, response=result)
                    )
                    if call.name == "ready_to_finalize":
                        await websocket.send_json(
                            {"type": "finalize_proposal", "patch": session.finalize_proposal}
                        )
                    elif call.name == "record_preference":
                        await websocket.send_json(
                            {"type": "preference_patch", "patch": session.latest_patch}
                        )
                await gemini_session.send_tool_response(function_responses=function_responses)


# --- Mock-only heuristics (VOICE_ASSISTANT_MOCK_GEMINI=true path) -----------
# Real Gemini doesn't need any of this — an actual LLM naturally splits
# compound statements and recognizes closing language. This exists purely so
# local testing without a billed GCP project can exercise the full WS
# protocol/UI with something resembling a real conversation.

_CLOSING_PHRASES = {
    "no", "nope", "no thanks", "nothing else", "nothing more", "that's all",
    "thats all", "that's it", "thats it", "i'm done", "im done", "done",
    "save it", "go ahead", "looks good", "save", "that's everything",
    "thats everything", "yes save it", "yes",
}

_FILLER_PREFIXES = [
    "show me", "i would like", "i'd like", "i want", "i like", "i love",
    "i need", "i'm looking for", "im looking for", "looking for",
    "i prefer", "get me", "find me",
    "i'm mostly shopping for", "im mostly shopping for",
    "i am mostly shopping for", "mostly shopping for", "shopping for",
    "i usually shop for", "i usually look for", "i tend to look for",
    "i tend to buy", "i mostly buy", "i usually buy", "i also look for",
]

_EXCLUSION_PATTERN = re.compile(
    r"^(?:no|not|avoid|don'?t want|don'?t like|exclude|skip)\s+(.+)$", re.IGNORECASE
)

_MOCK_CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "Furniture": ["furniture", "chair", "sofa", "couch", "desk", "table", "shelf", "wardrobe"],
    "Clothing": ["clothing", "clothes", "shirt", "jacket", "jeans", "dress", "shoe", "apparel"],
    "Kitchen & Cookware": ["kitchen", "cookware", "cooking", "appliance", "pan", "pot", "cook"],
    "Accessories": ["accessory", "accessories", "watch", "bag", "jewelry", "jewellery", "wallet"],
    "Electronics": ["electronics", "phone", "laptop", "tablet", "headphone", "gadget", "tech"],
    "Home Decor": ["home decor", "decor", "candle", "vase", "rug", "lamp", "pillow"],
    "Sports & Outdoors": ["sports", "outdoor", "gym", "fitness", "camping", "hiking", "yoga"],
    "Books & Stationery": ["book", "stationery", "notebook", "pen", "journal", "planner"],
}


def _is_closing_phrase(text: str) -> bool:
    return text.strip().lower().rstrip(".!") in _CLOSING_PHRASES


def _split_clauses(text: str) -> list[str]:
    # Splits on sentence boundaries too (".") in addition to "and"/commas/
    # semicolons, so a multi-sentence message like "...essentials. I usually
    # look for affordable options" doesn't collapse into one long clause.
    parts = re.split(r"\band\b|,|;|\.", text, flags=re.IGNORECASE)
    return [p.strip() for p in parts if p.strip()]


def _strip_filler(clause: str) -> str:
    lowered = clause.lower()
    # Longest match first so "i'm mostly shopping for" strips fully rather
    # than e.g. "shopping for" partially matching mid-phrase.
    for prefix in sorted(_FILLER_PREFIXES, key=len, reverse=True):
        if lowered.startswith(prefix):
            return clause[len(prefix):].strip()
    return clause.strip()


def _match_mock_category(clause: str) -> Optional[str]:
    lowered = clause.lower()
    for category, keywords in _MOCK_CATEGORY_KEYWORDS.items():
        if any(kw in lowered for kw in keywords):
            return category
    return None


def _classify_clause(clause: str) -> tuple[str, str]:
    """Returns (bucket, value): bucket is "category", "ignore", or "preference"."""
    category = _match_mock_category(clause)
    if category:
        return "category", category
    exclusion = _EXCLUSION_PATTERN.match(clause)
    if exclusion:
        return "ignore", exclusion.group(1).strip()
    return "preference", clause


def _mock_summary(patch: dict) -> str:
    parts = []
    if patch["shopping_categories"]:
        parts.append("categories: " + ", ".join(patch["shopping_categories"]))
    if patch["preference_terms"]:
        parts.append("preferences: " + ", ".join(patch["preference_terms"]))
    if patch["ignore_terms"]:
        parts.append("avoiding: " + ", ".join(patch["ignore_terms"]))
    body = "; ".join(parts) if parts else "nothing specific yet"
    return f"Here's what I'll save — {body}. Does that look right?"


def _next_mock_prompt(patch: dict) -> str:
    """A small bit of context-awareness so the mock doesn't repeat the exact
    same line every turn — still scripted, not real conversation, but asks
    about whichever bucket is still empty rather than a static loop."""
    if not patch["ignore_terms"]:
        return "Nice, that helps. Is there anything you usually want filtered out?"
    if not patch["shopping_categories"] and not patch["preference_terms"]:
        return "That is useful. What kinds of products should I keep an eye out for?"
    return "Perfect. I can save this now, or you can add one more preference."


async def _run_mock_session(websocket: WebSocket, session: SessionState) -> None:
    """Scripted fake conversation, responding only to text frames (no real STT
    to fake, so audio chunks are received and silently dropped). Accepts as
    many turns as the user gives — splitting compound statements ("X and Y")
    into separate clauses, matching categories by keyword rather than literal
    name, routing "no X"/"avoid X" to ignore_terms, and recognizing closing
    phrases ("no", "that's all", ...) as the cue to propose a finalize."""
    await websocket.send_json({
        "type": "transcript",
        "role": "model",
        "text": (
            "Hi, I'm here. Tell me what you usually like shopping for, or anything you "
            "want me to avoid — say \"I'm done\" any time you want to wrap up."
        ),
        "final": True,
    })
    while True:
        message = await websocket.receive()
        if message.get("type") == "websocket.disconnect":
            return
        if "bytes" in message and message["bytes"] is not None:
            continue
        if "text" not in message or message["text"] is None:
            continue
        try:
            frame = json.loads(message["text"])
        except (TypeError, ValueError):
            continue
        if frame.get("type") != "text":
            continue
        text = str(frame.get("text", "")).strip()
        if not text:
            continue

        if _is_closing_phrase(text):
            has_content = any(session.latest_patch.values())
            if has_content:
                summary = _mock_summary(session.latest_patch)
                session.finalize_proposal = {**session.latest_patch, "summary": summary}
                await websocket.send_json({"type": "transcript", "role": "model", "text": summary, "final": True})
                await websocket.send_json({"type": "finalize_proposal", "patch": session.finalize_proposal})
            else:
                reply = "No worries — tell me a category, brand, or style you're into, and I'll get started."
                await websocket.send_json({"type": "transcript", "role": "model", "text": reply, "final": True})
            continue

        for raw_clause in _split_clauses(text):
            clause = _strip_filler(raw_clause)
            if not clause:
                continue
            bucket, value = _classify_clause(clause)
            if bucket == "category":
                session.latest_patch["shopping_categories"] = sorted(
                    {*session.latest_patch["shopping_categories"], value}
                )
            elif bucket == "ignore":
                session.latest_patch["ignore_terms"] = sorted(
                    {*session.latest_patch["ignore_terms"], value}
                )
            else:
                session.latest_patch["preference_terms"] = sorted(
                    {*session.latest_patch["preference_terms"], value}
                )

        reply = _next_mock_prompt(session.latest_patch)
        await websocket.send_json({"type": "transcript", "role": "model", "text": reply, "final": True})
        await websocket.send_json({"type": "preference_patch", "patch": session.latest_patch})


async def _run_pumps(websocket: WebSocket, gemini_session, session: SessionState, timeout: float) -> bool:
    """Runs one fresh round of the client<->Gemini relay loops, bounded by
    `timeout`. Returns True if either side ended on its own before the
    timeout (most commonly: the client disconnected — _pump_gemini_to_client
    has no natural end of its own, it only ever stops via cancellation, so
    plain asyncio.gather() would never notice a disconnect and would just
    block until the timeout regardless), False if the timeout fired with
    neither side finishing.

    Callers can safely call this again with a fresh timeout after a False
    result — all relay state lives in `session`/`websocket`, not in the pump
    functions' locals, so a new pair of coroutines just resumes relaying
    where the cancelled ones left off."""
    client_task = asyncio.ensure_future(_pump_client_to_gemini(websocket, gemini_session, session))
    gemini_task = asyncio.ensure_future(_pump_gemini_to_client(websocket, gemini_session, session))
    tasks = {client_task, gemini_task}
    try:
        done, pending = await asyncio.wait(tasks, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        for task in done:
            exc = task.exception()
            if exc is not None:
                raise exc
        return bool(done)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()


async def _send_timeout_nudge(gemini_session) -> None:
    """Sent once after the conversation has gone genuinely quiet for
    INACTIVITY_NUDGE_SECONDS (see _watch_inactivity) — nudges the model to
    check in / wrap up rather than the session just silently sitting open
    or abruptly auto-saving with no warning. Same activity_start -> text ->
    activity_end shape as _send_greeting_trigger, for the same reason (see
    that function's docstring)."""
    await gemini_session.send_realtime_input(activity_start=types.ActivityStart())
    await gemini_session.send_realtime_input(
        text=(
            "(The user has gone quiet for a while. Check in warmly and ask if they're "
            "still there — if you already have enough to summarize, do that now and ask "
            "them to confirm.)"
        )
    )
    await gemini_session.send_realtime_input(activity_end=types.ActivityEnd())


async def _auto_save_and_close(websocket: WebSocket, session: SessionState) -> None:
    """Reached either via genuine inactivity (_watch_inactivity, after the
    nudge got no response) or the hard SESSION_MAX_SECONDS backstop —
    rather than just erroring out, save whatever's been captured (the
    confirmed proposal if one exists, else the live patch kept up to date
    by every turn) and tell the client it's done, same as a normal Confirm
    tap, instead of a timeout error. Idempotent — these two triggers race
    independently, so only the first to arrive should actually do anything."""
    if session.auto_saved:
        return
    session.auto_saved = True
    patch = session.finalize_proposal or session.latest_patch
    try:
        result = profile_store.merge_and_save(session.uid, patch)
        await websocket.send_json({"type": "auto_saved", **result})
    except Exception:
        logger.exception("voice session %s auto-save failed", session.session_id)
        try:
            await websocket.send_json({"type": "session_timeout"})
        except Exception:
            pass


async def _watch_inactivity(websocket: WebSocket, gemini_session, session: SessionState) -> None:
    """Runs for the whole session alongside the relay pumps, independent of
    how long the conversation itself runs. Tracks genuine silence via
    session.last_activity_at (bumped on the greeting, speech_start, typed
    text, and completed turns — see callers) rather than total elapsed
    time, so an actively-engaged conversation never gets nudged or cut off
    just for running long. Nudges once after INACTIVITY_NUDGE_SECONDS of
    silence; if still silent INACTIVITY_CLOSE_GRACE_SECONDS after that — or
    immediately if the user already verbally confirmed — auto-saves and
    returns."""
    nudged = False
    while True:
        await asyncio.sleep(_INACTIVITY_POLL_SECONDS)
        if session.finalize_proposal is not None:
            logger.info("voice session %s inactive after confirmation — auto-saving", session.session_id)
            await _auto_save_and_close(websocket, session)
            return
        idle_for = time.monotonic() - session.last_activity_at
        if not nudged and idle_for >= _INACTIVITY_NUDGE_SECONDS:
            logger.info("voice session %s inactive for %.0fs — nudging", session.session_id, idle_for)
            try:
                await _send_timeout_nudge(gemini_session)
            except Exception:
                logger.exception("voice session %s inactivity nudge failed", session.session_id)
            nudged = True
        elif nudged and idle_for >= _INACTIVITY_NUDGE_SECONDS + _INACTIVITY_CLOSE_GRACE_SECONDS:
            logger.info("voice session %s still inactive after nudge — auto-saving", session.session_id)
            await _auto_save_and_close(websocket, session)
            return


async def run_voice_session(websocket: WebSocket, session: SessionState) -> None:
    """Open a Gemini Live API session and relay audio/text/tool-call traffic
    between it and the client WebSocket until the session ends. Races two
    concurrent watchers: _run_pumps (stops as soon as the client disconnects,
    or as an absolute last resort at the hard SESSION_MAX_SECONDS backstop)
    and _watch_inactivity (nudges then auto-saves on genuine silence,
    regardless of total conversation length). Whichever finishes first wins;
    the other is cancelled."""
    if _MOCK_GEMINI:
        try:
            await _run_mock_session(websocket, session)
        finally:
            await session_registry.delete(session.session_id)
        return

    client = _get_client()
    hard_remaining = max(0.0, _SESSION_MAX_SECONDS - (time.monotonic() - session.created_at))

    try:
        async with client.aio.live.connect(
            model=_VOICE_MODEL, config=_live_config(session.existing_profile)
        ) as gemini_session:
            await _send_greeting_trigger(gemini_session)
            session.last_activity_at = time.monotonic()

            pumps_task = asyncio.ensure_future(_run_pumps(websocket, gemini_session, session, hard_remaining))
            watchdog_task = asyncio.ensure_future(_watch_inactivity(websocket, gemini_session, session))
            tasks = {pumps_task, watchdog_task}
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
            for task in done:
                exc = task.exception()
                if exc is not None:
                    raise exc
            if pumps_task in done and pumps_task.result() is False:
                # Neither a disconnect nor the inactivity watchdog ended things
                # first — absolute last-resort cutoff.
                logger.info("voice session %s hit hard SESSION_MAX_SECONDS cutoff — auto-saving", session.session_id)
                await _auto_save_and_close(websocket, session)
    finally:
        # Gemini session is torn down by the `async with` block's __aexit__ above
        # regardless of how the wait() above exits — stops audio billing promptly.
        await session_registry.delete(session.session_id)
