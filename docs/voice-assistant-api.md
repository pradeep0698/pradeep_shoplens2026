# Voice Assistant API

Backend: `services/voice-assistant` (FastAPI, fronting Gemini Live). Client usage:
[voice_api.dart](../mobile/lib/data/sources/remote/voice_api.dart) (REST),
[voice_socket_client.dart](../mobile/lib/data/sources/remote/voice_socket_client.dart) (WebSocket),
[voice_session.dart](../mobile/lib/data/models/voice_session.dart) (request/response models).

## Auth

All REST endpoints require `Authorization: Bearer <Firebase ID token>`
([main.py](../services/voice-assistant/main.py#L88-L92)). The WebSocket endpoint isn't
separately authenticated — it trusts the `session_id` issued by the already-authenticated
`start_session` call.

## Base URL

Configured via the `VOICE_ASSISTANT_API_URL` env var
([api_constants.dart](../mobile/lib/core/constants/api_constants.dart)). The WS stream URL is
derived from it (`wss` for an `https` base, `ws` for `http`).

## REST endpoints

### `POST /voice/session/start`

Starts a session and returns the WebSocket path to stream over.

```json
// request
{ "mode": "preferences" | "search" }   // optional, default "preferences"

// response (200)
{
  "session_id": "<hex>",
  "ws_url": "/voice/session/{session_id}/stream",
  "profile": { "shopping_categories": [], "preference_terms": [], "ignore_terms": [] }
}
```

`mode` selects the system prompt/tools for the session:
- `"preferences"` — forced first-run onboarding; learns shopping categories/likes/dislikes.
- `"search"` — every other session; conversational product search via the `search_products` tool.

### `POST /voice/session/event`

```json
// request
{ "session_id": "<id>", "event_type": "...", "payload": {} }

// response (200)
{ "status": "received" }
```

Logged server-side only — no client caller found in `mobile/lib` today.

### `POST /voice/session/finalize`

Writes the confirmed preference patch to the user's profile and deletes the in-memory session.

```json
// request
{
  "session_id": "<id>",
  "confirmed_patch": {
    "shopping_categories": ["..."],
    "preference_terms": ["..."],
    "ignore_terms": ["..."],
    "summary": "..."
  }
}

// response (200)
{
  "shopping_categories": ["..."],
  "preference_terms": ["..."],
  "ignore_terms": ["..."],
  "conflicts": ["..."]
}

// response (500)
{ "detail": "...", "error_code": "INTERNAL_ERROR" }
```

### `GET /health`

```json
{ "status": "ok", "project_id_set": true, "voice_model": "gemini-live-2.5-flash-native-audio" }
```

### `WS /voice/session/{session_id}/stream`

The live relay between the client and Gemini Live. Closes with code `4004` if `session_id` is
unknown or expired.

## WebSocket protocol

Defined in [live_session.py](../services/voice-assistant/live_session.py).

### Client → server frames

| Frame | Shape | Notes |
|---|---|---|
| binary | raw PCM audio bytes | mic input |
| text | `{"type": "text", "text": "..."}` | typed turn |
| text | `{"type": "audio_format", "sample_rate": 16000}` | must be sent before any audio frame |
| text | `{"type": "speech_start"}` | start of a hold-to-talk turn (server-side VAD is disabled) |
| text | `{"type": "speech_end"}` | end of a hold-to-talk turn |

### Server → client frames

| Frame | Shape | Notes |
|---|---|---|
| binary | 16-bit PCM, 24kHz, mono | Gemini's spoken audio |
| `transcript` | `{"type": "transcript", "role": "user"\|"model", "text": "...", "final": true}` | |
| `preference_patch` | `{"type": "preference_patch", "patch": {...}}` | sent after the `record_preference` tool call |
| `finalize_proposal` | `{"type": "finalize_proposal", "patch": {..., "summary": "..."}}` | sent after `ready_to_finalize` or a closing phrase |
| `product_results` | `{"type": "product_results", "query": "...", "products": [...]}` | search mode, after `search_products` |
| `interrupted` | `{"type": "interrupted"}` | barge-in cut the model off mid-turn |
| `session_timeout` | `{"type": "session_timeout"}` | auto-saved after inactivity or the hard session cap |

## Server-side config (env vars)

| Var | Default | Purpose |
|---|---|---|
| `PROJECT_ID` | — | GCP project for Vertex AI |
| `LOCATION` | `us-central1` | Vertex AI location (native-audio model is only available here) |
| `VOICE_MODEL` | `gemini-live-2.5-flash-native-audio` | Gemini Live model |
| `EXTRACTION_MODEL` | `gemini-2.5-flash` | cheap text model for structured preference extraction |
| `VOICE_NAME` | `Puck` | one of Gemini Live's 8 prebuilt voices |
| `VOICE_TEMPERATURE` | `0.7` | sampling temperature — this native-audio model generates audio tokens directly, so this affects waveform smoothness, not just word choice |
| `VOICE_TOP_P` | `0.9` | nucleus sampling top_p, same rationale as `VOICE_TEMPERATURE` |
| `SESSION_MAX_SECONDS` | `600` | hard session cutoff (cost/runaway backstop) |
| `SESSION_CONTEXT_WINDOW_TOKENS` | `32000` | triggers context-window compression |
| `INACTIVITY_NUDGE_SECONDS` | `45` | silence before the model is nudged to check in |
| `INACTIVITY_CLOSE_GRACE_SECONDS` | `20` | further silence after the nudge before auto-save |
| `PRODUCT_MATCHER_URL` | — | backs the `search_products` tool (calls its `POST /search`) |
| `VOICE_ASSISTANT_MOCK_GEMINI` | `false` | when `true`, runs a scripted fake conversation with no real Gemini calls |
