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
    required this.directConnectAllowed,
  });

  final String sessionId;
  final String wsUrl;
  final VoiceProfilePatch profile;
  // Server-side kill switch for the native-only direct client->Gemini Live
  // transport — when false, the transport selector always falls back to the
  // WS proxy regardless of platform/build flags (see voice_transport_selector.dart).
  final bool directConnectAllowed;

  factory VoiceSessionStartResponse.fromJson(Map<String, dynamic> json) => VoiceSessionStartResponse(
        sessionId: json['session_id'] as String,
        wsUrl:     json['ws_url'] as String,
        profile:   VoiceProfilePatch.fromJson(json['profile'] as Map<String, dynamic>? ?? const {}),
        directConnectAllowed: json['direct_connect_allowed'] as bool? ?? false,
      );
}

/// Response from POST /voice/session/token — an ephemeral Gemini Live auth
/// token scoped/locked to this session's exact model+config, plus the
/// backend-built wire-format `setup` JSON the direct-connect transport must
/// send verbatim as its first frame (see gemini_live_socket_client.dart).
class VoiceSessionTokenResponse {
  const VoiceSessionTokenResponse({required this.token, required this.model, required this.setup});

  final String token;
  final String model;
  final Map<String, dynamic> setup;

  factory VoiceSessionTokenResponse.fromJson(Map<String, dynamic> json) => VoiceSessionTokenResponse(
        token: json['token'] as String,
        model: json['model'] as String,
        setup: json['setup'] as Map<String, dynamic>? ?? const {},
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
  // seq orders transcript turns chronologically within the transcript chat
  // feed — see VoiceAssistantNotifier._nextSeq(). No longer shared with
  // VoiceSearchResult: search results are pinned/collapsed in their own
  // section (newest first), not interleaved into this chronological feed.
  const VoiceTranscriptTurn({required this.role, required this.text, this.seq = 0});
  final String role; // 'user' | 'model'
  final String text;
  final int seq;
}

/// One `search_products` tool call's results. Search-mode sessions insert
/// one of these at the FRONT of the list per query (see
/// VoiceAssistantNotifier._handleControlFrame), so the newest search is
/// always first — the overlay pins it prominently and collapses older
/// entries into an accordion.
class VoiceSearchResult {
  const VoiceSearchResult({
    required this.query,
    required this.products,
    required this.id,
    this.isPending = false,
  });

  final String query;
  final List<Product> products;
  // Stable key for accordion expand/collapse widget state — no longer a
  // shared ordering key with transcript turns; list position alone
  // (newest-first insertion) determines display order now.
  final int id;
  // True from the moment the search_started frame arrives until the
  // matching product_results frame (same query) replaces it.
  final bool isPending;

  factory VoiceSearchResult.fromJson(Map<String, dynamic> json, {required int id}) => VoiceSearchResult(
        query: json['query'] as String? ?? '',
        products: ((json['products'] as List?) ?? const [])
            .map((p) {
              final map = Map<String, dynamic>.from(p as Map<String, dynamic>);
              map['price'] = (map['price'] as num?)?.toDouble() ?? 0.0;
              map['image_url'] = (map['image_url'] as String?) ?? '';
              return Product.fromJson(map);
            })
            .toList(),
        id: id,
        isPending: false,
      );
}
