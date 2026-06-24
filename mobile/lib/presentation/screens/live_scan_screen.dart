import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import '../../core/services/mlkit_detector_service.dart';
import '../../core/utils/image_utils.dart';
import '../providers/pipeline_provider.dart';
import '../widgets/info_tooltip_icon.dart';
import '../widgets/object_glow_overlay.dart';

class LiveScanScreen extends ConsumerStatefulWidget {
  const LiveScanScreen({super.key});

  @override
  ConsumerState<LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends ConsumerState<LiveScanScreen>
    with WidgetsBindingObserver {
  // Below this, ML Kit's on-device classification is too unsure of what the
  // object is — escalate to the full cloud pipeline so Gemini gets a fresh
  // look instead of risking a wrong /identify search query.
  static const double _kOnDeviceConfidenceThreshold = 0.70;

  CameraController? _cam;
  final _detector = MlKitDetectorService();
  List<DetectedObject> _liveObjects = [];
  bool _processing = false;
  bool _initialized = false;
  String? _error;

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
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera found on this device');
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final ctrl = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await ctrl.initialize();
      if (!mounted) return;

      await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      ctrl.startImageStream(_onFrame);

      setState(() {
        _cam = ctrl;
        _initialized = true;
      });
    } catch (e) {
      setState(() => _error = e.toString());
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

      // Auto-start analysis so the user doesn't need to press Scan Image.
      // A confidently-classified tapped object skips straight to the cheap
      // single-item /identify lookup; "Scan All" and low-confidence taps
      // still get the full cloud Gemini detection pass.
      if (_topConfidence(tappedObject) case final confidence?
          when confidence >= _kOnDeviceConfidenceThreshold) {
        ref.read(pipelineProvider.notifier).identifyTappedObject(imageBytes);
      } else {
        ref.read(pipelineProvider.notifier).analyzeLoaded();
      }
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

  double? _topConfidence(DetectedObject? obj) =>
      (obj == null || obj.labels.isEmpty) ? null : obj.labels.first.confidence;

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
