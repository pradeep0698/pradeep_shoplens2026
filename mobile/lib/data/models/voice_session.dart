import 'product.dart';

/// A snapshot of the three preference lists, shared by the existing profile
/// (returned at session start) and by patches proposed/finalized mid-conversation.
class VoiceProfilePatch {
  const VoiceProfilePatch({
    this.shoppingCategories = const [],
    this.preferenceTerms = const [],
    this.ignoreTerms = const [],
    this.summary = '',
  });

  final List<String> shoppingCategories;
  final List<String> preferenceTerms;
  final List<String> ignoreTerms;
  final String summary;

  factory VoiceProfilePatch.fromJson(Map<String, dynamic> json) => VoiceProfilePatch(
        shoppingCategories: (json['shopping_categories'] as List? ?? []).cast<String>(),
        preferenceTerms:    (json['preference_terms']    as List? ?? []).cast<String>(),
        ignoreTerms:        (json['ignore_terms']         as List? ?? []).cast<String>(),
        summary:            json['summary'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'shopping_categories': shoppingCategories,
        'preference_terms':    preferenceTerms,
        'ignore_terms':        ignoreTerms,
        'summary':             summary,
      };

  bool get isEmpty =>
      shoppingCategories.isEmpty && preferenceTerms.isEmpty && ignoreTerms.isEmpty;

  VoiceProfilePatch copyWith({
    List<String>? shoppingCategories,
    List<String>? preferenceTerms,
    List<String>? ignoreTerms,
    String? summary,
  }) => VoiceProfilePatch(
        shoppingCategories: shoppingCategories ?? this.shoppingCategories,
        preferenceTerms:    preferenceTerms    ?? this.preferenceTerms,
        ignoreTerms:        ignoreTerms        ?? this.ignoreTerms,
        summary:            summary            ?? this.summary,
      );
}

class VoiceSessionStartResponse {
  const VoiceSessionStartResponse({
    required this.sessionId,
    required this.wsUrl,
    required this.profile,
  });

  final String sessionId;
  final String wsUrl;
  final VoiceProfilePatch profile;

  factory VoiceSessionStartResponse.fromJson(Map<String, dynamic> json) => VoiceSessionStartResponse(
        sessionId: json['session_id'] as String,
        wsUrl:     json['ws_url'] as String,
        profile:   VoiceProfilePatch.fromJson(json['profile'] as Map<String, dynamic>? ?? const {}),
      );
}

class VoiceFinalizeResult {
  const VoiceFinalizeResult({
    required this.shoppingCategories,
    required this.preferenceTerms,
    required this.ignoreTerms,
    required this.conflicts,
  });

  final List<String> shoppingCategories;
  final List<String> preferenceTerms;
  final List<String> ignoreTerms;
  final List<String> conflicts;

  factory VoiceFinalizeResult.fromJson(Map<String, dynamic> json) => VoiceFinalizeResult(
        shoppingCategories: (json['shopping_categories'] as List? ?? []).cast<String>(),
        preferenceTerms:    (json['preference_terms']    as List? ?? []).cast<String>(),
        ignoreTerms:        (json['ignore_terms']         as List? ?? []).cast<String>(),
        conflicts:          (json['conflicts']            as List? ?? []).cast<String>(),
      );
}

class VoiceTranscriptTurn {
  // seq orders this turn relative to VoiceSearchResult entries in the same
  // conversation — see VoiceAssistantNotifier._nextSeq() — so search-mode's
  // product results can be interleaved into the transcript in arrival order
  // instead of dumped in a separate block underneath it.
  const VoiceTranscriptTurn({required this.role, required this.text, this.seq = 0});
  final String role; // 'user' | 'model'
  final String text;
  final int seq;
}

/// One `search_products` tool call's results — search-mode sessions append
/// one of these per query, so refining a search keeps the earlier results
/// visible above the newer ones (mirrors how transcript turns accumulate).
class VoiceSearchResult {
  const VoiceSearchResult({required this.query, required this.products, this.seq = 0});

  final String query;
  final List<Product> products;
  final int seq;

  factory VoiceSearchResult.fromJson(Map<String, dynamic> json, {required int seq}) => VoiceSearchResult(
        query: json['query'] as String? ?? '',
        products: ((json['products'] as List?) ?? const [])
            .map((p) => Product.fromJson(p as Map<String, dynamic>))
            .toList(),
        seq: seq,
      );
}
