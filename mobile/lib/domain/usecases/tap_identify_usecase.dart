import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/analyze_request.dart';
import '../../data/models/product.dart';
import '../../data/sources/remote/analyzer_api.dart';
import '../../data/sources/remote/session_api.dart';

class TapIdentifyUseCase {
  final AnalyzerApi _analyzer;
  final SessionApi  _session;

  TapIdentifyUseCase(this._analyzer, this._session);

  /// Sends [croppedBytes] to the analyzer, gets visual product matches,
  /// then appends them to the existing session (load → merge → save).
  /// Returns the ranked products matched for this call specifically (not the
  /// full merged session), or an empty list if nothing matched.
  Future<List<Product>> identify({
    required Uint8List         croppedBytes,
    required String            sessionId,
    required List<String>      ignoreTerms,
    required List<String>      preferenceTerms,
    List<String>               shoppingCategories = const [],
    String?                    query,
    String?                    country,
    int?                       maxSearches,
    Map<String, dynamic>?      mlkitContext,
  }) async {
    // Use /identify (not /analyze) — skips Gemini bounding-box detection since
    // ML Kit already localized the object. /identify still calls Gemini once to
    // describe the crop (for a better Lens query), but skips the full-image
    // detection pass, making it faster than the full /analyze pipeline.
    final analyzeResponse = await _analyzer.identifyCrop(AnalyzeRequest(
      imageData:          encodeImageToBase64(croppedBytes),
      imageMimeType:      'image/jpeg',
      ignoreTerms:        ignoreTerms,
      transcript:         '',
      query:              query,
      country:            country,
      maxSearches:        maxSearches,
      preferenceTerms:    preferenceTerms,
      shoppingCategories: shoppingCategories,
      mlkitContext:       mlkitContext,
    ));

    if (analyzeResponse.products.isEmpty) return const [];

    // No client-side cap here — the server already limits result count via
    // MAX_RESULTS_PER_ITEM (a single tap is always a single-object search, so
    // it gets the deployment default rather than the multi-object dial).
    final ranked = rankProducts(analyzeResponse.products, shoppingCategories,
            preferenceTerms: preferenceTerms, isExactMatchSource: true)
        .toList();

    // Merge with whatever's already in the session instead of overwriting —
    // each tap should add to the shopping list, not replace it.
    final existing = await _session.loadSession(sessionId);
    final merged = _mergeProducts(existing, ranked);
    await _session.saveProducts(sessionId, merged);
    return ranked;
  }

  /// Combines [existing] with [newProducts], deduping by productId. New
  /// matches win on conflict (fresher data for the same product).
  List<Product> _mergeProducts(List<Product> existing, List<Product> newProducts) {
    final byId = {for (final p in existing) p.productId: p};
    for (final p in newProducts) {
      byId[p.productId] = p;
    }
    return byId.values.toList();
  }
}

final tapIdentifyUseCaseProvider = Provider((ref) => TapIdentifyUseCase(
      ref.read(analyzerApiProvider),
      ref.read(sessionApiProvider),
    ));
