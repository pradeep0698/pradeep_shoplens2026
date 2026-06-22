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
  /// Returns the first matched product name, or null if nothing matched.
  Future<String?> identify({
    required Uint8List    croppedBytes,
    required String       sessionId,
    required List<String> ignoreTerms,
    required List<String> preferenceTerms,
    List<String>          shoppingCategories = const [],
    String?               query,
    String?               country,
  }) async {
    // Use /identify (not /analyze) — skips Gemini re-detection on the
    // already-cropped image, sending it directly to GCS → Google Lens.
    final analyzeResponse = await _analyzer.identifyCrop(AnalyzeRequest(
      imageData:     encodeImageToBase64(croppedBytes),
      imageMimeType: 'image/png',
      ignoreTerms:   ignoreTerms,
      transcript:    '',
      query:         query,
      country:       country,
    ));

    if (analyzeResponse.products.isEmpty) return null;

    final ranked = rankProducts(analyzeResponse.products, shoppingCategories,
            preferenceTerms: preferenceTerms, isExactMatchSource: true)
        .take(5)
        .toList();

    // Merge with whatever's already in the session instead of overwriting —
    // each tap should add to the shopping list, not replace it.
    final existing = await _session.loadSession(sessionId);
    final merged = _mergeProducts(existing, ranked);
    await _session.saveProducts(sessionId, merged);
    return ranked.first.name;
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
