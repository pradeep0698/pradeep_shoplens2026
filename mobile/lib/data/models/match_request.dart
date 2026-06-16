import 'package:json_annotation/json_annotation.dart';

part 'match_request.g.dart';

@JsonSerializable()
class MatchRequest {
  final List<String> items;
  @JsonKey(name: 'ignore_terms') final List<String> ignoreTerms;

  const MatchRequest({required this.items, this.ignoreTerms = const []});

  Map<String, dynamic> toJson() => _$MatchRequestToJson(this);
}
