// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/widgets.dart' show GlobalKey;

Future<Uint8List?> captureFrame(GlobalKey key) async {
  try {
    final videos = html.document.querySelectorAll('video');
    if (videos.isEmpty) return null;
    final video = videos.first as html.VideoElement;

    if (video.videoWidth == 0 || video.videoHeight == 0) return null;

    final canvas = html.CanvasElement(
      width:  video.videoWidth,
      height: video.videoHeight,
    );
    canvas.context2D.drawImage(video, 0, 0);

    final dataUrl = canvas.toDataUrl('image/jpeg', 0.85);
    final base64  = dataUrl.split(',').last;
    return base64Decode(base64);
  } catch (_) {
    return null;
  }
}
