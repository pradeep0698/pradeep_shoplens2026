// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'match_request.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MatchRequest _$MatchRequestFromJson(Map<String, dynamic> json) => MatchRequest(
      items: (json['items'] as List<dynamic>).map((e) => e as String).toList(),
      ignoreTerms: (json['ignore_terms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      maxSearches: (json['max_searches'] as num?)?.toInt(),
      country: json['country'] as String?,
      preferenceTerms: (json['preference_terms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      shoppingCategories: (json['shopping_categories'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );

Map<String, dynamic> _$MatchRequestToJson(MatchRequest instance) =>
    <String, dynamic>{
      'items': instance.items,
      'ignore_terms': instance.ignoreTerms,
      if (instance.maxSearches case final value?) 'max_searches': value,
      if (instance.country case final value?) 'country': value,
      'preference_terms': instance.preferenceTerms,
      'shopping_categories': instance.shoppingCategories,
    };
