import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/core/utils/pcm16_resampler.dart';

Uint8List _pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

List<int> _readPcm16(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return List<int>.generate(bytes.length ~/ 2, (i) => data.getInt16(i * 2, Endian.little));
}

void main() {
  test('passes audio through unchanged when input and output rates match', () {
    final resampler = Pcm16Resampler(inputSampleRate: 16000, outputSampleRate: 16000);
    final chunk = _pcm16([1, 2, 3, 4]);

    expect(resampler.convert(chunk), same(chunk));
  });

  test('averages each window of input samples instead of picking one raw sample', () {
    final resampler = Pcm16Resampler(inputSampleRate: 4, outputSampleRate: 1);
    // step = 4 -> the single output sample should be the average of all 4 inputs.
    final output = _readPcm16(resampler.convert(_pcm16([0, 10, 20, 30])));

    expect(output, [15]);
  });

  test('downsamples 48kHz to 16kHz at roughly a 3:1 ratio across chunk boundaries', () {
    final resampler = Pcm16Resampler(inputSampleRate: 48000, outputSampleRate: 16000);
    final input = List<int>.generate(4800, (i) => i % 100);

    final outputLength = _readPcm16(resampler.convert(_pcm16(input))).length;

    // 4800 input samples at a 3:1 ratio should produce ~1600 output samples.
    expect(outputLength, inInclusiveRange(1590, 1600));
  });

  test('carries leftover samples across chunk boundaries without dropping audio', () {
    final resampler = Pcm16Resampler(inputSampleRate: 3, outputSampleRate: 1);
    final first = _readPcm16(resampler.convert(_pcm16([10, 20])));
    final second = _readPcm16(resampler.convert(_pcm16([30])));

    // First chunk (2 samples) isn't a full 3-sample window yet, so it must
    // produce nothing and carry both samples forward instead of dropping them.
    expect(first, isEmpty);
    // Once the third sample arrives, the averaged window [10, 20, 30] -> 20.
    expect(second, [20]);
  });

  test('returns empty output for a chunk too short to contain a sample', () {
    final resampler = Pcm16Resampler(inputSampleRate: 48000, outputSampleRate: 16000);

    expect(resampler.convert(Uint8List(1)), isEmpty);
  });
}
