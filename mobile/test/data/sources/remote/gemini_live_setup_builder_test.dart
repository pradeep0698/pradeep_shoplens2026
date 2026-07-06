import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/data/models/voice_session.dart';
import 'package:shoplens/data/sources/remote/gemini_live_setup_builder.dart';

void main() {
  group('profileNote', () {
    test('empty profile says first time', () {
      final note = profileNote(const VoiceProfilePatch());
      expect(note, contains('no saved preferences yet'));
    });

    test('summarizes existing data', () {
      final note = profileNote(const VoiceProfilePatch(
        shoppingCategories: ['Clothing'],
        preferenceTerms: ['Nike'],
        ignoreTerms: ['leather'],
      ));
      expect(note, contains('shops for Clothing'));
      expect(note, contains('likes Nike'));
      expect(note, contains('avoids leather'));
    });

    test('carve-out does not exempt per-search clarifying questions', () {
      final note = profileNote(const VoiceProfilePatch(
        shoppingCategories: ['Clothing'],
        preferenceTerms: ['Nike'],
        ignoreTerms: ['leather'],
      ));
      expect(note.toLowerCase(), contains("don't"));
      expect(note.toLowerCase(), contains('re-ask'));
      expect(note.toLowerCase(), contains('gather first'));
    });
  });

  group('systemPrompt', () {
    test('embeds profile note', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(shoppingCategories: ['Electronics']),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt, contains('shops for Electronics'));
      expect(prompt, contains('ready_to_finalize'));
    });

    test('tells model to mention finishing in greeting', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt.toLowerCase(), contains("i'm done"));
    });

    test('search mode uses search template and tool', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'search',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt, contains('search_products'));
      expect(prompt, isNot(contains('ready_to_finalize')));
    });

    test('search mode requires three clarifying questions before searching', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'search',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt.toLowerCase(), contains('clarifying questions'));
      expect(prompt.toLowerCase(), contains('three'));
    });

    test('search mode avoids repeat searches for rephrasing', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'search',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt.toLowerCase(), contains('rephrased'));
    });

    test('preferences mode follows up on same category before moving on', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt.toLowerCase(), contains('same category'));
    });

    test('defaults to no language directive for English', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt, isNot(contains('Conduct this entire conversation')));
    });

    test('appends language directive for non-English', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'Spanish',
        resumeTranscript: const [],
      );
      expect(prompt, contains('Conduct this entire conversation in Spanish'));
    });

    test('embeds resume note when transcript provided', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [VoiceTranscriptTurn(role: 'user', text: 'I like minimalist furniture')],
      );
      expect(prompt.toLowerCase(), contains('interrupted'));
      expect(prompt, contains('I like minimalist furniture'));
    });

    test('omits resume note for a fresh session', () {
      final prompt = systemPrompt(
        existingProfile: const VoiceProfilePatch(),
        mode: 'preferences',
        language: 'English',
        resumeTranscript: const [],
      );
      expect(prompt.toLowerCase(), isNot(contains('interrupted')));
    });
  });

  group('resumeNote', () {
    test('empty transcript yields no note', () {
      expect(resumeNote(const []), '');
    });

    test('includes prior turns', () {
      final note = resumeNote(const [
        VoiceTranscriptTurn(role: 'user', text: 'I like minimalist furniture'),
        VoiceTranscriptTurn(role: 'model', text: 'Got it, anything else?'),
      ]);
      expect(note.toLowerCase(), contains('interrupted'));
      expect(note, contains('I like minimalist furniture'));
      expect(note, contains('Got it, anything else?'));
    });

    test('only keeps last 20 turns', () {
      final transcript = List.generate(25, (i) => VoiceTranscriptTurn(role: 'user', text: 'turn $i'));
      final note = resumeNote(transcript);
      expect(note, isNot(contains('turn 0\n')));
      expect(note, isNot(contains('turn 0:')));
      expect(note, contains('turn 24'));
    });

    test('truncates very long conversations', () {
      final note = resumeNote([VoiceTranscriptTurn(role: 'user', text: 'x' * 3000)]);
      expect(note.length, lessThan(2500));
    });
  });

  group('buildSetupJson', () {
    Map<String, dynamic> setupFor({required String mode, String language = 'English'}) => buildSetupJson(
          existingProfile: const VoiceProfilePatch(),
          mode: mode,
          language: language,
          resumeTranscript: const [],
        );

    test('defaults to Puck voice', () {
      final setup = setupFor(mode: 'preferences');
      expect(
        setup['generationConfig']['speechConfig']['voiceConfig']['prebuiltVoiceConfig']['voiceName'],
        'Puck',
      );
    });

    test('disables automatic activity detection (snake_case wire key)', () {
      final setup = setupFor(mode: 'preferences');
      expect(setup['realtimeInputConfig']['automatic_activity_detection']['disabled'], isTrue);
    });

    test('context window compression uses snake_case wire keys', () {
      final setup = setupFor(mode: 'preferences');
      expect(setup['contextWindowCompression']['trigger_tokens'], kContextWindowTriggerTokens);
      expect(setup['contextWindowCompression']['sliding_window'], <String, dynamic>{});
    });

    test('preferences mode uses preference tools', () {
      final setup = setupFor(mode: 'preferences');
      final names = <String>{
        for (final tool in setup['tools'] as List)
          for (final fn in tool['functionDeclarations'] as List) fn['name'] as String,
      };
      expect(names, {'ready_to_finalize', 'record_preference'});
    });

    test('search mode uses search tool', () {
      final setup = setupFor(mode: 'search');
      final names = <String>{
        for (final tool in setup['tools'] as List)
          for (final fn in tool['functionDeclarations'] as List) fn['name'] as String,
      };
      expect(names, {'search_products'});
    });

    test('threads language into system instruction', () {
      final setup = setupFor(mode: 'preferences', language: 'French');
      expect(
        setup['systemInstruction']['parts'][0]['text'],
        contains('Conduct this entire conversation in French'),
      );
    });
  });

  test('search_products tool description requires a distinguishing detail', () {
    final description = (searchProductsTool()['description'] as String).toLowerCase();
    expect(description, contains('distinguishing detail'));
    expect(description, contains('bare category'));
  });

  test('kVoiceCategories has the 8 fixed categories', () {
    expect(kVoiceCategories, [
      'Furniture',
      'Clothing',
      'Kitchen & Cookware',
      'Accessories',
      'Electronics',
      'Home Decor',
      'Sports & Outdoors',
      'Books & Stationery',
    ]);
  });
}
