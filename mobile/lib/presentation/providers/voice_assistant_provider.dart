import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/constants/api_constants.dart';
import '../../core/utils/pcm16_resampler.dart';
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
    this.isRecording = false,
    this.transcript = const [],
    this.patch = const VoiceProfilePatch(),
    this.finalizeProposal,
    this.result,
    this.errorMessage,
  });

  final VoiceStatus status;
  // True only while the hold-to-talk button is pressed and mic audio is
  // actively streaming — see VoiceAssistantNotifier.beginSpeaking/endSpeaking.
  final bool isRecording;
  final List<VoiceTranscriptTurn> transcript;
  final VoiceProfilePatch patch;
  final VoiceProfilePatch? finalizeProposal;
  final VoiceFinalizeResult? result;
  final String? errorMessage;

  VoiceAssistantState copyWith({
    VoiceStatus? status,
    bool? isRecording,
    List<VoiceTranscriptTurn>? transcript,
    VoiceProfilePatch? patch,
    VoiceProfilePatch? finalizeProposal,
    VoiceFinalizeResult? result,
    String? errorMessage,
  }) =>
      VoiceAssistantState(
        status: status ?? this.status,
        isRecording: isRecording ?? this.isRecording,
        transcript: transcript ?? this.transcript,
        patch: patch ?? this.patch,
        finalizeProposal: finalizeProposal ?? this.finalizeProposal,
        result: result ?? this.result,
        errorMessage: errorMessage,
      );
}

/// Drives a single voice-assistant conversation: connects to
/// services/voice-assistant, streams mic audio, relays typed text turns,
/// plays back the model's spoken audio, and surfaces the live
/// transcript/preference preview/finalize proposal.
class VoiceAssistantNotifier extends Notifier<VoiceAssistantState> {
  String? _sessionId;
  AudioRecorder? _recorder;
  final VoiceSocketClient _socket = VoiceSocketClient();
  StreamSubscription<Uint8List>? _micSubscription;
  StreamSubscription<VoiceSocketFrame>? _frameSubscription;
  Timer? _speakingDebounce;
  VoiceAudioPlayer? _player;
  Pcm16Resampler? _micResampler;
  int _captureSampleRate = _kInputSampleRate;
  // feedUint8FromStream() must not be called again before the previous call's
  // future completes — this chain serializes frames as they arrive, since the
  // socket can deliver them faster than playback consumes them.
  Future<void> _feedChain = Future.value();

  @override
  VoiceAssistantState build() {
    ref.onDispose(_disposeSession);
    return const VoiceAssistantState();
  }

  Future<void> start() async {
    state = const VoiceAssistantState(status: VoiceStatus.connecting);
    try {
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'Microphone permission is required to talk to the assistant — you can still type instead.',
        );
        return;
      }

      final startResponse = await ref.read(voiceApiProvider).startSession();
      _sessionId = startResponse.sessionId;
      state = state.copyWith(patch: startResponse.profile);

      await _socket.connect(ApiConstants.voiceAssistantWsUrl(startResponse.wsUrl));
      _frameSubscription = _socket.frames.listen(_handleFrame, onError: _handleSocketError);

      final player = VoiceAudioPlayer();
      await player.open();
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

  /// Starts streaming mic audio for one turn — call when the hold-to-talk
  /// button is pressed. Gemini's own voice-activity detection is disabled
  /// server-side (see live_session.py's realtime_input_config), so the
  /// speech_start/speech_end markers sent here are what tell it the turn's
  /// boundaries instead.
  Future<void> beginSpeaking() async {
    if (state.isRecording || _recorder == null) return;
    state = state.copyWith(isRecording: true);
    _socket.sendSpeechStart();
    final stream = await _recorder!.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _captureSampleRate,
      numChannels: 1,
    ));
    _micSubscription = stream.listen((chunk) {
      final outbound = _micResampler?.convert(chunk) ?? chunk;
      if (outbound.isNotEmpty) _socket.sendAudio(outbound);
    });
  }

  /// Stops streaming and signals the turn is complete — call when the
  /// hold-to-talk button is released.
  Future<void> endSpeaking() async {
    if (!state.isRecording) return;
    state = state.copyWith(isRecording: false);
    await _micSubscription?.cancel();
    _micSubscription = null;
    try {
      await _recorder?.stop();
    } catch (_) {
      // Best-effort — the activity_end marker below still tells Gemini the
      // turn ended even if the platform stop() call itself failed.
    }
    _socket.sendSpeechEnd();
  }

  /// Used by both the text input field and tapping a suggestion chip —
  /// both paths produce the same WS text frame.
  void sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _socket.sendText(trimmed);
    state = state.copyWith(transcript: [...state.transcript, VoiceTranscriptTurn(role: 'user', text: trimmed)]);
  }

  /// Lets the user end the conversation on their own terms instead of
  /// waiting for the assistant to decide it's done — jumps straight to the
  /// review screen with whatever's been captured so far (state.patch, kept
  /// live-updated from preference_patch frames). Stops the live audio
  /// session immediately (see _stopLiveAudio) since nothing more is needed
  /// from it once a proposal exists — confirm()/cancel() still work
  /// unchanged, they just find the session already torn down.
  void finishNow() {
    if (state.status != VoiceStatus.listening && state.status != VoiceStatus.speaking) return;
    _speakingDebounce?.cancel();
    unawaited(_stopLiveAudio());
    state = state.copyWith(status: VoiceStatus.review, finalizeProposal: state.patch);
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
    await _teardownSession();
    state = const VoiceAssistantState();
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
          errorMessage: 'Connection lost — please start again.',
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
        state = state.copyWith(transcript: [...state.transcript, VoiceTranscriptTurn(role: role, text: text)]);
        if (role == 'model') _markSpeaking();
      case 'preference_patch':
        state = state.copyWith(
          patch: VoiceProfilePatch.fromJson(json['patch'] as Map<String, dynamic>? ?? const {}),
        );
      case 'finalize_proposal':
        _speakingDebounce?.cancel();
        unawaited(_stopLiveAudio());
        state = state.copyWith(
          status: VoiceStatus.review,
          finalizeProposal: VoiceProfilePatch.fromJson(json['patch'] as Map<String, dynamic>? ?? const {}),
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
        state = state.copyWith(status: VoiceStatus.done, result: VoiceFinalizeResult.fromJson(json));
      case 'session_timeout':
        state = state.copyWith(
          status: VoiceStatus.error,
          errorMessage: 'The conversation timed out — please start again.',
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
    state = state.copyWith(status: VoiceStatus.error, errorMessage: error.toString());
  }

  // Cancels the frame subscription before closing the socket, so our own
  // deliberate close (confirm/cancel/finalize_proposal/finishNow) never gets
  // misread as a dropped connection by _handleFrame's VoiceSocketClosed
  // branch. Safe to call more than once — every step is already null-safe.
  Future<void> _stopLiveAudio() async {
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
    NotifierProvider<VoiceAssistantNotifier, VoiceAssistantState>(VoiceAssistantNotifier.new);
