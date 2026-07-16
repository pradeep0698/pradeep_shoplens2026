# Voice Assistant — Architecture Diagrams

Three diagrams covering different views of the voice assistant system:
- [Data Flow](#data-flow) — what moves between which components
- [Control Flow](#control-flow) — session lifecycle and state transitions
- [Prompt Flow](#prompt-flow) — how the Gemini system prompt is assembled

**Scope note:** these diagrams cover the WS-proxy transport only (the one live in production
today). They predate the direct-connect transport (mobile talking straight to Gemini Live via an
ephemeral token) and the `VOICE_LIVE_PROVIDER` model switch — see
[voice-assistant-websocket-transport.md](../explainer/voice-assistant-websocket-transport.md) for
that architecture, including its own mermaid diagram covering both transports.

---

## Data Flow

End-to-end movement of audio, control frames, tool calls, and persistence.

```mermaid
flowchart TD
    subgraph Mobile["Mobile App (Flutter)"]
        MIC["Mic\n(AudioRecorder)"]
        GATE["Pcm16SpeechGate\nRMS threshold, 120ms trigger\n300ms pre-roll buffer"]
        RESAMP["Pcm16Resampler\ndevice rate → 16 kHz"]
        SOCK_OUT["VoiceSocketClient\nsend: binary PCM16\nsend: JSON control frames"]
        SOCK_IN["VoiceSocketClient\nreceive: binary audio\nreceive: JSON frames"]
        PLAYER["VoiceAudioPlayer\nflutter_sound stream\n24 kHz PCM16 mono"]
        PROVIDER["VoiceAssistantNotifier\n(Riverpod state)"]
        UI["Voice Overlay UI\ntranscript · patch preview\nsearch results · review screen"]
    end

    subgraph Backend["voice-assistant service (FastAPI / Cloud Run)"]
        REST["POST /voice/session/start\nPOST /voice/session/finalize"]
        WS["WebSocket\n/voice/session/{id}/stream"]
        PUMP_IN["_pump_client_to_gemini\nbinary → Blob(audio/pcm;rate=N)\nJSON → activity_start/end + text"]
        PUMP_OUT["_pump_gemini_to_client\naudio chunks → binary frames\ntranscripts → JSON frames\ntool calls → dispatch"]
        DISPATCH["_dispatch_tool_call\nrecord_preference\nready_to_finalize\nsearch_products"]
        EXTRACT["_extract_patch_from_transcript\n(typed text only)\ngemini-2.5-flash"]
    end

    subgraph External["External Services"]
        GEMINI["Gemini Live API\nVertex AI (default) or Developer API\nmodel/provider set by VOICE_LIVE_PROVIDER"]
        MATCHER["product-matcher\nPOST /search"]
        SERP["SerpAPI\nGoogle Shopping"]
        FS["Firestore\nUserProfiles collection"]
    end

    MIC -->|raw PCM16| GATE
    GATE -->|gated 16kHz chunks| RESAMP
    RESAMP -->|16kHz PCM16| SOCK_OUT
    SOCK_OUT -->|binary frames\nspeech_start/end\naudio_format| WS

    WS --> PUMP_IN
    PUMP_IN -->|Blob audio/pcm;rate=16000\nactivity_start/end| GEMINI

    GEMINI -->|audio chunks 24kHz PCM16\ntranscript fragments\ntool_call events| PUMP_OUT
    PUMP_OUT -->|binary audio| WS
    PUMP_OUT -->|transcript JSON\npreference_patch JSON\nproduct_results JSON\nfinalize_proposal JSON| WS
    PUMP_OUT -->|tool_call| DISPATCH

    DISPATCH -->|record_preference\nready_to_finalize| PUMP_OUT
    DISPATCH -->|search_products query| MATCHER
    MATCHER -->|shopping query| SERP
    SERP -->|product list| MATCHER
    MATCHER -->|products JSON| DISPATCH

    WS -->|binary audio| SOCK_IN
    WS -->|JSON control frames| SOCK_IN
    SOCK_IN -->|VoiceAudioFrame| PLAYER
    SOCK_IN -->|VoiceControlFrame| PROVIDER
    PLAYER -->|PCM16 playback| UI
    PROVIDER -->|state updates| UI

    REST -->|load existing profile| FS
    REST -->|session_id + ws_url + profile| Mobile
    EXTRACT -->|structured patch| PROVIDER
    PROVIDER -->|confirmed_patch| REST
    REST -->|save preferences| FS
```

---

## Control Flow

Session lifecycle, mode branching, and UI state transitions.

```mermaid
stateDiagram-v2
    [*] --> idle

    idle --> connecting : start(mode, language)

    connecting --> error : mic denied\nor HTTP error
    connecting --> listening : WebSocket open\ngreeting trigger sent\nplayer ready

    listening --> listening : model audio arrives\n(debounce 800ms → back)
    listening --> speaking : model audio / transcript arrives
    speaking --> listening : 800ms silence debounce
    speaking --> listening : interrupted frame\n(barge-in — flush queued audio)

    listening --> listening : hold-to-talk pressed\nbeginSpeaking()
    listening --> listening : hold-to-talk released\nendSpeaking()

    note right of listening
        hold-to-talk flow:
        press → speech_start frame
        PCM16 chunks stream
        release → speech_end frame
    end note

    listening --> review : finalize_proposal frame\n(Gemini called ready_to_finalize\nor user said closing phrase)
    speaking --> review : finalize_proposal frame
    listening --> review : finishNow()\n(Done button tapped)

    review --> saving : confirm()\nteardown live audio
    review --> idle : cancel()

    saving --> done : POST /finalize OK\nFirestore saved
    saving --> error : POST /finalize failed

    done --> [*]
    error --> [*] : user dismisses

    note right of review
        User can edit chips:
        categories · preference_terms
        ignore_terms
        before confirming
    end note

    note left of saving
        WebSocket already closed
        before this state —
        only REST call remains
    end note
```

### Mode Branching

```mermaid
flowchart TD
    START["POST /voice/session/start\n{mode, language}"]

    START --> MCHECK{mode?}

    MCHECK -->|"preferences\n(first run / onboarding)"| PMODE["Preferences Session"]
    MCHECK -->|"search\n(all other sessions)"| SMODE["Search Session"]

    subgraph PMODE_BOX["Preferences Mode"]
        PTOOL["Tools: record_preference\n        ready_to_finalize"]
        PPROMPT["System prompt:\nlearn durable shopping preferences\nask follow-ups per category\nrecord_preference on every mention"]
        PREC["record_preference called\n→ session.latest_patch updated\n→ preference_patch frame → mobile"]
        PFIN["ready_to_finalize called\n→ finalize_proposal frame\n→ UI enters review state"]
        PEXTRACT["_extract_patch_from_transcript\n(typed text only)\ngemini-2.5-flash structured output"]
        PTOOL --> PPROMPT --> PREC --> PFIN
        PREC --> PEXTRACT
    end

    subgraph SMODE_BOX["Search Mode"]
        STOOL["Tool: search_products"]
        SPROMPT["System prompt:\nhelp find products\nask 1 follow-up if query too vague\ndon't burn SerpAPI on broad queries"]
        SSEARCH["search_products({query}) called\n→ product-matcher POST /search\n→ SerpAPI Google Shopping\n→ product_results frame → mobile"]
        STOOL --> SPROMPT --> SSEARCH
    end

    PMODE --> PMODE_BOX
    SMODE --> SMODE_BOX
```

### Inactivity Watchdog

```mermaid
sequenceDiagram
    participant W as _watch_inactivity
    participant S as SessionState.last_activity_at
    participant G as Gemini Live
    participant C as Client WebSocket

    loop every 1s
        W->>S: check idle_for = now - last_activity_at
        alt idle_for >= 45s and not nudged
            W->>G: send_realtime_input(text="user gone quiet, check in")
            Note over W: nudged = True
        else idle_for >= 65s and nudged
            W->>C: send_json({type: session_timeout})
            W-->>W: return (session closes)
        end
    end

    Note over S: last_activity_at bumped on:<br/>greeting sent · speech_start<br/>typed text · turn completed
```

---

## Prompt Flow

How the Gemini Live system prompt is assembled from runtime data.

```mermaid
flowchart TD
    subgraph Inputs["Inputs (resolved at session start)"]
        PROFILE["Firestore UserProfile\n{shopping_categories,\n preference_terms,\n ignore_terms}"]
        MODE["mode\n'preferences' | 'search'"]
        LANG["language\ne.g. 'Spanish'"]
    end

    subgraph Build["_system_prompt() — live_session.py:199"]
        TMPL{Pick template}
        PTMPL["SYSTEM_PROMPT_TEMPLATE\n(preferences mode)\n— learn durable preferences\n— call record_preference immediately\n— ask category follow-ups\n— summarize, await confirmation\n— call ready_to_finalize after confirm"]
        STMPL["SEARCH_SYSTEM_PROMPT_TEMPLATE\n(search mode)\n— ask 1 follow-up if query vague\n— call search_products once per topic\n— don't repeat search on rephrasing\n— briefly acknowledge results"]
        PNOTE["_profile_note(existing_profile)\n\nNo data:\n'User has no saved preferences yet'\n\nWith data:\n'shops for X; likes Y; avoids Z.\nDon't re-ask unless user brings up'"]
        FILL[".format(profile_note=...)"]
        LANGCHECK{language\n!= 'English'?}
        LANGAPPEND["Append:\n'Conduct this entire conversation\nin {language} — speak and respond\nonly in {language}, regardless of\nwhat language the user uses.'"]
        NOTE_LANG["Note: SpeechConfig.language_code\nignored by native-audio models.\nSystem prompt is the only lever."]
    end

    subgraph Config["_live_config() → LiveConnectConfig"]
        SYSCONTENT["system_instruction:\nContent(parts=[Part(text=prompt)])"]
        MODALITIES["response_modalities: ['AUDIO']"]
        TOOLS["tools: PREFERENCE_TOOLS\n        or SEARCH_TOOLS"]
        VOICE["speech_config:\nPrebuiltVoiceConfig(voice_name='Puck')"]
        TRANSCRIPTION["input_audio_transcription: enabled\noutput_audio_transcription: enabled"]
        VAD["realtime_input_config:\nautomatic_activity_detection: disabled\n(client drives turn boundaries)"]
        CTX["context_window_compression:\ntrigger_tokens=32000, sliding_window"]
    end

    subgraph Connect["Session Open"]
        GREET["_send_greeting_trigger()\n→ activity_start\n→ text: '(user just opened, hasn't spoken)'\n→ activity_end\n\nGemini speaks opening greeting itself\n(not a static string)"]
    end

    PROFILE --> PNOTE
    MODE --> TMPL
    TMPL -->|preferences| PTMPL
    TMPL -->|search| STMPL
    PTMPL --> FILL
    STMPL --> FILL
    PNOTE --> FILL
    FILL --> LANGCHECK
    LANGCHECK -->|yes| LANGAPPEND --> SYSCONTENT
    LANGCHECK -->|no| SYSCONTENT
    LANGAPPEND -.->|how it works| NOTE_LANG
    LANG --> LANGCHECK

    SYSCONTENT --> Config
    MODE --> TOOLS
    TOOLS --> Config

    Config -->|"client.aio.live.connect(\n  model=<selected by VOICE_LIVE_PROVIDER>,\n  config=...)"| Connect
    Connect --> GREET
```

### Prompt Templates — Annotated

```mermaid
flowchart LR
    subgraph PREF["SYSTEM_PROMPT_TEMPLATE (preferences)"]
        P1["Role & tone\n'warm shopping assistant'\n'brief and human'"]
        P2["Conversation rules\n— acknowledge first, then ask one follow-up\n— vary phrasing, no checklist language\n— ask category follow-up before moving on\n— prefer stable over transient preferences"]
        P3["{profile_note}\ninjected at format() time"]
        P4["Tool call rules\n— call record_preference immediately\n  when user states anything\n— trust own audio understanding\n  over the transcribed caption\n— summarize once, ask for confirm\n— call ready_to_finalize after confirm only"]
        P5["Greeting cue rule\n'first message is a hidden cue —\nspeak first, mention done button'"]
        P1 --> P2 --> P3 --> P4 --> P5
    end

    subgraph SEARCH["SEARCH_SYSTEM_PROMPT_TEMPLATE (search)"]
        S1["Role & tone\n'friendly shopping assistant'\n'brief and conversational'"]
        S2["Search discipline\n— ask ONE follow-up if query is vague\n  (bare category = too vague)\n— fold budget into query text\n  ('headphones under $50')\n— don't search again on rephrasing"]
        S3["{profile_note}\ninjected at format() time"]
        S4["After results\n— briefly acknowledge without listing items\n  (user sees results on screen)\n— ask to refine or search again"]
        S5["Greeting cue rule\n'speak first, ask what they're shopping for'"]
        S1 --> S2 --> S3 --> S4 --> S5
    end
```

---

### Tool Definitions Summary

```mermaid
flowchart TD
    subgraph PTOOLS["Preference Tools (mode=preferences)"]
        RP["record_preference\n─────────────────────\nparams:\n  shopping_categories: string[]\n    (enum: 8 fixed categories)\n  preference_terms: string[]\n    (brand, style, material, color)\n  ignore_terms: string[]\n    (things to exclude)\n─────────────────────\ncall timing: immediately\nwhen user states anything\n─────────────────────\neffect: merges into\nsession.latest_patch\n→ preference_patch frame"]
        RTF["ready_to_finalize\n─────────────────────\nparams:\n  summary: string\n    (the sentence you spoke)\n─────────────────────\ncall timing: ONLY after\nexplicit user confirmation\n─────────────────────\neffect: packages latest_patch\n+ summary into proposal\n→ finalize_proposal frame\n→ UI enters review state"]
    end

    subgraph STOOLS["Search Tool (mode=search)"]
        SP["search_products\n─────────────────────\nparams:\n  query: string\n    (product type + detail)\n─────────────────────\ncall timing: once per topic,\nnot on rephrasing\nfold budget into query text\n─────────────────────\neffect: HTTP → product-matcher\n→ SerpAPI Google Shopping\n→ product_results frame"]
    end
```
