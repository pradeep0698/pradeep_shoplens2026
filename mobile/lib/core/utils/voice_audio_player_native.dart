import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

class VoiceAudioPlayer {
  static const outputSampleRate = 24000;
  static const outputChannelCount = 1;
  // iOS's AVAudioEngine-backed stream player is more prone to buffer
  // underflow than Android's, especially on the very first burst of a fresh
  // player instance (see flutter_sound 9.30.0's "fixes the onBufferUnderflow
  // bug" changelog entry) — a larger native ring buffer gives it more slack
  // at the cost of a little latency.
  static final int _bufferSize = Platform.isIOS ? 16384 : 8192;
  // Brief pause after starting the native stream so the engine has time to
  // stabilize before the first PCM chunk lands — targets the same first-burst
  // underflow window as _bufferSize above. Only needed on iOS.
  static const _iosWarmup = Duration(milliseconds: 180);

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
    if (Platform.isIOS) {
      await Future<void>.delayed(_iosWarmup);
    }
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
    if (Platform.isIOS) {
      await Future<void>.delayed(_iosWarmup);
    }
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
