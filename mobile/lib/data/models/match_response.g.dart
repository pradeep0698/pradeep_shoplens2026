// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'match_response.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MatchResponse _$MatchResponseFromJson(Map<String, dynamic> json) =>
    MatchResponse(
      matchedProducts: (json['matched_products'] as List<dynamic>)
          .map((e) => Product.fromJson(e as Map<String, dynamic>))
          .toList(),
      unmatched:
          (json['unmatched'] as List<dynamic>).map((e) => e as String).toList(),
    );

Map<String, dynamic> _$MatchResponseToJson(MatchResponse instance) =>
    <String, dynamic>{
      'matched_products':
          instance.matchedProducts.map((e) => e.toJson()).toList(),
      'unmatched': instance.unmatched,
    };
