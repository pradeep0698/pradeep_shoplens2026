import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/analyze_request.dart';
import '../../data/models/product.dart';
import '../../data/sources/firebase/firestore_source.dart';
import '../../data/sources/remote/analyzer_api.dart';

/// Displays a captured video frame, lets the admin draw a bounding box,
/// identifies the product inside, and returns a [VideoAnnotation] on confirm.
class FrameAnnotatorScreen extends ConsumerStatefulWidget {
  const FrameAnnotatorScreen({
    super.key,
    required this.frameBytes,
    required this.timestamp,
  });

  final Uint8List frameBytes;
  final double    timestamp;

  @override
  ConsumerState<FrameAnnotatorScreen> createState() => _FrameAnnotatorScreenState();
}

class _FrameAnnotatorScreenState extends ConsumerState<FrameAnnotatorScreen> {
  int _imageWidth  = 1;
  int _imageHeight = 1;

  Offset? _boxStart;
  Offset? _boxEnd;
  Size?   _lastRenderSize;

  bool           _identifying = false;
  String?        _identifyError;
  List<Product>? _products;

  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadDimensions();
  }

  Future<void> _loadDimensions() async {
    final codec = await ui.instantiateImageCodec(widget.frameBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _imageWidth  = frame.image.width;
        _imageHeight = frame.image.height;
      });
    }
  }

  void _removePendingProduct(int index) {
    setState(() {
      _products!.removeAt(index);
      if (_products!.isEmpty) _products = null;
    });
  }

  Future<void> _identify() async {
    final box        = _normalizedBox();
    final renderSize = _lastRenderSize;
    if (box == null || renderSize == null) return;

    setState(() { _identifying = true; _identifyError = null; _products = null; });
    try {
      final cropped = await _cropImage(
        widget.frameBytes, box, renderSize,
        Size(_imageWidth.toDouble(), _imageHeight.toDouble()),
      );
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
              : 'No products found. Try a larger area.';
          _boxStart = null;
          _boxEnd   = null;
        });
      } else {
        setState(() {
          _products = response.products;
          _boxStart  = null;
          _boxEnd    = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _identifyError = e.toString());
    } finally {
      if (mounted) setState(() => _identifying = false);
    }
  }

  Rect? _normalizedBox() {
    if (_boxStart == null || _boxEnd == null) return null;
    final box = Rect.fromPoints(_boxStart!, _boxEnd!);
    if (box.width < 10 || box.height < 10) return null;
    return box;
  }

  Future<Uint8List> _cropImage(
    Uint8List bytes,
    Rect boxInRender,
    Size renderSize,
    Size imageSize,
  ) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = (await codec.getNextFrame()).image;

    final scaleX = imageSize.width  / renderSize.width;
    final scaleY = imageSize.height / renderSize.height;

    final srcRect = Rect.fromLTWH(
      (boxInRender.left   * scaleX).clamp(0, imageSize.width  - 1),
      (boxInRender.top    * scaleY).clamp(0, imageSize.height - 1),
      (boxInRender.width  * scaleX).clamp(1, imageSize.width),
      (boxInRender.height * scaleY).clamp(1, imageSize.height),
    );

    final recorder = ui.PictureRecorder();
    final canvas   = Canvas(recorder);
    canvas.drawImageRect(
      frame,
      srcRect,
      Rect.fromLTWH(0, 0, srcRect.width, srcRect.height),
      Paint(),
    );
    final picture    = recorder.endRecording();
    final croppedImg = await picture.toImage(
      srcRect.width.toInt().clamp(1, 4096),
      srcRect.height.toInt().clamp(1, 4096),
    );
    final byteData = await croppedImg.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw Exception('Image encoding failed (toByteData returned null)');
    return byteData.buffer.asUint8List();
  }

  String _fmtTime(double seconds) {
    final m  = (seconds ~/ 60).toString().padLeft(2, '0');
    final s  = (seconds % 60).toInt().toString().padLeft(2, '0');
    final ms = ((seconds % 1) * 10).toInt();
    return '$m:$s.$ms';
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _imageWidth / _imageHeight;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Annotate at ${_fmtTime(widget.timestamp)}',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
      ),
      body: Column(
        children: [
          // Frame image with bounding-box overlay
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxW = constraints.maxWidth;
                final maxH = constraints.maxHeight;

                double renderW, renderH;
                if (maxW / maxH > aspectRatio) {
                  renderH = maxH;
                  renderW = maxH * aspectRatio;
                } else {
                  renderW = maxW;
                  renderH = maxW / aspectRatio;
                }
                final renderSize = Size(renderW, renderH);

                return Center(
                  child: SizedBox(
                    width:  renderW,
                    height: renderH,
                    child: GestureDetector(
                      onPanStart: (d) => setState(() {
                        _lastRenderSize = renderSize;
                        _boxStart       = d.localPosition;
                        _boxEnd         = d.localPosition;
                        _products       = null;
                        _identifyError  = null;
                      }),
                      onPanUpdate: (d) => setState(() {
                        _lastRenderSize = renderSize;
                        _boxEnd         = d.localPosition;
                      }),
                      onPanEnd: (_) {
                        if (_normalizedBox() != null) _identify();
                      },
                      child: CustomPaint(
                        painter: _BoxPainter(_boxStart, _boxEnd),
                        child: Image.memory(widget.frameBytes, fit: BoxFit.fill),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Bottom panel: status / products / confirm
          Container(
            color: const Color(0xFF0F172A),
            padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).padding.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_identifying)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF34D399)),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Identifying product…',
                          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                        ),
                      ],
                    ),
                  ),

                if (_identifyError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _identifyError!,
                      style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
                    ),
                  ),

                if (_products != null && _products!.isNotEmpty) ...[
                  SizedBox(
                    height: 80,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount:       _products!.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final p = _products![i];
                        return Stack(
                          children: [
                            Container(
                              width: 180,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08)),
                              ),
                              child: Row(
                                children: [
                                  if (p.imageUrl.isNotEmpty)
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.network(
                                        p.imageUrl,
                                        width: 52, height: 52, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox(width: 52),
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment:  MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          p.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (p.price > 0)
                                          Text(
                                            '\$${p.price.toStringAsFixed(2)}',
                                            style: const TextStyle(
                                              color: Color(0xFF34D399),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
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
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(
                      VideoAnnotation(
                        timestamp: widget.timestamp,
                        products:  _products!,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF34D399),
                      foregroundColor: const Color(0xFF0F172A),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                    ),
                    child: const Text(
                      'Add to timeline',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
                if (!_identifying) ...[
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
                  if (_products == null)
                    Text(
                      _boxStart == null
                          ? 'Drag on the image to select a product'
                          : 'Box too small — drag a larger area',
                      style: const TextStyle(
                          color: Color(0xFF64748B), fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                ],
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
