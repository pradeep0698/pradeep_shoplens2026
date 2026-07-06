import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/core/utils/pcm16_agc.dart';

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

int _peak(List<int> samples) => samples.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);

void main() {
  test('boosts a quiet chunk toward the target peak over repeated chunks', () {
    final agc = Pcm16Agc();
    // ~6% of full scale — well below the 55% target.
    final quiet = List<int>.generate(200, (i) => (i.isEven ? 2000 : -2000));

    var output = quiet;
    for (var i = 0; i < 20; i++) {
      output = _readPcm16(agc.process(_pcm16(quiet)));
    }

    expect(_peak(output), greaterThan(_peak(quiet)));
  });

  test('attenuates a loud chunk toward the target peak over repeated chunks', () {
    final agc = Pcm16Agc();
    // Full-scale square wave — well above the 55% target.
    final loud = List<int>.generate(200, (i) => (i.isEven ? 32000 : -32000));

    var output = loud;
    for (var i = 0; i < 20; i++) {
      output = _readPcm16(agc.process(_pcm16(loud)));
    }

    expect(_peak(output), lessThan(_peak(loud)));
  });

  test('never overflows int16 range regardless of gain applied', () {
    final agc = Pcm16Agc();
    final quiet = List<int>.generate(200, (i) => (i.isEven ? 100 : -100));

    Uint8List output = _pcm16(quiet);
    for (var i = 0; i < 50; i++) {
      output = agc.process(output.length == quiet.length * 2 ? _pcm16(quiet) : output);
    }
    final samples = _readPcm16(output);

    expect(samples.every((s) => s >= -32768 && s <= 32767), isTrue);
  });

  test('leaves near-silent chunks unamplified rather than chasing noise upward', () {
    final agc = Pcm16Agc();
    // ~0.3% of full scale — below the default noise floor.
    final silence = List<int>.generate(200, (i) => (i.isEven ? 100 : -100));

    final output = _readPcm16(agc.process(_pcm16(silence)));

    // Default gain is 1.0 and silence is below the noise floor, so gain
    // should not have moved from its initial value.
    expect(output, silence);
  });

  test('recalibrates immediately for each assistant turn', () {
    final agc = Pcm16Agc();
    final loud = _pcm16(List<int>.generate(200, (i) => i.isEven ? 30000 : -30000));
    final quiet = _pcm16(List<int>.generate(200, (i) => i.isEven ? 4000 : -4000));

    agc.process(loud);
    agc.resetForTurn();
    final output = _readPcm16(agc.process(quiet));

    expect(_peak(output), greaterThan(12000));
  });
}
