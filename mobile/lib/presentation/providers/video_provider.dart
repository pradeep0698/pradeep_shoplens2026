import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/analyzer_error.dart';
import '../../data/models/product.dart';
import '../../data/models/user_profile.dart';
import '../../data/sources/firebase/firestore_source.dart';
import '../../core/utils/session_id.dart';
import '../../core/utils/video_fingerprint.dart';
import '../../domain/usecases/video_analyze_usecase.dart';
import 'auth_provider.dart';
import 'profile_provider.dart';

sealed class VideoState {
  const VideoState();
}

class VideoIdle extends VideoState {
  const VideoIdle();
}

class VideoLoaded extends VideoState {
  const VideoLoaded({
    required this.videoPath,
    required this.fileName,
    this.thumbnail,
    this.annotations = const [],
  });
  final String               videoPath;
  final String               fileName;
  final Uint8List?           thumbnail;
  final List<VideoAnnotation> annotations;
}

class VideoCacheHit extends VideoState {
  const VideoCacheHit({
    required this.videoPath,
    required this.fileName,
    required this.products,
    this.thumbnail,
    this.annotations = const [],
  });
  final String               videoPath;
  final String               fileName;
  final List<Product>        products;
  final Uint8List?           thumbnail;
  final List<VideoAnnotation> annotations;
}

class VideoAnalyzing extends VideoState {
  const VideoAnalyzing({
    required this.step,
    required this.fileName,
    this.thumbnail,
  });
  final VideoStep  step;
  final String     fileName;
  final Uint8List? thumbnail;
}

class VideoDone extends VideoState {
  const VideoDone();
}

class VideoError extends VideoState {
  const VideoError({
    required this.message,
    required this.fileName,
    this.thumbnail,
  });
  final String     message;
  final String     fileName;
  final Uint8List? thumbnail;
}

class VideoNotifier extends Notifier<VideoState> {
  @override VideoState build() => const VideoIdle();

  /// Called after user picks a video: shows section immediately, then extracts
  /// thumbnail and checks cache in the background.
  Future<void> videoLoaded(String videoPath, String fileName) async {
    // Show the section right away so UI responds instantly
    state = VideoLoaded(videoPath: videoPath, fileName: fileName);

    try {
      final uc          = ref.read(videoAnalyzeUseCaseProvider);
      final firestoreSource = ref.read(firestoreSourceProvider);

      final thumbnail   = await uc.extractFrame(videoPath);
      final cached      = await uc.checkCache(fileName);

      // Look up by content fingerprint first — image_picker assigns a fresh
      // filename to the same physical video on every pick on iOS, so the
      // filename-keyed lookup misses there. Fall back to it for older docs
      // (and platforms like Android, where filenames stay stable) that
      // predate the fingerprint field.
      final fingerprint  = await videoFingerprint(videoPath);
      var   annotations  = await firestoreSource.getVideoAnnotationsByFingerprint(fingerprint);
      if (annotations.isEmpty) {
        annotations = await firestoreSource.getVideoAnnotations(fileName);
      }

      if (cached != null) {
        state = VideoCacheHit(
          videoPath:   videoPath,
          fileName:    fileName,
          products:    cached,
          thumbnail:   thumbnail,
          annotations: annotations,
        );
      } else {
        state = VideoLoaded(
          videoPath:   videoPath,
          fileName:    fileName,
          thumbnail:   thumbnail,
          annotations: annotations,
        );
      }
    } catch (e) {
      final message = e is AnalyzerException ? e.displayMessage : e.toString();
      state = VideoError(message: message, fileName: fileName);
    }
  }

  /// Loads cached products directly into the session (no API calls).
  Future<void> loadCachedProducts() async {
    final s = state;
    if (s is! VideoCacheHit) return;

    final user = ref.read(authStateProvider).value;
    if (user == null) return;

    await ref.read(videoAnalyzeUseCaseProvider).loadCachedIntoSession(
      s.products,
      getSessionId(user.uid),
    );
    state = const VideoDone();
  }

  /// Runs the full analysis pipeline using a frame captured by the video player.
  Future<void> analyzeWithFrame(Uint8List frameBytes) async {
    final s = state;
    if (s is! VideoLoaded) return;

    final user    = ref.read(authStateProvider).value;
    final profile = ref.read(profileProvider).value ?? const UserProfile();
    if (user == null) return;

    final thumbnail = s.thumbnail;
    final fileName  = s.fileName;
    final sessionId = getSessionId(user.uid);

    try {
      await for (final step in ref.read(videoAnalyzeUseCaseProvider).analyzeAndCache(
        frameBytes:      frameBytes,
        fileName:        fileName,
        sessionId:       sessionId,
        ignoreTerms:     profile.ignoreTerms,
        preferenceTerms: profile.preferenceTerms,
      )) {
        state = VideoAnalyzing(step: step, fileName: fileName, thumbnail: thumbnail);
      }
      state = const VideoDone();
    } catch (e) {
      final message = e is AnalyzerException ? e.displayMessage : e.toString();
      state = VideoError(message: message, fileName: fileName, thumbnail: thumbnail);
    }
  }

  void reset() => state = const VideoIdle();
}

final videoProvider =
    NotifierProvider<VideoNotifier, VideoState>(VideoNotifier.new);
