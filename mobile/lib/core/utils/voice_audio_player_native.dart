import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

class VoiceAudioPlayer {
  static const outputSampleRate = 24000;
  static const outputChannelCount = 1;

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
      bufferSize: 8192,
    );
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
      bufferSize: 8192,
    );
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
