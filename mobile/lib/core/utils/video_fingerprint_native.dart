import 'dart:io';

import 'package:video_player/video_player.dart';

/// A stable identifier for a video file derived from intrinsic properties
/// (byte size + duration) rather than its OS-assigned filename.
///
/// iOS's image_picker generates a fresh UUID-based name every time the same
/// video is picked from Photos, so filename-keyed VideoAnnotations lookups
/// always miss there. This fingerprint stays stable across picks of the same
/// underlying video, on any platform — computed identically on the admin's
/// device (at annotation time) and the end user's device (at playback time).
Future<String> videoFingerprint(String path) async {
  final sizeBytes  = await File(path).length();
  final controller = VideoPlayerController.file(File(path));
  try {
    await controller.initialize();
    final durationMs = controller.value.duration.inMilliseconds;
    return '${sizeBytes}_$durationMs';
  } finally {
    await controller.dispose();
  }
}
