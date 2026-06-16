import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import '../../core/services/vision_service.dart';

// ── Still-image glow overlay (GCP Vision normalized bounding boxes) ───────────

class ObjectGlowOverlay extends StatefulWidget {
  const ObjectGlowOverlay({
    super.key,
    required this.objects,
    required this.imageSize,
    required this.widgetSize,
    required this.boxFit,
    this.onObjectTap,
  });

  final List<VisionLabel> objects;
  final Size imageSize;
  final Size widgetSize;
  final BoxFit boxFit;
  final void Function(VisionLabel)? onObjectTap;

  @override
  State<ObjectGlowOverlay> createState() => _ObjectGlowOverlayState();
}

class _ObjectGlowOverlayState extends State<ObjectGlowOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => CustomPaint(
        painter: _GlowPainter(
          objects:    widget.objects,
          imageSize:  widget.imageSize,
          widgetSize: widget.widgetSize,
          boxFit:     widget.boxFit,
          pulseValue: _pulse.value,
        ),
        child: _tapLayer(),
      ),
    );
  }

  Widget _tapLayer() {
    if (widget.onObjectTap == null) return const SizedBox.expand();
    return Stack(
      children: widget.objects
          .where((o) => o.boundingBox != null)
          .map((o) {
            final r = normalizedToWidget(
                o.boundingBox!, widget.imageSize, widget.widgetSize, widget.boxFit);
            return Positioned(
              left: r.left, top: r.top, width: r.width, height: r.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onObjectTap!(o),
                child: Container(color: Colors.transparent),
              ),
            );
          })
          .toList(),
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({
    required this.objects,
    required this.imageSize,
    required this.widgetSize,
    required this.boxFit,
    required this.pulseValue,
  });

  final List<VisionLabel> objects;
  final Size imageSize;
  final Size widgetSize;
  final BoxFit boxFit;
  final double pulseValue;

  static const _kGreen = Color(0xFF34D399);

  @override
  void paint(Canvas canvas, Size size) {
    for (final obj in objects) {
      if (obj.boundingBox == null) continue;
      final r = normalizedToWidget(obj.boundingBox!, imageSize, widgetSize, boxFit);
      _drawGlow(canvas, r);
      _drawBorder(canvas, r);
      _drawLabel(canvas, r, obj.description, obj.score);
    }
  }

  void _drawGlow(Canvas canvas, Rect r) {
    for (int i = 3; i >= 1; i--) {
      final expand  = i * 6.0 + pulseValue * 4;
      final opacity = (0.12 - i * 0.02) * (0.6 + pulseValue * 0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.inflate(expand), Radius.circular(10 + expand)),
        Paint()
          ..color      = _kGreen.withValues(alpha: opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  void _drawBorder(Canvas canvas, Rect r) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(6)),
      Paint()
        ..color       = _kGreen.withValues(alpha: 0.7 + pulseValue * 0.3)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  void _drawLabel(Canvas canvas, Rect r, String label, double score) {
    final text = '$label ${(score * 100).round()}%';
    final span = TextSpan(
      text: text,
      style: const TextStyle(
        color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.w600,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: r.width);

    final bgRect = Rect.fromLTWH(r.left, r.top - 20, tp.width + 10, 18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
      Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.85),
    );
    tp.paint(canvas, Offset(r.left + 5, r.top - 19));
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.pulseValue != pulseValue || old.objects != objects;
}

/// Converts a normalized [0,1] GCP Vision bounding rect to widget pixel coords,
/// accounting for BoxFit letterboxing.
Rect normalizedToWidget(Rect norm, Size imageSize, Size widgetSize, BoxFit boxFit) {
  final fitted  = applyBoxFit(boxFit, imageSize, widgetSize);
  final scaleX  = fitted.destination.width  / fitted.source.width;
  final scaleY  = fitted.destination.height / fitted.source.height;
  final renderLeft = (widgetSize.width  - fitted.destination.width)  / 2;
  final renderTop  = (widgetSize.height - fitted.destination.height) / 2;

  final srcLeft = (imageSize.width  - fitted.source.width)  / 2;
  final srcTop  = (imageSize.height - fitted.source.height) / 2;

  double toWX(double nx) => (nx * imageSize.width  - srcLeft) * scaleX + renderLeft;
  double toWY(double ny) => (ny * imageSize.height - srcTop)  * scaleY + renderTop;

  return Rect.fromLTRB(
    toWX(norm.left), toWY(norm.top),
    toWX(norm.right), toWY(norm.bottom),
  );
}

// ── Live-feed glow overlay (ML Kit pixel-space bounding boxes) ────────────────

class LiveObjectGlowOverlay extends StatefulWidget {
  const LiveObjectGlowOverlay({
    super.key,
    required this.objects,
    required this.previewSize,
    required this.screenSize,
    this.onObjectTap,
  });

  final List<DetectedObject> objects;
  final Size previewSize;  // camera native resolution (may be rotated)
  final Size screenSize;   // widget render size
  final void Function(DetectedObject)? onObjectTap;

  @override
  State<LiveObjectGlowOverlay> createState() => _LiveObjectGlowOverlayState();
}

class _LiveObjectGlowOverlayState extends State<LiveObjectGlowOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => CustomPaint(
        painter: _LiveGlowPainter(
          objects:     widget.objects,
          previewSize: widget.previewSize,
          screenSize:  widget.screenSize,
          pulseValue:  _pulse.value,
        ),
        child: _tapLayer(),
      ),
    );
  }

  Widget _tapLayer() {
    if (widget.onObjectTap == null) return const SizedBox.expand();
    const tapSize = 44.0; // comfortable touch target around the small dot
    return Stack(
      children: widget.objects.map((obj) {
        final r = _mlkitRectToScreen(obj.boundingBox, widget.previewSize, widget.screenSize);
        final center = r.center;
        return Positioned(
          left:   center.dx - tapSize / 2,
          top:    center.dy - tapSize / 2,
          width:  tapSize,
          height: tapSize,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onObjectTap!(obj),
            child: Container(color: Colors.transparent),
          ),
        );
      }).toList(),
    );
  }
}

class _LiveGlowPainter extends CustomPainter {
  const _LiveGlowPainter({
    required this.objects,
    required this.previewSize,
    required this.screenSize,
    required this.pulseValue,
  });

  final List<DetectedObject> objects;
  final Size previewSize;
  final Size screenSize;
  final double pulseValue;

  static const _kGreen = Color(0xFF34D399);
  static const _kDotRadius = 7.0;

  @override
  void paint(Canvas canvas, Size size) {
    for (final obj in objects) {
      final r = _mlkitRectToScreen(obj.boundingBox, previewSize, screenSize);
      final center = r.center;
      _drawGlow(canvas, center);
      _drawDot(canvas, center);
      final label = obj.labels.isNotEmpty ? obj.labels.first : null;
      if (label != null) _drawLabel(canvas, center, label.text, label.confidence);
    }
  }

  void _drawGlow(Canvas canvas, Offset center) {
    for (int i = 3; i >= 1; i--) {
      final radius  = _kDotRadius + i * 5.0 + pulseValue * 3;
      final opacity = (0.20 - i * 0.04) * (0.6 + pulseValue * 0.4);
      canvas.drawCircle(
        center, radius,
        Paint()
          ..color      = _kGreen.withValues(alpha: opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  void _drawDot(Canvas canvas, Offset center) {
    final radius = _kDotRadius * (0.9 + pulseValue * 0.15);
    canvas.drawCircle(
      center, radius,
      Paint()..color = _kGreen.withValues(alpha: 0.85 + pulseValue * 0.15),
    );
    canvas.drawCircle(
      center, radius,
      Paint()
        ..color       = Colors.white.withValues(alpha: 0.9)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawLabel(Canvas canvas, Offset center, String text, double confidence) {
    final label = '$text ${(confidence * 100).round()}%';
    final span = TextSpan(
      text: label,
      style: const TextStyle(
        color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.w600,
      ),
    );
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();

    final bgRect = Rect.fromLTWH(
      center.dx - tp.width / 2 - 5,
      center.dy - _kDotRadius - 24,
      tp.width + 10,
      18,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
      Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.85),
    );
    tp.paint(canvas, Offset(bgRect.left + 5, bgRect.top + 1));
  }

  @override
  bool shouldRepaint(_LiveGlowPainter old) =>
      old.pulseValue != pulseValue || old.objects != objects;
}

/// Converts ML Kit pixel-space Rect (in camera native resolution) to screen coords.
/// ML Kit uses portrait-rotated coords on Android — scaleX/scaleY accounts for
/// the camera preview being fit inside the screen widget.
Rect _mlkitRectToScreen(Rect mlkitRect, Size previewSize, Size screenSize) {
  final scaleX = screenSize.width  / previewSize.width;
  final scaleY = screenSize.height / previewSize.height;
  return Rect.fromLTRB(
    mlkitRect.left   * scaleX,
    mlkitRect.top    * scaleY,
    mlkitRect.right  * scaleX,
    mlkitRect.bottom * scaleY,
  );
}
