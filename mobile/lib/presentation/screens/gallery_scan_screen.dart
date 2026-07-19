import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/vision_service.dart';
import '../../core/utils/image_utils.dart';
import '../providers/scan_review_provider.dart';
import '../widgets/info_tooltip_icon.dart';
import '../widgets/object_glow_overlay.dart';
import 'scan_review_screen.dart' show ScanReviewArgs;

/// Gallery Scan All, phases 1-3: auto-detects every object in the picked
/// image via /detect, overlays a glowing dot per object over the image,
/// lets the user tap dots to build a multi-select, then dispatches parallel
/// /identify calls for the selection (reusing [ScanReviewNotifier]) and
/// transitions immediately to the results screen.
class GalleryScanScreen extends ConsumerStatefulWidget {
  const GalleryScanScreen({super.key, required this.args});
  final ScanReviewArgs args;

  @override
  ConsumerState<GalleryScanScreen> createState() => _GalleryScanScreenState();
}

class _GalleryScanScreenState extends ConsumerState<GalleryScanScreen> {
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
    Future.microtask(() => ref.read(scanReviewProvider.notifier).detectOnDevice(
          widget.args.imageBytes,
          widget.args.imagePath!,
        ));
  }

  Future<void> _loadImageSize() async {
    final codec = await ui.instantiateImageCodec(widget.args.imageBytes);
    final frame = await codec.getNextFrame();
    final size  = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    if (mounted) setState(() => _imageSize = size);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(scanReviewProvider);
    final imageSize = _imageSize;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tap objects to scan'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => context.pop(),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: InfoTooltipIcon(
              message: 'Tap a glowing dot to select it. Missed an item? Tap or draw '
                  'a circle around it anywhere on the photo to add your own point.',
            ),
          ),
        ],
      ),
      body: switch (state.phase) {
        ScanReviewPhase.detecting => const _LoadingBody(),
        ScanReviewPhase.error => _ErrorBody(message: state.errorMessage ?? 'Detection failed'),
        ScanReviewPhase.ready => imageSize == null
            ? const _LoadingBody()
            : _ReadyBody(state: state, imageBytes: widget.args.imageBytes, imageSize: imageSize),
      },
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF34D399)),
            SizedBox(height: 16),
            Text('Detecting objects…', style: TextStyle(color: Color(0xFF64748B))),
          ],
        ),
      );
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFF87171), size: 48),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: Color(0xFFF87171), fontSize: 14), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go back', style: TextStyle(color: Color(0xFF34D399))),
              ),
            ],
          ),
        ),
      );
}

class _ReadyBody extends ConsumerWidget {
  const _ReadyBody({required this.state, required this.imageBytes, required this.imageSize});
  final ScanReviewState state;
  final Uint8List imageBytes;
  final Size imageSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = [
      for (var i = 0; i < state.items.length; i++)
        VisionLabel(
          // Always "Item N" by position — never the detector's own label,
          // which is inconsistent across runs (ML Kit's on-device labels in
          // particular vary run to run for the same object).
          description: 'Item ${i + 1}',
          score: 1.0,
          boundingBox: state.items[i].box != null ? geminiBoxToNormalizedRect(state.items[i].box!) : null,
        ),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Text(
            state.items.isEmpty
                ? 'No objects detected — tap or draw around an item on the photo to add one'
                : 'Tap a dot to select it, or tap/draw anywhere else to add a missed item',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: const Color(0xFF1E293B)),
                      Image.memory(imageBytes, fit: BoxFit.contain, width: double.infinity, height: double.infinity),
                      ObjectGlowOverlay(
                        objects:         labels,
                        imageSize:       imageSize,
                        widgetSize:      widgetSize,
                        boxFit:          BoxFit.contain,
                        selectedIndices: state.selected,
                        // Purely visual here — tap handling for both dots and
                        // empty-area points is centralized in
                        // _InteractionLayer below, which owns the single
                        // gesture detector covering the whole image.
                        onObjectTap:     null,
                        showLabels:      false,
                      ),
                      _InteractionLayer(
                        items:      state.items,
                        imageSize:  imageSize,
                        widgetSize: widgetSize,
                        onToggleDot: (i) => ref.read(scanReviewProvider.notifier).toggleSelect(i),
                        onAddPoint: (widgetRect) {
                          final box = widgetRectToGeminiBox(widgetRect, imageSize, widgetSize, BoxFit.contain);
                          ref.read(scanReviewProvider.notifier).addManualItem(box, imageBytes);
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: state.selected.isEmpty
                    ? null
                    : () {
                        ref.read(scanReviewProvider.notifier).searchSelected();
                        context.push('/gallery-scan-results');
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF34D399),
                  foregroundColor: const Color(0xFF0F172A),
                  disabledBackgroundColor: const Color(0xFF334155),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                ),
                child: Text(
                  state.selected.isEmpty
                      ? 'Tap objects to select'
                      : 'Scan All (${state.selected.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Single gesture layer covering the whole image, on top of everything else
/// in the Stack — owns every touch instead of splitting tap-vs-empty-area
/// handling across sibling widgets and hoping Flutter's Stack hit-test
/// fallthrough sorts it out (that approach proved unreliable in practice).
/// On pointer-down it decides, in plain code, whether the touch landed near
/// an existing dot (toggle it) or not (track it as a candidate new point):
/// a quick tap adds a fixed-size box centered on the tap; dragging a
/// circle/lasso/line around an item adds its bounding box instead.
class _InteractionLayer extends StatefulWidget {
  const _InteractionLayer({
    required this.items,
    required this.imageSize,
    required this.widgetSize,
    required this.onToggleDot,
    required this.onAddPoint,
  });
  final List<DetectedItem> items;
  final Size imageSize;
  final Size widgetSize;
  final void Function(int index) onToggleDot;
  final void Function(Rect widgetRect) onAddPoint;

  @override
  State<_InteractionLayer> createState() => _InteractionLayerState();
}

class _InteractionLayerState extends State<_InteractionLayer> {
  final List<Offset> _points = [];
  int? _pendingDotIndex;

  // Matches the ~44px comfortable touch target ObjectGlowOverlay's own
  // (now-unused-for-taps) dot detectors used.
  static const _dotTapRadius = 24.0;
  // A drag shorter than this in either dimension is treated as a plain tap
  // rather than a deliberately drawn area.
  static const _dragThreshold = 20.0;

  double get _tapBoxSize => (widget.widgetSize.shortestSide * 0.14).clamp(56.0, 130.0);

  int? _dotNear(Offset point) {
    for (var i = 0; i < widget.items.length; i++) {
      final box = widget.items[i].box;
      if (box == null) continue;
      final center = normalizedToWidget(
        geminiBoxToNormalizedRect(box), widget.imageSize, widget.widgetSize, BoxFit.contain,
      ).center;
      if ((center - point).distance <= _dotTapRadius) return i;
    }
    return null;
  }

  // onPanDown (not onPanStart) fires on every pointer-down inside these
  // bounds, drag or not — it's the only callback guaranteed to fire for a
  // plain tap that never moves past the pan gesture's touch-slop. Deciding
  // dot-vs-empty-area right here means the decision doesn't depend on how
  // far (if at all) the finger later moves.
  void _onPanDown(DragDownDetails d) {
    _pendingDotIndex = _dotNear(d.localPosition);
    setState(() {
      _points
        ..clear()
        ..add(d.localPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) => setState(() => _points.add(d.localPosition));

  void _onPanEnd(DragEndDetails d) {
    final dotIndex = _pendingDotIndex;
    if (dotIndex != null) {
      widget.onToggleDot(dotIndex);
    } else if (_points.isNotEmpty) {
      var minX = _points.first.dx, maxX = _points.first.dx;
      var minY = _points.first.dy, maxY = _points.first.dy;
      for (final p in _points) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
      var rect = Rect.fromLTRB(minX, minY, maxX, maxY);
      if (rect.width < _dragThreshold || rect.height < _dragThreshold) {
        rect = Rect.fromCenter(center: rect.center, width: _tapBoxSize, height: _tapBoxSize);
      }
      widget.onAddPoint(rect);
    }
    _pendingDotIndex = null;
    setState(() => _points.clear());
  }

  void _onPanCancel() {
    _pendingDotIndex = null;
    setState(() => _points.clear());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanDown: _onPanDown,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onPanCancel: _onPanCancel,
      child: CustomPaint(
        size: Size.infinite,
        // No path preview while dragging out of an existing dot — that
        // gesture just toggles selection, nothing to draw.
        painter: _pendingDotIndex == null ? _DrawPathPainter(points: _points) : null,
      ),
    );
  }
}

class _DrawPathPainter extends CustomPainter {
  const _DrawPathPainter({required this.points});
  final List<Offset> points;

  static const _kGreen = Color(0xFF34D399);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color       = _kGreen
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap   = StrokeCap.round
        ..strokeJoin  = StrokeJoin.round,
    );

    var minX = points.first.dx, maxX = points.first.dx;
    var minY = points.first.dy, maxY = points.first.dy;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    canvas.drawRect(
      Rect.fromLTRB(minX, minY, maxX, maxY),
      Paint()
        ..color       = _kGreen.withValues(alpha: 0.5)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_DrawPathPainter old) => old.points != points;
}
