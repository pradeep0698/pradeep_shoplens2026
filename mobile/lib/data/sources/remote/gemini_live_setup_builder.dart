/// The direct-connect transport (GeminiLiveSocketClient) now gets its Gemini
/// Live `setup` JSON from the backend's ephemeral-token mint response
/// (POST /voice/session/token — see services/voice-assistant/live_session.py's
/// mint_ephemeral_token/_build_setup_json) instead of building it client-side,
/// so this file no longer needs to port live_session.py's _live_config/
/// _system_prompt/_profile_note/_resume_note/tool schemas — the backend is
/// now the sole source of truth for session setup. This also removes what
/// used to be a hard requirement to keep the Python and Dart system-prompt
/// strings byte-for-byte in sync.
///
/// What's left: the greeting-trigger cue text. The greeting trigger is a
/// separate `realtimeInput` message sent right after `setup` completes
/// (see gemini_live_socket_client.dart's _sendGreetingTrigger), not part of
/// `setup` itself, so it isn't covered by the server-minted response and
/// still needs to be built client-side.
library;

// Verbatim from live_session.py's _send_greeting_trigger cue strings.
const kFreshGreetingCue = "(The user just opened the conversation and hasn't said anything yet.)";
const kResumeGreetingCue =
    "(The connection was briefly interrupted and has just reconnected — the user hasn't said anything new since reconnecting. Don't re-introduce yourself or restart the conversation; briefly acknowledge you're back and continue from where you left off.)";

String greetingCue(bool resumed) => resumed ? kResumeGreetingCue : kFreshGreetingCue;
