import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

// Same encoding the web app applies via FileReader before calling /analyze
String encodeImageToBase64(Uint8List bytes) => base64Encode(bytes);

/// Encodes a decoded [ui.Image] as JPEG bytes. dart:ui's [ui.Image.toByteData]
/// has no JPEG format, so pixels are read out as raw RGBA and re-encoded with
/// the pure-Dart `image` package. Used for tap-crop uploads: the server
/// re-encodes every crop to JPEG anyway, so sending PNG from the client only
/// cost upload bytes for no benefit.
Future<Uint8List> encodeUiImageToJpeg(ui.Image image, {int quality = 85}) async {
  final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bd == null) throw Exception('Image encoding failed (toByteData returned null)');
  final rgba = img.Image.fromBytes(
    width:       image.width,
    height:      image.height,
    bytes:       bd.buffer,
    numChannels: 4,
    order:       img.ChannelOrder.rgba,
  );
  return img.encodeJpg(rgba, quality: quality);
}

// AI Analyzer accepts: image/jpeg, image/png, image/webp
String getMimeType(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'png'  => 'image/png',
    'webp' => 'image/webp',
    _      => 'image/jpeg',
  };
}

/// Crops [imageBytes] to the region defined by [box] (ML Kit portrait pixel coords).
///
/// [portraitStreamSize] is the camera stream size in portrait orientation —
/// swap W/H from [CameraController.value.previewSize] if it's landscape.
///
/// The captured JPEG is expected to be portrait (guaranteed by
/// [CameraController.lockCaptureOrientation]). If the decoded image turns out
/// to be landscape (EXIF not applied on some devices), the function falls back
/// to rotating the coordinate mapping 90° so the crop is still correct.
///
/// Returns JPEG bytes (accepted by /analyze and /identify backends).
Future<Uint8List?> cropToMlKitBox(
  Uint8List imageBytes,
  Rect box,
  Size portraitStreamSize, {
  double padFraction = 0.08,
}) async {
  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final srcImage = frame.image;

  try {
    final imgW = srcImage.width.toDouble();
    final imgH = srcImage.height.toDouble();

    // Determine scale — handle the rare case where the JPEG is still landscape
    // (EXIF not auto-applied): rotate the box mapping 90°.
    final double scaleX, scaleY, srcX1, srcY1, srcX2, srcY2;

    if (imgW <= imgH) {
      // Portrait image — direct scale from ML Kit portrait coords
      scaleX = imgW / portraitStreamSize.width;
      scaleY = imgH / portraitStreamSize.height;

      final padX = box.width  * padFraction;
      final padY = box.height * padFraction;
      srcX1 = ((box.left   - padX) * scaleX).clamp(0.0, imgW);
      srcY1 = ((box.top    - padY) * scaleY).clamp(0.0, imgH);
      srcX2 = ((box.right  + padX) * scaleX).clamp(0.0, imgW);
      srcY2 = ((box.bottom + padY) * scaleY).clamp(0.0, imgH);
    } else {
      // Landscape image — ML Kit portrait (portW × portH) maps to landscape
      // (portH × portW): x→y, y→(imgW - x)
      final portW = portraitStreamSize.width;
      final portH = portraitStreamSize.height;
      scaleX = imgW / portH;
      scaleY = imgH / portW;

      final padX = box.width  * padFraction;
      final padY = box.height * padFraction;
      // ML Kit portrait (x=left/right, y=top/bottom) → landscape (x=top/bottom, y=imgW-right/left)
      final lsLeft   = ((box.top    - padY) * scaleX).clamp(0.0, imgW);
      final lsRight  = ((box.bottom + padY) * scaleX).clamp(0.0, imgW);
      final lsTop    = (imgH - (box.right  + padX) * scaleY).clamp(0.0, imgH);
      final lsBottom = (imgH - (box.left   - padX) * scaleY).clamp(0.0, imgH);
      srcX1 = lsLeft;
      srcY1 = lsTop;
      srcX2 = lsRight;
      srcY2 = lsBottom;
    }

    final cw = (srcX2 - srcX1).clamp(1.0, imgW);
    final ch = (srcY2 - srcY1).clamp(1.0, imgH);

    final recorder = ui.PictureRecorder();
    Canvas(recorder, Rect.fromLTWH(0, 0, cw, ch)).drawImageRect(
      srcImage,
      Rect.fromLTWH(srcX1, srcY1, cw, ch),
      Rect.fromLTWH(0, 0, cw, ch),
      Paint(),
    );
    final cropped = await recorder.endRecording().toImage(cw.round(), ch.round());
    final jpeg = await encodeUiImageToJpeg(cropped);
    cropped.dispose();
    return jpeg;
  } finally {
    srcImage.dispose();
  }
}

/// Converts Gemini's `[y_min, x_min, y_max, x_max]` box on a 0-1000 scale to
/// a normalized `[0,1]` Rect, for use with [ObjectGlowOverlay]'s
/// `normalizedToWidget` BoxFit-aware mapping.
Rect geminiBoxToNormalizedRect(List<int> box) => Rect.fromLTRB(
      box[1] / 1000.0,
      box[0] / 1000.0,
      box[3] / 1000.0,
      box[2] / 1000.0,
    );

/// Crops [imageBytes] to the region defined by [box] — Gemini's
/// `[y_min, x_min, y_max, x_max]` on a 0-1000 scale, normalized to whatever
/// image was sent to /detect. Since the scale is a fraction of the image's
/// own dimensions, it applies directly to the full-res bytes with no
/// portrait/landscape conversion needed (unlike [cropToMlKitBox], whose box
/// is in camera-preview pixel coords).
///
/// Mirrors the backend's `_crop_product` (analyzer.py) padding convention so
/// client-cropped previews match what the server would have cropped.
///
/// Returns JPEG bytes (accepted by /identify).
Future<Uint8List?> cropToGeminiBox(
  Uint8List imageBytes,
  List<int> box, {
  double padFraction = 0.05,
}) async {
  if (box.length != 4) return null;
  final codec = await ui.instantiateImageCodec(imageBytes);
  final frame = await codec.getNextFrame();
  final srcImage = frame.image;

  try {
    final imgW = srcImage.width.toDouble();
    final imgH = srcImage.height.toDouble();
    final y1 = box[0] / 1000.0, x1 = box[1] / 1000.0;
    final y2 = box[2] / 1000.0, x2 = box[3] / 1000.0;

    final srcX1 = ((x1 - padFraction) * imgW).clamp(0.0, imgW);
    final srcY1 = ((y1 - padFraction) * imgH).clamp(0.0, imgH);
    final srcX2 = ((x2 + padFraction) * imgW).clamp(0.0, imgW);
    final srcY2 = ((y2 + padFraction) * imgH).clamp(0.0, imgH);

    final cw = (srcX2 - srcX1).clamp(1.0, imgW);
    final ch = (srcY2 - srcY1).clamp(1.0, imgH);

    final recorder = ui.PictureRecorder();
    Canvas(recorder, Rect.fromLTWH(0, 0, cw, ch)).drawImageRect(
      srcImage,
      Rect.fromLTWH(srcX1, srcY1, cw, ch),
      Rect.fromLTWH(0, 0, cw, ch),
      Paint(),
    );
    final cropped = await recorder.endRecording().toImage(cw.round(), ch.round());
    final jpeg = await encodeUiImageToJpeg(cropped);
    cropped.dispose();
    return jpeg;
  } finally {
    srcImage.dispose();
  }
}
