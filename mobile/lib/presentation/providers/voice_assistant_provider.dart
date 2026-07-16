import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/utils/mic_permission.dart';
import '../../core/utils/pcm16_agc.dart';
import '../../core/utils/pcm16_resampler.dart';
import '../../core/utils/pcm16_speech_gate.dart';
import '../../core/utils/transcript_fragment_merger.dart';
import '../../core/utils/voice_audio_player.dart';
import '../../core/utils/web_audio_sample_rate.dart';
import '../../data/models/voice_session.dart';
import '../../data/sources/remote/voice_api.dart';
import '../../data/sources/remote/voice_transport.dart';
import '../../data/sources/remote/voice_transport_selector.dart';

// Gemini Live API expects raw 16-bit PCM input at 16kHz.
const _kInputSampleRate = 16000;
const _kAssistantTurnTailMs = 140;

String _displayVoiceError(Object error) {
  return error
      .toString()
      .replaceFirst(RegExp(r'^(Bad state|Exception):\s*'), '');
}

enum VoiceStatus { idle, connecting, listening, speaking, review, saving, done, error }

class VoiceAssistantState {
  const VoiceAssistantState({
    this.status = VoiceStatus.idle,
    this.isHandsFreeActive = false,
    this.isRecording = false,
    this.transcript = const [],
    this.patch = const VoiceProfilePatch(),
    this.finalizeProposal,
    this.result,
    this.errorMessage,
    this.searchResults = const [],
  });

  final VoiceStatus status;
  // True from the moment the hands-free toggle is tapped on until it's
  // tapped off again (or the session otherwise ends) — spans the whole
  // conversation, not just one utterance. See
  // VoiceAssistantNotifier.startHandsFree/stopHandsFree.
  final bool isHandsFreeActive;
  // True only while an utterance is actively being captured right now (the
  // re-armable speech gate is open) — NOT paused while the assistant is
  // talking, since hands-free mode supports barge-in: the gate can reopen
  // (and this flips back to true) the instant the user starts talking over
  // the assistant, whatever `status` currently is.
  final bool isRecording;
  final List<VoiceTranscriptTurn> transcript;
  final VoiceProfilePatch patch;
  final VoiceProfilePatch? finalizeProposal;
  final VoiceFinalizeResult? result;
  final String? errorMessage;
  // Search-mode only — one entry per search_products tool call, newest
  // first (inserted at the front) so the overlay can pin the latest search
  // prominently and collapse older ones into an accordion.
  final List<VoiceSearchResult> searchResults;

  VoiceAssistantState copyWith({
    VoiceStatus? status,
    bool? isHandsFreeActive,
    bool? isRecording,
    List<VoiceTranscriptTurn>? transcript,
    VoiceProfilePatch? patch,
    VoiceProfilePatch? finalizeProposal,
    VoiceFinalizeResult? result,
    String? errorMessage,
    List<VoiceSearchResult>? searchResults,
  }) =>
      VoiceAssistantState(
        status: status ?? this.status,
        isHandsFreeActive: isHandsFreeActive ?? this.isHandsFreeActive,
        isRecording: isRecording ?? this.isRecording,
        transcript: transcript ?? this.transcript,
        patch: patch ?? this.patch,
        finalizeProposal: finalizeProposal ?? this.finalizeProposal,
        result: result ?? this.result,
        errorMessage: errorMessage,
        searchResults: searchResults ?? this.searchResults,
      );
}

/// Drives a single voice-assistant conversation: connects to
/// services/voice-assistant, streams mic audio, relays typed text turns,
/// plays back the model's spoken audio, and surfaces the live
/// transcript/preference preview/finalize proposal.
class VoiceAssistantNotifier extends AutoDisposeNotifier<VoiceAssistantState> {
  String? _sessionId;
  AudioRecorder? _recorder;
  // Constructed lazily in start() once the session-start response's
  // directConnectAllowed flag is known — createVoiceTransport() (see
  // voice_transport_selector.dart) picks the WS proxy or the native-only
  // direct-connect transport based on that flag plus a compile-time flag.
  VoiceTransport? _socket;
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<VoiceSocketFrame>? _frameSubscription;
  Timer? _speakingDebounce;
  // Set on the rising edge into VoiceStatus.speaking (see _markSpeaking) —
  // used to suppress the optimistic local-VAD barge-in flush for a short
  // grace period after the assistant starts talking. Right as a fast-
  // trailing phrase ends, imperfect echo cancellation can leak a bit of the
  // assistant's own audio into the mic, reading as the user starting to
  // talk — flushing on that reads as truncated/mushed playback. Within the
  // grace period, only the server's own authoritative 'interrupted' message
  // (handled elsewhere) clears playback; outside it, the instant local flush
  // still applies for genuine mid-utterance barge-in.
  DateTime? _speakingSince;
  static const _bargeInGraceMs = 400;
  // False until the assistant's first utterance on the current player
  // instance (almost always the opening greeting) has finished — the local
  // VAD flush is skipped entirely for that one turn (see the
  // Pcm16SpeechGateEvent.started handler), relying solely on the server's
  // authoritative 'interrupted' message instead. A fresh FlutterSoundPlayer
  // is more prone to first-burst timing hiccups (see VoiceAudioPlayer's own
  // iOS warmup workaround) and the greeting is the one utterance every
  // session guarantees, so it's worth eating the round-trip latency here to
  // never truncate it, rather than tuning _bargeInGraceMs against a cold
  // player's less predictable timing.
  bool _hadFirstSpeakingTurn = false;
  VoiceAudioPlayer? _player;
  // Smooths out Gemini's turn-to-turn TTS loudness variance before playback
  // — see Pcm16Agc. One instance per player/session so its gain state
  // doesn't carry an odd starting point over from a previous conversation.
  Pcm16Agc? _agc;
  Pcm16Resampler? _micResampler;
  Pcm16ReArmableSpeechGate? _speechGate;
  int _captureSampleRate = _kInputSampleRate;
  bool _speechStarted = false;
  int _generation = 0;
  // Set by start() — gates the preference-only closing-phrase/review-step
  // behavior in sendText()/finishNow() below, since search-mode sessions
  // never reach a review step.
  bool _isOnboarding = true;
  // Orders transcript turns chronologically within the transcript chat feed.
  int _seq = 0;
  int _nextSeq() => _seq++;
  // Direct Gemini transcription arrives as fragments. Tracks the currently
  // open speaker bubble so each fragment updates one visible turn.
  String? _openTranscriptRole;
  // Stable key for VoiceSearchResult entries — a separate counter from _seq
  // since search results are no longer ordered by arrival relative to the
  // transcript (they're pinned newest-first in their own section instead).
  int _searchId = 0;
  int _nextSearchId() => _searchId++;
  // feedUint8FromStream() must not be called again before the previous call's
  // future completes — this chain serializes frames as they arrive, since the
  // socket can deliver them faster than playback consumes them.
  Future<void> _feedChain = Future.value();
  // Bumped by _flushPlayback() so chunks already chained onto a pre-flush
  // _feedChain (queued behind an in-flight playPcm16 await) no-op instead of
  // writing stale audio into the freshly restarted stream — reassigning
  // _feedChain alone only affects chunks chained after the flush, not ones
  // already attached to the old chain.
  int _playbackGeneration = 0;

  // Lightweight per-session diagnostics, pushed to the backend (which logs it
  // under the VOICE_TRACE prefix — see live_session.py/main.py) at teardown
  // so a "mic seems dead" report can be correlated with server-side timing
  // without needing a device attached. Reset at the top of start() for a
  // fresh (non-resume) session.
  DateTime? _diagSessionStart;
  final List<Map<String, dynamic>> _diagEvents = [];
  int _diagMicChunks = 0;
  int _diagMicBytesReceived = 0;
  int _diagAudioBytesSent = 0;
  int _diagGateOpenCount = 0;
  String? _diagMicPermissionStatus;
  bool _diagDirectConnect = false;
  String? _diagRecorderError;
  // Set the moment sendSpeechEnd() fires; cleared on the first frame back
  // from the server — end-to-end (network + Gemini + tool-call) latency for
  // that turn, comparable against the server's own turn_first_response trace
  // to isolate network overhead from backend/model latency.
  DateTime? _diagTurnRequestedAt;

  void _diagEvent(String event, [Map<String, dynamic>? data]) {
    if (_diagEvents.length >= 100) return;
    final elapsedMs =
        _diagSessionStart == null ? 0 : DateTime.now().difference(_diagSessionStart!).inMilliseconds;
    _diagEvents.add({'t_ms': elapsedMs, 'event': event, if (data != null) ...data});
  }

  void _flushDiagnostics() {
    final sessionId = _sessionId;
    if (sessionId == null || _diagEvents.isEmpty) return;
    final payload = {
      'platform': defaultTargetPlatform.name,
      'direct_connect': _diagDirectConnect,
      'mic_permission': _diagMicPermissionStatus,
      'recorder_error': _diagRecorderError,
      'mic_chunks_received': _diagMicChunks,
      'mic_bytes_received': _diagMicBytesReceived,
      'audio_bytes_sent': _diagAudioBytesSent,
      'gate_open_count': _diagGateOpenCount,
      'events': _diagEvents,
    };
    unawaited(ref.read(voiceApiProvider).sendSessionEvent(sessionId, 'client_diagnostics', payload));
  }

  @override
  VoiceAssistantState build() {
    ref.onDispose(_disposeSession);
    return const VoiceAssistantState();
  }

  Future<void> start({required bool isOnboarding, required String language, bool resume = false}) async {
    // On resume, don't tear down the session (that would null _sessionId,
    // the very thing needed to resume) and don't reset to a blank state
    // (state.transcript/patch/searchResults already hold everything captured
    // before the disconnect — they're the source of truth, not the fresh
    // profile snapshot the REST call below would otherwise overwrite them
    // with). Still clean up the dangling transport instance from the drop.
    final resumeSessionId = resume ? _sessionId : null;
    if (!resume) {
      await _teardownSession();
      _seq = 0;
      _searchId = 0;
      _openTranscriptRole = null;
      _diagSessionStart = DateTime.now();
      _diagEvents.clear();
      _diagMicChunks = 0;
      _diagMicBytesReceived = 0;
      _diagAudioBytesSent = 0;
      _diagGateOpenCount = 0;
      _diagMicPermissionStatus = null;
      _diagRecorderError = null;
    } else {
      await _socket?.close();
    }
    _isOnboarding = isOnboarding;
    final generation = ++_generation;
    state = (resume ? state : const VoiceAssistantState()).copyWith(status: VoiceStatus.connecting);
    try {
      final micStatus = await requestMicrophonePermission();
      if (!_isCurrent(generation)) return;
      _diagMicPermissionStatus = micStatus.name;
      _diagEvent('mic_permission', {'status': micStatus.name});
      if (!micStatus.isGranted) {
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'Microphone permission is required to talk to the assistant — you can still type instead.',
        );
        return;
      }

      final voiceApi = ref.read(voiceApiProvider);
      final sessionStartBegin = DateTime.now();
      final startResponse = await voiceApi.startSession(
        isOnboarding: isOnboarding,
        language: language,
        resumeSessionId: resumeSessionId,
      );
      if (!_isCurrent(generation)) return;
      _sessionId = startResponse.sessionId;
      _diagDirectConnect = startResponse.directConnectAllowed;
      _diagEvent('session_start', {'ms': DateTime.now().difference(sessionStartBegin).inMilliseconds});
      if (!resume) {
        state = state.copyWith(patch: startResponse.profile);
      }

      // Player must be fully open (and _player assigned) before the socket is
      // connected/subscribed below — otherwise the backend's near-immediate
      // greeting audio can arrive while _handleFrame's `_player?.isReady`
      // check is still false, silently dropping the leading audio bytes.
      final player = VoiceAudioPlayer();
      await player.open();
      if (!_isCurrent(generation)) {
        await player.close();
        return;
      }
      _player = player;
      _agc = Pcm16Agc(sampleRateHz: VoiceAudioPlayer.outputSampleRate);
      _speakingSince = null;
      _hadFirstSpeakingTurn = false;

      final socket = createVoiceTransport(
        directConnectAllowed: startResponse.directConnectAllowed,
        voiceApi: voiceApi,
      );
      _socket = socket;
      // Subscribe before connect so setup failures and a fast opening response
      // cannot be lost by the transport's broadcast stream.
      _frameSubscription = socket.frames.listen(
        (frame) {
          if (_isCurrent(generation)) _handleFrame(frame);
        },
        onError: (Object error) {
          if (_isCurrent(generation)) _handleSocketError(error);
        },
      );
      final socketConnectBegin = DateTime.now();
      await socket.connect(
        sessionId: startResponse.sessionId,
        wsUrl: startResponse.wsUrl,
        existingProfile: startResponse.profile,
        mode: isOnboarding ? 'preferences' : 'search',
        language: language,
        resumeTranscript: state.transcript,
      );
      if (!_isCurrent(generation)) return;
      _diagEvent('socket_connect', {
        'ms': DateTime.now().difference(socketConnectBegin).inMilliseconds,
        'transport': _diagDirectConnect ? 'direct' : 'proxy',
      });

      // On web, record_web ignores RecordConfig.sampleRate and silently
      // captures at whatever rate the browser's AudioContext settles on
      // instead — probing it ourselves and telling the backend the truth is
      // the only way Gemini gets audio labeled with its actual rate (see
      // web_audio_sample_rate_web.dart). Done once here rather than per
      // hold-to-talk press since it can't change mid-session.
      _captureSampleRate = probeWebMicSampleRate() ?? _kInputSampleRate;
      _micResampler = Pcm16Resampler(
        inputSampleRate: _captureSampleRate,
        outputSampleRate: _kInputSampleRate,
      );
      socket.sendAudioFormat(_kInputSampleRate);
      _recorder = AudioRecorder();

      // The model speaks its own greeting once the backend's hidden trigger
      // turn lands (see live_session.py's _send_greeting_trigger) — it
      // arrives as a normal transcript/audio frame, same as any other turn.
      state = state.copyWith(status: VoiceStatus.listening);
    } catch (e) {
      _diagEvent('start_failed', {'error': e.toString()});
      await _stopLiveAudio(invalidate: false);
      state = state.copyWith(
        status: VoiceStatus.error,
        errorMessage: _displayVoiceError(e),
      );
    }
  }

  /// Starts a hands-free session — call once when the toggle button is
  /// tapped on. Opens the mic stream once and leaves it open for the whole
  /// conversation; a re-armable local VAD (Pcm16ReArmableSpeechGate) detects
  /// each utterance's start/end automatically and emits its own
  /// speech_start/speech_end pair per utterance (Gemini's own voice-activity
  /// detection stays disabled server-side — see live_session.py's
  /// realtime_input_config — so these client-driven markers are still what
  /// tell it every turn's boundaries).
  ///
  /// Unlike the old push-to-talk beginSpeaking(), this does NOT pause/mute
  /// while the assistant is talking (status == speaking) — the gate keeps
  /// running continuously so the user can barge in just by talking, same as
  /// ChatGPT's voice mode. That only works because echoCancel/noiseSuppress/
  /// autoGain are turned on below so the mic doesn't simply pick the
  /// assistant's own voice back up — see the listener's `started` handling
  /// for how a detected barge-in flushes playback immediately.
  Future<void> startHandsFree() async {
    if (state.isHandsFreeActive || _recorder == null) return;
    final generation = _generation;
    _speechGate = Pcm16ReArmableSpeechGate(sampleRate: _kInputSampleRate);
    _speechStarted = false;
    // isHandsFreeActive is only flipped on AFTER startStream() actually
    // succeeds (previously it was set optimistically before the await —
    // if startStream() throws, the UI showed "Listening" forever with a mic
    // that was never actually capturing anything, and no error surfaced at
    // all).
    final recorderStartBegin = DateTime.now();
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder!.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _captureSampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        // voiceCommunication (Android's telephony-tuned source, chosen for
        // its OS-level AEC so the mic doesn't pick the assistant's own
        // playback back up) turned out to over-suppress real speech on real
        // devices outside of an active call — production traces showed mic
        // chunks arriving but every one at an RMS too low to ever cross
        // Pcm16SpeechGate's threshold, so zero audio ever reached Gemini.
        // voiceRecognition applies far less aggressive processing at the
        // cost of weaker echo rejection (echoCancel/noiseSuppress above are
        // the plugin-level fallback for that) — trading barge-in robustness
        // for audio actually going out at all.
        androidConfig: const AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
      ));
    } catch (e) {
      _diagRecorderError = e.toString();
      _diagEvent('recorder_start_failed', {'error': e.toString()});
      _flushDiagnostics();
      state = state.copyWith(
        status: VoiceStatus.error,
        errorMessage: 'Could not start the microphone (${_displayVoiceError(e)}) — tap the mic to try again.',
      );
      return;
    }
    _diagEvent('recorder_started', {'ms': DateTime.now().difference(recorderStartBegin).inMilliseconds});
    state = state.copyWith(isHandsFreeActive: true);
    _micSubscription = stream.listen((chunk) {
      if (!_isCurrent(generation) || !state.isHandsFreeActive) return;
      final outbound = _micResampler?.convert(chunk) ?? chunk;
      if (outbound.isEmpty) return;
      _diagMicChunks++;
      _diagMicBytesReceived += outbound.length;
      // Auto-VAD models (see VoiceTransport.usesAutoActivityDetection) need
      // an unbroken audio stream to detect turn boundaries themselves —
      // gating on our own RMS detector, as manual-control models require
      // below, starves them of the silence either side of speech they need
      // and leaves the turn hanging with no response (confirmed on real
      // device audio — see docs/explainer/voice-assistant-gemini-live-model
      // -switch.md §7). The gate still runs unconditionally below purely to
      // drive local UI feedback (isRecording, optimistic barge-in flush);
      // its .chunks are just never used for sending in this branch, so nothing
      // here gets double-sent.
      final autoActivityDetection = _socket?.usesAutoActivityDetection ?? false;
      if (autoActivityDetection) {
        _socket?.sendAudio(outbound);
        _diagAudioBytesSent += outbound.length;
      }
      final result = _speechGate?.add(outbound) ??
          const Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: []);
      switch (result.event) {
        case Pcm16SpeechGateEvent.started:
          // Barge-in: if the assistant is still talking, cut it off right
          // away instead of waiting for the server's own 'interrupted'
          // frame to round-trip back — _flushPlayback() is idempotent with
          // that frame if/when it arrives afterward. Suppressed for a short
          // grace period right after the assistant starts talking (see
          // _speakingSince) — imperfect echo cancellation can leak the tail
          // of a fast-trailing phrase back into the mic and read as the user
          // starting to talk, which would truncate/mush the assistant's own
          // audio. During that window the server's own authoritative
          // 'interrupted' message (handled below) still clears playback if
          // the user is genuinely interrupting. The very first assistant
          // turn on this player (the greeting) never gets the optimistic
          // local flush at all, regardless of grace period — see
          // _hadFirstSpeakingTurn.
          _openTranscriptRole = null;
          final withinBargeInGrace = _speakingSince != null &&
              DateTime.now().difference(_speakingSince!) < const Duration(milliseconds: _bargeInGraceMs);
          if (state.status == VoiceStatus.speaking && _hadFirstSpeakingTurn && !withinBargeInGrace) {
            unawaited(_flushPlayback());
            _speakingDebounce?.cancel();
            state = state.copyWith(status: VoiceStatus.listening);
          }
          _diagGateOpenCount++;
          _diagEvent('gate_opened');
          _speechStarted = true;
          state = state.copyWith(isRecording: true);
          if (!autoActivityDetection) {
            _socket?.sendSpeechStart();
            for (final c in result.chunks) {
              if (c.isNotEmpty) {
                _socket?.sendAudio(c);
                _diagAudioBytesSent += c.length;
              }
            }
          }
        case Pcm16SpeechGateEvent.ended:
          if (!autoActivityDetection) {
            for (final c in result.chunks) {
              if (c.isNotEmpty) {
                _socket?.sendAudio(c);
                _diagAudioBytesSent += c.length;
              }
            }
            _socket?.sendSpeechEnd();
          }
          _diagTurnRequestedAt = DateTime.now();
          _diagEvent('gate_closed');
          _speechStarted = false;
          state = state.copyWith(isRecording: false);
        case Pcm16SpeechGateEvent.none:
          if (!autoActivityDetection && _speechStarted) {
            for (final c in result.chunks) {
              if (c.isNotEmpty) {
                _socket?.sendAudio(c);
                _diagAudioBytesSent += c.length;
              }
            }
          }
      }
    });
  }

  /// Ends the hands-free session — call when the toggle button is tapped
  /// off. Only stops listening; it does not itself jump to the review/finish
  /// flow (the "I'm done" button or a typed closing phrase still does that,
  /// same as before) — so the user can tap this to go quiet for a moment and
  /// tap startHandsFree() again later in the same conversation if they want.
  Future<void> stopHandsFree() async {
    if (!state.isHandsFreeActive) return;
    if (_speechStarted) _socket?.sendSpeechEnd();
    await _micSubscription?.cancel();
    _micSubscription = null;
    try {
      await _recorder?.stop();
    } catch (_) {
      // Best-effort — the activity_end marker above already told Gemini the
      // turn ended even if the platform stop() call itself failed.
    }
    _speechStarted = false;
    _speechGate = null;
    state = state.copyWith(isHandsFreeActive: false, isRecording: false);
  }

  /// Used by both the text input field and tapping a suggestion chip —
  /// both paths produce the same WS text frame.
  void sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _openTranscriptRole = null;
    // Closing phrases only mean "review and save" in the preference flow —
    // search mode has no review step, so "done"/"no" is just another turn.
    if (_isOnboarding && _isClosingPhrase(trimmed)) {
      state = state.copyWith(
        transcript: [...state.transcript, VoiceTranscriptTurn(role: 'user', text: trimmed, seq: _nextSeq())],
      );
      finishNow();
      return;
    }
    _socket?.sendText(trimmed);
    state = state.copyWith(
      transcript: [...state.transcript, VoiceTranscriptTurn(role: 'user', text: trimmed, seq: _nextSeq())],
    );
  }

  /// Lets the user end the conversation on their own terms instead of
  /// waiting for the assistant to decide it's done — jumps straight to the
  /// review screen with whatever's been captured so far (state.patch, kept
  /// live-updated from preference_patch frames). Stops the live audio
  /// session immediately (see _stopLiveAudio) since nothing more is needed
  /// from it once a proposal exists — confirm()/cancel() still work
  /// unchanged, they just find the session already torn down.
  void finishNow() {
    if (!_isOnboarding) return;
    if (state.status != VoiceStatus.listening && state.status != VoiceStatus.speaking) return;
    _speakingDebounce?.cancel();
    unawaited(_stopLiveAudio());
    state = state.copyWith(
      status: VoiceStatus.review,
      finalizeProposal: state.patch,
      isHandsFreeActive: false,
      isRecording: false,
    );
  }

  void updateReviewProposal(VoiceProfilePatch updated) {
    if (state.status != VoiceStatus.review) return;
    state = state.copyWith(finalizeProposal: updated);
  }

  Future<void> confirm() async {
    final proposal = state.finalizeProposal;
    final sessionId = _sessionId;
    if (proposal == null || sessionId == null) return;
    state = state.copyWith(status: VoiceStatus.saving);
    await _teardownSession();
    try {
      final result = await ref.read(voiceApiProvider).finalizeSession(sessionId, proposal);
      state = state.copyWith(status: VoiceStatus.done, result: result);
    } catch (e) {
      state = state.copyWith(status: VoiceStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> cancel() async {
    // Tells the backend this is an explicit exit — deletes the session
    // immediately instead of leaving it in the resumable post-disconnect
    // grace period (see live_session.py's SessionState.disconnected_at).
    // Fire-and-forget: cancelSession() is itself best-effort (swallows its
    // own errors), and the UI shouldn't wait on it to close.
    final sessionId = _sessionId;
    if (sessionId != null) {
      unawaited(ref.read(voiceApiProvider).cancelSession(sessionId));
    }
    await _teardownSession();
    state = const VoiceAssistantState();
  }

  /// Called when the app is truly backgrounded (AppLifecycleState.paused)
  /// while a live turn is in progress — stops mic/audio/socket like cancel(),
  /// but uses copyWith (not a fresh VoiceAssistantState) so transcript and
  /// searchResults survive and are still visible if the user returns to the
  /// overlay. No-op outside listening/speaking (e.g. mid-save, in review, or
  /// already torn down) so those flows aren't disturbed by backgrounding.
  Future<void> pauseForBackground() async {
    if (state.status != VoiceStatus.listening && state.status != VoiceStatus.speaking) return;
    _speakingDebounce?.cancel();
    await _stopLiveAudio();
    state = state.copyWith(
      status: VoiceStatus.error,
      errorMessage: 'Paused — the assistant stopped listening while the app was in the background.',
      isHandsFreeActive: false,
      isRecording: false,
    );
  }

  void _handleFrame(VoiceSocketFrame frame) {
    if (_diagTurnRequestedAt != null) {
      _diagEvent('turn_first_response', {'ms': DateTime.now().difference(_diagTurnRequestedAt!).inMilliseconds});
      _diagTurnRequestedAt = null;
    }
    switch (frame) {
      case VoiceAudioFrame(data: final data):
        _markSpeaking();
        if (_player?.isReady ?? false) {
          final leveled = _agc?.process(data) ?? data;
          final playbackGeneration = _playbackGeneration;
          _feedChain = _feedChain
              .then((_) => playbackGeneration != _playbackGeneration ? null : _player!.playPcm16(leveled))
              .catchError((_) => 0);
        }
      case VoiceControlFrame(json: final json):
        _handleControlFrame(json);
      case VoiceSocketClosed(:final code, :final reason):
        // The underlying close code/reason (e.g. dart:io's WebSocket 1007)
        // is only useful as a diagnostic signal — the direct-connect
        // transport in particular bypasses the backend entirely, so
        // _diagEvent below is often the only place this detail is captured
        // at all, without a device console attached. It's deliberately kept
        // out of the user-facing message: a raw close code reads as an
        // alarming, unactionable error, when reconnecting is all the user
        // actually needs to do.
        _diagEvent('socket_closed', {'code': code, 'reason': reason});
        _flushDiagnostics();
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: "Hmm, something interrupted our conversation — press Reconnect to continue your chat.",
          isHandsFreeActive: false,
          isRecording: false,
        );
    }
  }

  void _handleControlFrame(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'transcript':
        final role = json['role'] as String? ?? 'model';
        final text = json['text'] as String? ?? '';
        if (text.isEmpty) return;
        // Gemini understands speech more reliably than its best-effort input
        // captions. Keep spoken user captions off screen; typed turns are
        // still inserted locally by sendText().
        if (role == 'user') {
          _openTranscriptRole = null;
          return;
        }
        final isFragment = json['fragment'] == true;
        final isFinal = json['final'] == true;
        final transcript = [...state.transcript];
        if (transcript.isNotEmpty &&
            transcript.last.role == role &&
            transcript.last.text.trim() == text.trim()) {
          _openTranscriptRole = isFragment && !isFinal ? role : null;
          return;
        }
        if (isFragment &&
            _openTranscriptRole == role &&
            transcript.isNotEmpty &&
            transcript.last.role == role) {
          final current = transcript.last;
          transcript[transcript.length - 1] = VoiceTranscriptTurn(
            role: role,
            text: mergeTranscriptFragment(current.text, text),
            seq: current.seq,
          );
        } else {
          transcript.add(
            VoiceTranscriptTurn(role: role, text: text, seq: _nextSeq()),
          );
        }
        _openTranscriptRole = isFragment && !isFinal ? role : null;
        state = state.copyWith(
          transcript: transcript,
        );
        if (role == 'model') _markSpeaking();
      case 'assistant_turn_complete':
        _agc?.resetForTurn();
        final silenceBytes = VoiceAudioPlayer.outputSampleRate *
            2 *
            _kAssistantTurnTailMs ~/
            1000;
        final player = _player;
        if (player?.isReady ?? false) {
          final playbackGeneration = _playbackGeneration;
          _feedChain = _feedChain
              .then((_) => playbackGeneration != _playbackGeneration ? null : player!.playPcm16(Uint8List(silenceBytes)))
              .catchError((_) => 0);
        }
      case 'preference_patch':
        state = state.copyWith(
          patch: VoiceProfilePatch.fromJson(json['patch'] as Map<String, dynamic>? ?? const {}),
        );
      case 'search_started':
        // Deterministic loading-state signal sent the instant the backend
        // dispatches a search_products tool call — arrives well before the
        // (now up to ~20-25s combined Google Shopping + Amazon fallback)
        // product_results frame, so the UI shows a spinner immediately
        // instead of going quiet. Inserted at the front — newest search
        // first — same ordering rule as product_results below.
        final startedQuery = json['query'] as String? ?? '';
        state = state.copyWith(
          searchResults: [
            VoiceSearchResult(query: startedQuery, products: const [], id: _nextSearchId(), isPending: true),
            ...state.searchResults,
          ],
        );
      case 'product_results':
        // Insert at the front (newest first) instead of appending — fixes
        // the bug where an earlier, empty search stayed pinned above a
        // later, successful one. Replaces the pending placeholder for the
        // same query (if any) rather than leaving both in the list.
        final resultQuery = json['query'] as String? ?? '';
        final incoming = VoiceSearchResult.fromJson(json, id: _nextSearchId());
        final withoutPending = state.searchResults
            .where((r) => !(r.isPending && r.query == resultQuery))
            .toList();
        state = state.copyWith(searchResults: [incoming, ...withoutPending]);
      case 'finalize_proposal':
        _speakingDebounce?.cancel();
        unawaited(_stopLiveAudio());
        state = state.copyWith(
          status: VoiceStatus.review,
          finalizeProposal: VoiceProfilePatch.fromJson(json['patch'] as Map<String, dynamic>? ?? const {}),
          isHandsFreeActive: false,
          isRecording: false,
        );
      case 'interrupted':
        // Barge-in: the user started talking while the model was still
        // speaking. stopPlayer() drops anything already queued; restarting
        // the stream right after is what actually clears it (no separate
        // flush-only API exists for the stream-playback path).
        _flushPlayback();
        _speakingDebounce?.cancel();
        if (state.status == VoiceStatus.speaking) state = state.copyWith(status: VoiceStatus.listening);
      case 'auto_saved':
        // Hard session timeout with no confirmation — the backend already
        // saved whatever was captured (see live_session.py's
        // _auto_save_and_close) rather than erroring out, so just show the
        // same success screen a normal Confirm tap would.
        state = state.copyWith(
          status: VoiceStatus.done,
          result: VoiceFinalizeResult.fromJson(json),
          isHandsFreeActive: false,
          isRecording: false,
        );
      case 'session_timeout':
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'The conversation timed out — please start again.',
          isHandsFreeActive: false,
          isRecording: false,
        );
    }
  }

  Future<void> _flushPlayback() async {
    if (!(_player?.isReady ?? false)) return;
    // Invalidate chunks already chained onto the pre-flush _feedChain before
    // it's reassigned below — see _playbackGeneration's declaration.
    _playbackGeneration++;
    try {
      await _player!.flush();
      _feedChain = Future.value();
    } catch (_) {
      // Best-effort — worst case the tail of the interrupted audio still plays out.
    }
  }

  bool _isCurrent(int generation) => generation == _generation;

  void _markSpeaking() {
    if (state.status == VoiceStatus.review ||
        state.status == VoiceStatus.saving ||
        state.status == VoiceStatus.done) {
      return;
    }
    if (state.status != VoiceStatus.speaking) {
      if (_speakingSince != null) _hadFirstSpeakingTurn = true;
      _speakingSince = DateTime.now();
    }
    state = state.copyWith(status: VoiceStatus.speaking);
    _speakingDebounce?.cancel();
    _speakingDebounce = Timer(const Duration(milliseconds: 800), () {
      if (state.status == VoiceStatus.speaking) state = state.copyWith(status: VoiceStatus.listening);
    });
  }

  void _handleSocketError(Object error) {
    _diagEvent('socket_error', {'error': error.toString()});
    _flushDiagnostics();
    state = state.copyWith(
      status: VoiceStatus.error,
      errorMessage: "Hmm, something interrupted our conversation — press Reconnect to continue your chat.",
      isHandsFreeActive: false,
      isRecording: false,
    );
  }

  // Cancels the frame subscription before closing the socket, so our own
  // deliberate close (confirm/cancel/finalize_proposal/finishNow) never gets
  // misread as a dropped connection by _handleFrame's VoiceSocketClosed
  // branch. Safe to call more than once — every step is already null-safe.
  Future<void> _stopLiveAudio({bool invalidate = true}) async {
    _flushDiagnostics();
    if (invalidate) _generation++;
    _speakingDebounce?.cancel();
    await _micSubscription?.cancel();
    _micSubscription = null;
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    try {
      await _recorder?.stop();
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    _micResampler = null;
    _speechGate = null;
    _speechStarted = false;
    try {
      await _player?.close();
    } catch (_) {}
    _player = null;
    _agc = null;
    _feedChain = Future.value();
    await _socket?.close();
  }

  // _sessionId must survive _stopLiveAudio (confirm() still needs it for the
  // REST finalize call after the live audio session has already been torn
  // down on entering review) — only this full teardown clears it.
  Future<void> _teardownSession() async {
    await _stopLiveAudio();
    _sessionId = null;
  }

  void _disposeSession() {
    unawaited(_teardownSession());
    _socket?.dispose();
  }
}

final voiceAssistantProvider =
    AutoDisposeNotifierProvider<VoiceAssistantNotifier, VoiceAssistantState>(VoiceAssistantNotifier.new);

// Deliberately excludes ambiguous bare conversational answers like "no",
// "yes", "done", "save", "go ahead" — those are extremely likely to occur as
// an ordinary answer to a mid-interview yes/no follow-up (e.g. "Do you have
// a favorite brand?" -> "No"), and matching on them here ended the interview
// after just a few turns instead of letting the model keep going. Only
// unambiguous multi-word closing phrases are matched now. Must be kept in
// sync with the duplicate list in services/voice-assistant/live_session.py's
// _CLOSING_PHRASES — no shared source of truth between the two today.
bool _isClosingPhrase(String text) {
  final normalized = text
      .trim()
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll(RegExp(r'[.!?]+$'), '');
  return {
    'nothing else',
    'nothing more',
    "that's all",
    'thats all',
    "that's it",
    'thats it',
    "i'm done",
    'im done',
    'save it',
    'looks good',
    "that's everything",
    'thats everything',
  }.contains(normalized);
}
