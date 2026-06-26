import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import '../../core/services/mlkit_detector_service.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/tap_crop_utils.dart';
import '../providers/pipeline_provider.dart';
import '../widgets/info_tooltip_icon.dart';
import '../widgets/object_glow_overlay.dart';
import '../widgets/zoom_slider.dart';

class LiveScanScreen extends ConsumerStatefulWidget {
  const LiveScanScreen({super.key});

  @override
  ConsumerState<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends ConsumerState<LiveScanScreen>
    with WidgetsBindingObserver {
  CameraController? _cam;
  final _detector = MlKitDetectorService();
  List<DetectedObject> _liveObjects = [];
  bool _processing = false;
  bool _initialized = false;
  String? _error;
  CameraDescription? _wideDescription;
  CameraDescription? _ultraWideDescription;
  bool _usingUltraWide = false;
  bool _switchingLens = false;

  double _zoom = 1.0;
  double _logicalMinZoom = 1.0;
  double _logicalMaxZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _baseZoom = 1.0;

  // Hardware often reports an absolute digital-zoom ceiling well past the
  // point of a usable image (some phones report >100x). Cap the UI/pinch
  // range to something actually useful, like native camera apps do.
  static const double _kMaxUsableZoom = 10.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _detector.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      cam.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final backCameras = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();
      if (backCameras.isEmpty) {
        setState(() => _error = 'No camera found on this device');
        return;
      }

      final wide = backCameras.firstWhere(
        (c) => c.lensType == CameraLensType.wide,
        orElse: () => backCameras.first,
      );
      CameraDescription? ultraWide;
      for (final c in backCameras) {
        if (c.lensType == CameraLensType.ultraWide) {
          ultraWide = c;
          break;
        }
      }

      final ctrl = await _buildController(wide);
      if (!mounted) return;

      final minZoom = await ctrl.getMinZoomLevel();
      final maxZoom = await ctrl.getMaxZoomLevel();

      setState(() {
        _cam = ctrl;
        _initialized = true;
        _wideDescription = wide;
        _ultraWideDescription = ultraWide;
        _usingUltraWide = false;
        _zoom = 1.0;
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _logicalMinZoom = ultraWide != null ? 0.5 : minZoom;
        _logicalMaxZoom = maxZoom > _kMaxUsableZoom ? _kMaxUsableZoom : maxZoom;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<CameraController> _buildController(CameraDescription description) async {
    final ctrl = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    await ctrl.initialize();
    await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
    ctrl.startImageStream(_onFrame);
    return ctrl;
  }

  Future<void> _switchLens(bool toUltraWide) async {
    final cam = _cam;
    final target = toUltraWide ? _ultraWideDescription : _wideDescription;
    if (cam == null || target == null) return;
    _switchingLens = true;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
      await cam.setDescription(target);
      await cam.lockCaptureOrientation(DeviceOrientation.portraitUp);
      final minZoom = await cam.getMinZoomLevel();
      final maxZoom = await cam.getMaxZoomLevel();
      cam.startImageStream(_onFrame);
      if (mounted) {
        setState(() {
          _usingUltraWide = toUltraWide;
          _minZoom = minZoom;
          _maxZoom = maxZoom;
        });
      }
    } finally {
      _switchingLens = false;
    }
  }

  void _onFrame(CameraImage img) async {
    if (_processing || _cam == null) return;
    _processing = true;
    try {
      final rotation = _sensorRotation(_cam!.description.sensorOrientation);
      final objects = await _detector.detectFromCameraImage(
        img, rotation, _cam!.description.lensDirection,
      );
      if (mounted) setState(() => _liveObjects = objects);
    } catch (_) {
      // Silently drop frame errors — next frame will retry
    } finally {
      _processing = false;
    }
  }

  bool _wantsUltraWide(double zoom) {
    if (_ultraWideDescription == null) return false;
    // Hysteresis band around the 1.0x boundary so pinch jitter doesn't
    // repeatedly re-trigger a lens switch.
    return _usingUltraWide ? zoom < 1.05 : zoom < 0.95;
  }

  Future<void> _setZoom(double level) async {
    if (_cam == null || _switchingLens) return;
    final clamped = level.clamp(_logicalMinZoom, _logicalMaxZoom);
    if ((clamped - _zoom).abs() < 0.01) return;

    final shouldUseUltraWide = _wantsUltraWide(clamped);
    if (shouldUseUltraWide != _usingUltraWide) {
      await _switchLens(shouldUseUltraWide);
    }

    final cam = _cam;
    if (cam == null) return;
    // Ultra-wide's own zoomFactor 1.0 == displayed 0.5x; displayed 1.0x ==
    // ultra-wide factor 2.0 just before handing off to the wide lens.
    final localFactor = shouldUseUltraWide ? clamped / 0.5 : clamped;
    await cam.setZoomLevel(localFactor.clamp(_minZoom, _maxZoom));
    if (mounted) setState(() => _zoom = clamped);
  }

  InputImageRotation _sensorRotation(int sensorDegrees) {
    return switch (sensorDegrees) {
      90  => InputImageRotation.rotation90deg,
      180 => InputImageRotation.rotation180deg,
      270 => InputImageRotation.rotation270deg,
      _   => InputImageRotation.rotation0deg,
    };
  }

  Future<void> _freezeAndIdentify({DetectedObject? tappedObject}) async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;

    try {
      await cam.stopImageStream();
      final file  = await cam.takePicture();
      final bytes = await file.readAsBytes();

      Uint8List imageBytes = bytes;
      String    mime       = getMimeType(file.path);

      if (tappedObject != null) {
        // Compute portrait stream size (swap W/H if sensor gives landscape dims)
        final preview = cam.value.previewSize ?? const Size(1080, 1920);
        final portraitSize = preview.width > preview.height
            ? Size(preview.height, preview.width)
            : preview;

        final cropped = await cropToMlKitBox(
          bytes,
          tappedObject.boundingBox,
          portraitSize,
        );
        if (cropped != null) {
          imageBytes = cropped;
          mime       = 'image/png';
        }
      }

      await ref.read(pipelineProvider.notifier).setImage(imageBytes, mime, fromLiveScan: true);
      if (mounted) context.go('/main');
      // Auto-start analysis so the user doesn't need to press Scan Image
      ref.read(pipelineProvider.notifier).analyzeLoaded();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
      // Restart stream so the user can retry
      cam.startImageStream(_onFrame);
    }
  }

  Future<void> _freezeAndIdentifyObject(DetectedObject obj) async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized) return;

    try {
      await cam.stopImageStream();
      final file  = await cam.takePicture();
      final bytes = await file.readAsBytes();

      // Get the actual captured image dimensions
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final imgW  = frame.image.width.toDouble();
      final imgH  = frame.image.height.toDouble();
      frame.image.dispose();

      // ML Kit bbox is in portrait camera-stream space; scale to captured image
      final preview = cam.value.previewSize ?? const Size(1080, 1920);
      final streamW = preview.width  > preview.height ? preview.height : preview.width;
      final streamH = preview.width  > preview.height ? preview.width  : preview.height;

      final box = obj.boundingBox;
      final scaledRect = Rect.fromLTRB(
        box.left   * imgW / streamW,
        box.top    * imgH / streamH,
        box.right  * imgW / streamW,
        box.bottom * imgH / streamH,
      );

      final cropped = await TapCropUtils.cropRect(
        imageBytes: bytes,
        rect:       scaledRect,
        imageSize:  Size(imgW, imgH),
      );

      // analyzeImage sets state to `analyzing` synchronously before its first
      // await, so the progress indicator is visible the moment /main renders.
      ref.read(pipelineProvider.notifier).analyzeImage(cropped, 'image/png');
      if (mounted) context.go('/main');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
      cam.startImageStream(_onFrame);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _ErrorView(message: _error!);
    if (!_initialized || _cam == null) return const _LoadingView();

    final cam = _cam!;
    final previewSize = cam.value.previewSize ?? const Size(1080, 1920);

    // Camera preview is always portrait — swap W/H if sensor gives landscape dims
    final cameraSize = previewSize.width > previewSize.height
        ? Size(previewSize.height, previewSize.width)
        : previewSize;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          Center(child: CameraPreview(cam)),

          // Full-screen pinch-to-zoom capture layer. Kept separate from
          // CameraPreview because CameraPreview letterboxes to the sensor's
          // aspect ratio, which would otherwise shrink the gesture hit area
          // to less than the full screen.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => _baseZoom = _zoom,
              onScaleUpdate: (details) {
                if (details.pointerCount < 2) return;
                _setZoom(_baseZoom * details.scale);
              },
            ),
          ),

          // ML Kit real-time glow overlay
          if (_liveObjects.isNotEmpty)
            LayoutBuilder(
              builder: (_, constraints) => LiveObjectGlowOverlay(
                objects:     _liveObjects,
                previewSize: cameraSize,
                screenSize:  Size(constraints.maxWidth, constraints.maxHeight),
                onObjectTap: (obj) => _freezeAndIdentify(tappedObject: obj),
              ),
            ),

          // Top bar with back button
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                  onPressed: () => context.pop(),
                ),
              ),
            ),
          ),

          // Object count badge
          if (_liveObjects.isNotEmpty)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 16, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF34D399).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF34D399), width: 1),
                    ),
                    child: Text(
                      '${_liveObjects.length} object${_liveObjects.length != 1 ? 's' : ''}',
                      style: const TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Zoom slider — a small vertical bar docked on the side rather
          // than a bar spanning the camera preview.
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ZoomSlider(
                currentZoom: _zoom,
                minZoom: _logicalMinZoom,
                maxZoom: _logicalMaxZoom,
                onZoomChanged: _setZoom,
              ),
            ),
          ),

          // Identify button
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _freezeAndIdentify(),
                      icon: const Icon(Icons.center_focus_strong, size: 20),
                      label: const Text(
                        'Scan All',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF34D399),
                        foregroundColor: const Color(0xFF0F172A),
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(32),
                        ),
                        elevation: 6,
                        shadowColor: const Color(0xFF34D399).withValues(alpha: 0.4),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const InfoTooltipIcon(
                      message: 'Scan All identifies all objects marked with dots.',
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Color(0xFF34D399)),
          SizedBox(height: 16),
          Text('Starting camera…', style: TextStyle(color: Color(0xFF64748B))),
        ],
      ),
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0F172A),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_outlined, color: Color(0xFFF87171), size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(color: Color(0xFFF87171), fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go back', style: TextStyle(color: Color(0xFF34D399))),
            ),
          ],
        ),
      ),
    ),
  );
}
