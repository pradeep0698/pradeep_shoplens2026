import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/analyze_request.dart';
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

    final ranked = rankProducts(analyzeResponse.products, preferenceTerms,
            isExactMatchSource: true)
        .take(5)
        .toList();
    await _session.clearSession(sessionId);
    await _session.saveProducts(sessionId, ranked);
    return ranked.first.name;
  }
}

final tapIdentifyUseCaseProvider = Provider((ref) => TapIdentifyUseCase(
      ref.read(analyzerApiProvider),
      ref.read(sessionApiProvider),
    ));
