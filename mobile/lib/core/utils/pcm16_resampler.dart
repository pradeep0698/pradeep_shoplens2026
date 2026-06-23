import 'dart:typed_data';

class Pcm16Resampler {
  Pcm16Resampler({
    required this.inputSampleRate,
    required this.outputSampleRate,
  });

  final int inputSampleRate;
  final int outputSampleRate;

  double _nextInputIndex = 0;
  List<int> _pendingSamples = const [];

  Uint8List convert(Uint8List chunk) {
    if (inputSampleRate == outputSampleRate) return chunk;
    if (chunk.length < 2) return Uint8List(0);

    final samples = _readSamples(chunk);
    final input = _pendingSamples.isEmpty
        ? samples
        : <int>[..._pendingSamples, ...samples];
    if (input.isEmpty) return Uint8List(0);

    final step = inputSampleRate / outputSampleRate;
    final output = <int>[];
    // Box-filter (moving-average) decimation rather than picking a single
    // raw sample per step — a minimal anti-aliasing low-pass matched to the
    // decimation factor. Naive point-sampling folds high-frequency content
    // back into the audible band as noise; Gemini's conversational
    // understanding tolerates that fine, but its separate transcription
    // pass does not, producing on-screen text that doesn't match what was
    // actually said even though the assistant responds correctly.
    while (_nextInputIndex + step <= input.length) {
      final start = _nextInputIndex.floor();
      final end = (_nextInputIndex + step).floor().clamp(start + 1, input.length);
      var sum = 0;
      for (var i = start; i < end; i++) {
        sum += input[i];
      }
      output.add(sum ~/ (end - start));
      _nextInputIndex += step;
    }

    final consumed = _nextInputIndex.floor();
    if (consumed >= input.length) {
      _pendingSamples = const [];
      _nextInputIndex -= input.length;
    } else {
      _pendingSamples = input.sublist(consumed);
      _nextInputIndex -= consumed;
    }

    return _writeSamples(output);
  }

  List<int> _readSamples(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    final data = ByteData.sublistView(bytes);
    return List<int>.generate(
      sampleCount,
      (i) => data.getInt16(i * 2, Endian.little),
      growable: false,
    );
  }

  Uint8List _writeSamples(List<int> samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
