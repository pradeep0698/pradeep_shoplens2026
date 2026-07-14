import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/vision_service.dart';
import '../../core/utils/image_utils.dart';
import '../providers/scan_review_provider.dart';
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
    Future.microtask(() => ref.read(scanReviewProvider.notifier).detect(
          widget.args.imageBytes,
          widget.args.mime,
          mlkitContext: widget.args.mlkitContext,
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
    if (state.items.isEmpty) {
      return const Center(
        child: Text('No objects detected', style: TextStyle(color: Color(0xFF64748B))),
      );
    }

    final labels = [
      for (final item in state.items)
        VisionLabel(
          description: item.name,
          score: 1.0,
          boundingBox: item.box != null ? geminiBoxToNormalizedRect(item.box!) : null,
        ),
    ];

    return Column(
      children: [
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
                        onObjectTap:     (i) => ref.read(scanReviewProvider.notifier).toggleSelect(i),
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
