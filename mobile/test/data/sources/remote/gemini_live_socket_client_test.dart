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

  group('searchResultForModel', () {
    test('caps the product list at 15 and strips image/purchase URLs', () {
      // 20 results — more than the search ceiling would realistically ever
      // return (15) — to exercise the cap itself, not just the stripping.
      final result = {
        'status': 'found',
        'query': 'gadgets',
        'provider': 'google_shopping',
        'products': List.generate(
          20,
          (i) => {
            'name': 'Product $i',
            'price': 9.99,
            'seller': 'Acme',
            'image_url': 'data:image/jpeg;base64,${'A' * 5000}',
            'purchase_url': 'https://example.com/buy',
            'product_id': 'p$i',
          },
        ),
      };

      final trimmed = searchResultForModel(result);

      expect(trimmed['status'], 'found');
      expect(trimmed['query'], 'gadgets');
      expect((trimmed['products'] as List).length, 15);
      expect(trimmed['products'][0], {'name': 'Product 0', 'price': 9.99, 'seller': 'Acme'});
      expect((trimmed['products'][0] as Map).containsKey('image_url'), isFalse);
      expect((trimmed['products'][0] as Map).containsKey('purchase_url'), isFalse);
    });

    test('handles a missing products key without throwing', () {
      final trimmed = searchResultForModel({'status': 'error', 'query': ''});
      expect(trimmed['products'], isEmpty);
    });
  });
}
