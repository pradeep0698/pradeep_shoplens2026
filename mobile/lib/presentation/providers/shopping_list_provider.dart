import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/session_id.dart';
import '../../data/models/product.dart';
import '../../data/repositories/shopping_list_repository.dart';
import 'auth_provider.dart';

// Watches existing LiveShoppingSessions/{sessionId} Firestore document
// Real-time updates arrive whenever State Manager writes to Firestore
// This fires automatically after analyzeImageUseCase.execute() completes Step 3
final shoppingListProvider = StreamProvider<List<Product>>((ref) {
  // Block subscription until the post-login session clear has finished,
  // preventing the previous session's products from flashing on screen.
  final loginInProgress = ref.watch(loginInProgressProvider);
  if (loginInProgress) return const Stream.empty();

  final user = ref.watch(authStateProvider).value;
  if (user == null) return const Stream.empty();
  final sessionId = getSessionId(user.uid); // "shoplens-user-{uid}"
  return ref.read(shoppingListRepositoryProvider).watch(sessionId);
});
