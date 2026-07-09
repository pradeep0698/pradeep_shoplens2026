import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/data/sources/remote/gemini_live_socket_client.dart';

void main() {
  group('categoriesFromRecordPreferenceArgs', () {
    test('returns the categories when present', () {
      expect(
        categoriesFromRecordPreferenceArgs({
          'shopping_categories': ['Kitchen & Cookware'],
        }),
        ['Kitchen & Cookware'],
      );
    });

    test('returns empty when absent', () {
      expect(categoriesFromRecordPreferenceArgs({'preference_terms': ['Nike']}), isEmpty);
    });
  });

  group('recordPreferenceArgsWithCategoryFallback', () {
    test('leaves args untouched when this call already names a category', () {
      final args = {
        'shopping_categories': ['Electronics'],
        'preference_terms': ['Sony'],
      };

      final result = recordPreferenceArgsWithCategoryFallback(args, lastCategories: const ['Clothing']);

      expect(result['shopping_categories'], ['Electronics']);
    });

    test('fills in the last mentioned category for a category-less follow-up call', () {
      final args = {'preference_terms': ['cast iron']};

      final result = recordPreferenceArgsWithCategoryFallback(
        args,
        lastCategories: const ['Kitchen & Cookware'],
      );

      expect(result['shopping_categories'], ['Kitchen & Cookware']);
      expect(result['preference_terms'], ['cast iron']);
    });

    test('fills in for ignore_terms too', () {
      final args = {'ignore_terms': ['plastic']};

      final result = recordPreferenceArgsWithCategoryFallback(
        args,
        lastCategories: const ['Kitchen & Cookware'],
      );

      expect(result['shopping_categories'], ['Kitchen & Cookware']);
    });

    test('leaves args untouched when no category has ever been mentioned (true general case)', () {
      final args = {'preference_terms': ['minimalist style']};

      final result = recordPreferenceArgsWithCategoryFallback(args, lastCategories: const []);

      expect(result.containsKey('shopping_categories'), isFalse);
    });

    test('does not inject a category into a call with no terms at all', () {
      final args = <String, dynamic>{};

      final result = recordPreferenceArgsWithCategoryFallback(
        args,
        lastCategories: const ['Kitchen & Cookware'],
      );

      expect(result.containsKey('shopping_categories'), isFalse);
    });
  });
}
