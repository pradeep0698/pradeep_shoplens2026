import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/constants/api_constants.dart';
import '../../models/voice_session.dart';
import 'gemini_live_setup_builder.dart';
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

/// Categories explicitly present in a record_preference call's args, if any.
List<String> categoriesFromRecordPreferenceArgs(Map<String, dynamic> args) =>
    (args['shopping_categories'] as List?)?.whereType<String>().toList() ?? const [];

/// Fills in shopping_categories from [lastCategories] when this call's args
/// omit it but still report a preference or exclusion term — the model
/// reliably states a category once, then reports terms for it in later
/// calls without repeating shopping_categories (see the
/// kSystemPromptTemplate clause requiring this, which the model doesn't
/// always follow). Mirrors live_session.py's SessionState.last_categories/
/// _bucket_keys_for_call fallback, applied client-side here so the
/// direct-connect transport doesn't depend on that backend fix being
/// deployed. The backend still re-validates whatever category name is
/// threaded through against the fixed 8-value enum and the current turn's
/// transcript (see _filter_categories) — a stale category can still get
/// dropped there if the current turn's wording gives no evidence for it.
Map<String, dynamic> recordPreferenceArgsWithCategoryFallback(
  Map<String, dynamic> args, {
  required List<String> lastCategories,
}) {
  if (categoriesFromRecordPreferenceArgs(args).isNotEmpty) return args;
  final hasTerms = ((args['preference_terms'] as List?)?.isNotEmpty ?? false) ||
      ((args['ignore_terms'] as List?)?.isNotEmpty ?? false);
  if (hasTerms && lastCategories.isNotEmpty) {
    return {...args, 'shopping_categories': lastCategories};
  }
  return args;
}

// Cap on how many products go into the function response Gemini actually
// reads — matches the backend's search_products result ceiling (see
// live_session.py's _MAX_SEARCH_RESULTS_CEILING/_MAX_PRODUCTS_FOR_MODEL),
// i.e. no truncation beyond what a search can return anyway; the actual
// payload-size fix is stripping image_url/purchase_url below, not limiting
// the count.
const _kMaxProductsForModel = 15;

/// Trimmed view of a search_products result for Gemini's function response —
/// mirrors live_session.py's _search_result_for_model. Real scraped listing
/// data (SerpAPI) can carry image_url as a large inline base64 data URI
/// rather than a plain link, and the model has no use for image/purchase
/// URLs in a spoken conversation anyway — sending the full raw list back as
/// this tool's response risked a single WebSocket text frame large/malformed
/// enough for Gemini's raw Live API to reject the connection outright (a
/// 1007 "invalid frame payload data" close observed right after a search).
/// The on-screen product cards still get the full, untrimmed data separately
/// via the product_results control frame built alongside this.
Map<String, dynamic> searchResultForModel(Map<String, dynamic> result) {
  final products = (result['products'] as List?) ?? const [];
  final trimmed = products.take(_kMaxProductsForModel).map((p) {
    final map = p as Map<String, dynamic>;
    return {
      'name': map['name'] ?? '',
      'price': map['price'] ?? 0,
      'seller': map['seller'] ?? '',
    };
  }).toList();
  return {...result, 'products': trimmed};
}

/// Direct client -> Gemini Live WebSocket transport (native platforms only —
/// dart:io's WebSocket.connect supports the custom auth headers ephemeral
/// tokens require; browsers cannot set custom headers on a WS handshake, so
/// this is never used on web — see voice_transport_selector.dart).
///
/// Bypasses the backend entirely for session start: opens a WebSocket
/// straight to Google's Gemini Live endpoint using a static AI Studio API
/// key (ApiConstants.aiStudioApiKey) and builds its own `setup` JSON
/// client-side (see gemini_live_setup_builder.dart) — no backend call, no
/// ephemeral token. This trades away the ephemeral-token model's short-lived,
/// config-locked security properties for simplicity/backend-independence; a
/// decompiled build exposes this key with no expiry or lock, an accepted
/// tradeoff. Tool-call side effects (record_preference, search_products,
/// ready_to_finalize) still route through backend REST calls (see VoiceApi)
/// since that logic (Firestore writes, the Google Shopping+Amazon combined
/// search) must stay server-side — only the audio/transcript relay and
/// session setup are direct.
///
/// Wire protocol notes (confirmed against the installed google-genai SDK's
/// source, and partially against a live spike — see Phase 0 of the plan):
/// - Raw WebSocket JSON uses lowerCamelCase envelope keys: `setup`,
///   `realtimeInput`, and `toolResponse` client-side; `setupComplete`,
///   `serverContent`, `toolCall`, and `goAway` server-side.
/// - Audio travels base64-encoded inside JSON frames. Incoming JSON may be
///   exposed as either text or bytes depending on the WebSocket client.
/// - Audio uses standard Base64, matching the raw-WebSocket API examples.
///
/// Note: services/voice-assistant's VOICE_ASSISTANT_MOCK_GEMINI dev/test
/// mode has no equivalent here — it only exists in the WS-proxy path
/// (_run_mock_session in live_session.py), since this transport requires a
/// real AI Studio key/model with no mock. This is one reason the transport
/// selector (voice_transport_selector.dart) defaults to the proxy unless a
/// build explicitly opts in via the VOICE_DIRECT_CONNECT_ENABLED dart-define.
class GeminiLiveSocketClient implements VoiceTransport {
  GeminiLiveSocketClient(this._voiceApi);

  // v1beta/BidiGenerateContent (not the token-locked "Constrained" variant,
  // which requires an ephemeral auth token — not applicable with a static
  // key) is the stable, publicly documented Gemini Live endpoint. Not yet
  // spike-tested live — verify on first real connection.
  static const _wsUri =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  final VoiceApi _voiceApi;
  final String _apiKey = ApiConstants.aiStudioApiKey;
  WebSocket? _socket;
  StreamSubscription? _subscription;
  final _frames = StreamController<VoiceSocketFrame>.broadcast();
  Completer<void>? _setupCompleter;

  String? _sessionId;
  int _sampleRate = 16000;

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

  // Categories from the most recent record_preference call that actually
  // named one — mirrors live_session.py's SessionState.last_categories, kept
  // client-side too so this transport doesn't depend on that backend fix
  // being deployed: the model reliably states a category once, then reports
  // preferences/exclusions for it in later calls without repeating
  // shopping_categories, so we fill it back in here before the call ever
  // reaches the backend (see _handleToolCall's 'record_preference' case).
  List<String> _lastCategories = const [];

  @override
  Stream<VoiceSocketFrame> get frames => _frames.stream;

  @override
  Future<void> connect({
    required String sessionId,
    required String wsUrl,
    required VoiceProfilePatch existingProfile,
    required String mode,
    required String language,
    required List<VoiceTranscriptTurn> resumeTranscript,
  }) async {
    if (_apiKey.isEmpty) {
      throw StateError('AI_STUDIO_API_KEY not set — direct-connect transport requires it');
    }
    _sessionId = sessionId;
    final setup = buildSetupJson(
      existingProfile: existingProfile,
      mode: mode,
      language: language,
      resumeTranscript: resumeTranscript,
    );

    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        _wsUri,
        headers: {'x-goog-api-key': _apiKey},
      );
    } on Object {
      // Keep low-level handshake details out of the user-visible error text.
      throw StateError('Could not connect to Gemini Live.');
    }
    _socket = socket;
    final setupCompleter = Completer<void>();
    _setupCompleter = setupCompleter;
    _subscription = socket.listen(
      (event) {
        Map<String, dynamic> message;
        try {
          final payload = switch (event) {
            String value => value,
            List<int> value => utf8.decode(value),
            _ => throw const FormatException(
                'Unsupported WebSocket frame type.',
              ),
          };
          message = jsonDecode(payload) as Map<String, dynamic>;
        } on Object catch (_, stackTrace) {
          if (!setupCompleter.isCompleted) {
            setupCompleter.completeError(
              StateError('Gemini Live returned an unreadable setup response.'),
              stackTrace,
            );
          }
          return;
        }
        _handleMessage(message);
      },
      onDone: () {
        if (!setupCompleter.isCompleted) {
          setupCompleter.completeError(
            StateError(
              'Gemini closed before setup completed '
              '(${socket.closeCode}: ${socket.closeReason ?? 'no reason'}).',
            ),
          );
        }
        _frames.add(
          VoiceSocketClosed(
            code: socket.closeCode,
            reason: socket.closeReason,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!setupCompleter.isCompleted) {
          setupCompleter.completeError(error, stackTrace);
        }
        _frames.addError(error, stackTrace);
      },
    );

    socket.add(jsonEncode({'setup': setup}));
    try {
      await setupCompleter.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      await close();
      throw StateError('Gemini Live did not acknowledge the session setup.');
    } on Object {
      await close();
      rethrow;
    }
    _sendGreetingTrigger(resumed: resumeTranscript.isNotEmpty);
    _resetIdleTimer();
  }

  /// Sends a hidden turn right after connecting so Gemini speaks the opening
  /// greeting itself, mirroring live_session.py's _send_greeting_trigger —
  /// the WS-proxy path's backend sends this; direct-connect must send its
  /// own equivalent now that there's no backend involved in session start.
  /// Reuses the exact activityStart/text/activityEnd shape already proven
  /// by _onIdleNudge below.
  void _sendGreetingTrigger({required bool resumed}) {
    _socket?.add(jsonEncode({'realtimeInput': {'activityStart': {}}}));
    _socket?.add(jsonEncode({'realtimeInput': {'text': greetingCue(resumed)}}));
    _socket?.add(jsonEncode({'realtimeInput': {'activityEnd': {}}}));
  }

  void _handleMessage(Map<String, dynamic> message) {
    final setupCompleter = _setupCompleter;
    final error =
        message['error'] ?? (message.containsKey('code') ? message : null);
    if (error != null) {
      final detail = error is Map ? error['message'] : error;
      final exception = StateError(
        detail is String && detail.isNotEmpty
            ? 'Gemini Live rejected the session: $detail'
            : 'Gemini Live rejected the session.',
      );
      if (setupCompleter != null && !setupCompleter.isCompleted) {
        setupCompleter.completeError(exception);
      } else {
        _frames.addError(exception);
      }
      return;
    }
    if (message.containsKey('setupComplete')) {
      if (setupCompleter != null && !setupCompleter.isCompleted) {
        setupCompleter.complete();
      }
    }
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
    _socket?.add(jsonEncode({'realtimeInput': {'activityStart': {}}}));
    _socket?.add(jsonEncode({'realtimeInput': {'text': _kNudgeText}}));
    _socket?.add(jsonEncode({'realtimeInput': {'activityEnd': {}}}));
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
      _frames.add(const VoiceControlFrame({'type': 'interrupted'}));
    }

    final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
    if (modelTurn != null) {
      final parts = modelTurn['parts'] as List? ?? const [];
      for (final part in parts) {
        final inlineData = (part as Map<String, dynamic>)['inlineData'] as Map<String, dynamic>?;
        final data = inlineData?['data'] as String?;
        if (data != null) {
          _frames.add(VoiceAudioFrame(base64Decode(data)));
        }
      }
    }

    // Raw Live API transcription frames document only `text`; `finished` is
    // not guaranteed on the wire. Forward every fragment so the provider can
    // coalesce it into a live conversation bubble instead of buffering forever.
    final inputTranscription = serverContent['inputTranscription'] as Map<String, dynamic>?;
    if (inputTranscription != null) {
      final text = inputTranscription['text'] as String?;
      if (text != null && text.isNotEmpty) {
        _frames.add(VoiceControlFrame({
          'type': 'transcript',
          'role': 'user',
          'text': text,
          'final': inputTranscription['finished'] == true,
          'fragment': true,
        }));
        _resetIdleTimer();
      }
    }

    final outputTranscription = serverContent['outputTranscription'] as Map<String, dynamic>?;
    if (outputTranscription != null) {
      final text = outputTranscription['text'] as String?;
      if (text != null && text.isNotEmpty) {
        _frames.add(VoiceControlFrame({
          'type': 'transcript',
          'role': 'model',
          'text': text,
          'final': outputTranscription['finished'] == true,
          'fragment': true,
        }));
        _resetIdleTimer();
      }
    }
    if (serverContent['turnComplete'] == true) {
      _frames.add(const VoiceControlFrame({'type': 'assistant_turn_complete'}));
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
          final category = args['category'] as String?;
          // Sent immediately, before awaiting the (possibly ~20-25s combined
          // Google Shopping + Amazon) result — same deterministic loading-
          // state backstop the backend sends on the proxy path.
          _frames.add(VoiceControlFrame({'type': 'search_started', 'query': query}));
          result = await _voiceApi.searchProducts(sessionId, query, category: category);
          _frames.add(VoiceControlFrame({
            'type': 'product_results',
            'query': result['query'] ?? query,
            'products': result['products'] ?? const [],
            'provider': result['provider'] ?? 'unknown',
          }));
        case 'record_preference':
          final effectiveArgs = recordPreferenceArgsWithCategoryFallback(args, lastCategories: _lastCategories);
          final calledCategories = categoriesFromRecordPreferenceArgs(args);
          if (calledCategories.isNotEmpty) _lastCategories = calledCategories;
          result = await _voiceApi.recordPreference(sessionId, effectiveArgs);
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

      functionResponses.add({
        'id': id,
        'name': name,
        'response': name == 'search_products' ? searchResultForModel(result) : result,
        // Matches record_preference's 'behavior': 'NON_BLOCKING' in
        // gemini_live_setup_builder.dart — SILENT scheduling adds the result
        // to context without resuming generation, so it can't produce a
        // second spoken acknowledgement.
        if (name == 'record_preference') 'scheduling': 'SILENT',
      });
    }

    // Sent back over Gemini's own WebSocket after local tool execution.
    _socket?.add(jsonEncode({'toolResponse': {'functionResponses': functionResponses}}));
  }

  @override
  void sendAudio(Uint8List chunk) => _socket?.add(jsonEncode({
        'realtimeInput': {
          'audio': {'data': base64Encode(chunk), 'mimeType': 'audio/pcm;rate=$_sampleRate'}
        }
      }));

  @override
  void sendText(String text) {
    _socket?.add(jsonEncode({'realtimeInput': {'activityStart': {}}}));
    _socket?.add(jsonEncode({'realtimeInput': {'text': text}}));
    _socket?.add(jsonEncode({'realtimeInput': {'activityEnd': {}}}));
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
    _socket?.add(jsonEncode({'realtimeInput': {'activityStart': {}}}));
    _resetIdleTimer();
  }

  @override
  void sendSpeechEnd() => _socket?.add(jsonEncode({'realtimeInput': {'activityEnd': {}}}));

  @override
  Future<void> close() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _subscription?.cancel();
    await _socket?.close();
    _socket = null;
    _setupCompleter = null;
  }

  @override
  void dispose() {
    close();
    _frames.close();
  }
}
