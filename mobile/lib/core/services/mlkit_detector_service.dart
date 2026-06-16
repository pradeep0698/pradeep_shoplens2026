import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/painting.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

class MlKitDetectorService {
  MlKitDetectorService()
      : _detector = ObjectDetector(
          options: ObjectDetectorOptions(
            mode: DetectionMode.stream,
            classifyObjects: true,
            multipleObjects: true,
          ),
        );

  final ObjectDetector _detector;

  Future<List<DetectedObject>> detectFromCameraImage(
    CameraImage image,
    InputImageRotation rotation,
    CameraLensDirection lensDirection,
  ) async {
    final format = InputImageFormatValue.fromRawValue(image.format.raw)
        ?? (Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormat.bgra8888);

    final plane = image.planes.first;
    final metadata = InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: plane.bytesPerRow,
    );

    final inputImage = InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: metadata,
    );

    return _detector.processImage(inputImage);
  }

  void dispose() => _detector.close();
}
