import 'dart:math' as math;
import 'dart:typed_data';

class Pcm16SpeechGateResult {
  const Pcm16SpeechGateResult({
    required this.started,
    required this.chunks,
  });

  final bool started;
  final List<Uint8List> chunks;
}

class Pcm16SpeechGate {
  Pcm16SpeechGate({
    this.sampleRate = 16000,
    this.rmsThreshold = 700,
    this.triggerMs = 120,
    this.preRollMs = 300,
  });

  final int sampleRate;
  final int rmsThreshold;
  final int triggerMs;
  final int preRollMs;

  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;
  int _voicedSamples = 0;
  bool _open = false;

  bool get isOpen => _open;

  Pcm16SpeechGateResult add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return const Pcm16SpeechGateResult(started: false, chunks: []);
    }
    if (_open) {
      return Pcm16SpeechGateResult(started: false, chunks: [chunk]);
    }

    _addPreRoll(chunk);
    if (_rms(chunk) >= rmsThreshold) {
      _voicedSamples += chunk.length ~/ 2;
    } else {
      _voicedSamples = 0;
    }

    final triggerSamples = (sampleRate * triggerMs / 1000).ceil();
    if (_voicedSamples < triggerSamples) {
      return const Pcm16SpeechGateResult(started: false, chunks: []);
    }

    _open = true;
    final chunks = List<Uint8List>.from(_preRoll);
    _preRoll.clear();
    _preRollBytes = 0;
    return Pcm16SpeechGateResult(started: true, chunks: chunks);
  }

  void _addPreRoll(Uint8List chunk) {
    _preRoll.add(Uint8List.fromList(chunk));
    _preRollBytes += chunk.length;
    final maxBytes = ((sampleRate * preRollMs / 1000).ceil()) * 2;
    while (_preRollBytes > maxBytes && _preRoll.isNotEmpty) {
      final overflow = _preRollBytes - maxBytes;
      final first = _preRoll.first;
      if (overflow >= first.length) {
        _preRoll.removeAt(0);
        _preRollBytes -= first.length;
      } else {
        final trim = overflow.isOdd ? overflow + 1 : overflow;
        _preRoll[0] = Uint8List.sublistView(first, trim);
        _preRollBytes -= trim;
      }
    }
  }

  double _rms(Uint8List chunk) {
    final sampleCount = chunk.length ~/ 2;
    if (sampleCount == 0) return 0;
    final view = ByteData.sublistView(chunk);
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = view.getInt16(i * 2, Endian.little);
      sumSquares += sample * sample;
    }
    return math.sqrt(sumSquares / sampleCount);
  }
}
