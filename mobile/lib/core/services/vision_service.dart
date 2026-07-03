import 'dart:typed_data';
import 'package:flutter/painting.dart';

// ── Result types ─────────────────────────────────────────────────────────────

class VisionLabel {
  const VisionLabel({
    required this.description,
    required this.score,
    this.boundingBox,
  });
  final String description;
  final double score;
  // Normalized [0,1] bounding rect from GCP OBJECT_LOCALIZATION
  final Rect? boundingBox;
}

class VisionResult {
  const VisionResult({required this.objects, required this.labels});
  final List<VisionLabel> objects; // from OBJECT_LOCALIZATION (more specific)
  final List<VisionLabel> labels;  // from LABEL_DETECTION     (broader)

  /// Deduplicated list, objects first (more specific), then labels.
  List<String> get topDescriptions {
    final seen = <String>{};
    return [
      ...objects.map((o) => o.description),
      ...labels.map((l) => l.description),
    ].where(seen.add).take(6).toList();
  }
}

// ── Service contract ──────────────────────────────────────────────────────────

/// Implement this to swap in any vision backend (Cloud Vision, Vertex AI, etc.)
/// without touching the widget layer.
abstract interface class VisionService {
  Future<VisionResult> identify(Uint8List croppedImageBytes);
}
