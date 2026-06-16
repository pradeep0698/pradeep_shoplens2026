import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../data/models/product.dart';
import '../../data/sources/firebase/firestore_source.dart';

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    required this.fileName,
    this.annotations = const [],
  });

  final String                videoPath;
  final String                fileName;
  final List<VideoAnnotation> annotations;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller;
  bool          _initialized    = false;
  String?       _initError;
  List<Product> _currentProducts = [];

  @override
  void initState() {
    super.initState();
    _controller = _makeController(widget.videoPath);
    _controller.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((Object e) {
      if (mounted) setState(() { _initialized = true; _initError = e.toString(); });
    });
    _controller.addListener(_onVideoTick);
  }

  void _onVideoTick() {
    if (!mounted) return;
    final posSeconds = _controller.value.position.inMilliseconds / 1000.0;
    final next = _resolveProducts(posSeconds);
    // Only call setState when the product list actually changes.
    if (next.length != _currentProducts.length ||
        (next.isNotEmpty &&
            (next.first.productId != _currentProducts.firstOrNull?.productId))) {
      setState(() => _currentProducts = next);
    } else {
      setState(() {}); // still needed for seek slider updates
    }
  }

  /// Returns all products from annotations whose timestamp is ≤ [posSeconds].
  /// Collects from the latest "group" — all annotations within 1 second of
  /// the most recent one that has passed, so multiple boxes on the same frame
  /// are shown together.
  List<Product> _resolveProducts(double posSeconds) {
    if (widget.annotations.isEmpty) return [];

    // Find the latest annotation that has passed.
    double? latestPassed;
    for (final ann in widget.annotations) {
      if (ann.timestamp <= posSeconds + 0.05) {
        latestPassed = ann.timestamp;
      } else {
        break;
      }
    }
    if (latestPassed == null) return [];

    // Collect all annotations within 1 second of the latest passed timestamp.
    final products = <Product>[];
    for (final ann in widget.annotations) {
      if (ann.timestamp <= latestPassed + 1.0 &&
          ann.timestamp >= latestPassed - 1.0 &&
          ann.timestamp <= posSeconds + 0.05) {
        products.addAll(ann.products);
      }
    }
    return products;
  }

  static VideoPlayerController _makeController(String path) {
    // Web: image_picker returns a blob: URL; File is not available
    if (kIsWeb) {
      return VideoPlayerController.networkUrl(Uri.parse(path));
    }
    final uri = Uri.tryParse(path);
    // Any URI with a non-file scheme (content://, android.resource://, etc.)
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      return VideoPlayerController.contentUri(uri);
    }
    // file:// URI — convert to path first
    if (uri != null && uri.scheme == 'file') {
      return VideoPlayerController.file(File(uri.toFilePath()));
    }
    // Plain absolute path (most common on iOS and older Android)
    return VideoPlayerController.file(File(path));
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoTick);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _controller.value.isPlaying;
    final position  = _controller.value.position;
    final duration  = _controller.value.duration;
    final hasAnnotations = widget.annotations.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.fileName,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          // Video
          Expanded(
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
                      ? AspectRatio(
                          aspectRatio: _controller.value.aspectRatio,
                          child: VideoPlayer(_controller),
                        )
                      : const CircularProgressIndicator(color: Color(0xFF34D399)),
            ),
          ),

          // Timestamped products panel (only shown when annotations exist)
          if (hasAnnotations)
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              constraints: const BoxConstraints(maxHeight: 140),
              color: const Color(0xFF0A1628),
              child: _currentProducts.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                          child: Text(
                            'NOW SHOWING',
                            style: TextStyle(
                              color: Color(0xFF34D399),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 96,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                            child: Row(
                              children: [
                                for (int i = 0; i < _currentProducts.length; i++) ...[
                                  if (i > 0) const SizedBox(width: 10),
                                  _buildProductCard(_currentProducts[i]),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),

          // Controls
          Container(
            padding: EdgeInsets.fromLTRB(
              16, 12, 16,
              MediaQuery.of(context).padding.bottom + 16,
            ),
            color: const Color(0xFF0F172A),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Seek slider
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor:   const Color(0xFF34D399),
                    inactiveTrackColor: const Color(0xFF1E293B),
                    thumbColor:         const Color(0xFF34D399),
                    overlayColor:       const Color(0xFF34D399).withValues(alpha: 0.2),
                    trackHeight:        3,
                  ),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: _initialized
                        ? (v) => _controller.seekTo(
                              Duration(milliseconds: (v * duration.inMilliseconds).round()),
                            )
                        : null,
                  ),
                ),
                Row(
                  children: [
                    Text(_fmt(position), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                    const Spacer(),
                    Text(_fmt(duration), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _initialized
                        ? () => isPlaying ? _controller.pause() : _controller.play()
                        : null,
                    icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, size: 20),
                    label: Text(isPlaying ? 'Pause' : 'Play'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF94A3B8),
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProductCard(Product p) {
    final hasBuyUrl = p.purchaseUrl != null && p.purchaseUrl!.isNotEmpty;
    return GestureDetector(
      onTap: hasBuyUrl
          ? () => launchUrl(Uri.parse(p.purchaseUrl!),
                mode: LaunchMode.externalApplication)
          : null,
      child: Container(
        width: 200,
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasBuyUrl
                ? const Color(0xFF34D399).withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            if (p.imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(12)),
                child: Image.network(
                  p.imageUrl,
                  width: 68,
                  height: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(width: 68),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
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
                    if (p.price > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '\$${p.price.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (hasBuyUrl)
                      const Text(
                        'Tap to buy →',
                        style: TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
