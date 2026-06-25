import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/core/utils/pcm16_speech_gate.dart';
import 'package:shoplens/data/models/voice_session.dart';

void main() {
  test('speech gate ignores silence and low noise', () {
    final gate = Pcm16SpeechGate();

    expect(gate.add(_pcm(samples: 1600, amplitude: 0)).chunks, isEmpty);
    expect(gate.add(_pcm(samples: 1600, amplitude: 300)).chunks, isEmpty);
    expect(gate.isOpen, isFalse);
  });

  test('speech gate opens after threshold duration and flushes pre-roll', () {
    final gate = Pcm16SpeechGate();

    final quiet = _pcm(samples: 1600, amplitude: 0);
    final speech = _pcm(samples: 1920, amplitude: 1200);

    expect(gate.add(quiet).chunks, isEmpty);
    final result = gate.add(speech);

    expect(result.started, isTrue);
    expect(gate.isOpen, isTrue);
    expect(result.chunks.length, 2);
    expect(result.chunks.first, orderedEquals(quiet));
    expect(result.chunks.last, orderedEquals(speech));
  });

  test('speech gate forwards later speech after opening', () {
    final gate = Pcm16SpeechGate();
    gate.add(_pcm(samples: 1920, amplitude: 1200));

    final next = _pcm(samples: 320, amplitude: 900);
    final result = gate.add(next);

    expect(result.started, isFalse);
    expect(result.chunks, hasLength(1));
    expect(result.chunks.first, orderedEquals(next));
  });

  test('review patch copy preserves deleted chips in confirmed payload', () {
    const original = VoiceProfilePatch(
      shoppingCategories: ['Clothing', 'Electronics'],
      preferenceTerms: ['cotton', 'Nike'],
      ignoreTerms: ['leather'],
    );

    final reviewed = original.copyWith(
      shoppingCategories: original.shoppingCategories.where((c) => c != 'Clothing').toList(),
      preferenceTerms: original.preferenceTerms.where((t) => t != 'Nike').toList(),
    );

    expect(reviewed.toJson(), {
      'shopping_categories': ['Electronics'],
      'preference_terms': ['cotton'],
      'ignore_terms': ['leather'],
      'summary': '',
    });
  });
}

Uint8List _pcm({required int samples, required int amplitude}) {
  final bytes = Uint8List(samples * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    view.setInt16(i * 2, amplitude, Endian.little);
  }
  return bytes;
}
