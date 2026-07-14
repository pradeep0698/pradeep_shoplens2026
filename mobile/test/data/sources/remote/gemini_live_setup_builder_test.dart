import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/data/sources/remote/gemini_live_setup_builder.dart';

void main() {
  group('greetingCue', () {
    test('fresh session mentions opening the conversation', () {
      expect(greetingCue(false), kFreshGreetingCue);
      expect(greetingCue(false).toLowerCase(), contains('just opened the conversation'));
    });

    test('resumed session mentions reconnecting', () {
      expect(greetingCue(true), kResumeGreetingCue);
      expect(greetingCue(true).toLowerCase(), contains('reconnected'));
    });
  });
}
