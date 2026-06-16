import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/user_profile.dart';
import '../../data/repositories/profile_repository.dart';
import 'auth_provider.dart';

// Watches existing UserProfiles/{uid} Firestore document
// Auto-updates when web app or Flutter saves the profile
final profileProvider = StreamProvider<UserProfile>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return const Stream.empty();
  return ref.read(profileRepositoryProvider).watch(user.uid);
});
