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

    test('preserves category association in preferencesByCategory', () {
      final profile = UserProfile.fromFirestore({
        'preference_terms': {
          'Kitchen & Cookware': ['cast iron', 'mixing bowls'],
        },
        'ignore_terms': {
          'Kitchen & Cookware': ['plastic'],
          'Furniture': [],
        },
      });

      expect(profile.preferencesByCategory['Kitchen & Cookware']?.include,
          ['cast iron', 'mixing bowls']);
      expect(profile.preferencesByCategory['Kitchen & Cookware']?.exclude, ['plastic']);
      expect(profile.preferencesByCategory['Furniture']?.exclude, isEmpty);
    });

    test('buckets a flat legacy list under the general bucket', () {
      final profile = UserProfile.fromFirestore({
        'preference_terms': ['Nike', 'Adidas'],
      });

      expect(profile.preferencesByCategory[generalPreferenceBucket]?.include,
          ['Nike', 'Adidas']);
    });
  });

  group('UserProfile.toFirestore', () {
    test('writes preference_terms/ignore_terms as category-keyed maps, dropping empty buckets', () {
      const profile = UserProfile(
        preferencesByCategory: {
          'Kitchen & Cookware': CategoryTerms(include: ['cast iron'], exclude: ['plastic']),
          'Furniture': CategoryTerms(include: [], exclude: []),
        },
      );

      final data = UserProfile.toFirestore(profile);

      expect(data['preference_terms'], {'Kitchen & Cookware': ['cast iron']});
      expect(data['ignore_terms'], {'Kitchen & Cookware': ['plastic']});
    });

    test('preserves unrelated fields via merge-style save payload', () {
      const profile = UserProfile(username: 'Ava', dob: '1990-01-01');
      final data = UserProfile.toFirestore(profile);

      expect(data['username'], 'Ava');
      expect(data['dob'], '1990-01-01');
      expect(data['preference_terms'], isEmpty);
      expect(data['ignore_terms'], isEmpty);
    });
  });

  group('UserProfile flat term getters', () {
    test('dedupe case-insensitively across categories', () {
      const profile = UserProfile(
        preferencesByCategory: {
          'Kitchen & Cookware': CategoryTerms(include: ['Nike']),
          'Clothing': CategoryTerms(include: ['nike', 'Adidas']),
        },
      );

      expect(profile.preferenceTerms, ['Nike', 'Adidas']);
    });
  });
}
