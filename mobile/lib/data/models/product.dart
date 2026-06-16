import 'package:freezed_annotation/freezed_annotation.dart';

part 'product.freezed.dart';
part 'product.g.dart';

@freezed
class Product with _$Product {
  const factory Product({
    @JsonKey(name: 'product_id') required String productId,
    required String name,
    required double price,
    @JsonKey(name: 'image_url') required String imageUrl,
    @JsonKey(name: 'purchase_url') String? purchaseUrl,
    String? seller,
    String? category,
  }) = _Product;

  factory Product.fromJson(Map<String, dynamic> json) => _$ProductFromJson(json);

  factory Product.fromFirestore(Map<String, dynamic> data) => Product(
        productId:   data['product_id']   as String? ?? '',
        name:        data['name']         as String? ?? '',
        price:       (data['price']       as num?)?.toDouble() ?? 0.0,
        imageUrl:    data['image_url']    as String? ?? '',
        purchaseUrl: data['purchase_url'] as String?,
        seller:      data['seller']       as String?,
        category:    data['category']     as String?,
      );

  static Map<String, dynamic> toFirestore(Product p) => {
        'product_id': p.productId,
        'name':       p.name,
        'price':      p.price,
        'image_url':  p.imageUrl,
        if (p.purchaseUrl != null) 'purchase_url': p.purchaseUrl,
        if (p.seller      != null) 'seller':       p.seller,
        if (p.category    != null) 'category':     p.category,
      };
}
