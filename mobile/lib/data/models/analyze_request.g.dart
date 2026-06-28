// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'analyze_request.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AnalyzeRequest _$AnalyzeRequestFromJson(Map<String, dynamic> json) =>
    AnalyzeRequest(
      imageData: json['image_data'] as String?,
      imageMimeType: json['image_mime_type'] as String?,
      ignoreTerms: (json['ignore_terms'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      gcsUri: json['gcs_uri'] as String?,
      imageUrl: json['image_url'] as String?,
      maxSearches: (json['max_searches'] as num?)?.toInt(),
      mlkitContext: json['mlkit_context'] as Map<String, dynamic>?,
      transcript: json['transcript'] as String? ?? '',
      query: json['query'] as String?,
      country: json['country'] as String?,
    );

Map<String, dynamic> _$AnalyzeRequestToJson(AnalyzeRequest instance) =>
    <String, dynamic>{
      if (instance.imageData case final value?) 'image_data': value,
      if (instance.imageMimeType case final value?) 'image_mime_type': value,
      'ignore_terms': instance.ignoreTerms,
      if (instance.gcsUri case final value?) 'gcs_uri': value,
      if (instance.imageUrl case final value?) 'image_url': value,
      if (instance.maxSearches case final value?) 'max_searches': value,
      if (instance.mlkitContext case final value?) 'mlkit_context': value,
      'transcript': instance.transcript,
      if (instance.query case final value?) 'query': value,
      if (instance.country case final value?) 'country': value,
    };
