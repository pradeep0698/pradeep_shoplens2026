import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kKey = 'recent_searches_v2';
const _kMax = 10;

class RecentSearchEntry {
  final String id;
  final Uint8List imageBytes;
  final String mimeType;
  final DateTime searchedAt;

  RecentSearchEntry({
    required this.id,
    required this.imageBytes,
    required this.mimeType,
    required this.searchedAt,
  });

  Map<String, dynamic> toJson() => {
        'id':          id,
        'imageBase64': base64Encode(imageBytes),
        'mimeType':    mimeType,
        'searchedAt':  searchedAt.millisecondsSinceEpoch,
      };

  factory RecentSearchEntry.fromJson(Map<String, dynamic> json) =>
      RecentSearchEntry(
        id:         json['id'] as String,
        imageBytes: base64Decode(json['imageBase64'] as String),
        mimeType:   json['mimeType'] as String,
        searchedAt: DateTime.fromMillisecondsSinceEpoch(json['searchedAt'] as int),
      );
}

class RecentSearchesRepository {
  String _hashImage(Uint8List bytes) => md5.convert(bytes).toString();

  Future<List<RecentSearchEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kKey) ?? [];
    return raw.map((e) => RecentSearchEntry.fromJson(jsonDecode(e))).toList();
  }

  Future<void> add(Uint8List imageBytes, String mimeType) async {
    final prefs = await SharedPreferences.getInstance();
    var list = prefs.getStringList(_kKey) ?? [];
    final id = _hashImage(imageBytes);
    // Remove existing entry with same image hash (deduplication)
    list.removeWhere((e) {
      final decoded = jsonDecode(e) as Map<String, dynamic>;
      return decoded['id'] == id;
    });
    final entry = RecentSearchEntry(
      id:         id,
      imageBytes: imageBytes,
      mimeType:   mimeType,
      searchedAt: DateTime.now(),
    );
    list.insert(0, jsonEncode(entry.toJson()));
    if (list.length > _kMax) list = list.sublist(0, _kMax);
    await prefs.setStringList(_kKey, list);
  }

  Future<void> remove(String id) async {
    final prefs = await SharedPreferences.getInstance();
    var list = prefs.getStringList(_kKey) ?? [];
    list.removeWhere((e) {
      final decoded = jsonDecode(e) as Map<String, dynamic>;
      return decoded['id'] == id;
    });
    await prefs.setStringList(_kKey, list);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }
}

final recentSearchesRepository = RecentSearchesRepository();
