import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/constants/api_constants.dart';
import '../../core/utils/mic_permission.dart';
import '../../core/utils/pcm16_resampler.dart';
import '../../core/utils/pcm16_speech_gate.dart';
import '../../core/utils/voice_audio_player.dart';
import '../../core/utils/web_audio_sample_rate.dart';
import '../../data/models/voice_session.dart';
import '../../data/sources/remote/voice_api.dart';
import '../../data/sources/remote/voice_socket_client.dart';

// Gemini Live API expects raw 16-bit PCM input at 16kHz.
const _kInputSampleRate = 16000;

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
  // Search-mode only — one entry per search_products tool call, oldest
  // first, so a refined search appends rather than replaces.
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
  final VoiceSocketClient _socket = VoiceSocketClient();
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<VoiceSocketFrame>? _frameSubscription;
  Timer? _speakingDebounce;
  VoiceAudioPlayer? _player;
  Pcm16Resampler? _micResampler;
  Pcm16ReArmableSpeechGate? _speechGate;
  int _captureSampleRate = _kInputSampleRate;
  bool _speechStarted = false;
  int _generation = 0;
  // Set by start() — gates the preference-only closing-phrase/review-step
  // behavior in sendText()/finishNow() below, since search-mode sessions
  // never reach a review step.
  bool _isOnboarding = true;
  // Stamps transcript turns and search results with their arrival order so
  // the overlay can interleave the two lists into one conversation instead
  // of rendering them in two separate blocks — see _nextSeq().
  int _seq = 0;
  int _nextSeq() => _seq++;
  // feedUint8FromStream() must not be called again before the previous call's
  // future completes — this chain serializes frames as they arrive, since the
  // socket can deliver them faster than playback consumes them.
  Future<void> _feedChain = Future.value();

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
    // with).
    final resumeSessionId = resume ? _sessionId : null;
    if (!resume) {
      await _teardownSession();
      _seq = 0;
    }
    _isOnboarding = isOnboarding;
    final generation = ++_generation;
    state = (resume ? state : const VoiceAssistantState()).copyWith(status: VoiceStatus.connecting);
    try {
      final micStatus = await requestMicrophonePermission();
      if (!_isCurrent(generation)) return;
      if (!micStatus.isGranted) {
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'Microphone permission is required to talk to the assistant — you can still type instead.',
        );
        return;
      }

      final startResponse = await ref.read(voiceApiProvider).startSession(
        isOnboarding: isOnboarding,
        language: language,
        resumeSessionId: resumeSessionId,
      );
      if (!_isCurrent(generation)) return;
      _sessionId = startResponse.sessionId;
      if (!resume) {
        state = state.copyWith(patch: startResponse.profile);
      }

      await _socket.connect(ApiConstants.voiceAssistantWsUrl(startResponse.wsUrl));
      if (!_isCurrent(generation)) return;
      _frameSubscription = _socket.frames.listen(
        (frame) {
          if (_isCurrent(generation)) _handleFrame(frame);
        },
        onError: (Object error) {
          if (_isCurrent(generation)) _handleSocketError(error);
        },
      );

      final player = VoiceAudioPlayer();
      await player.open();
      if (!_isCurrent(generation)) {
        await player.close();
        return;
      }
      _player = player;

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
      _socket.sendAudioFormat(_kInputSampleRate);
      _recorder = AudioRecorder();

      // The model speaks its own greeting once the backend's hidden trigger
      // turn lands (see live_session.py's _send_greeting_trigger) — it
      // arrives as a normal transcript/audio frame, same as any other turn.
      state = state.copyWith(status: VoiceStatus.listening);
    } catch (e, st) {
      // Stack trace is included here (not just e.toString()) purely as a
      // temporary diagnostic aid since this path is hard to attach a
      // debugger to on a real device — remove once the cause is found.
      final frames = st.toString().split('\n').take(8).join('\n');
      state = state.copyWith(status: VoiceStatus.error, errorMessage: '$e\n\n$frames');
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
  /// autoGain are turned on below (plus AndroidAudioSource.voiceCommunication
  /// on Android) so the mic doesn't simply pick the assistant's own voice
  /// back up — see the listener's `started` handling for how a detected
  /// barge-in flushes playback immediately.
  Future<void> startHandsFree() async {
    if (state.isHandsFreeActive || _recorder == null) return;
    state = state.copyWith(isHandsFreeActive: true);
    final generation = _generation;
    _speechGate = Pcm16ReArmableSpeechGate(sampleRate: _kInputSampleRate);
    _speechStarted = false;
    final stream = await _recorder!.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _captureSampleRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidConfig: const AndroidRecordConfig(audioSource: AndroidAudioSource.voiceCommunication),
    ));
    _micSubscription = stream.listen((chunk) {
      if (!_isCurrent(generation) || !state.isHandsFreeActive) return;
      final outbound = _micResampler?.convert(chunk) ?? chunk;
      if (outbound.isEmpty) return;
      final result = _speechGate?.add(outbound) ??
          const Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: []);
      switch (result.event) {
        case Pcm16SpeechGateEvent.started:
          // Barge-in: if the assistant is still talking, cut it off right
          // away instead of waiting for the server's own 'interrupted'
          // frame to round-trip back — _flushPlayback() is idempotent with
          // that frame if/when it arrives afterward.
          if (state.status == VoiceStatus.speaking) {
            unawaited(_flushPlayback());
            _speakingDebounce?.cancel();
            state = state.copyWith(status: VoiceStatus.listening);
          }
          _speechStarted = true;
          state = state.copyWith(isRecording: true);
          _socket.sendSpeechStart();
          for (final c in result.chunks) {
            if (c.isNotEmpty) _socket.sendAudio(c);
          }
        case Pcm16SpeechGateEvent.ended:
          for (final c in result.chunks) {
            if (c.isNotEmpty) _socket.sendAudio(c);
          }
          _socket.sendSpeechEnd();
          _speechStarted = false;
          state = state.copyWith(isRecording: false);
        case Pcm16SpeechGateEvent.none:
          if (_speechStarted) {
            for (final c in result.chunks) {
              if (c.isNotEmpty) _socket.sendAudio(c);
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
    if (_speechStarted) _socket.sendSpeechEnd();
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
    // Closing phrases only mean "review and save" in the preference flow —
    // search mode has no review step, so "done"/"no" is just another turn.
    if (_isOnboarding && _isClosingPhrase(trimmed)) {
      state = state.copyWith(
        transcript: [...state.transcript, VoiceTranscriptTurn(role: 'user', text: trimmed, seq: _nextSeq())],
      );
      finishNow();
      return;
    }
    _socket.sendText(trimmed);
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
    switch (frame) {
      case VoiceAudioFrame(data: final data):
        _markSpeaking();
        if (_player?.isReady ?? false) {
          _feedChain = _feedChain
              .then((_) => _player!.playPcm16(data))
              .catchError((_) => 0);
        }
      case VoiceControlFrame(json: final json):
        _handleControlFrame(json);
      case VoiceSocketClosed():
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'Connection lost — tap Reconnect to keep talking.',
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
        // Voice user transcripts are only best-effort captions from the Live
        // API and can be visibly wrong even when the assistant understood the
        // audio. Typed user messages are already added locally in sendText().
        if (role == 'user') return;
        state = state.copyWith(
          transcript: [...state.transcript, VoiceTranscriptTurn(role: role, text: text, seq: _nextSeq())],
        );
        if (role == 'model') _markSpeaking();
      case 'preference_patch':
        state = state.copyWith(
          patch: VoiceProfilePatch.fromJson(json['patch'] as Map<String, dynamic>? ?? const {}),
        );
      case 'product_results':
        try {
          state = state.copyWith(
            searchResults: [...state.searchResults, VoiceSearchResult.fromJson(json, seq: _nextSeq())],
          );
        } catch (_) {
          state = state.copyWith(
            searchResults: [
              ...state.searchResults,
              VoiceSearchResult(query: json['query'] as String? ?? '', products: const [], seq: _nextSeq()),
            ],
          );
        }
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
    state = state.copyWith(status: VoiceStatus.speaking);
    _speakingDebounce?.cancel();
    _speakingDebounce = Timer(const Duration(milliseconds: 800), () {
      if (state.status == VoiceStatus.speaking) state = state.copyWith(status: VoiceStatus.listening);
    });
  }

  void _handleSocketError(Object error) {
    state = state.copyWith(
      status: VoiceStatus.error,
      errorMessage: error.toString(),
      isHandsFreeActive: false,
      isRecording: false,
    );
  }

  // Cancels the frame subscription before closing the socket, so our own
  // deliberate close (confirm/cancel/finalize_proposal/finishNow) never gets
  // misread as a dropped connection by _handleFrame's VoiceSocketClosed
  // branch. Safe to call more than once — every step is already null-safe.
  Future<void> _stopLiveAudio({bool invalidate = true}) async {
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
    _feedChain = Future.value();
    await _socket.close();
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
    _socket.dispose();
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
