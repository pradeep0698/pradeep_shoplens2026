import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/analyze_request.dart';
import '../../data/models/match_request.dart';
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
    String?               country,
  }) async* {
    yield const PipelineEvent(PipelineStep.analyzing);
    final analyzeResponse = await _analyzer.analyze(AnalyzeRequest(
      imageData:     encodeImageToBase64(imageBytes),
      imageMimeType: mimeType,
      ignoreTerms:   ignoreTerms,
      transcript:    '',
      country:       country,
    ));

    if (analyzeResponse.products.isNotEmpty) {
      // Lens returned visual matches — save directly, skip product-matcher
      yield const PipelineEvent(PipelineStep.saving);
      final ranked = rankProducts(analyzeResponse.products, preferenceTerms,
              isExactMatchSource: true)
          .toList();
      await _session.saveProducts(sessionId, ranked);
    } else if (analyzeResponse.items.isNotEmpty) {
      // No Lens results — fall back to product-matcher. This text search is
      // slower than the Lens path, so run it in the background instead of
      // blocking "done": shoppingListProvider streams from Firestore in real
      // time, so whatever the matcher finds will appear the moment it's saved.
      unawaited(_matchInBackground(
        sessionId:       sessionId,
        items:           analyzeResponse.items,
        ignoreTerms:     ignoreTerms,
        preferenceTerms: preferenceTerms,
      ));
    }

    yield PipelineEvent(PipelineStep.done, warnings: analyzeResponse.warnings);
  }

  Future<void> _matchInBackground({
    required String sessionId,
    required List<String> items,
    required List<String> ignoreTerms,
    required List<String> preferenceTerms,
  }) async {
    try {
      final matchResponse = await _matcher.match(MatchRequest(
        items:       items,
        ignoreTerms: ignoreTerms,
      ));
      if (matchResponse.matchedProducts.isNotEmpty) {
        final ranked = rankProducts(matchResponse.matchedProducts, preferenceTerms,
                isExactMatchSource: false)
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
