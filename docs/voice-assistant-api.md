# Voice Assistant API

Backend: `services/voice-assistant` (FastAPI, fronting Gemini Live). Client usage:
[voice_api.dart](../mobile/lib/data/sources/remote/voice_api.dart) (REST),
[voice_socket_client.dart](../mobile/lib/data/sources/remote/voice_socket_client.dart) (WS-proxy transport),
[gemini_live_socket_client.dart](../mobile/lib/data/sources/remote/gemini_live_socket_client.dart) (direct-connect transport),
[voice_session.dart](../mobile/lib/data/models/voice_session.dart) (request/response models).

## Transports

There are two ways a voice session's audio/transcript reaches Gemini Live — see
[voice-assistant-websocket-transport.md](explainer/voice-assistant-websocket-transport.md) for the
full architecture writeup:

- **WS-proxy (default, live in production)** — mobile streams audio over `WS
  /voice/session/{session_id}/stream`; the backend holds the actual Gemini Live session
  (Vertex AI or the Developer API, see `VOICE_LIVE_PROVIDER` below) and relays both directions.
- **Direct-connect (native only, off by default)** — mobile calls `POST /voice/session/token` to
  obtain a short-lived, config-locked ephemeral token, then opens its own WebSocket straight to
  Gemini Live using that token. Tool-call side effects (`record_preference`, `search_products`,
  `ready_to_finalize`) still route through the `POST /voice/tool/*` endpoints below either way —
  only the audio/transcript/session-setup relay differs. Gated by two independent flags that must
  both be true: a mobile compile-time flag and the server's own `VOICE_DIRECT_CONNECT_ENABLED`
  (surfaced to the client as `direct_connect_allowed` on `/voice/session/start`); web always uses
  the proxy, since browsers can't set custom WS handshake auth.

## Auth

All REST endpoints require `Authorization: Bearer <Firebase ID token>`
([main.py](../services/voice-assistant/main.py#L88-L92)). The WebSocket endpoint isn't
separately authenticated — it trusts the `session_id` issued by the already-authenticated
`start_session` call. The direct-connect transport's own Gemini Live WebSocket authenticates
with the ephemeral token from `POST /voice/session/token`, not a Firebase token.

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
  "profile": { "shopping_categories": [], "preference_terms": [], "ignore_terms": [] },
  "direct_connect_allowed": false
}
```

`mode` selects the system prompt/tools for the session:
- `"preferences"` — forced first-run onboarding; learns shopping categories/likes/dislikes.
- `"search"` — every other session; conversational product search via the `search_products` tool.

`direct_connect_allowed` is the server-side kill switch for the direct-connect transport (see
Transports above) — `false` unless `VOICE_DIRECT_CONNECT_ENABLED=true` is set on the backend.

### `POST /voice/session/token`

Direct-connect transport only. Mints a short-lived (default 10 min), single-use, model/config-locked
ephemeral auth token for the native mobile app to open its own WebSocket straight to Gemini Live
(Developer API), bypassing this backend for audio streaming. Tool-call side effects still route
through `POST /voice/tool/*` below.

```json
// request
{ "session_id": "<id>" }

// response (200)
{
  "token": "auth_tokens/...",
  "model": "models/gemini-2.5-flash-native-audio-latest",
  "setup": { "model": "...", "generationConfig": { "...": "..." }, "systemInstruction": { "...": "..." }, "...": "..." }
}

// response (502)
{ "detail": "Failed to mint Gemini Live token", "error_code": "REQUEST_ERROR" }
```

`setup` is the exact wire-format JSON the client sends as its first frame on the direct Gemini Live
WebSocket — built server-side (locked to the token via `live_connect_constraints`) so the backend
stays the single source of truth for the session's prompt/tools/voice; the client sends it verbatim,
it never rebuilds this JSON itself.

### `POST /voice/tool/record_preference`, `POST /voice/tool/search_products`, `POST /voice/tool/ready_to_finalize`

Direct-connect transport only. Execute the exact same `apply_record_preference`/`apply_search_products`/
`apply_ready_to_finalize` side effects the WS-proxy path runs internally when Gemini calls the
matching tool — so tool-call side-effect logic (Firestore writes, the Google Shopping+Amazon search)
has exactly one implementation regardless of transport. Each takes `session_id` plus that tool's own
arguments (see [live_session.py](../services/voice-assistant/live_session.py)'s `RECORD_PREFERENCE`/
`SEARCH_PRODUCTS`/`READY_TO_FINALIZE` `FunctionDeclaration`s for the argument shapes) and returns the
same result shape the WS-proxy path would have sent as a `preference_patch`/`product_results`/
`finalize_proposal` frame.

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
{
  "status": "ok",
  "project_id_set": true,
  "voice_live_provider": "vertex",
  "voice_model": "gemini-live-2.5-flash-native-audio"
}
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
| `VOICE_LIVE_PROVIDER` | `vertex` | `vertex` or `dev_api` — which client/model the live session itself connects with (see below) |
| `VOICE_MODEL` | `gemini-live-2.5-flash-native-audio` | Gemini Live model, when `VOICE_LIVE_PROVIDER=vertex` |
| `EXTRACTION_MODEL` | `gemini-2.5-flash` | cheap text model for structured preference extraction (always Vertex AI, unaffected by `VOICE_LIVE_PROVIDER`) |
| `VOICE_NAME` | `Puck` | one of Gemini Live's 8 prebuilt voices |
| `SESSION_MAX_SECONDS` | `600` | hard session cutoff (cost/runaway backstop) |
| `DISCONNECT_GRACE_SECONDS` | `120` | how long a disconnected-but-not-explicitly-exited session stays resumable |
| `SESSION_CONTEXT_WINDOW_TOKENS` | `32000` | triggers context-window compression |
| `INACTIVITY_NUDGE_SECONDS` | `45` | silence before the model is nudged to check in |
| `INACTIVITY_CLOSE_GRACE_SECONDS` | `20` | further silence after the nudge before auto-save |
| `PRODUCT_MATCHER_URL` | — | backs the `search_products` tool (calls its `POST /search`) |
| `VOICE_ASSISTANT_MOCK_GEMINI` | `false` | when `true`, runs a scripted fake conversation with no real Gemini calls |
| `AI_STUDIO_API_KEY` | — | Gemini Developer API key — mints direct-connect ephemeral tokens, and powers the live session itself when `VOICE_LIVE_PROVIDER=dev_api` |
| `VOICE_MODEL_DEV_API` | `models/gemini-2.5-flash-native-audio-latest` | Developer-API model id — dual-purpose: locks direct-connect tokens to this model, and is what the live session uses when `VOICE_LIVE_PROVIDER=dev_api` |
| `VOICE_DIRECT_CONNECT_ENABLED` | `false` | server-side kill switch for the direct-connect transport (see Transports above) |
