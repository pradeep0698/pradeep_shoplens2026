import 'package:json_annotation/json_annotation.dart';

part 'match_request.g.dart';

@JsonSerializable(includeIfNull: false)
class MatchRequest {
  final List<String> items;
  @JsonKey(name: 'ignore_terms')        final List<String> ignoreTerms;
  @JsonKey(name: 'max_searches')        final int?         maxSearches;
  final String?                                            country;
  @JsonKey(name: 'preference_terms')    final List<String> preferenceTerms;
  @JsonKey(name: 'shopping_categories') final List<String> shoppingCategories;

  const MatchRequest({
    required this.items,
    this.ignoreTerms = const [],
    this.maxSearches,
    this.country,
    this.preferenceTerms = const [],
    this.shoppingCategories = const [],
  });

  Map<String, dynamic> toJson() => _$MatchRequestToJson(this);
}
