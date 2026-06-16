import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/product.dart';
import '../sources/remote/session_api.dart';

class SessionRepository {
  final SessionApi _api;
  SessionRepository(this._api);

  Future<void>          save(String sid, List<Product> p) => _api.saveProducts(sid, p);
  Future<List<Product>> load(String sid)                  => _api.loadSession(sid);
  Future<void>          clear(String sid)                 => _api.clearSession(sid);
}

final sessionRepositoryProvider =
    Provider((ref) => SessionRepository(ref.read(sessionApiProvider)));
