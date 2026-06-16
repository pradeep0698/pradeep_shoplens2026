import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/product.dart';
import 'dio_client.dart';

class SessionApi {
  final Dio _dio;
  SessionApi(this._dio);

  // POST /session/{sessionId}/products — same endpoint the web app calls after matching
  Future<void> saveProducts(String sessionId, List<Product> products) async {
    await _dio.post(
      '/session/$sessionId/products',
      data: {'products': products.map(Product.toFirestore).toList()},
    );
  }

  // GET /session/{sessionId} — hydrates session on app launch
  Future<List<Product>> loadSession(String sessionId) async {
    final response = await _dio.get('/session/$sessionId');
    final data     = response.data as Map<String, dynamic>;
    final list     = data['products'] as List<dynamic>? ?? [];
    return list
        .map((e) => Product.fromFirestore(e as Map<String, dynamic>))
        .toList();
  }

  // Clear by POSTing empty products — state manager DELETE returns 500 in production
  Future<void> clearSession(String sessionId) async {
    await _dio.post(
      '/session/$sessionId/products',
      data: {'products': []},
    );
  }
}

final sessionApiProvider =
    Provider((ref) => SessionApi(ref.read(stateDioProvider)));
