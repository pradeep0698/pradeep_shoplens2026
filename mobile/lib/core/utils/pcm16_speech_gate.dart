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

double _rmsOf(Uint8List chunk) {
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

enum Pcm16SpeechGateEvent { none, started, ended }

/// Result of feeding one chunk into a [Pcm16ReArmableSpeechGate] — unlike
/// [Pcm16SpeechGate]'s one-shot [Pcm16SpeechGateResult], this can report
/// [Pcm16SpeechGateEvent.ended] as well, since the gate cycles closed->open->
/// closed repeatedly over the life of one continuously-open mic stream.
class Pcm16SpeechGateCycleResult {
  const Pcm16SpeechGateCycleResult({required this.event, required this.chunks});

  final Pcm16SpeechGateEvent event;
  final List<Uint8List> chunks;
}

/// A re-armable variant of [Pcm16SpeechGate] for hands-free mode, where one
/// mic stream stays open for a whole conversation and must detect many
/// separate utterances (not just the first one). Cycles CLOSED -> OPEN (on
/// sustained speech, same trigger/pre-roll logic as [Pcm16SpeechGate]) ->
/// CLOSED again (on sustained trailing silence) -> repeats, with a fresh
/// pre-roll buffer started immediately after each close so a fast follow-up
/// utterance isn't handicapped by audio buffered before the previous one.
///
/// silenceHangoverMs is the highest-risk empirical default here (800ms,
/// borrowed from this codebase's existing _speakingDebounce constant purely
/// for a proven-elsewhere starting point, not because it's validated for
/// end-of-speech detection) — too short truncates natural mid-sentence
/// pauses, too long feels laggy. Needs on-device tuning with real speech.
class Pcm16ReArmableSpeechGate {
  Pcm16ReArmableSpeechGate({
    this.sampleRate = 16000,
    this.rmsThreshold = 700,
    this.triggerMs = 120,
    this.preRollMs = 300,
    this.silenceHangoverMs = 800,
  });

  final int sampleRate;
  final int rmsThreshold;
  final int triggerMs;
  final int preRollMs;
  final int silenceHangoverMs;

  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;
  int _voicedSamples = 0;
  int _silentSamples = 0;
  bool _open = false;

  bool get isOpen => _open;

  Pcm16SpeechGateCycleResult add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return const Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: []);
    }

    if (!_open) {
      _addPreRoll(chunk);
      if (_rmsOf(chunk) >= rmsThreshold) {
        _voicedSamples += chunk.length ~/ 2;
      } else {
        _voicedSamples = 0;
      }

      final triggerSamples = (sampleRate * triggerMs / 1000).ceil();
      if (_voicedSamples < triggerSamples) {
        return const Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: []);
      }

      _open = true;
      _silentSamples = 0;
      final chunks = List<Uint8List>.from(_preRoll);
      _preRoll.clear();
      _preRollBytes = 0;
      return Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.started, chunks: chunks);
    }

    // OPEN: forward this chunk, but also track trailing silence so a
    // sustained quiet spell closes the gate again (re-arming for the next
    // utterance) instead of staying open forever like the single-shot gate.
    if (_rmsOf(chunk) >= rmsThreshold) {
      _silentSamples = 0;
      return Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: [chunk]);
    }

    _silentSamples += chunk.length ~/ 2;
    final hangoverSamples = (sampleRate * silenceHangoverMs / 1000).ceil();
    if (_silentSamples < hangoverSamples) {
      return Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.none, chunks: [chunk]);
    }

    // Sustained silence — close and re-arm. The pre-roll buffer is already
    // empty (cleared on open) so the very next add() call starts a fresh
    // pre-roll exactly as it would for a brand-new instance.
    _open = false;
    _voicedSamples = 0;
    _silentSamples = 0;
    return Pcm16SpeechGateCycleResult(event: Pcm16SpeechGateEvent.ended, chunks: [chunk]);
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
}
