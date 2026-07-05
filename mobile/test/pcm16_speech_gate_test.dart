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

  group('Pcm16ReArmableSpeechGate', () {
    test('stays closed under silence', () {
      final gate = Pcm16ReArmableSpeechGate();

      final result = gate.add(_pcm(samples: 1600, amplitude: 0));

      expect(result.event, Pcm16SpeechGateEvent.none);
      expect(result.chunks, isEmpty);
      expect(gate.isOpen, isFalse);
    });

    test('opens on sustained speech and flushes pre-roll', () {
      final gate = Pcm16ReArmableSpeechGate();
      final quiet = _pcm(samples: 1600, amplitude: 0);
      final speech = _pcm(samples: 1920, amplitude: 1200);

      expect(gate.add(quiet).event, Pcm16SpeechGateEvent.none);
      final result = gate.add(speech);

      expect(result.event, Pcm16SpeechGateEvent.started);
      expect(gate.isOpen, isTrue);
      expect(result.chunks.length, 2);
      expect(result.chunks.first, orderedEquals(quiet));
      expect(result.chunks.last, orderedEquals(speech));
    });

    test('forwards chunks while open', () {
      final gate = Pcm16ReArmableSpeechGate();
      gate.add(_pcm(samples: 1920, amplitude: 1200));

      final next = _pcm(samples: 320, amplitude: 900);
      final result = gate.add(next);

      expect(result.event, Pcm16SpeechGateEvent.none);
      expect(result.chunks, hasLength(1));
      expect(result.chunks.first, orderedEquals(next));
    });

    test('brief silence while open does not close the gate', () {
      final gate = Pcm16ReArmableSpeechGate(silenceHangoverMs: 800);
      gate.add(_pcm(samples: 1920, amplitude: 1200)); // opens

      final briefSilence = _pcm(samples: 100, amplitude: 0);
      final result = gate.add(briefSilence);

      expect(result.event, Pcm16SpeechGateEvent.none);
      expect(result.chunks, hasLength(1));
      expect(result.chunks.first, orderedEquals(briefSilence));
      expect(gate.isOpen, isTrue);
    });

    test('closes after sustained trailing silence and includes the final chunk', () {
      final gate = Pcm16ReArmableSpeechGate(silenceHangoverMs: 800);
      gate.add(_pcm(samples: 1920, amplitude: 1200)); // opens

      final trailingSilence = _pcm(samples: 12800, amplitude: 0); // 800ms at 16kHz
      final result = gate.add(trailingSilence);

      expect(result.event, Pcm16SpeechGateEvent.ended);
      expect(result.chunks, hasLength(1));
      expect(result.chunks.first, orderedEquals(trailingSilence));
      expect(gate.isOpen, isFalse);
    });

    test('re-arms and opens again for a second utterance without leaking prior audio into pre-roll', () {
      final gate = Pcm16ReArmableSpeechGate(silenceHangoverMs: 800);
      // First utterance: opens, then closes on trailing silence.
      gate.add(_pcm(samples: 1920, amplitude: 1200));
      gate.add(_pcm(samples: 12800, amplitude: 0));
      expect(gate.isOpen, isFalse);

      // Gap between utterances, then a second speech burst.
      final gap = _pcm(samples: 800, amplitude: 0);
      final secondSpeech = _pcm(samples: 1920, amplitude: 1500);
      expect(gate.add(gap).event, Pcm16SpeechGateEvent.none);
      final result = gate.add(secondSpeech);

      expect(result.event, Pcm16SpeechGateEvent.started);
      expect(gate.isOpen, isTrue);
      // Pre-roll for the second utterance is only the gap audio since the
      // gate re-armed — none of the first utterance's speech/silence bytes
      // should leak into this "started" event's chunks.
      expect(result.chunks.length, 2);
      expect(result.chunks.first, orderedEquals(gap));
      expect(result.chunks.last, orderedEquals(secondSpeech));
    });
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
