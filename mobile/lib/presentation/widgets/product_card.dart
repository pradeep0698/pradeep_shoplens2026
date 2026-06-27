import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/api_constants.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/product.dart';

// Google's image CDN (where every thumbnail we're handed points) never sends
// Access-Control-Allow-Origin, so on Flutter web the browser silently blocks
// a direct cross-origin fetch of it regardless of any headers we set
// client-side. Routing through product-matcher's GET /thumbnail proxy
// (services/product-matcher/main.py) instead works because that response
// comes from our own CORS-enabled origin.
String _proxiedThumbnailUrl(String rawUrl) =>
    '${ApiConstants.matcherBaseUrl}/thumbnail?url=${Uri.encodeQueryComponent(rawUrl)}';

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    required this.shoppingCategories,
  });

  final Product      product;
  final List<String> shoppingCategories;

  @override
  Widget build(BuildContext context) {
    final preferred = isPreferred(product, shoppingCategories);
    final hasBuyLink = product.purchaseUrl != null && product.purchaseUrl!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: product.imageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl:    _proxiedThumbnailUrl(product.imageUrl),
                      placeholder: (_, __) => _placeholder(),
                      errorWidget: (_, __, ___) => _placeholder(),
                      width:       64,
                      height:      64,
                      fit:         BoxFit.cover,
                    )
                  : _placeholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      product.price > 0
                          ? Text(
                              '\$${product.price.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Color(0xFF34D399),
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : const SizedBox.shrink(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        child: Text(
                          preferred ? 'Preferred' : 'Matched',
                          style: const TextStyle(
                            color: Color(0xFFCBD5E1),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (hasBuyLink) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (product.seller != null && product.seller!.isNotEmpty)
                          Expanded(
                            child: Text(
                              product.seller!,
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        GestureDetector(
                          onTap: () async {
                            final uri = Uri.tryParse(product.purchaseUrl!);
                            if (uri != null) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF34D399).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFF34D399).withValues(alpha: 0.4),
                              ),
                            ),
                            child: const Text(
                              'Buy',
                              style: TextStyle(
                                color: Color(0xFF34D399),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
        width:  64,
        height: 64,
        color: const Color(0xFF334155),
        child: const Icon(Icons.image_outlined, color: Color(0xFF64748B), size: 24),
      );
}
