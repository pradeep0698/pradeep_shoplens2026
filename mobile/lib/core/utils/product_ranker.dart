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

/// Ranks [products] by category preference, then — for non-exact-match sources —
/// sinks $0.00 items toward the bottom so priced results surface first.
///
/// [isExactMatchSource] should be `true` when [products] came directly from
/// Google Lens's visual match on the photo (the literal item the camera saw),
/// and `false` when they came from the text-based product-matcher fallback.
/// Exact-match $0.00 items are left wherever category ranking placed them
/// (never demoted); non-exact-match $0.00 items are pushed toward the bottom.
List<Product> rankProducts(
  List<Product> products,
  List<String> shoppingCategories, {
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
    ranked = [...preferred, ...rest];
  }

  if (isExactMatchSource) return ranked;
  return [
    ...ranked.where((p) => p.price > 0),
    ...ranked.where((p) => p.price <= 0),
  ];
}
