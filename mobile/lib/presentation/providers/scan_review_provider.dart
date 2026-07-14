import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/session_id.dart';
import '../../data/models/analyze_request.dart';
import '../../data/models/product.dart';
import '../../data/models/user_profile.dart';
import '../../data/sources/remote/analyzer_api.dart';
import '../../domain/usecases/tap_identify_usecase.dart';
import 'auth_provider.dart';
import 'profile_provider.dart';

enum ItemSearchStatus { idle, searching, done, error }

class DetectedItem {
  final String name;
  final List<int>? box; // [y_min, x_min, y_max, x_max] on a 0-1000 scale
  final Uint8List? cropBytes;
  final ItemSearchStatus status;
  final List<Product> products;
  final String? errorMessage;

  const DetectedItem({
    required this.name,
    this.box,
    this.cropBytes,
    this.status = ItemSearchStatus.idle,
    this.products = const [],
    this.errorMessage,
  });

  DetectedItem copyWith({
    Uint8List? cropBytes,
    ItemSearchStatus? status,
    List<Product>? products,
    String? errorMessage,
  }) => DetectedItem(
        name: name,
        box: box,
        cropBytes: cropBytes ?? this.cropBytes,
        status: status ?? this.status,
        products: products ?? this.products,
        errorMessage: errorMessage,
      );
}

enum ScanReviewPhase { detecting, ready, error }

class ScanReviewState {
  final ScanReviewPhase phase;
  final String? errorMessage;
  final List<DetectedItem> items;
  final Set<int> selected;

  const ScanReviewState({
    this.phase = ScanReviewPhase.detecting,
    this.errorMessage,
    this.items = const [],
    this.selected = const {},
  });

  bool get isSearching => items.any((i) => i.status == ItemSearchStatus.searching);

  ScanReviewState copyWith({
    ScanReviewPhase? phase,
    String? errorMessage,
    List<DetectedItem>? items,
    Set<int>? selected,
  }) => ScanReviewState(
        phase: phase ?? this.phase,
        errorMessage: errorMessage,
        items: items ?? this.items,
        selected: selected ?? this.selected,
      );
}

/// Drives the "Scan All" review step: detect every object in the frame via
/// Gemini (no search yet), let the user pick which ones matter, then run the
/// same /identify call the single-tap live-camera flow uses — once per
/// selected object, all in parallel — and surface each item's own results
/// independently as they resolve.
class ScanReviewNotifier extends AutoDisposeNotifier<ScanReviewState> {
  @override
  ScanReviewState build() => const ScanReviewState();

  Future<void> detect(Uint8List imageBytes, String mime, {Map<String, dynamic>? mlkitContext}) async {
    final profile = ref.read(profileProvider).valueOrNull ?? const UserProfile();
    state = const ScanReviewState(phase: ScanReviewPhase.detecting);

    try {
      final response = await ref.read(analyzerApiProvider).detectItems(AnalyzeRequest(
            imageData:          encodeImageToBase64(imageBytes),
            imageMimeType:      mime,
            ignoreTerms:        profile.ignoreTerms,
            preferenceTerms:    profile.preferenceTerms,
            shoppingCategories: profile.shoppingCategories,
            country:            profile.country.isEmpty ? null : profile.country,
            mlkitContext:       mlkitContext,
          ));

      // Crop every detected box client-side, in parallel, before showing the
      // review list — mirrors the tap flow's client-side crop, just applied
      // to Gemini's boxes instead of ML Kit's.
      final crops = await Future.wait(response.items.map(
        (item) => item.box != null
            ? cropToGeminiBox(imageBytes, item.box!)
            : Future<Uint8List?>.value(null),
      ));

      final items = [
        for (var i = 0; i < response.items.length; i++)
          DetectedItem(
            name: response.items[i].name,
            box: response.items[i].box,
            cropBytes: crops[i] ?? imageBytes,
          ),
      ];

      state = ScanReviewState(phase: ScanReviewPhase.ready, items: items);
    } catch (e) {
      state = ScanReviewState(phase: ScanReviewPhase.error, errorMessage: e.toString());
    }
  }

  void toggleSelect(int index) {
    final selected = {...state.selected};
    if (!selected.add(index)) selected.remove(index);
    state = state.copyWith(selected: selected);
  }

  void _setItem(int index, DetectedItem Function(DetectedItem) update) {
    final items = [...state.items];
    items[index] = update(items[index]);
    state = state.copyWith(items: items);
  }

  /// Runs one /identify call per selected item, all in parallel, and updates
  /// each item's own status/products as its call resolves independently.
  Future<void> searchSelected() async {
    final user = ref.read(authStateProvider).value;
    if (user == null) return;
    final profile = ref.read(profileProvider).valueOrNull ?? const UserProfile();
    final sessionId = getSessionId(user.uid);

    final indices = state.selected
        .where((i) => state.items[i].cropBytes != null &&
                      state.items[i].status != ItemSearchStatus.searching)
        .toList();
    if (indices.isEmpty) return;

    for (final i in indices) {
      _setItem(i, (it) => it.copyWith(status: ItemSearchStatus.searching, errorMessage: null));
    }

    await Future.wait(indices.map((i) => _searchOne(i, sessionId, profile)));
  }

  Future<void> _searchOne(int index, String sessionId, UserProfile profile) async {
    final item = state.items[index];
    try {
      final products = await ref.read(tapIdentifyUseCaseProvider).identify(
            croppedBytes:       item.cropBytes!,
            sessionId:          sessionId,
            ignoreTerms:        profile.ignoreTerms,
            preferenceTerms:    profile.preferenceTerms,
            shoppingCategories: profile.shoppingCategories,
            country:            profile.country.isEmpty ? null : profile.country,
            maxSearches:        profile.maxSearchesPerRun,
            query:              item.name,
          );
      _setItem(index, (it) => it.copyWith(status: ItemSearchStatus.done, products: products));
    } catch (e) {
      _setItem(index, (it) => it.copyWith(status: ItemSearchStatus.error, errorMessage: e.toString()));
    }
  }
}

final scanReviewProvider =
    AutoDisposeNotifierProvider<ScanReviewNotifier, ScanReviewState>(ScanReviewNotifier.new);
