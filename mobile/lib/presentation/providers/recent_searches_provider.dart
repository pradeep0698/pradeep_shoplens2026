import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/recent_searches_repository.dart';

class RecentSearchesNotifier extends AsyncNotifier<List<RecentSearchEntry>> {
  @override
  Future<List<RecentSearchEntry>> build() => recentSearchesRepository.load();

  Future<void> add(Uint8List imageBytes, String mimeType) async {
    await recentSearchesRepository.add(imageBytes, mimeType);
    state = AsyncData(await recentSearchesRepository.load());
  }

  Future<void> remove(String id) async {
    await recentSearchesRepository.remove(id);
    state = AsyncData(await recentSearchesRepository.load());
  }

  Future<void> clear() async {
    await recentSearchesRepository.clear();
    state = const AsyncData([]);
  }
}

final recentSearchesProvider =
    AsyncNotifierProvider<RecentSearchesNotifier, List<RecentSearchEntry>>(
        RecentSearchesNotifier.new);
