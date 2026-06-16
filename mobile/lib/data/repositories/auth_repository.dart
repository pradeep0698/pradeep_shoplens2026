import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../sources/firebase/auth_source.dart';

class AuthRepository {
  final AuthSource _source;
  AuthRepository(this._source);

  Stream<User?> authStateChanges() => _source.authStateChanges();
  Future<void>  signIn(String email, String password) => _source.signIn(email, password);
  Future<void>  signUp(String email, String password) => _source.signUp(email, password);
  Future<void>  signOut()                             => _source.signOut();
  User?         get currentUser                       => _source.currentUser;
}

final authRepositoryProvider =
    Provider((ref) => AuthRepository(ref.read(authSourceProvider)));
