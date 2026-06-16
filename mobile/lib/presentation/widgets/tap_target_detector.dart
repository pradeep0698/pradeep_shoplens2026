import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/services/vision_service.dart';
import '../../core/utils/tap_crop_utils.dart';
import '../../data/models/analyzer_error.dart';

/// Wraps any widget that renders an image. On first tap a resizable bounding
/// box (Google Lens style) appears centered on the tap. The user drags the
/// corner handles to resize/move it. The parent triggers identification by
/// calling [TapTargetDetectorState.analyzeSelection] (e.g. from a button).
class TapTargetDetector extends StatefulWidget {
  const TapTargetDetector({
    super.key,
    required this.imageBytes,
    required this.boxFit,
    required this.onIdentify,
    required this.onStateChanged,
    required this.child,
    this.rippleColor,
  });

  final Uint8List imageBytes;
  final BoxFit boxFit;
  /// Called with cropped PNG bytes when the user triggers identification.
  /// Returns the matched product name, or null if nothing was found.
  final Future<String?> Function(Uint8List croppedBytes) onIdentify;
  final void Function(TapIdentifyState state) onStateChanged;
  final Widget child;
  final Color? rippleColor;

  @override
  TapTargetDetectorState createState() => TapTargetDetectorState();
}

// ─── constants ───────────────────────────────────────────────────────────────
const double _kDefaultBoxSize = 150.0;
const double _kMinBoxSize     = 60.0;
const double _kHandleHit      = 44.0; // touch target
const double _kHandleVis      = 12.0; // visual square side
const Color  _kGreen          = Color(0xFF34D399);

// ─── state ───────────────────────────────────────────────────────────────────
class TapTargetDetectorState extends State<TapTargetDetector>
    with SingleTickerProviderStateMixin {
  final _boxKey = GlobalKey();

  Size?  _imageSize;
  bool   _busy     = false;
  bool   _showBox  = false;
  Rect?  _boxRect;

  late final AnimationController _ripple;

  /// True when a bounding box is actively selected.
  bool get hasSelection => _showBox && _boxRect != null;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _loadImageSize(widget.imageBytes);
  }

  @override
  void didUpdateWidget(TapTargetDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageBytes != widget.imageBytes) {
      _loadImageSize(widget.imageBytes);
      setState(() { _showBox = false; _boxRect = null; });
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  Future<void> _loadImageSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img   = frame.image;
    if (mounted) {
      setState(() => _imageSize = Size(img.width.toDouble(), img.height.toDouble()));
    }
    img.dispose();
  }

  // ── gesture: tap on image → show box ──────────────────────────────────────
  void _onTapUp(TapUpDetails details) {
    if (_busy) return;
    if (_showBox) {
      // Tap outside the box while box is shown → dismiss
      final tap = details.localPosition;
      if (_boxRect != null && !_boxRect!.contains(tap)) {
        setState(() { _showBox = false; _boxRect = null; });
        widget.onStateChanged(const TapIdentifyIdle());
      }
      return;
    }

    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final w   = box.size.width;
    final h   = box.size.height;
    final tap = details.localPosition;
    const half = _kDefaultBoxSize / 2;

    final left = (tap.dx - half).clamp(0.0, (w - _kDefaultBoxSize).clamp(0.0, w));
    final top  = (tap.dy - half).clamp(0.0, (h - _kDefaultBoxSize).clamp(0.0, h));

    // Brief ripple then show box
    setState(() { _showBox = false; });
    _ripple.forward(from: 0).then((_) {
      if (mounted) {
        setState(() {
          _showBox = true;
          _boxRect = Rect.fromLTWH(left, top, _kDefaultBoxSize, _kDefaultBoxSize);
        });
        widget.onStateChanged(const TapIdentifyIdle());
      }
    });
  }

  // ── box move (drag interior) ───────────────────────────────────────────────
  void _onBoxMove(DragUpdateDetails d) {
    if (_boxRect == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final w = box.size.width;
    final h = box.size.height;
    final r = _boxRect!;
    final newL = (r.left + d.delta.dx).clamp(0.0, w - r.width);
    final newT = (r.top  + d.delta.dy).clamp(0.0, h - r.height);
    setState(() => _boxRect = Rect.fromLTWH(newL, newT, r.width, r.height));
  }

  // ── corner resize helpers ─────────────────────────────────────────────────
  void _resizeTL(DragUpdateDetails d) {
    if (_boxRect == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final r = _boxRect!;
    final newL = (r.left + d.delta.dx).clamp(0.0, r.right - _kMinBoxSize);
    final newT = (r.top  + d.delta.dy).clamp(0.0, r.bottom - _kMinBoxSize);
    setState(() => _boxRect = Rect.fromLTRB(newL, newT, r.right, r.bottom));
  }

  void _resizeTR(DragUpdateDetails d) {
    if (_boxRect == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final w = box.size.width;
    final r = _boxRect!;
    final newR = (r.right + d.delta.dx).clamp(r.left + _kMinBoxSize, w.toDouble());
    final newT = (r.top   + d.delta.dy).clamp(0.0, r.bottom - _kMinBoxSize);
    setState(() => _boxRect = Rect.fromLTRB(r.left, newT, newR, r.bottom));
  }

  void _resizeBL(DragUpdateDetails d) {
    if (_boxRect == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final h = box.size.height;
    final r = _boxRect!;
    final newL = (r.left   + d.delta.dx).clamp(0.0, r.right - _kMinBoxSize);
    final newB = (r.bottom + d.delta.dy).clamp(r.top + _kMinBoxSize, h.toDouble());
    setState(() => _boxRect = Rect.fromLTRB(newL, r.top, r.right, newB));
  }

  void _resizeBR(DragUpdateDetails d) {
    if (_boxRect == null) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final w = box.size.width;
    final h = box.size.height;
    final r = _boxRect!;
    final newR = (r.right  + d.delta.dx).clamp(r.left + _kMinBoxSize, w.toDouble());
    final newB = (r.bottom + d.delta.dy).clamp(r.top  + _kMinBoxSize, h.toDouble());
    setState(() => _boxRect = Rect.fromLTRB(r.left, r.top, newR, newB));
  }

  // ── crop + identify ────────────────────────────────────────────────────────
  /// Called by the parent (e.g. "Analyze Image" button) to identify the
  /// current selection. Returns immediately if no box is active.
  Future<void> analyzeSelection() async {
    if (_imageSize == null || _boxRect == null || _busy) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final savedRect = _boxRect!;
    setState(() { _busy = true; _showBox = false; _boxRect = null; });
    widget.onStateChanged(const TapIdentifyLoading());

    try {
      final imageRect = TapCropUtils.widgetRectToImageRect(
        rect:       savedRect,
        widgetSize: box.size,
        imageSize:  _imageSize!,
        boxFit:     widget.boxFit,
      );

      final cropped = await TapCropUtils.cropRect(
        imageBytes: widget.imageBytes,
        rect:       imageRect,
        imageSize:  _imageSize!,
      );

      final productName = await widget.onIdentify(cropped);
      if (mounted) widget.onStateChanged(TapIdentifySuccess(productName: productName));
    } catch (e) {
      final message = e is AnalyzerException ? e.displayMessage : e.toString();
      if (mounted) widget.onStateChanged(TapIdentifyError(message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onDismiss() {
    setState(() { _showBox = false; _boxRect = null; });
    widget.onStateChanged(const TapIdentifyIdle());
  }

  // ── build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key:      _boxKey,
      behavior: HitTestBehavior.opaque,
      onTapUp:  _busy ? null : _onTapUp,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          widget.child,

          // ── ripple feedback (brief, before box appears) ──────────────────
          if (!_showBox)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ripple,
                  builder: (_, __) => CustomPaint(
                    painter: _RipplePainter(
                      center:   _boxRect != null
                          ? _boxRect!.center
                          : Offset.zero,
                      progress: _ripple.value,
                      color:    widget.rippleColor ?? _kGreen,
                    ),
                  ),
                ),
              ),
            ),

          // ── bounding box overlay ─────────────────────────────────────────
          if (_showBox && _boxRect != null) ..._boxOverlay(_boxRect!),
        ],
      ),
    );
  }

  List<Widget> _boxOverlay(Rect r) {
    const halfHit = _kHandleHit / 2;

    return [
      // Scrim with cutout + box border
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _BoxOverlayPainter(rect: r)),
        ),
      ),

      // Interior drag (move box)
      Positioned(
        left:   r.left   + halfHit,
        top:    r.top    + halfHit,
        width:  (r.width  - _kHandleHit).clamp(0, double.infinity),
        height: (r.height - _kHandleHit).clamp(0, double.infinity),
        child: GestureDetector(
          behavior:      HitTestBehavior.opaque,
          onPanUpdate:   _onBoxMove,
          child: Container(color: Colors.transparent),
        ),
      ),

      // Corner handles
      _handle(r.left,         r.top,          _resizeTL),
      _handle(r.right,        r.top,          _resizeTR),
      _handle(r.left,         r.bottom,       _resizeBL),
      _handle(r.right,        r.bottom,       _resizeBR),

      // Dismiss (×) button — top-right of box
      Positioned(
        left: r.right - 18,
        top:  r.top   - 18,
        child: GestureDetector(
          onTap: _onDismiss,
          child: Container(
            width: 28, height: 28,
            decoration: const BoxDecoration(
              color:        Colors.white,
              shape:        BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
            ),
            child: const Icon(Icons.close, size: 16, color: Colors.black87),
          ),
        ),
      ),
    ];
  }

  Widget _handle(double cx, double cy, void Function(DragUpdateDetails) onPan) {
    return Positioned(
      left: cx - _kHandleHit / 2,
      top:  cy - _kHandleHit / 2,
      width:  _kHandleHit,
      height: _kHandleHit,
      child: GestureDetector(
        behavior:    HitTestBehavior.opaque,
        onPanUpdate: onPan,
        child: Center(
          child: Container(
            width: _kHandleVis, height: _kHandleVis,
            decoration: BoxDecoration(
              color:        Colors.white,
              borderRadius: BorderRadius.circular(2),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3)],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── painters ────────────────────────────────────────────────────────────────

class _BoxOverlayPainter extends CustomPainter {
  const _BoxOverlayPainter({required this.rect});
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    // Scrim with cutout
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)))
        ..fillType = PathFillType.evenOdd,
      scrim,
    );

    // Box border
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()
        ..color       = Colors.white
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Corner bracket marks (L-shapes)
    const arm   = 16.0;
    const thick = 3.0;
    final bp = Paint()
      ..color       = Colors.white
      ..style       = PaintingStyle.stroke
      ..strokeWidth = thick
      ..strokeCap   = StrokeCap.square;

    // TL
    canvas.drawLine(Offset(rect.left,  rect.top + arm), Offset(rect.left, rect.top),  bp);
    canvas.drawLine(Offset(rect.left,  rect.top),       Offset(rect.left + arm, rect.top), bp);
    // TR
    canvas.drawLine(Offset(rect.right - arm, rect.top), Offset(rect.right, rect.top),  bp);
    canvas.drawLine(Offset(rect.right, rect.top),        Offset(rect.right, rect.top + arm), bp);
    // BL
    canvas.drawLine(Offset(rect.left,  rect.bottom - arm), Offset(rect.left, rect.bottom), bp);
    canvas.drawLine(Offset(rect.left,  rect.bottom),        Offset(rect.left + arm, rect.bottom), bp);
    // BR
    canvas.drawLine(Offset(rect.right - arm, rect.bottom), Offset(rect.right, rect.bottom), bp);
    canvas.drawLine(Offset(rect.right, rect.bottom),        Offset(rect.right, rect.bottom - arm), bp);
  }

  @override
  bool shouldRepaint(_BoxOverlayPainter old) => old.rect != rect;
}

class _RipplePainter extends CustomPainter {
  const _RipplePainter({
    required this.center,
    required this.progress,
    required this.color,
  });

  final Offset center;
  final double progress;
  final Color  color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    final radius  = 20 + progress * 40;
    final opacity = (1.0 - progress).clamp(0.0, 1.0);

    canvas.drawCircle(
      center, radius,
      Paint()
        ..color = color.withValues(alpha: 0.18 * opacity)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center, radius,
      Paint()
        ..color       = color.withValues(alpha: opacity)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress || old.center != center;
}
