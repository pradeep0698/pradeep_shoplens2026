import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/product.dart';
import '../sources/firebase/firestore_source.dart';

class ShoppingListRepository {
  final FirestoreSource _firestore;
  ShoppingListRepository(this._firestore);

  // sessionId must be built with getSessionId(uid)
  Stream<List<Product>> watch(String sessionId) =>
      _firestore.watchShoppingList(sessionId);

  Future<void> clear(String sessionId) =>
      _firestore.clearShoppingList(sessionId);
}

final shoppingListRepositoryProvider =
    Provider((ref) => ShoppingListRepository(ref.read(firestoreSourceProvider)));
