import '../../data/models/product.dart';

// Keyword fallback for Firestore docs written before the category field existed
const _fallbackKeywords = <String, List<String>>{
  'Furniture':          ['chair', 'sofa', 'couch', 'desk', 'table', 'shelf', 'wardrobe', 'ottoman', 'stool', 'bookcase'],
  'Clothing':           ['shirt', 'jacket', 'jeans', 'dress', 'hoodie', 'shoe', 'boot', 'sneaker', 'hat', 'scarf', 'coat', 'pants'],
  'Kitchen & Cookware': ['pan', 'pot', 'knife', 'cutting board', 'mug', 'blender', 'bowl', 'skillet', 'kettle'],
  'Accessories':        ['watch', 'bag', 'wallet', 'necklace', 'sunglasses', 'bracelet', 'earring', 'purse', 'backpack'],
  'Electronics':        ['phone', 'laptop', 'tablet', 'headphone', 'speaker', 'charger', 'camera', 'tv', 'monitor', 'earbud'],
  'Home Decor':         ['candle', 'vase', 'frame', 'pillow', 'rug', 'lamp', 'blanket', 'curtain', 'mirror'],
  'Sports & Outdoors':  ['yoga', 'gym', 'bicycle', 'tent', 'bottle', 'dumbbell', 'mat', 'racket', 'hiking'],
  'Books & Stationery': ['book', 'notebook', 'pen', 'journal', 'planner', 'marker', 'pencil'],
};

bool isPreferred(Product product, List<String> shoppingCategories) {
  if (shoppingCategories.isEmpty) return false;

  // Primary: use the category field set by the backend matcher
  if (product.category != null && product.category!.isNotEmpty) {
    return shoppingCategories.contains(product.category);
  }

  // Fallback: keyword-match product name for docs missing the category field
  final nameLower = product.name.toLowerCase();
  for (final category in shoppingCategories) {
    final keywords = _fallbackKeywords[category] ?? [];
    if (keywords.any((kw) => nameLower.contains(kw))) return true;
  }
  return false;
}

/// Free-text style/brand/material words (e.g. "minimalist", "Nike") don't map
/// to the 8 fixed categories, so this matches against product name and
/// seller text directly, independent of [isPreferred]'s category logic. Also
/// used by ProductCard to upgrade a search result's badge from "Matched" to
/// "Preferred" when it matches one of the user's saved preference terms.
bool matchesPreferenceTerms(Product product, List<String> preferenceTerms) {
  if (preferenceTerms.isEmpty) return false;
  final haystack = '${product.name} ${product.seller ?? ''}'.toLowerCase();
  return preferenceTerms.any((term) {
    final needle = term.trim().toLowerCase();
    return needle.isNotEmpty && haystack.contains(needle);
  });
}

/// Within [products], sinks nothing — just moves preference-term matches to
/// the front.
List<Product> _boostByPreferenceTerms(List<Product> products, List<String> preferenceTerms) {
  if (preferenceTerms.isEmpty) return products;
  final matched   = <Product>[];
  final unmatched = <Product>[];
  for (final product in products) {
    matchesPreferenceTerms(product, preferenceTerms)
        ? matched.add(product)
        : unmatched.add(product);
  }
  return [...matched, ...unmatched];
}

/// Ranks [products] by category preference, then by [preferenceTerms]
/// (additive boost within each category bucket), then — for non-exact-match
/// sources — sinks $0.00 items toward the bottom so priced results surface first.
///
/// [isExactMatchSource] should be `true` when [products] came directly from
/// Google Lens's visual match on the photo (the literal item the camera saw),
/// and `false` when they came from the text-based product-matcher fallback.
/// Exact-match $0.00 items are left wherever category ranking placed them
/// (never demoted); non-exact-match $0.00 items are pushed toward the bottom.
List<Product> rankProducts(
  List<Product> products,
  List<String> shoppingCategories, {
  List<String> preferenceTerms = const [],
  required bool isExactMatchSource,
}) {
  List<Product> ranked = products;
  if (shoppingCategories.isNotEmpty) {
    final preferred = <Product>[];
    final rest      = <Product>[];
    for (final product in products) {
      isPreferred(product, shoppingCategories)
          ? preferred.add(product)
          : rest.add(product);
    }
    ranked = [
      ..._boostByPreferenceTerms(preferred, preferenceTerms),
      ..._boostByPreferenceTerms(rest, preferenceTerms),
    ];
  } else {
    ranked = _boostByPreferenceTerms(products, preferenceTerms);
  }

  if (isExactMatchSource) return ranked;
  return [
    ...ranked.where((p) => p.price > 0),
    ...ranked.where((p) => p.price <= 0),
  ];
}
