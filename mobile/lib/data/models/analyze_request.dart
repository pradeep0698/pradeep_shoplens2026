import 'package:json_annotation/json_annotation.dart';

part 'analyze_request.g.dart';

// Must match the exact JSON body the AI Analyzer Cloud Run service expects
@JsonSerializable(includeIfNull: false)
class AnalyzeRequest {
  @JsonKey(name: 'image_data')      final String?              imageData;
  @JsonKey(name: 'image_mime_type') final String?              imageMimeType;
  @JsonKey(name: 'ignore_terms')    final List<String>         ignoreTerms;
  @JsonKey(name: 'gcs_uri')         final String?              gcsUri;
  @JsonKey(name: 'image_url')       final String?              imageUrl;
  @JsonKey(name: 'max_searches')    final int?                 maxSearches;
  @JsonKey(name: 'mlkit_context')   final Map<String, dynamic>? mlkitContext;
  final String transcript;
  final String? query;
  final String? country;

  const AnalyzeRequest({
    this.imageData,
    this.imageMimeType,
    this.ignoreTerms = const [],
    this.gcsUri,
    this.imageUrl,
    this.maxSearches,
    this.mlkitContext,
    this.transcript = '',
    this.query,
    this.country,
  });

  Map<String, dynamic> toJson() => _$AnalyzeRequestToJson(this);
}
