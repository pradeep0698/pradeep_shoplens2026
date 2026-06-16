import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/utils/video_fingerprint.dart';
import '../../core/utils/video_frame_capture.dart';
import '../../data/models/analyze_request.dart';
import '../../data/models/product.dart';
import '../../data/sources/firebase/firestore_source.dart';
import '../../data/sources/remote/analyzer_api.dart';

/// Admin annotation tool.
/// Pause the video, drag to draw a bounding box directly on the frame,
/// and the selected crop is sent to /identify. Confirmed results are
/// collected as pending annotations and saved to Firestore in one batch.
class AdminAnnotatorScreen extends ConsumerStatefulWidget {
  const AdminAnnotatorScreen({
    super.key,
    required this.fileName,
    required this.videoPath,
    this.initialAnnotations = const [],
  });

  final String                fileName;
  final String                videoPath;
  final List<VideoAnnotation> initialAnnotations;

  @override
  ConsumerState<AdminAnnotatorScreen> createState() =>
      _AdminAnnotatorScreenState();
}

class _AdminAnnotatorScreenState
    extends ConsumerState<AdminAnnotatorScreen> {
  late final VideoPlayerController _controller;
  final _repaintKey = GlobalKey();

  bool    _initialized = false;
  String? _initError;
  bool    _saving      = false;
  String? _saveError;

  // Bounding-box drawing
  Offset? _boxStart;
  Offset? _boxEnd;
  Size?   _lastRenderSize;

  // Identification
  bool           _analyzing       = false;
  String?        _identifyError;
  List<Product>? _pendingProducts;
  double?        _pendingTimestamp;

  final TextEditingController _queryController = TextEditingController();

  late List<VideoAnnotation> _annotations;

  @override
  void initState() {
    super.initState();
    _annotations = List.from(widget.initialAnnotations);
    _controller  = _makeController(widget.videoPath);
    _controller.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((Object e) {
      if (mounted) setState(() { _initialized = true; _initError = e.toString(); });
    });
    _controller.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  static VideoPlayerController _makeController(String path) {
    if (kIsWeb) return VideoPlayerController.networkUrl(Uri.parse(path));
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      return VideoPlayerController.contentUri(uri);
    }
    if (uri != null && uri.scheme == 'file') {
      return VideoPlayerController.file(File(uri.toFilePath()));
    }
    return VideoPlayerController.file(File(path));
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    _queryController.dispose();
    super.dispose();
  }

  // ── Crop + identify ────────────────────────────────────────────────────────

  Future<void> _identifyBox(Rect boxInRender, Size renderSize) async {
    setState(() {
      _analyzing      = true;
      _identifyError  = null;
      _pendingProducts = null;
    });
    _pendingTimestamp =
        _controller.value.position.inMilliseconds / 1000.0;

    try {
      final frameBytes = await captureFrame(_repaintKey);
      if (frameBytes == null) throw Exception('Could not capture frame.');

      final cropped  = await _cropImage(frameBytes, boxInRender, renderSize);
      final q = _queryController.text.trim();
      final response = await ref.read(analyzerApiProvider).identifyCrop(
        AnalyzeRequest(
          imageData:     base64Encode(cropped),
          imageMimeType: 'image/png',
          ignoreTerms:   const [],
          query:         q.isEmpty ? null : q,
        ),
      );

      if (!mounted) return;
      if (response.products.isEmpty) {
        final detected =
            response.items.where((s) => s.isNotEmpty).join(', ');
        setState(() {
          _identifyError = detected.isNotEmpty
              ? 'No matching products. Detected: "$detected". Try a different area.'
              : 'No products found. Try a different area.';
          _boxStart = null;
          _boxEnd   = null;
        });
      } else {
        setState(() {
          _pendingProducts = response.products;
          _boxStart        = null;
          _boxEnd          = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _identifyError = e.toString());
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<Uint8List> _cropImage(
    Uint8List frameBytes,
    Rect boxInRender,
    Size renderSize,
  ) async {
    final codec = await ui.instantiateImageCodec(frameBytes);
    final image = (await codec.getNextFrame()).image;

    final scaleX = image.width  / renderSize.width;
    final scaleY = image.height / renderSize.height;

    final src = Rect.fromLTWH(
      (boxInRender.left   * scaleX).clamp(0, image.width  - 1),
      (boxInRender.top    * scaleY).clamp(0, image.height - 1),
      (boxInRender.width  * scaleX).clamp(1, image.width.toDouble()),
      (boxInRender.height * scaleY).clamp(1, image.height.toDouble()),
    );

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
        image, src, Rect.fromLTWH(0, 0, src.width, src.height), Paint());
    final cropped  = await recorder
        .endRecording()
        .toImage(src.width.toInt().clamp(1, 4096),
                 src.height.toInt().clamp(1, 4096));
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw Exception('Image encoding failed (toByteData returned null)');
    return byteData.buffer.asUint8List();
  }

  void _removePendingProduct(int index) {
    setState(() {
      _pendingProducts!.removeAt(index);
      if (_pendingProducts!.isEmpty) {
        _pendingProducts  = null;
        _pendingTimestamp = null;
      }
    });
  }

  void _addPendingToList() {
    if (_pendingProducts == null || _pendingTimestamp == null) return;
    setState(() {
      _annotations = [
        ..._annotations,
        VideoAnnotation(
            timestamp: _pendingTimestamp!,
            products:  _pendingProducts!),
      ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _pendingProducts  = null;
      _pendingTimestamp = null;
      _boxStart         = null;
      _boxEnd           = null;
    });
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_annotations.isEmpty) return;
    setState(() { _saving = true; _saveError = null; });
    try {
      final uid         = FirebaseAuth.instance.currentUser?.uid ?? '';
      final source      = ref.read(firestoreSourceProvider);
      final fingerprint = await videoFingerprint(widget.videoPath);
      await source.initVideoAnnotationsDoc(widget.fileName, uid, fingerprint: fingerprint);
      await source.saveVideoAnnotations(widget.fileName, _annotations);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_annotations.length} annotation(s) saved!')));
        setState(() { _boxStart = null; _boxEnd = null; });
      }
    } catch (e) {
      if (mounted) setState(() => _saveError = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtSec(double s) {
    final m  = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toInt().toString().padLeft(2, '0');
    final ms = ((s % 1) * 10).toInt();
    return '$m:$ss.$ms';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isPlaying = _controller.value.isPlaying;
    final position  = _controller.value.position;
    final duration  = _controller.value.duration;
    final canDraw   = _initialized && !isPlaying && !_analyzing;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.fileName,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            overflow: TextOverflow.ellipsis),
        actions: [
          if (_annotations.isNotEmpty)
            TextButton(
              onPressed: _saving ? null : _save,
              child: Text(
                _saving
                    ? 'Saving…'
                    : 'Save (${_annotations.length})',
                style: const TextStyle(
                    color: Color(0xFF34D399),
                    fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Video + bounding-box overlay ─────────────────────────────────
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: Center(
                child: _initError != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Failed to load video: $_initError',
                          style: const TextStyle(color: Color(0xFFF87171), fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : _initialized
                    ? LayoutBuilder(builder: (context, constraints) {
                        final aspect = _controller.value.aspectRatio;
                        final maxW   = constraints.maxWidth;
                        final maxH   = constraints.maxHeight;

                        double renderW, renderH;
                        if (maxW / maxH > aspect) {
                          renderH = maxH;
                          renderW = maxH * aspect;
                        } else {
                          renderW = maxW;
                          renderH = maxW / aspect;
                        }
                        final renderSize = Size(renderW, renderH);

                        return SizedBox(
                          width:  renderW,
                          height: renderH,
                          child: Stack(
                            children: [
                              // Video frame (captured via RepaintBoundary)
                              RepaintBoundary(
                                key: _repaintKey,
                                child: AspectRatio(
                                  aspectRatio: aspect,
                                  child: VideoPlayer(_controller),
                                ),
                              ),

                              // Bounding-box gesture layer — only when paused
                              if (canDraw)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanStart: (d) => setState(() {
                                      _lastRenderSize   = renderSize;
                                      _boxStart         = d.localPosition;
                                      _boxEnd           = d.localPosition;
                                      _pendingProducts  = null;
                                      _identifyError    = null;
                                    }),
                                    onPanUpdate: (d) => setState(() {
                                      _lastRenderSize = renderSize;
                                      _boxEnd         = d.localPosition;
                                    }),
                                    onPanEnd: (_) {
                                      final s  = _boxStart;
                                      final e  = _boxEnd;
                                      final rs = _lastRenderSize;
                                      if (s == null || e == null ||
                                          rs == null) { return; }
                                      final box = Rect.fromPoints(s, e);
                                      if (box.width > 10 &&
                                          box.height > 10) {
                                        _identifyBox(box, rs);
                                      }
                                    },
                                    child: CustomPaint(
                                      painter:
                                          _BoxPainter(_boxStart, _boxEnd),
                                    ),
                                  ),
                                ),

                              // Analyzing spinner
                              if (_analyzing)
                                Positioned.fill(
                                  child: Container(
                                    color: Colors.black
                                        .withValues(alpha: 0.45),
                                    child: const Center(
                                      child: CircularProgressIndicator(
                                          color: Color(0xFF34D399)),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      })
                    : const CircularProgressIndicator(
                        color: Color(0xFF34D399)),
              ),
            ),
          ),

          // ── Controls ────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            color: const Color(0xFF0F172A),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor:   const Color(0xFF34D399),
                    inactiveTrackColor: const Color(0xFF1E293B),
                    thumbColor:         const Color(0xFF34D399),
                    trackHeight:        3,
                  ),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? (position.inMilliseconds /
                                duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: _initialized && _initError == null
                        ? (v) => _controller.seekTo(Duration(
                              milliseconds: (v * duration.inMilliseconds)
                                  .round()))
                        : null,
                  ),
                ),
                Row(
                  children: [
                    Text(_fmt(position),
                        style: const TextStyle(
                            color: Color(0xFF64748B), fontSize: 12)),
                    const Spacer(),
                    Text(_fmt(duration),
                        style: const TextStyle(
                            color: Color(0xFF64748B), fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _initialized && _initError == null
                        ? () {
                            if (isPlaying) {
                              _controller.pause();
                            } else {
                              setState(() { _boxStart = null; _boxEnd = null; });
                              _controller.play();
                            }
                          }
                        : null,
                    icon: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 20),
                    label: Text(isPlaying ? 'Pause' : 'Play'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF94A3B8),
                      side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.15)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                      padding:
                          const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isPlaying
                      ? 'Pause the video, then drag on it to box a product.'
                      : _analyzing
                          ? 'Identifying…'
                          : 'Drag on the video to draw a box around a product.',
                  style: const TextStyle(
                      color: Color(0xFF64748B), fontSize: 11),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _queryController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Optional: describe what you\'re looking for',
                    hintStyle: const TextStyle(
                        color: Color(0xFF475569), fontSize: 13),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          // ── Identify error ───────────────────────────────────────────────
          if (_identifyError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(_identifyError!,
                  style: const TextStyle(
                      color: Color(0xFFF87171), fontSize: 12)),
            ),

          // ── Pending results ──────────────────────────────────────────────
          if (_pendingProducts != null && _pendingProducts!.isNotEmpty)
            Container(
              color: const Color(0xFF0A1628),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Found at ${_fmtSec(_pendingTimestamp ?? 0)}',
                        style: const TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: _addPendingToList,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF34D399),
                          foregroundColor: const Color(0xFF0F172A),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20)),
                        ),
                        child: const Text('Add to timeline',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount:       _pendingProducts!.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final p = _pendingProducts![i];
                        return Stack(
                          children: [
                            Container(
                              width: 170,
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: const Color(0xFF34D399)
                                        .withValues(alpha: 0.35)),
                              ),
                              child: Row(
                                children: [
                                  if (p.imageUrl.isNotEmpty)
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.network(
                                        p.imageUrl,
                                        width: 44, height: 44,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox(width: 44),
                                      ),
                                    ),
                                  const SizedBox(width: 7),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(p.name,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600),
                                            maxLines: 2,
                                            overflow:
                                                TextOverflow.ellipsis),
                                        if (p.price > 0)
                                          Text(
                                            '\$${p.price.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                                color: Color(0xFF34D399),
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              top: 2, right: 2,
                              child: GestureDetector(
                                onTap: () => _removePendingProduct(i),
                                child: const Icon(
                                  Icons.close,
                                  size: 14,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

          // ── Save error ───────────────────────────────────────────────────
          if (_saveError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(_saveError!,
                  style: const TextStyle(
                      color: Color(0xFFF87171), fontSize: 12)),
            ),

          // ── Annotations list ─────────────────────────────────────────────
          Expanded(
            flex: 2,
            child: _annotations.isEmpty
                ? const Center(
                    child: Text(
                      'No annotations yet.\nPause and drag on the video to start.',
                      style: TextStyle(
                          color: Color(0xFF475569), fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'SAVED ANNOTATIONS',
                          style: TextStyle(
                            color: Color(0xFF34D399),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              16, 0, 16, 16),
                          itemCount: _annotations.length,
                          itemBuilder: (_, i) {
                            final ann = _annotations[i];
                            return Container(
                              margin:
                                  const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius:
                                    BorderRadius.circular(12),
                                border: Border.all(
                                    color: Colors.white
                                        .withValues(alpha: 0.08)),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    _fmtSec(ann.timestamp),
                                    style: const TextStyle(
                                      color: Color(0xFF34D399),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      ann.products
                                          .map((p) => p.name)
                                          .join(', '),
                                      style: const TextStyle(
                                          color: Color(0xFF94A3B8),
                                          fontSize: 12),
                                      maxLines: 1,
                                      overflow:
                                          TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close,
                                        size: 16,
                                        color: Color(0xFF64748B)),
                                    onPressed: () => setState(
                                        () => _annotations.removeAt(i)),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.start, this.end);
  final Offset? start;
  final Offset? end;

  @override
  void paint(Canvas canvas, Size size) {
    if (start == null || end == null) return;
    final rect = Rect.fromPoints(start!, end!);
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF34D399).withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF34D399)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.start != start || old.end != end;
}
