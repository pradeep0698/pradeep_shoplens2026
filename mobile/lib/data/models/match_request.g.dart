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
    );

Map<String, dynamic> _$MatchRequestToJson(MatchRequest instance) =>
    <String, dynamic>{
      'items': instance.items,
      'ignore_terms': instance.ignoreTerms,
      if (instance.maxSearches case final value?) 'max_searches': value,
    };
