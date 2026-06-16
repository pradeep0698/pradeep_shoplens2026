import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/session_id.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/session_repository.dart';

// Watches Firebase Auth state — same user accounts as web app
final authStateProvider = StreamProvider<User?>(
  (ref) => ref.read(authRepositoryProvider).authStateChanges(),
);

// True only during the brief window between Firebase auth completing and
// session clear finishing — prevents the shopping list from subscribing to
// Firestore before the previous session is wiped.
final loginInProgressProvider = StateProvider<bool>((ref) => false);

class AuthNotifier extends AsyncNotifier<void> {
  @override Future<void> build() async {}

  Future<void> signIn(String email, String password) async {
    ref.read(loginInProgressProvider.notifier).state = true;
    try {
      state = const AsyncLoading();
      state = await AsyncValue.guard(
        () => ref.read(authRepositoryProvider).signIn(email, password),
      );
      if (state is AsyncData) {
        final user = ref.read(authRepositoryProvider).currentUser;
        if (user != null) {
          try {
            await ref.read(sessionRepositoryProvider).clear(getSessionId(user.uid));
          } catch (_) {}
        }
      }
    } finally {
      ref.read(loginInProgressProvider.notifier).state = false;
    }
  }

  Future<void> signUp(String email, String password) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(authRepositoryProvider).signUp(email, password),
    );
  }

  Future<void> signOut() => ref.read(authRepositoryProvider).signOut();
}

final authNotifierProvider =
    AsyncNotifierProvider<AuthNotifier, void>(AuthNotifier.new);
