import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class VoiceAudioPlayer {
  static const outputSampleRate = 24000;

  web.AudioContext? _context;
  double _nextStartTime = 0;
  bool _ready = false;

  bool get isReady => _ready;

  Future<void> open() async {
    final context = web.AudioContext();
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }
    _context = context;
    _nextStartTime = context.currentTime;
    _ready = true;
  }

  Future<void> playPcm16(Uint8List data) async {
    final context = _context;
    if (!_ready || context == null || data.length < 2) return;
    if (context.state == 'suspended') {
      await context.resume().toDart;
    }

    final sampleCount = data.length ~/ 2;
    final samples = Float32List(sampleCount);
    final view = ByteData.sublistView(data);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final buffer = context.createBuffer(1, sampleCount, outputSampleRate);
    buffer.copyToChannel(samples.toJS, 0);

    final source = context.createBufferSource()
      ..buffer = buffer;
    source.connect(context.destination);

    final startAt = _nextStartTime < context.currentTime
        ? context.currentTime
        : _nextStartTime;
    source.start(startAt);
    _nextStartTime = startAt + sampleCount / outputSampleRate;
  }

  Future<void> flush() async {
    final context = _context;
    if (context == null) return;
    await context.close().toDart;
    _context = null;
    _ready = false;
    await open();
  }

  Future<void> close() async {
    final context = _context;
    _context = null;
    _ready = false;
    if (context != null) {
      await context.close().toDart;
    }
  }
}
