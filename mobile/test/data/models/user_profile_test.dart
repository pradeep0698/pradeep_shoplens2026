import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/data/models/user_profile.dart';

void main() {
  group('UserProfile.fromFirestore', () {
    test('parses a plain flat list (pre category-scoping documents)', () {
      final profile = UserProfile.fromFirestore({
        'preference_terms': ['Nike', 'Adidas'],
        'ignore_terms': ['leather'],
      });

      expect(profile.preferenceTerms, ['Nike', 'Adidas']);
      expect(profile.ignoreTerms, ['leather']);
    });

    test('flattens a category-keyed map instead of throwing', () {
      // Regression guard: services/voice-assistant/profile_store.py stores
      // preference_terms/ignore_terms as a category-keyed map — a naive
      // List<String>.from(...) on a Map throws "type 'Map' is not a subtype
      // of type 'Iterable'".
      final profile = UserProfile.fromFirestore({
        'preference_terms': {
          'Electronics': ['LG'],
          'Clothing': ['Nike', 'Adidas'],
        },
        'ignore_terms': {
          '_general': ['plastic'],
        },
      });

      expect(profile.preferenceTerms, containsAll(['LG', 'Nike', 'Adidas']));
      expect(profile.ignoreTerms, ['plastic']);
    });

    test('defaults to an empty list when the field is missing', () {
      final profile = UserProfile.fromFirestore({});

      expect(profile.preferenceTerms, isEmpty);
      expect(profile.ignoreTerms, isEmpty);
    });
  });
}
