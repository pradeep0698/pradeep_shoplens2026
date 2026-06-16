import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user_profile.dart';
import '../sources/firebase/firestore_source.dart';

class ProfileRepository {
  final FirestoreSource _firestore;
  ProfileRepository(this._firestore);

  Stream<UserProfile> watch(String uid)                    => _firestore.watchProfile(uid);
  Future<void>        save(String uid, UserProfile profile) => _firestore.saveProfile(uid, profile);
}

final profileRepositoryProvider =
    Provider((ref) => ProfileRepository(ref.read(firestoreSourceProvider)));
