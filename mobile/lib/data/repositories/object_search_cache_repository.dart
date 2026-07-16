import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/product.dart';

const _kOrderKey = 'object_search_cache_order_v1';
const _kEntryPrefix = 'object_search_cache_entry_v1:';
const _kMax = 200;

/// Caches /identify results by a hash of the searched crop's pixel bytes.
/// Re-picking the same gallery image re-runs on-device detection and
/// produces byte-identical crops for the same objects (deterministic, no
/// camera jitter), so a repeat tap on an already-scanned object can be
/// served from cache instead of re-hitting the network.
class ObjectSearchCacheRepository {
  String keyFor(Uint8List cropBytes) => md5.convert(cropBytes).toString();

  Future<List<Product>?> get(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_kEntryPrefix$key');
    if (raw == null) return null;
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> put(String key, List<Product> products) async {
    final prefs = await SharedPreferences.getInstance();
    final order = prefs.getStringList(_kOrderKey) ?? [];
    order.remove(key);
    order.insert(0, key);
    while (order.length > _kMax) {
      await prefs.remove('$_kEntryPrefix${order.removeLast()}');
    }
    await prefs.setStringList(_kOrderKey, order);
    await prefs.setString(
      '$_kEntryPrefix$key',
      jsonEncode(products.map((p) => p.toJson()).toList()),
    );
  }
}

final objectSearchCacheRepository = ObjectSearchCacheRepository();
