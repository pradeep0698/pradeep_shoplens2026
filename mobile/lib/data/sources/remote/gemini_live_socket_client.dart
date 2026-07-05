import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/voice_session.dart';
import 'voice_api.dart';
import 'voice_transport.dart';

// Mirrors services/voice-assistant/live_session.py's
// _INACTIVITY_NUDGE_SECONDS/_INACTIVITY_CLOSE_GRACE_SECONDS — duplicated as
// Dart constants since, on this transport, the backend no longer holds the
// live session to run its own watchdog against.
const _kInactivityNudgeSeconds = 45;
const _kInactivityCloseGraceSeconds = 20;
const _kNudgeText =
    "(The user has gone quiet for a while. Check in warmly and ask if they're "
    'still there — if you already have enough to summarize, do that now and ask '
    'them to confirm.)';

/// Direct client -> Gemini Live WebSocket transport (native platforms only —
/// dart:io's WebSocket.connect supports the custom auth headers ephemeral
/// tokens require; browsers cannot set custom headers on a WS handshake, so
/// this is never used on web — see voice_transport_selector.dart).
///
/// Bypasses the backend for audio streaming entirely: opens a WebSocket
/// straight to Google's Gemini Live endpoint using a short-lived, model/
/// config-locked token minted by POST /voice/session/token. Tool-call side
/// effects (record_preference, search_products, ready_to_finalize) still
/// route through backend REST calls (see VoiceApi) since that logic
/// (Firestore writes, the Google Shopping+Amazon combined search) must stay
/// server-side — only the audio/transcript relay itself is direct.
///
/// Wire protocol notes (confirmed against the installed google-genai SDK's
/// source, and partially against a live spike — see Phase 0 of the plan):
/// - Client->server envelope keys are snake_case: `setup`, `realtime_input`,
///   `tool_response`. Server->client envelope keys are camelCase:
///   `setupComplete`, `serverContent`, `toolCall`, `goAway`. All NESTED
///   fields in both directions are camelCase.
/// - There are no binary WS frames in this protocol — audio travels
///   base64-encoded inside JSON text frames both directions.
/// - Base64 flavor (urlsafe vs standard) was NOT confirmed against a real
///   session by the Phase 0 spike (blocked by an AI Studio billing issue
///   before reaching that check) — this defaults to urlsafe base64
///   (base64Url), matching the installed google-genai SDK's own internal
///   choice (base64.urlsafe_b64encode in _common.py's encode_unserializable_
///   types), the best available signal absent a live confirmation. Flag
///   this as something to verify once billing is resolved, and switch to
///   standard base64Encode/base64Decode if audio doesn't round-trip correctly.
///
/// Note: services/voice-assistant's VOICE_ASSISTANT_MOCK_GEMINI dev/test
/// mode has no equivalent here — it only exists in the WS-proxy path
/// (_run_mock_session in live_session.py), since this transport requires a
/// real AI Studio key/model with no mock. This is one reason the transport
/// selector (voice_transport_selector.dart) defaults to the proxy unless a
/// build explicitly opts in via the VOICE_DIRECT_CONNECT_ENABLED dart-define.
class GeminiLiveSocketClient implements VoiceTransport {
  GeminiLiveSocketClient(this._voiceApi);

  static const _wsUri =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';

  final VoiceApi _voiceApi;
  WebSocket? _socket;
  StreamSubscription? _subscription;
  final _frames = StreamController<VoiceSocketFrame>.broadcast();

  String? _sessionId;
  int _sampleRate = 16000;
  String _pendingInputTranscript = '';
  String _pendingOutputTranscript = '';

  // Idle nudge/close-grace watchdog — moved client-side since the backend no
  // longer holds this session's live connection to run its own watchdog
  // against (see live_session.py's _watch_inactivity for the proxy-path
  // equivalent this mirrors). Reset on every real activity signal below.
  Timer? _idleTimer;
  bool _nudged = false;
  bool _autoSaved = false;
  // Accumulated locally from record_preference tool-call results — the
  // transport's own best-effort copy of "what's been captured so far",
  // used only as the fallback auto-save payload if the session goes
  // genuinely idle. Starts empty rather than backfilled from the existing
  // profile (unlike the backend's SessionState.latest_patch), since that
  // profile isn't threaded into this transport — acceptable because this
  // path is a rare safety net, not the normal save flow (ready_to_finalize
  // + user confirmation is).
  Map<String, dynamic> _latestPatch = const {
    'shopping_categories': <String>[],
    'preference_terms': <String>[],
    'ignore_terms': <String>[],
  };

  @override
  Stream<VoiceSocketFrame> get frames => _frames.stream;

  @override
  Future<void> connect({required String sessionId, required String wsUrl}) async {
    _sessionId = sessionId;
    final tokenResponse = await _voiceApi.mintToken(sessionId);

    final socket = await WebSocket.connect(
      _wsUri,
      headers: {
        'Authorization': 'Token ${tokenResponse.token}',
        'x-goog-api-key': tokenResponse.token,
      },
    );
    _socket = socket;
    _subscription = socket.listen(
      (event) {
        if (event is! String) return; // no binary frames in this protocol
        Map<String, dynamic> message;
        try {
          message = jsonDecode(event) as Map<String, dynamic>;
        } catch (_) {
          return; // malformed frame — ignore rather than crash the session
        }
        _handleMessage(message);
      },
      onDone: () => _frames.add(const VoiceSocketClosed()),
      onError: (Object error, StackTrace _) => _frames.addError(error),
    );

    socket.add(jsonEncode({'setup': tokenResponse.setup}));
    _resetIdleTimer();
  }

  void _handleMessage(Map<String, dynamic> message) {
    if (message.containsKey('serverContent')) {
      _handleServerContent(message['serverContent'] as Map<String, dynamic>);
    }
    if (message.containsKey('toolCall')) {
      _resetIdleTimer();
      unawaited(_handleToolCall(message['toolCall'] as Map<String, dynamic>));
    }
    if (message.containsKey('goAway')) {
      // Server-initiated close warning — same graceful path as the hard
      // session-length backstop (_autoSaveAndClose below), matching the
      // proxy path's _auto_save_and_close (which also isn't a bare error —
      // it saves whatever's captured and reports success).
      unawaited(_autoSaveAndClose());
    }
    // setupComplete: no-op, connection is simply ready for realtime_input.
  }

  /// Restarts the nudge/close-grace watchdog — called on every genuine
  /// activity signal (connect, outbound speech/text, a finished
  /// transcription fragment, a tool call). Mirrors live_session.py's
  /// _watch_inactivity, just client-side since the backend doesn't hold
  /// this session's live connection on this transport.
  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _nudged = false;
    _idleTimer = Timer(const Duration(seconds: _kInactivityNudgeSeconds), _onIdleNudge);
  }

  void _onIdleNudge() {
    if (_nudged) return;
    _nudged = true;
    _socket?.add(jsonEncode({'realtime_input': {'activityStart': {}}}));
    _socket?.add(jsonEncode({'realtime_input': {'text': _kNudgeText}}));
    _socket?.add(jsonEncode({'realtime_input': {'activityEnd': {}}}));
    _idleTimer = Timer(const Duration(seconds: _kInactivityCloseGraceSeconds), () {
      unawaited(_autoSaveAndClose());
    });
  }

  /// Reached either via genuine inactivity (nudge got no response) or a
  /// server-initiated goAway — saves whatever's been captured so far (the
  /// transport's own _latestPatch, accumulated from record_preference
  /// results) via the existing POST /voice/session/finalize endpoint,
  /// rather than just erroring out. Idempotent — goAway and the idle
  /// watchdog could both fire.
  Future<void> _autoSaveAndClose() async {
    if (_autoSaved) return;
    _autoSaved = true;
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final result = await _voiceApi.finalizeSession(sessionId, VoiceProfilePatch.fromJson(_latestPatch));
      _frames.add(VoiceControlFrame({
        'type': 'auto_saved',
        'shopping_categories': result.shoppingCategories,
        'preference_terms': result.preferenceTerms,
        'ignore_terms': result.ignoreTerms,
        'conflicts': result.conflicts,
      }));
    } catch (_) {
      _frames.add(const VoiceControlFrame({'type': 'session_timeout'}));
    }
  }

  void _handleServerContent(Map<String, dynamic> serverContent) {
    if (serverContent['interrupted'] == true) {
      // Barge-in cuts the turn short — matches _pump_gemini_to_client's
      // handling: drop any buffered fragments, they belong to the cut-off turn.
      _pendingInputTranscript = '';
      _pendingOutputTranscript = '';
      _frames.add(const VoiceControlFrame({'type': 'interrupted'}));
    }

    final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
    if (modelTurn != null) {
      final parts = modelTurn['parts'] as List? ?? const [];
      for (final part in parts) {
        final inlineData = (part as Map<String, dynamic>)['inlineData'] as Map<String, dynamic>?;
        final data = inlineData?['data'] as String?;
        if (data != null) {
          _frames.add(VoiceAudioFrame(base64Url.decode(data)));
        }
      }
    }

    // Mirrors _pump_gemini_to_client's fragment accumulation: flush only on
    // that stream's own `finished` flag, never on an outer turn-complete
    // signal — Gemini's docs give no ordering guarantee between the two,
    // and flushing early can emit an incomplete/wrong fragment.
    final inputTranscription = serverContent['inputTranscription'] as Map<String, dynamic>?;
    if (inputTranscription != null) {
      final text = inputTranscription['text'] as String?;
      if (text != null) _pendingInputTranscript += text;
      if (inputTranscription['finished'] == true && _pendingInputTranscript.isNotEmpty) {
        _frames.add(VoiceControlFrame({
          'type': 'transcript', 'role': 'user', 'text': _pendingInputTranscript, 'final': true,
        }));
        _pendingInputTranscript = '';
        _resetIdleTimer();
      }
    }

    final outputTranscription = serverContent['outputTranscription'] as Map<String, dynamic>?;
    if (outputTranscription != null) {
      final text = outputTranscription['text'] as String?;
      if (text != null) _pendingOutputTranscript += text;
      if (outputTranscription['finished'] == true && _pendingOutputTranscript.isNotEmpty) {
        _frames.add(VoiceControlFrame({
          'type': 'transcript', 'role': 'model', 'text': _pendingOutputTranscript, 'final': true,
        }));
        _pendingOutputTranscript = '';
        _resetIdleTimer();
      }
    }
  }

  Future<void> _handleToolCall(Map<String, dynamic> toolCall) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final functionCalls = toolCall['functionCalls'] as List? ?? const [];
    final functionResponses = <Map<String, dynamic>>[];

    for (final rawCall in functionCalls) {
      final call = rawCall as Map<String, dynamic>;
      final id = call['id'] as String;
      final name = call['name'] as String;
      final args = (call['args'] as Map<String, dynamic>?) ?? const {};

      Map<String, dynamic> result;
      switch (name) {
        case 'search_products':
          final query = args['query'] as String? ?? '';
          // Sent immediately, before awaiting the (possibly ~20-25s combined
          // Google Shopping + Amazon) result — same deterministic loading-
          // state backstop the backend sends on the proxy path.
          _frames.add(VoiceControlFrame({'type': 'search_started', 'query': query}));
          result = await _voiceApi.searchProducts(sessionId, query);
          _frames.add(VoiceControlFrame({
            'type': 'product_results',
            'query': result['query'] ?? query,
            'products': result['products'] ?? const [],
            'provider': result['provider'] ?? 'unknown',
          }));
        case 'record_preference':
          result = await _voiceApi.recordPreference(sessionId, args);
          if (result['patch'] is Map<String, dynamic>) {
            _latestPatch = result['patch'] as Map<String, dynamic>;
          }
          _frames.add(VoiceControlFrame({'type': 'preference_patch', 'patch': result['patch'] ?? const {}}));
        case 'ready_to_finalize':
          final summary = args['summary'] as String? ?? '';
          result = await _voiceApi.readyToFinalize(sessionId, summary);
          _frames.add(VoiceControlFrame({'type': 'finalize_proposal', 'patch': result['patch'] ?? const {}}));
        default:
          result = {'status': 'unknown_tool'};
      }

      functionResponses.add({'id': id, 'name': name, 'response': result});
    }

    // Sent back over Gemini's own WS (not the backend) — note the
    // snake_case top-level key despite every other server-bound field being
    // camelCase (confirmed from the SDK's literal json.dumps call site).
    _socket?.add(jsonEncode({'tool_response': {'functionResponses': functionResponses}}));
  }

  @override
  void sendAudio(Uint8List chunk) => _socket?.add(jsonEncode({
        'realtime_input': {
          'audio': {'data': base64Url.encode(chunk), 'mimeType': 'audio/pcm;rate=$_sampleRate'}
        }
      }));

  @override
  void sendText(String text) {
    _socket?.add(jsonEncode({'realtime_input': {'activityStart': {}}}));
    _socket?.add(jsonEncode({'realtime_input': {'text': text}}));
    _socket?.add(jsonEncode({'realtime_input': {'activityEnd': {}}}));
    _resetIdleTimer();
  }

  /// No server-side counterpart on this transport — the mime type (which
  /// encodes the sample rate) is sent per audio chunk instead (see
  /// sendAudio above). Kept as a stored value only, for VoiceTransport
  /// interface compatibility with the proxy transport.
  @override
  void sendAudioFormat(int sampleRate) => _sampleRate = sampleRate;

  @override
  void sendSpeechStart() {
    _socket?.add(jsonEncode({'realtime_input': {'activityStart': {}}}));
    _resetIdleTimer();
  }

  @override
  void sendSpeechEnd() => _socket?.add(jsonEncode({'realtime_input': {'activityEnd': {}}}));

  @override
  Future<void> close() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;
  }

  @override
  void dispose() {
    close();
    _frames.close();
  }
}
