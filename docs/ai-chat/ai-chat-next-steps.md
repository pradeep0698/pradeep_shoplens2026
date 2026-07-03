# Voice Chat — SWOT Analysis & Next Steps

> Analysis based on full codebase review: `services/voice-assistant/`, `mobile/lib/presentation/providers/voice_assistant_provider.dart`, `mobile/lib/presentation/widgets/voice_assistant_overlay.dart`, and supporting utilities.

---

## SWOT Analysis

---

### Strengths

**S1 — No separate STT layer**
Gemini Live's native-audio model understands speech directly. `record_preference` uses the model's audio understanding, not the transcribed caption (which can be wrong). This is explicitly guarded at `live_session.py:595` — the architecture is already designed around this.

**S2 — Explicit turn boundaries (hold-to-talk)**
VAD is disabled on purpose. Client-driven `speech_start/speech_end` means Gemini never cuts a user off mid-sentence due to background noise or a brief pause. On web, where mic audio is noisy/resampled, this is the right call.

**S3 — Pre-roll buffer prevents speech clipping**
`Pcm16SpeechGate` buffers 300ms before the gate opens (`pcm16_speech_gate.dart:19`). The first syllable is never dropped even though the gate triggers after 120ms of voiced audio.

**S4 — Profile baked into system prompt**
Existing preferences are injected as text at session start (`_profile_note`, `live_session.py:172`) rather than fetched via a tool call. This sidesteps a confirmed Gemini Live bug where a data-only tool call kills the model's spoken turn.

**S5 — Two-mode architecture**
`preferences` and `search` modes get separate system prompts, separate tools, and separate behavioral constraints. Neither mode bleeds into the other.

**S6 — Defense-in-depth on category extraction**
Categories go through two gates: `_filter_categories` (enum allowlist) and `_category_has_evidence` (keyword presence check), preventing hallucinated or mismatched categories from entering the profile.

---

### Weaknesses

**W1 — User voice transcripts are silently dropped on the mobile side**
The server sends `{"type": "transcript", "role": "user", ...}` frames. The mobile provider discards them at `voice_assistant_provider.dart:314`:
```dart
if (role == 'user') return;
```
The user sees the model's side of the conversation but not their own. This makes it impossible to notice when the model misheard something.

**W2 — No microphone level feedback**
`Pcm16SpeechGate._rms()` computes RMS per chunk (`pcm16_speech_gate.dart:79`) but the result is private and discarded — only `started: bool` and `chunks` are returned. There is no way to render a mic level indicator without changing the gate's API.

**W3 — 45s inactivity nudge is too long**
`INACTIVITY_NUDGE_SECONDS = 45` (`live_session.py:42`). If a user finishes speaking and doesn't say a closing phrase, the app is silent for 45 seconds. Most users will assume it's broken or closed the app by then.

**W4 — Silent preference accumulation**
`record_preference` tool calls update `session.latest_patch` in real time, but there's no user-visible moment when a new preference is added. The chip preview updates, but only if the user is looking at it. A misheard term accumulates invisibly.

**W5 — No mid-session chip removal**
The review screen allows full editing. But during the live conversation there's no way to remove a wrongly-captured chip. The user has to remember it and fix it at review.

**W6 — No WebSocket reconnect**
If the connection drops (cellular handoff, brief outage), the session is gone. `VoiceSocketClosed` puts the app into `VoiceStatus.error` with "Connection lost — please start again." There is no retry or resume path.

**W7 — Language change disconnects mid-conversation**
The system prompt is fixed for the lifetime of a Gemini Live session. Changing language reconnects entirely (`voice_assistant_overlay.dart:110`). If a user is mid-conversation when they switch, everything is lost.

**W8 — User preferences not applied to search queries**
In search mode, `_dispatch_tool_call` passes only the raw `query` string to product-matcher (`live_session.py:561`). The user's `ignore_terms` (e.g., "plastic", "leather") are not appended to the search query, so SerpAPI returns results the user would have excluded.

**W9 — No "searching..." feedback during product lookup**
`_search_shopping` can take up to 15 seconds (httpx timeout). During that time the UI is silent — no frame is sent before the HTTP call starts. On a slow connection, the user has no indication anything is happening.

---

### Opportunities

**O1 — Typed text already has structured extraction**
`_extract_patch_from_transcript` (`live_session.py:510`) runs a full `gemini-2.5-flash` extraction pass on typed turns. The infrastructure for a secondary accuracy pass already exists and could be extended.

**O2 — Session ID survives teardown**
`_sessionId` in the mobile provider is set to `null` only in `_teardownSession()`, not in `_stopLiveAudio()`. The session can outlive the WebSocket and be re-used for reconnect if the backend session is still alive.

**O3 — `latest_patch` is always current**
The `latest_patch` on both backend and frontend is kept continuously synchronized via `preference_patch` frames. Any mid-session intervention (chip removal, correction) has an accurate base to work from.

**O4 — `save_reviewed_profile` uses `merge=True`**
Non-voice Firestore fields (`allergies`, `dietary_restrictions`) are never clobbered by a voice session finalize. Extending what the voice session saves is safe.

**O5 — Env-var-driven configuration**
Most behavioral parameters (`INACTIVITY_NUDGE_SECONDS`, `SESSION_MAX_SECONDS`, `VOICE_NAME`, `EXTRACTION_MODEL`) are env vars. Several improvements can be shipped as config changes with no code deploy.

---

### Threats

**T1 — Gemini Live regional constraint**
Native-audio model only works at `us-central1`, not `global` (returns 1008 policy-violation close). This is a single point of geographic failure with no fallback in the code.

**T2 — Context window compression can lose early turns**
Sliding window compression (`trigger_tokens=32000`, `live_session.py:448`) can push out early turns. If the model's record of early preferences is compressed away, it may re-ask about things already discussed, reducing trust.

**T3 — SerpAPI cost scales with session engagement**
Each `search_products` call is a real SerpAPI query. The ceiling is 5 per session but an engaged search session reaches it quickly. No user-visible signal that search quota is near.

**T4 — Cloud Run instance affinity**
Sessions live in `session_registry` (in-memory dict). A Cloud Run scale-out event routes a reconnect to a new instance that has no knowledge of the session. Without sticky sessions configured, a reconnect attempt gets a 4004 close.

---

## Improvement Suggestions

Ordered by impact-to-effort ratio — the first four are the highest return for the least work.

---

### 1. Show user voice transcripts as approximate captions
**Effort: Low (remove 2 lines, add a style)**

**What to change:** `voice_assistant_provider.dart:314` — remove the `if (role == 'user') return;` guard. Show user transcript turns in an italic or muted style with a `~` prefix or tooltip saying "approximate."

**Why this matters:** The user currently sees a one-sided conversation. When the model misunderstands ("I said 'organic', not 'organic coffee'"), the user has no way to notice until the review screen. Showing even an approximate transcript gives them a fast feedback loop — if the caption is wrong, they know immediately that a chip may be wrong too. The server already sends this data; the client just throws it away.

**Risk:** Very low. The data arrives already; the only change is rendering it with a visual caveat about accuracy.

**Fixes:** W1

---

### 2. Reduce inactivity nudge from 45s to 20s
**Effort: Trivial (env var change, no code)**

**What to change:** Set `INACTIVITY_NUDGE_SECONDS=20` in the Cloud Run service env vars.

**Why this matters:** 45 seconds of silence with no feedback is an eternity in a voice interaction. Users expect conversational cadence (2-4s between turns). At 45s, most will have closed the app or assumed it crashed. At 20s, the model checks in while the user is still engaged — and the nudge prompt already exists and works well.

**Risk:** Zero. The nudge message is already tuned to be warm and non-jarring. Firing it sooner only helps.

**Fixes:** W3

---

### 3. Append ignore_terms to search queries
**Effort: Low (~10 lines in live_session.py)**

**What to change:** In `_dispatch_tool_call`, before calling `_search_shopping`, append the user's `ignore_terms` as negative keywords to the query:

```python
ignore = session.existing_profile.get("ignore_terms", [])
if ignore:
    exclusions = " ".join(f"-{t}" for t in ignore[:3])  # cap at 3 to stay concise
    query = f"{query} {exclusions}"
```

**Why this matters:** A user who has said "I avoid plastic" or "no leather" expects those filters to apply everywhere — including voice search. Currently, every `search_products` call ignores the profile entirely. This is the single biggest consistency gap between the preferences mode and the search mode: the profile is gathered in one and completely ignored in the other. SerpAPI respects `-term` negative filters in its query string.

**Risk:** Low. Cap the negative terms at 3 to avoid over-constraining queries. Fall back gracefully if the query becomes too long.

**Fixes:** W8

---

### 4. Send a "search_started" frame before the HTTP call
**Effort: Low (1 line in live_session.py)**

**What to change:** In `_dispatch_tool_call` search branch, before the `await _search_shopping(...)` call:

```python
await websocket.send_json({"type": "search_started", "query": query})
```

Mobile handles it by showing a "Searching for [query]..." loading state on the result card.

**Why this matters:** Product-matcher can take up to 15s (the configured httpx timeout). During that window the UI is completely silent — no audio, no transcript, nothing. Users have no signal that a search is running. This single frame eliminates the most common source of "is it working?" confusion in search mode.

**Risk:** Very low. A new frame type the mobile already has a clean switch statement to extend.

**Fixes:** W9

---

### 5. Expose RMS from speech gate for a mic level indicator
**Effort: Medium (~30 lines across 2 files)**

**What to change:** Update `Pcm16SpeechGateResult` to include a `double rms` field. Change `Pcm16SpeechGate.add()` to return the computed RMS on each call. In `VoiceAssistantNotifier.beginSpeaking()`, pass the RMS to a `StreamController` that drives a simple amplitude bar in the overlay.

**Why this matters:** The hold-to-talk model has no visual confirmation that the mic is picking up audio. Users holding the button in a loud environment can't tell if the gate will fire. A waveform or level bar (even just 3 bars) closes this gap entirely — it's the single most common affordance in voice interfaces. The gate already computes RMS; it just doesn't expose it.

**Risk:** Low. The change is contained to the speech gate class and its caller. The gate's existing behavior (triggering at RMS ≥ 700) doesn't change.

**Fixes:** W2

---

### 6. Allow chip removal during the live session
**Effort: Medium (~40 lines in the overlay)**

**What to change:** In the live chip preview shown during the `listening/speaking` states, add a small ✕ button on each chip. Tapping it sends a short correction turn via `_socket.sendText("actually don't include [term]")` and removes the chip optimistically from local state. Since `latest_patch` is server-authoritative, the correction will also update the backend patch via the next `preference_patch` frame.

**Why this matters:** `record_preference` is called immediately and mid-conversation — by design. This means a misheard preference accumulates and the user doesn't get to correct it until the review screen, by which point it's easy to miss. A one-tap removal during the live conversation is much faster and more natural. The review screen already handles full editing, so this is purely additive.

**Risk:** Low. Optimistic removal + server correction via text turn is a clean pattern. Worst case: the server re-adds the term if the correction turn isn't processed (user can always fix at review).

**Fixes:** W4, W5

---

## Summary

| # | Change | Effort | Fixes |
|---|--------|--------|-------|
| 1 | Show user voice transcripts (muted/italic) | Low | W1 — one-sided conversation, missed mishears |
| 2 | Reduce inactivity nudge 45s → 20s | Trivial | W3 — 45s silence feels broken |
| 3 | Append ignore_terms to search queries | Low | W8 — user exclusions ignored in search mode |
| 4 | Send `search_started` frame before HTTP call | Low | W9 — silent 15s wait during product search |
| 5 | Expose RMS from SpeechGate for mic indicator | Medium | W2 — no feedback that mic is picking up audio |
| 6 | Allow chip removal during live session | Medium | W4/W5 — silent accumulation, no mid-session correction |
