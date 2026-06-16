import 'product.dart';

class AnalyzeResponse {
  final List<String> items;
  final List<Product> products;
  final List<String> warnings;
  final String? gcsUri;
  final String? imageUrl;

  const AnalyzeResponse({
    required this.items,
    required this.products,
    this.warnings = const [],
    this.gcsUri,
    this.imageUrl,
  });

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) => AnalyzeResponse(
        items: (json['items'] as List? ?? []).cast<String>(),
        products: (json['products'] as List? ?? [])
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList(),
        warnings: (json['warnings'] as List? ?? []).cast<String>(),
        gcsUri: json['gcs_uri'] as String?,
        imageUrl: json['image_url'] as String?,
      );
}
