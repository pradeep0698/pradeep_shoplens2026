import 'package:json_annotation/json_annotation.dart';
import 'product.dart';

part 'match_response.g.dart';

@JsonSerializable(explicitToJson: true)
class MatchResponse {
  @JsonKey(name: 'matched_products') final List<Product> matchedProducts;
  final List<String> unmatched;

  const MatchResponse({required this.matchedProducts, required this.unmatched});

  factory MatchResponse.fromJson(Map<String, dynamic> json) =>
      _$MatchResponseFromJson(json);
}
