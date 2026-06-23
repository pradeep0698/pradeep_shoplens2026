import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/analyze_request.dart';
import '../../data/models/analyzer_error.dart';
import '../../data/models/match_request.dart';
import '../../data/models/product.dart';
import '../../data/sources/remote/analyzer_api.dart';
import '../../data/sources/remote/matcher_api.dart';
import '../../data/sources/remote/session_api.dart';

enum PipelineStep { analyzing, matching, saving, done }

/// A pipeline progress update. [warnings] carries soft-failure codes from the
/// backend (e.g. `LENS_DISABLED`, `GEMINI_BLOCKED`) and is only populated on
/// the terminal [PipelineStep.done] event.
class PipelineEvent {
  const PipelineEvent(this.step, {this.warnings = const []});

  final PipelineStep step;
  final List<String> warnings;
}

class AnalyzeImageUseCase {
  final AnalyzerApi _analyzer;
  final MatcherApi  _matcher;
  final SessionApi  _session;

  AnalyzeImageUseCase(this._analyzer, this._matcher, this._session);

  Stream<PipelineEvent> execute({
    required Uint8List    imageBytes,
    required String       mimeType,
    required String       sessionId,
    required List<String> ignoreTerms,
    required List<String> preferenceTerms,
    List<String>          shoppingCategories = const [],
    String?               country,
    int?                  maxSearches,
  }) async* {
    yield const PipelineEvent(PipelineStep.analyzing);

    // Uses /analyze/stream instead of /analyze: results are saved to the
    // session as each item's Lens search completes (not all at once after
    // the slowest item finishes), so shoppingListProvider's Firestore
    // listener shows products appearing one by one instead of a single
    // jump at the end.
    final allProducts = <Product>[];
    final warnings = <String>[];
    var detectedItems = const <String>[];
    var anyMatched = false;

    await for (final event in _analyzer.analyzeStream(AnalyzeRequest(
      imageData:     encodeImageToBase64(imageBytes),
      imageMimeType: mimeType,
      ignoreTerms:   ignoreTerms,
      transcript:    '',
      country:       country,
      maxSearches:   maxSearches,
    ))) {
      switch (event['type']) {
        case 'items':
          detectedItems = ((event['items'] as List?) ?? const []).cast<String>();
          break;
        case 'match':
          warnings.addAll(((event['warnings'] as List?) ?? const []).cast<String>());
          final productsJson = (event['products'] as List?) ?? const [];
          if (productsJson.isNotEmpty) {
            anyMatched = true;
            final ranked = rankProducts(
              productsJson.map((p) => Product.fromJson(p as Map<String, dynamic>)).toList(),
              preferenceTerms,
              isExactMatchSource: true,
            );
            allProducts.addAll(ranked);
            await _session.saveProducts(sessionId, allProducts);
            yield PipelineEvent(PipelineStep.saving, warnings: warnings);
          }
          break;
        case 'done':
          warnings.addAll(((event['warnings'] as List?) ?? const []).cast<String>());
          break;
        case 'error':
          throw AnalyzerException(
            code: AnalyzerErrorCode.fromWire(event['error_code'] as String?),
            message: (event['detail'] as String?) ?? 'Something went wrong',
          );
      }
    }

    if (!anyMatched && detectedItems.isNotEmpty) {
      // No Lens results for any item — fall back to product-matcher. This
      // text search is slower than the Lens path, so run it in the
      // background instead of blocking "done": shoppingListProvider streams
      // from Firestore in real time, so whatever the matcher finds will
      // appear the moment it's saved.
      unawaited(_matchInBackground(
        sessionId:          sessionId,
        items:              detectedItems,
        ignoreTerms:        ignoreTerms,
        preferenceTerms:    preferenceTerms,
        shoppingCategories: shoppingCategories,
        maxSearches:        maxSearches,
      ));
    }

    yield PipelineEvent(PipelineStep.done, warnings: warnings);
  }

  Future<void> _matchInBackground({
    required String sessionId,
    required List<String> items,
    required List<String> ignoreTerms,
    required List<String> preferenceTerms,
    List<String>          shoppingCategories = const [],
    int?                  maxSearches,
  }) async {
    try {
      final matchResponse = await _matcher.match(MatchRequest(
        items:       items,
        ignoreTerms: ignoreTerms,
        maxSearches: maxSearches,
      ));
      if (matchResponse.matchedProducts.isNotEmpty) {
        final ranked = rankProducts(matchResponse.matchedProducts, shoppingCategories,
                preferenceTerms: preferenceTerms, isExactMatchSource: false)
            .toList();
        await _session.saveProducts(sessionId, ranked);
      }
    } catch (_) {
      // Best-effort background match — the pipeline already reported "done".
    }
  }
}

final analyzeImageUseCaseProvider = Provider((ref) => AnalyzeImageUseCase(
      ref.read(analyzerApiProvider),
      ref.read(matcherApiProvider),
      ref.read(sessionApiProvider),
    ));
