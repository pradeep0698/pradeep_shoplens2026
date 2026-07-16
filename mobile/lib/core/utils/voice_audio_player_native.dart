import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

class VoiceAudioPlayer {
  static const outputSampleRate = 24000;
  static const outputChannelCount = 1;
  // Was iOS-only (16384 vs Android's 8192) because iOS's AVAudioEngine-backed
  // stream player used to be the one more prone to buffer underflow on the
  // first burst of a fresh player instance (flutter_sound 9.30.0's
  // "onBufferUnderflow" fix). Testing against the dev backend
  // (gemini-3.1-flash-live-preview, auto-VAD instead of manual hold-to-talk —
  // see docs/explainer/voice-assistant-gemini-live-model-switch.md) surfaced
  // static/glitches on Android specifically, not iOS — this model/pacing
  // combination was never validated against real device audio before, so
  // giving Android the same slack as an experiment to confirm/rule out
  // underrun as the cause.
  static const int _bufferSize = 16384;
  // See _bufferSize above — same experiment, applied to both platforms now.
  static const _startupWarmup = Duration(milliseconds: 180);

  FlutterSoundPlayer? _player;
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> open() async {
    final player = FlutterSoundPlayer();
    await player.openPlayer();
    await player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: outputChannelCount,
      sampleRate: outputSampleRate,
      bufferSize: _bufferSize,
    );
    await Future<void>.delayed(_startupWarmup);
    _player = player;
    _ready = true;
  }

  Future<void> playPcm16(Uint8List data) async {
    if (!_ready || _player == null || data.isEmpty) return;
    await _player!.feedUint8FromStream(data);
  }

  Future<void> flush() async {
    if (!_ready || _player == null) return;
    await _player!.stopPlayer();
    await _player!.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: outputChannelCount,
      sampleRate: outputSampleRate,
      bufferSize: _bufferSize,
    );
    await Future<void>.delayed(_startupWarmup);
  }

  Future<void> close() async {
    if (!_ready || _player == null) return;
    try {
      await _player!.stopPlayer();
      await _player!.closePlayer();
    } finally {
      _ready = false;
      _player = null;
    }
  }
}
