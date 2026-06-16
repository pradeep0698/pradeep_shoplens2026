// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:video_player/video_player.dart';

/// Web variant of [videoFingerprint] — `dart:io`'s File is unavailable here
/// (throws "Unsupported operation: _Namespace"), so byte size is read from
/// the picked file's blob URL instead. Must stay in sync with the native
/// implementation: same `'${sizeBytes}_$durationMs'` format, since the admin
/// (often on the web annotation tool) and the end user (on the mobile app)
/// need to compute matching fingerprints for the same physical video.
Future<String> videoFingerprint(String path) async {
  final request   = await html.HttpRequest.request(path, responseType: 'blob');
  final sizeBytes = (request.response as html.Blob).size;

  final controller = VideoPlayerController.networkUrl(Uri.parse(path));
  try {
    await controller.initialize();
    final durationMs = controller.value.duration.inMilliseconds;
    return '${sizeBytes}_$durationMs';
  } finally {
    await controller.dispose();
  }
}
