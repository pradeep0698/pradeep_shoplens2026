import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/sources/firebase/firestore_source.dart';
import 'auth_provider.dart';

final isAdminProvider = FutureProvider<bool>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.value;
  if (user == null) return false;
  return ref.read(firestoreSourceProvider).isUserAdmin(user.uid);
});

final allVideoAnnotationsProvider = StreamProvider<List<AdminVideoDoc>>((ref) =>
    ref.read(firestoreSourceProvider).watchAllVideoAnnotations());
