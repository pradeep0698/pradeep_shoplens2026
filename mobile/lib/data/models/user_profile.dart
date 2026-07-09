import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_profile.freezed.dart';

// Hard ceiling on SerpAPI searches per analyze run — mirrors
// MAX_SEARCHES_PER_RUN in services/ai-analyzer. Users can dial it down
// (1-5) from their profile, never above this. Defaults to 2 (fewer,
// faster results) rather than the server's max of 5 — users who want more
// results per scan can raise it themselves.
const int maxSearchesPerRunCeiling = 5;
const int defaultMaxSearchesPerRun = 2;

int clampMaxSearchesPerRun(int? value) {
  if (value == null) return defaultMaxSearchesPerRun;
  return value.clamp(1, maxSearchesPerRunCeiling);
}

// preference_terms/ignore_terms are stored category-keyed in Firestore by the
// voice-assistant backend (services/voice-assistant/profile_store.py's
// _coerce_categorized) — a Map<String, List> there, not a flat List. Terms
// recorded without a specific category (e.g. by voice, pre category-scoping
// documents) land in this bucket, matching profile_store.py's GENERAL_BUCKET.
const String generalPreferenceBucket = '_general';

// Case-insensitive de-duplicated union, preserving the casing of whichever
// occurrence is seen first — mirrors profile_store.py's _dedup_case_insensitive
// so client-side normalization matches what the backend does on merge.
List<String> dedupeTermsCaseInsensitive(Iterable<String> terms) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in terms) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final lower = value.toLowerCase();
    if (seen.add(lower)) result.add(value);
  }
  return result;
}

// Parses a Firestore preference_terms/ignore_terms value into its
// category-keyed shape. Handles a plain List for documents that predate
// category-scoping by bucketing it under generalPreferenceBucket.
Map<String, List<String>> _categorizedTermsFromFirestore(dynamic value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(
          k.toString(),
          List<String>.from((v as List?) ?? const []),
        ));
  }
  if (value is List && value.isNotEmpty) {
    return {generalPreferenceBucket: value.map((t) => t.toString()).toList()};
  }
  return {};
}

Map<String, CategoryTerms> _mergePreferencesByCategory(
  Map<String, List<String>> include,
  Map<String, List<String>> exclude,
) {
  final categories = {...include.keys, ...exclude.keys};
  return {
    for (final category in categories)
      category: CategoryTerms(
        include: include[category] ?? const [],
        exclude: exclude[category] ?? const [],
      ),
  };
}

Map<String, CategoryTerms> _saveablePreferenceBuckets(UserProfile p) {
  final selectedCategories = p.shoppingCategories.toSet();
  final result = <String, CategoryTerms>{};

  p.preferencesByCategory.forEach((category, terms) {
    if (selectedCategories.isNotEmpty) {
      if (category == generalPreferenceBucket) return;
      if (!selectedCategories.contains(category)) return;
    }

    final include = dedupeTermsCaseInsensitive(terms.include);
    final exclude = dedupeTermsCaseInsensitive(terms.exclude);
    if (include.isEmpty && exclude.isEmpty) return;

    result[category] = CategoryTerms(include: include, exclude: exclude);
  });

  return result;
}

@freezed
class CategoryTerms with _$CategoryTerms {
  const factory CategoryTerms({
    @Default([]) List<String> include,
    @Default([]) List<String> exclude,
  }) = _CategoryTerms;
}

@freezed
class UserProfile with _$UserProfile {
  const factory UserProfile({
    @Default('') String username,
    @Default('') String dob,
    @Default('') String profilePhotoUrl,
    @Default('') String gender,
    @Default('') String country,
    @Default([]) List<String> shoppingCategories,
    @Default({}) Map<String, CategoryTerms> preferencesByCategory,
    @Default(defaultMaxSearchesPerRun) int maxSearchesPerRun,
    @Default(false) bool voiceOnboardingSeen,
    @Default('English') String voiceLanguage,
  }) = _UserProfile;

  const UserProfile._();

  // Flattened across every category bucket — the shape the analyze/match
  // pipeline and voice-assistant wire contract expect (see
  // profile_store.py's _flatten_categorized). Category association only
  // matters to the profile settings screen, which reads preferencesByCategory
  // directly instead.
  List<String> get preferenceTerms => dedupeTermsCaseInsensitive(
      preferencesByCategory.values.expand((c) => c.include));
  List<String> get ignoreTerms => dedupeTermsCaseInsensitive(
      preferencesByCategory.values.expand((c) => c.exclude));

  // Field names must match existing Firestore UserProfiles documents exactly
  factory UserProfile.fromFirestore(Map<String, dynamic> data) => UserProfile(
        username:            data['username']           as String? ?? '',
        dob:                 data['dob']                as String? ?? '',
        profilePhotoUrl:     data['profile_photo_url']  as String? ?? '',
        gender:              data['gender']             as String? ?? '',
        country:             data['country']            as String? ?? '',
        shoppingCategories:  List<String>.from(data['shopping_categories'] ?? []),
        preferencesByCategory: _mergePreferencesByCategory(
          _categorizedTermsFromFirestore(data['preference_terms']),
          _categorizedTermsFromFirestore(data['ignore_terms']),
        ),
        maxSearchesPerRun:   clampMaxSearchesPerRun(data['max_searches_per_run'] as int?),
        voiceOnboardingSeen: data['voice_onboarding_seen'] as bool? ?? false,
        voiceLanguage:       data['voice_language'] as String? ?? 'English',
      );

  // Writes preference_terms/ignore_terms back out as the same category-keyed
  // maps the backend expects (empty buckets dropped, matching
  // profile_store.py's merge_categorized) instead of clobbering them with a
  // flat list.
  static Map<String, dynamic> toFirestore(UserProfile p) {
    final preferenceTerms = <String, List<String>>{};
    final ignoreTerms = <String, List<String>>{};
    _saveablePreferenceBuckets(p).forEach((category, terms) {
      if (terms.include.isNotEmpty) preferenceTerms[category] = terms.include;
      if (terms.exclude.isNotEmpty) ignoreTerms[category] = terms.exclude;
    });
    return {
      'username':              p.username,
      'dob':                   p.dob,
      'profile_photo_url':     p.profilePhotoUrl,
      'gender':                p.gender,
      'country':               p.country,
      'shopping_categories':   p.shoppingCategories,
      'preference_terms':      preferenceTerms,
      'ignore_terms':          ignoreTerms,
      'max_searches_per_run':  p.maxSearchesPerRun,
      'voice_onboarding_seen': p.voiceOnboardingSeen,
      'voice_language':        p.voiceLanguage,
    };
  }
}
