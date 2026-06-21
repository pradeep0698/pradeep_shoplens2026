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

@freezed
class UserProfile with _$UserProfile {
  const factory UserProfile({
    @Default('') String username,
    @Default('') String dob,
    @Default('') String profilePhotoUrl,
    @Default('') String gender,
    @Default('') String country,
    @Default([]) List<String> shoppingCategories,
    @Default([]) List<String> preferenceTerms,
    @Default([]) List<String> ignoreTerms,
    @Default(defaultMaxSearchesPerRun) int maxSearchesPerRun,
  }) = _UserProfile;

  // Field names must match existing Firestore UserProfiles documents exactly
  factory UserProfile.fromFirestore(Map<String, dynamic> data) => UserProfile(
        username:           data['username']           as String? ?? '',
        dob:                data['dob']                as String? ?? '',
        profilePhotoUrl:    data['profile_photo_url']  as String? ?? '',
        gender:             data['gender']             as String? ?? '',
        country:            data['country']            as String? ?? '',
        shoppingCategories: List<String>.from(data['shopping_categories'] ?? []),
        preferenceTerms:    List<String>.from(data['preference_terms']    ?? []),
        ignoreTerms:        List<String>.from(data['ignore_terms']        ?? []),
        maxSearchesPerRun:  clampMaxSearchesPerRun(data['max_searches_per_run'] as int?),
      );

  static Map<String, dynamic> toFirestore(UserProfile p) => {
        'username':            p.username,
        'dob':                 p.dob,
        'profile_photo_url':   p.profilePhotoUrl,
        'gender':              p.gender,
        'country':             p.country,
        'shopping_categories': p.shoppingCategories,
        'preference_terms':    p.preferenceTerms,
        'ignore_terms':        p.ignoreTerms,
        'max_searches_per_run': p.maxSearchesPerRun,
      };
}
