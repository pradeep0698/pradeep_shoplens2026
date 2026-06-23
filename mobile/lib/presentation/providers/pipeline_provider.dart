import 'dart:typed_data';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/session_id.dart';
import '../../data/models/analyzer_error.dart';
import '../../data/models/user_profile.dart';
import '../../data/repositories/session_repository.dart';
import '../../domain/usecases/analyze_image_usecase.dart';
import 'auth_provider.dart';
import 'profile_provider.dart';

part 'pipeline_provider.freezed.dart';

enum PipelineStatus { idle, analyzing, matching, saving, success, error, timeout }

@freezed
class PipelineState with _$PipelineState {
  const factory PipelineState({
    @Default(PipelineStatus.idle) PipelineStatus status,
    String? errorMessage,
    AnalyzerErrorCode? errorCode,
    @Default(false) bool isRetryable,
    @Default([]) List<String> warnings,
    Uint8List? imageBytes,
    @Default(false) bool fromLiveScan,
  }) = _PipelineState;
}

class PipelineNotifier extends AutoDisposeNotifier<PipelineState> {
  String? _mimeType;
  bool _fromLiveScan = false;

  @override PipelineState build() => const PipelineState();

  Future<void> _clearSession(String sessionId) async {
    try {
      await ref.read(sessionRepositoryProvider).clear(sessionId);
    } catch (_) {}
  }

  /// Load an image without running analysis. Clears the session so the
  /// shopping list resets immediately when a new image is loaded.
  Future<void> setImage(Uint8List bytes, String mimeType, {bool fromLiveScan = false}) async {
    _mimeType = mimeType;
    _fromLiveScan = fromLiveScan;
    state = PipelineState(status: PipelineStatus.idle, imageBytes: bytes, fromLiveScan: fromLiveScan);
    final user = ref.read(authStateProvider).value;
    if (user != null) await _clearSession(getSessionId(user.uid));
  }

  /// Run the full analyze pipeline on the image loaded by [setImage].
  Future<void> analyzeLoaded() async {
    final bytes = state.imageBytes;
    final mime  = _mimeType;
    if (bytes == null || mime == null) return;
    await analyzeImage(bytes, mime);
  }

  Future<void> analyzeImage(Uint8List bytes, String mimeType) async {
    final user    = ref.read(authStateProvider).value;
    final profile = ref.read(profileProvider).value ?? const UserProfile();
    if (user == null) return;

    final sessionId = getSessionId(user.uid);
    await _clearSession(sessionId);
    state = PipelineState(status: PipelineStatus.analyzing, imageBytes: bytes, fromLiveScan: _fromLiveScan);
    await ref.read(sessionRepositoryProvider).clear(sessionId);

    try {
      await for (final event in ref.read(analyzeImageUseCaseProvider).execute(
        imageBytes:         bytes,
        mimeType:           mimeType,
        sessionId:          sessionId,
        ignoreTerms:        profile.ignoreTerms,
        preferenceTerms:    profile.preferenceTerms,
        shoppingCategories: profile.shoppingCategories,
        country:            profile.country.isEmpty ? null : profile.country,
        maxSearches:        profile.maxSearchesPerRun,
      )) {
        state = PipelineState(
          imageBytes: bytes,
          fromLiveScan: _fromLiveScan,
          status: switch (event.step) {
            PipelineStep.analyzing => PipelineStatus.analyzing,
            PipelineStep.matching  => PipelineStatus.matching,
            PipelineStep.saving    => PipelineStatus.saving,
            PipelineStep.done      => PipelineStatus.success,
          },
          warnings: event.warnings,
        );
      }
    } on AnalyzerException catch (e) {
      state = PipelineState(
        status: e.code == AnalyzerErrorCode.networkTimeout ? PipelineStatus.timeout : PipelineStatus.error,
        errorMessage: e.displayMessage,
        errorCode: e.code,
        isRetryable: e.isRetryable,
        fromLiveScan: _fromLiveScan,
      );
    } catch (e) {
      state = PipelineState(status: PipelineStatus.error, errorMessage: e.toString(), fromLiveScan: _fromLiveScan);
    }
  }

  Future<void> clearSession() async {
    final user = ref.read(authStateProvider).value;
    if (user == null) return;
    await _clearSession(getSessionId(user.uid));
    _fromLiveScan = false;
    state = const PipelineState();
  }

  void resetImage() {
    _fromLiveScan = false;
    state = const PipelineState();
  }
}

final pipelineProvider =
    AutoDisposeNotifierProvider<PipelineNotifier, PipelineState>(
        PipelineNotifier.new);
