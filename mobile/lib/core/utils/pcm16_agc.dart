import 'dart:math' as math;
import 'dart:typed_data';

/// Streaming automatic gain control for the assistant's own TTS output —
/// Gemini's synthesized speech varies noticeably in loudness turn to turn
/// (quiet answers, louder greetings), which reads as inconsistent volume on
/// playback. Applies a smoothed per-chunk gain that pulls the signal toward
/// [targetPeak], attenuating chunks that are too loud and boosting ones that
/// are too quiet, without a lookahead pass (chunks are fed as they stream in,
/// so there is no way to know a whole utterance's loudness ahead of time).
///
/// Calibrates once per turn over a short buffered window (see
/// [calibrationBudgetMs]) using RMS rather than a single chunk's instantaneous
/// peak — a lone plosive or quiet consonant as the very first chunk of a turn
/// used to lock in the wrong gain for the whole turn. The calibrated gain is
/// then committed in one large jump (see [calibrationConvergence]) rather
/// than through the gradual attack/release smoothing used for ongoing
/// mid-turn nudges — that gradual smoothing is still what carries
/// [_currentGain] forward from wherever the previous turn ended (see
/// [resetForTurn]) into the pre-calibration window of the next one, so
/// consecutive turns in a session drift toward a consistent volume instead of
/// each starting from a blank slate, but the actual per-turn correction needs
/// to land fast enough that a short turn doesn't finish before converging.
class Pcm16Agc {
  Pcm16Agc({
    required this.sampleRateHz,
    this.targetPeak = 0.55,
    this.maxGain = 4.5,
    this.minGain = 0.35,
    this.attack = 0.5,
    this.release = 0.06,
    this.noiseFloor = 0.02,
    this.calibrationBudgetMs = 150,
    this.silenceFallbackMs = 450,
    this.calibrationConvergence = 0.85,
  })  : _calibrationSampleBudget = (sampleRateHz * calibrationBudgetMs / 1000).round(),
        _silenceFallbackSampleCeiling = (sampleRateHz * silenceFallbackMs / 1000).round();

  // Playback sample rate — needed to convert the calibration/fallback
  // windows below from milliseconds into a sample count.
  final int sampleRateHz;
  // Amplitude (fraction of full scale) the AGC steers each chunk's RMS
  // level toward.
  final double targetPeak;
  // Gain is clamped to this range so near-silent chunks don't get amplified
  // into audible hiss, and loud transients aren't attenuated unnaturally.
  final double maxGain;
  final double minGain;
  // How quickly _currentGain moves toward the chunk's ideal gain — fast
  // "attack" when the signal is louder than target (cut quickly to avoid
  // clipping/harshness), slower "release" when it's quieter (avoids pumping
  // the gain up on brief dips within an utterance).
  final double attack;
  final double release;
  // Chunks quieter than this (as a fraction of full scale) are passed
  // through with the last-known gain rather than chasing background
  // noise/silence upward.
  final double noiseFloor;
  // How long to accumulate voiced audio at the start of a turn before
  // committing a calibrated gain — long enough to smooth out a single
  // unrepresentative chunk (a plosive, a quiet consonant), short enough that
  // playback doesn't audibly wait for it (chunks still play immediately at
  // the carried-forward gain while this accumulates, see [process]).
  final int calibrationBudgetMs;
  // Ceiling on how long to wait for voiced audio to reach the calibration
  // budget above — a turn that opens with silence would otherwise never
  // finish calibrating.
  final int silenceFallbackMs;
  // Fraction of the way _currentGain jumps toward the calibrated ideal gain
  // the instant the calibration window closes (see [process]) — deliberately
  // much larger than a single attack/release step. Committing the calibrated
  // gain through the same slow smoothing used for ongoing mid-turn nudges
  // meant a short turn could end before ever converging, and a carried-over
  // gain from an unusually loud/quiet previous turn could take dozens of
  // chunks to correct. Not 1.0 (full snap) so the very first post-calibration
  // chunk still blends slightly rather than jumping instantaneously.
  final double calibrationConvergence;

  final int _calibrationSampleBudget;
  final int _silenceFallbackSampleCeiling;

  double _currentGain = 1.0;
  bool _calibrating = true;
  int _calibrationSamples = 0;
  double _calibrationEnergy = 0.0;
  int _elapsedSamplesThisTurn = 0;

  /// Starts a fresh model utterance. Deliberately does NOT reset
  /// [_currentGain] — the new turn carries forward wherever the previous
  /// turn's gain ended up, and only re-triggers the calibration window so
  /// that carried-forward value gets corrected against this turn's own
  /// loudness rather than assumed to still be right.
  void resetForTurn() {
    _calibrating = true;
    _calibrationSamples = 0;
    _calibrationEnergy = 0.0;
    _elapsedSamplesThisTurn = 0;
  }

  Uint8List process(Uint8List input) {
    if (input.length < 2) return input;
    final data = ByteData.sublistView(input);
    final sampleCount = input.length ~/ 2;

    var peak = 0;
    var sumSquares = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little);
      final absSample = sample.abs();
      if (absSample > peak) peak = absSample;
      sumSquares += sample * sample;
    }
    final rmsFraction = math.sqrt(sumSquares / sampleCount) / 32768.0;

    if (_calibrating) {
      _elapsedSamplesThisTurn += sampleCount;
      if (rmsFraction >= noiseFloor) {
        _calibrationEnergy += sumSquares;
        _calibrationSamples += sampleCount;
      }
      final budgetMet = _calibrationSamples >= _calibrationSampleBudget;
      final timedOut = _elapsedSamplesThisTurn >= _silenceFallbackSampleCeiling;
      if (budgetMet || timedOut) {
        if (_calibrationSamples > 0) {
          final calibratedRms = math.sqrt(_calibrationEnergy / _calibrationSamples) / 32768.0;
          _commitCalibratedGain(calibratedRms);
        }
        _calibrating = false;
      }
    } else if (rmsFraction >= noiseFloor) {
      _applyTowardIdeal(rmsFraction);
    }

    // Clip-safety clamp: whatever _currentGain the RMS-based smoothing
    // above settled on, never let it push *this* chunk's loudest sample
    // past full scale — a chunk with one unusually hot sample against an
    // otherwise-average RMS could otherwise clip.
    final safeGain = peak > 0 ? math.min(_currentGain, 32767.0 / peak) : _currentGain;

    final output = Uint8List(input.length);
    final outData = ByteData.sublistView(output);
    for (var i = 0; i < sampleCount; i++) {
      final scaled = (data.getInt16(i * 2, Endian.little) * safeGain).round();
      outData.setInt16(i * 2, scaled.clamp(-32768, 32767), Endian.little);
    }
    return output;
  }

  void _applyTowardIdeal(double levelFraction) {
    final idealGain = (targetPeak / levelFraction).clamp(minGain, maxGain).toDouble();
    final rate = idealGain < _currentGain ? attack : release;
    _currentGain += (idealGain - _currentGain) * rate;
  }

  // Jumps most of the way to the calibrated ideal gain in one step rather
  // than the gradual attack/release used for ongoing mid-turn nudges — see
  // [calibrationConvergence]'s doc comment for why.
  void _commitCalibratedGain(double levelFraction) {
    final idealGain = (targetPeak / levelFraction).clamp(minGain, maxGain).toDouble();
    _currentGain += (idealGain - _currentGain) * calibrationConvergence;
  }
}
