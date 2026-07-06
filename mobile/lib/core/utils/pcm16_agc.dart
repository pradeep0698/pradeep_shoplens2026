import 'dart:typed_data';

/// Streaming automatic gain control for the assistant's own TTS output —
/// Gemini's synthesized speech varies noticeably in loudness turn to turn
/// (quiet answers, louder greetings), which reads as inconsistent volume on
/// playback. Applies a smoothed per-chunk gain that pulls the signal toward
/// [targetPeak], attenuating chunks that are too loud and boosting ones that
/// are too quiet, without a lookahead pass (chunks are fed as they stream in,
/// so there is no way to know a whole utterance's loudness ahead of time).
class Pcm16Agc {
  Pcm16Agc({
    this.targetPeak = 0.55,
    this.maxGain = 4.0,
    this.minGain = 0.4,
    this.attack = 0.5,
    this.release = 0.1,
    this.noiseFloor = 0.02,
  });

  // Amplitude (fraction of full scale) the AGC steers each chunk's peak
  // toward.
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

  double _currentGain = 1.0;

  Uint8List process(Uint8List input) {
    if (input.length < 2) return input;
    final data = ByteData.sublistView(input);
    final sampleCount = input.length ~/ 2;

    var peak = 0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    final peakFraction = peak / 32768.0;

    if (peakFraction >= noiseFloor) {
      final idealGain = (targetPeak / peakFraction).clamp(minGain, maxGain);
      final rate = idealGain < _currentGain ? attack : release;
      _currentGain += (idealGain - _currentGain) * rate;
    }

    final output = Uint8List(input.length);
    final outData = ByteData.sublistView(output);
    for (var i = 0; i < sampleCount; i++) {
      final scaled = (data.getInt16(i * 2, Endian.little) * _currentGain).round();
      outData.setInt16(i * 2, scaled.clamp(-32768, 32767), Endian.little);
    }
    return output;
  }
}
