import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Coordinate translation and image-cropping helpers for [TapTargetDetector].
/// Uses only [dart:ui] — no additional packages required.
final class TapCropUtils {
  TapCropUtils._();

  /// Converts a tap position in widget-local coordinates to raw image pixel
  /// coordinates, correctly accounting for [boxFit].
  ///
  /// Works for BoxFit.contain (letterboxed), BoxFit.cover (cropped centre),
  /// BoxFit.fill, BoxFit.fitWidth, BoxFit.fitHeight, etc.
  static Offset widgetToImageCoords({
    required Offset tap,
    required Size widgetSize,
    required Size imageSize,
    required BoxFit boxFit,
  }) {
    final fitted = applyBoxFit(boxFit, imageSize, widgetSize);

    // Pixels per image pixel in each axis
    final scaleX = fitted.destination.width  / fitted.source.width;
    final scaleY = fitted.destination.height / fitted.source.height;

    // Where the rendered image begins inside the widget (centred by Flutter)
    final renderLeft = (widgetSize.width  - fitted.destination.width)  / 2;
    final renderTop  = (widgetSize.height - fitted.destination.height) / 2;

    // For BoxFit.cover the visible source is a centred sub-rect of the image
    final srcLeft = (imageSize.width  - fitted.source.width)  / 2;
    final srcTop  = (imageSize.height - fitted.source.height) / 2;

    return Offset(
      (tap.dx - renderLeft) / scaleX + srcLeft,
      (tap.dy - renderTop)  / scaleY + srcTop,
    );
  }

  /// Extracts a [cropPx]×[cropPx] square PNG crop centred on [center]
  /// (raw image coordinates), clamped to the image bounds.
  ///
  /// Runs on the UI isolate via [dart:ui]. For very large source images
  /// (>4 K) consider using `compute()` with the `image` package instead.
  static Future<Uint8List> cropSquare({
    required Uint8List imageBytes,
    required Offset center,
    required Size imageSize,
    double cropPx = 256,
  }) async {
    final side = cropPx.clamp(8.0, imageSize.shortestSide);
    final half = side / 2;
    final left = (center.dx - half).clamp(0.0, imageSize.width  - side);
    final top  = (center.dy - half).clamp(0.0, imageSize.height - side);

    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final src   = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas   = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      Rect.fromLTWH(left, top, side, side),
      Rect.fromLTWH(0,    0,    side, side),
      Paint(),
    );
    src.dispose();

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(side.toInt(), side.toInt());
    final bd      = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();

    if (bd == null) throw Exception('Image encoding failed (toByteData returned null)');
    return bd.buffer.asUint8List();
  }

  /// Converts a widget-local [Rect] to raw image pixel coordinates,
  /// accounting for [boxFit] scaling and centering.
  static Rect widgetRectToImageRect({
    required Rect rect,
    required Size widgetSize,
    required Size imageSize,
    required BoxFit boxFit,
  }) {
    final fitted   = applyBoxFit(boxFit, imageSize, widgetSize);
    final scaleX   = fitted.destination.width  / fitted.source.width;
    final scaleY   = fitted.destination.height / fitted.source.height;
    final renderLeft = (widgetSize.width  - fitted.destination.width)  / 2;
    final renderTop  = (widgetSize.height - fitted.destination.height) / 2;
    final srcLeft    = (imageSize.width   - fitted.source.width)  / 2;
    final srcTop     = (imageSize.height  - fitted.source.height) / 2;

    double toImgX(double wx) => (wx - renderLeft) / scaleX + srcLeft;
    double toImgY(double wy) => (wy - renderTop)  / scaleY + srcTop;

    return Rect.fromLTRB(
      toImgX(rect.left).clamp(0.0, imageSize.width),
      toImgY(rect.top).clamp(0.0, imageSize.height),
      toImgX(rect.right).clamp(0.0, imageSize.width),
      toImgY(rect.bottom).clamp(0.0, imageSize.height),
    );
  }

  /// Extracts an arbitrary rectangular PNG crop from [imageBytes]
  /// using [rect] in raw image pixel coordinates.
  static Future<Uint8List> cropRect({
    required Uint8List imageBytes,
    required Rect rect,
    required Size imageSize,
  }) async {
    final clamped = Rect.fromLTRB(
      rect.left.clamp(0.0, imageSize.width),
      rect.top.clamp(0.0, imageSize.height),
      rect.right.clamp(0.0, imageSize.width),
      rect.bottom.clamp(0.0, imageSize.height),
    );
    final w = clamped.width.toInt().clamp(1, imageSize.width.toInt());
    final h = clamped.height.toInt().clamp(1, imageSize.height.toInt());

    final codec = await ui.instantiateImageCodec(imageBytes);
    final frame = await codec.getNextFrame();
    final src   = frame.image;

    final recorder = ui.PictureRecorder();
    final canvas   = ui.Canvas(recorder);
    canvas.drawImageRect(
      src,
      clamped,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint(),
    );
    src.dispose();

    final picture = recorder.endRecording();
    final cropped = await picture.toImage(w, h);
    final bd      = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();

    if (bd == null) throw Exception('Image encoding failed (toByteData returned null)');
    return bd.buffer.asUint8List();
  }
}
