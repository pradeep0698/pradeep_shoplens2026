import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../data/models/product.dart';
import '../../data/sources/firebase/firestore_source.dart';
import '../../data/sources/remote/session_api.dart';
import 'analyze_image_usecase.dart';

enum VideoStep { analyzing, matching, saving }

class VideoAnalyzeUseCase {
  final FirestoreSource     _firestore;
  final AnalyzeImageUseCase _analyzeUseCase;
  final SessionApi          _session;

  VideoAnalyzeUseCase(this._firestore, this._analyzeUseCase, this._session);

  Future<List<Product>?> checkCache(String fileName) =>
      _firestore.loadVideoCache(fileName);

  Future<Uint8List?> extractFrame(String videoPath) async {
    try {
      return await VideoThumbnail.thumbnailData(
        video:       videoPath,
        imageFormat: ImageFormat.JPEG,
        maxHeight:   720,
        quality:     85,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> loadCachedIntoSession(
    List<Product> products,
    String        sessionId,
  ) async {
    await _session.clearSession(sessionId);
    await _session.saveProducts(sessionId, products);
  }

  static String _mimeFromBytes(Uint8List b) {
    if (b.length >= 4 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
    if (b.length >= 4 && b[0] == 0x52 && b[1] == 0x49) return 'image/webp';
    return 'image/png'; // safe fallback
  }

  Stream<VideoStep> analyzeAndCache({
    required Uint8List    frameBytes,
    required String       fileName,
    required String       sessionId,
    required List<String> ignoreTerms,
    required List<String> preferenceTerms,
    List<String>          shoppingCategories = const [],
  }) async* {
    await _session.clearSession(sessionId);

    await for (final event in _analyzeUseCase.execute(
      imageBytes:         frameBytes,
      mimeType:           _mimeFromBytes(frameBytes),
      sessionId:          sessionId,
      ignoreTerms:        ignoreTerms,
      preferenceTerms:    preferenceTerms,
      shoppingCategories: shoppingCategories,
    )) {
      if (event.step != PipelineStep.done) {
        yield switch (event.step) {
          PipelineStep.analyzing => VideoStep.analyzing,
          PipelineStep.matching  => VideoStep.matching,
          PipelineStep.saving    => VideoStep.saving,
          PipelineStep.done      => VideoStep.saving,
        };
      }
    }

    // Save to permanent video cache keyed by filename
    final products = await _session.loadSession(sessionId);
    if (products.isNotEmpty) {
      await _firestore.saveVideoCache(fileName, products);
    }
  }
}

final videoAnalyzeUseCaseProvider = Provider((ref) => VideoAnalyzeUseCase(
      ref.read(firestoreSourceProvider),
      ref.read(analyzeImageUseCaseProvider),
      ref.read(sessionApiProvider),
    ));
