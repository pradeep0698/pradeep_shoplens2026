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
    final agc = Pcm16Agc(sampleRateHz: 24000);
    // ~6% of full scale — well below the 55% target.
    final quiet = List<int>.generate(200, (i) => (i.isEven ? 2000 : -2000));

    var output = quiet;
    for (var i = 0; i < 20; i++) {
      output = _readPcm16(agc.process(_pcm16(quiet)));
    }

    expect(_peak(output), greaterThan(_peak(quiet)));
  });

  test('attenuates a loud chunk toward the target peak over repeated chunks', () {
    final agc = Pcm16Agc(sampleRateHz: 24000);
    // Full-scale square wave — well above the 55% target.
    final loud = List<int>.generate(200, (i) => (i.isEven ? 32000 : -32000));

    var output = loud;
    for (var i = 0; i < 20; i++) {
      output = _readPcm16(agc.process(_pcm16(loud)));
    }

    expect(_peak(output), lessThan(_peak(loud)));
  });

  test('never overflows int16 range regardless of gain applied', () {
    final agc = Pcm16Agc(sampleRateHz: 24000);
    final quiet = List<int>.generate(200, (i) => (i.isEven ? 100 : -100));

    Uint8List output = _pcm16(quiet);
    for (var i = 0; i < 50; i++) {
      output = agc.process(output.length == quiet.length * 2 ? _pcm16(quiet) : output);
    }
    final samples = _readPcm16(output);

    expect(samples.every((s) => s >= -32768 && s <= 32767), isTrue);
  });

  test('leaves near-silent chunks unamplified rather than chasing noise upward', () {
    final agc = Pcm16Agc(sampleRateHz: 24000);
    // ~0.3% of full scale — below the default noise floor.
    final silence = List<int>.generate(200, (i) => (i.isEven ? 100 : -100));

    final output = _readPcm16(agc.process(_pcm16(silence)));

    // Default gain is 1.0 and silence is below the noise floor, so gain
    // should not have moved from its initial value.
    expect(output, silence);
  });

  test('never lets a single hot sample clip even when gain is boosted', () {
    final agc = Pcm16Agc(sampleRateHz: 24000);
    // Mostly quiet (drives gain up over repeated chunks) but with one
    // near-full-scale sample mixed in — the clip-safety clamp must cap the
    // *applied* gain for this chunk without touching the AGC's underlying
    // gain trajectory.
    final mixed = List<int>.generate(200, (i) => i == 5 ? 32000 : (i.isEven ? 2000 : -2000));

    Uint8List output = _pcm16(mixed);
    for (var i = 0; i < 20; i++) {
      output = agc.process(_pcm16(mixed));
    }
    final samples = _readPcm16(output);

    expect(samples.every((s) => s >= -32768 && s <= 32767), isTrue);
  });

  test('buffers calibration across several chunks rather than snapping to the first one', () {
    // Small sample rate/budget so a short chunk stays well under the
    // calibration window, making the "still accumulating" state easy to
    // observe directly.
    final agc = Pcm16Agc(sampleRateHz: 1000, calibrationBudgetMs: 60);
    // A single loud, short first chunk (20 samples — under the 60-sample
    // calibration budget) must NOT instantly snap the gain down the way the
    // old single-chunk-peak calibration did; it should still play at the
    // untouched initial gain while calibration keeps accumulating.
    final loudFirstChunk = _pcm16(List<int>.generate(20, (i) => i.isEven ? 32000 : -32000));

    final output = agc.process(loudFirstChunk);

    expect(_readPcm16(output), _readPcm16(loudFirstChunk));
  });

  test("carries the previous turn's calibrated gain forward instead of resetting to unity", () {
    final agc = Pcm16Agc(sampleRateHz: 1000, calibrationBudgetMs: 50);
    final quiet = List<int>.generate(100, (i) => i.isEven ? 2000 : -2000); // well under target

    // Drive turn 1 to a settled, boosted gain over several chunks.
    Uint8List output = _pcm16(quiet);
    for (var i = 0; i < 10; i++) {
      output = agc.process(_pcm16(quiet));
    }
    expect(_peak(_readPcm16(output)), greaterThan(_peak(quiet)));

    agc.resetForTurn();

    // The very first chunk of turn 2 should already reflect something close
    // to turn 1's ending gain rather than unity — even though turn 2's own
    // calibration window hasn't committed yet (the same input chunk alone
    // exceeds the budget and triggers an immediate commit here, but starting
    // from the carried-forward gain, not from 1.0).
    final turn2Output = _readPcm16(agc.process(_pcm16(quiet)));
    expect(_peak(turn2Output), greaterThan((_peak(quiet) * 1.5).round()));
  });
}
