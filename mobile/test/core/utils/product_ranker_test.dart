import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/core/utils/product_ranker.dart';
import 'package:shoplens/data/models/product.dart';

Product _product({
  required String name,
  String? category,
  String? seller,
  double price = 10.0,
}) =>
    Product(
      productId: name,
      name: name,
      price: price,
      imageUrl: '',
      category: category,
      seller: seller,
    );

void main() {
  group('isPreferred', () {
    test('matches on the category field when present', () {
      final product = _product(name: 'Office Chair', category: 'Furniture');
      expect(isPreferred(product, ['Furniture']), isTrue);
      expect(isPreferred(product, ['Electronics']), isFalse);
    });

    test('falls back to keyword match when category is missing', () {
      final product = _product(name: 'Cozy reading chair');
      expect(isPreferred(product, ['Furniture']), isTrue);
    });

    test('returns false when shoppingCategories is empty', () {
      final product = _product(name: 'Office Chair', category: 'Furniture');
      expect(isPreferred(product, const []), isFalse);
    });
  });

  group('rankProducts — preferenceTerms boost', () {
    test('a product matching a preferenceTerms word ranks above a non-matching '
        'product within the same category bucket', () {
      final nikeShoe   = _product(name: 'Nike running shoe', category: 'Clothing');
      final otherShoe  = _product(name: 'Generic running shoe', category: 'Clothing');

      final ranked = rankProducts(
        [otherShoe, nikeShoe],
        const ['Clothing'],
        preferenceTerms: const ['Nike'],
        isExactMatchSource: true,
      );

      expect(ranked.first, equals(nikeShoe));
    });

    test('preferenceTerms boost is additive to, not a replacement for, category ranking', () {
      final preferredCategoryNoTerm = _product(name: 'Plain desk', category: 'Furniture');
      final otherCategoryWithTerm   = _product(name: 'Minimalist mug', category: 'Kitchen & Cookware');

      final ranked = rankProducts(
        [otherCategoryWithTerm, preferredCategoryNoTerm],
        const ['Furniture'],
        preferenceTerms: const ['minimalist'],
        isExactMatchSource: true,
      );

      // The Furniture item stays ahead of the Kitchen item even though only
      // the Kitchen item matches a preference term — category bucket wins first.
      expect(ranked.first, equals(preferredCategoryNoTerm));
    });

    test('matches case-insensitively against product name and seller', () {
      final bySeller = _product(name: 'Running shoe', seller: 'Nike Store', category: 'Clothing');
      final neither  = _product(name: 'Running shoe', category: 'Clothing');

      final ranked = rankProducts(
        [neither, bySeller],
        const ['Clothing'],
        preferenceTerms: const ['NIKE'],
        isExactMatchSource: true,
      );

      expect(ranked.first, equals(bySeller));
    });

    test('with no shoppingCategories, preferenceTerms still boosts globally', () {
      final matching    = _product(name: 'Minimalist vase');
      final nonMatching = _product(name: 'Ornate vase');

      final ranked = rankProducts(
        [nonMatching, matching],
        const [],
        preferenceTerms: const ['minimalist'],
        isExactMatchSource: true,
      );

      expect(ranked.first, equals(matching));
    });

    test('preferenceTerms defaults to empty and changes nothing when omitted', () {
      final a = _product(name: 'Item A', category: 'Furniture');
      final b = _product(name: 'Item B', category: 'Furniture');

      final ranked = rankProducts([a, b], const ['Furniture'], isExactMatchSource: true);

      expect(ranked, equals([a, b]));
    });
  });

  group('rankProducts — ignoreTerms-adjacent regression guard (\$0 demotion)', () {
    test('non-exact-match sources still sink \$0 items to the bottom, unaffected by preferenceTerms', () {
      final free   = _product(name: 'Free sample', category: 'Furniture', price: 0);
      final priced = _product(name: 'Plain desk', category: 'Furniture', price: 50);

      final ranked = rankProducts(
        [free, priced],
        const ['Furniture'],
        preferenceTerms: const ['plain'],
        isExactMatchSource: false,
      );

      expect(ranked.last, equals(free));
    });

    test('exact-match sources never demote \$0 items regardless of preferenceTerms', () {
      final free   = _product(name: 'Free sample', category: 'Furniture', price: 0);
      final priced = _product(name: 'Plain desk', category: 'Furniture', price: 50);

      final ranked = rankProducts(
        [free, priced],
        const ['Furniture'],
        preferenceTerms: const ['plain'],
        isExactMatchSource: true,
      );

      // Category bucket places both as preferred; preferenceTerms then puts
      // "Plain desk" first since it matches "plain" and "Free sample" doesn't.
      expect(ranked.first, equals(priced));
    });
  });
}
