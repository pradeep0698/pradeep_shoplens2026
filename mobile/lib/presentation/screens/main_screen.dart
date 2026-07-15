import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/services/vision_service.dart';
import '../../core/utils/mic_permission.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/product_ranker.dart';
import '../../data/models/user_profile.dart';
import '../../data/repositories/profile_repository.dart';
import '../../data/repositories/recent_searches_repository.dart';
import '../../domain/usecases/video_analyze_usecase.dart';
import 'scan_review_screen.dart' show ScanReviewArgs;
import 'video_player_screen.dart';
import '../providers/admin_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/pipeline_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/recent_searches_provider.dart';
import '../providers/shopping_list_provider.dart';
import '../providers/video_provider.dart';
import '../widgets/chatbot_fab.dart';
import '../widgets/info_tooltip_icon.dart';
import '../widgets/pipeline_status_bar.dart';
import '../widgets/product_card.dart';
import '../widgets/recent_searches_list.dart';
import '../widgets/sync_indicator.dart';
import '../widgets/tap_target_detector.dart';
import '../widgets/voice_assistant_overlay.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  final _tapKey = GlobalKey<TapTargetDetectorState>();
  bool  _productCheckSettled = false;
  Timer? _productCheckTimer;
  bool  _onboardingTriggered = false;
  bool  _savedToRecent = false;
  bool  _imageCollapsed = false;

  @override
  void initState() {
    super.initState();
    unawaited(requestMicrophonePermission());
  }

  @override
  void dispose() {
    _productCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _maybeShowOnboarding(UserProfile resolvedProfile) async {
    if (_onboardingTriggered || resolvedProfile.voiceOnboardingSeen) return;
    _onboardingTriggered = true;

    await showVoiceAssistantOverlay(context, isOnboarding: true);
    if (!mounted) return;

    final user = ref.read(authStateProvider).value;
    if (user == null) return;
    // Re-read the freshest profile rather than reusing the stale snapshot —
    // a finalized voice session may have already merged new preferences into
    // Firestore server-side while the overlay was open.
    final latest = ref.read(profileProvider).valueOrNull ?? resolvedProfile;
    if (latest.voiceOnboardingSeen) return;
    await ref.read(profileRepositoryProvider).save(
          user.uid,
          latest.copyWith(voiceOnboardingSeen: true),
        );
  }

  Future<void> _reScan(RecentSearchEntry entry) async {
    ref.read(videoProvider.notifier).reset();
    await ref.read(pipelineProvider.notifier).setImage(entry.imageBytes, entry.mimeType);
    setState(() => _savedToRecent = true);
    ref.read(pipelineProvider.notifier).analyzeLoaded();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pipelineProvider, (prev, next) {
      // Collapsing the photo only makes sense once results are actually
      // showing — force it back open for a fresh pick, a new analysis run,
      // or an error, so the user always sees the image before/while it's
      // being worked on.
      if (next.status != PipelineStatus.success) {
        _imageCollapsed = false;
      }
      if (next.status == PipelineStatus.analyzing) {
        _productCheckTimer?.cancel();
        setState(() {
          _productCheckSettled = false;
          _savedToRecent = false;
        });
      }
      if (next.status == PipelineStatus.success &&
          prev?.status != PipelineStatus.success) {
        _productCheckTimer?.cancel();
        _productCheckTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(() => _productCheckSettled = true);
        });
        // Auto-collapse the photo so the product list gets the full screen —
        // still one tap away via the collapsed strip below.
        _imageCollapsed = true;
        // Save image to recent searches once per scan
        if (!_savedToRecent) {
          final bytes    = next.imageBytes;
          final mimeType = _mimeType;
          if (bytes != null && mimeType != null) {
            _savedToRecent = true;
            ref.read(recentSearchesProvider.notifier).add(bytes, mimeType);
          }
        }
      }
    });

    final pipeline           = ref.watch(pipelineProvider);
    final video              = ref.watch(videoProvider);
    final shoppingList       = ref.watch(shoppingListProvider);
    final profile            = ref.watch(profileProvider).valueOrNull;
    final shoppingCategories = profile?.shoppingCategories ?? const [];
    final isAdmin            = ref.watch(isAdminProvider).valueOrNull ?? false;
    final hasSelection       = _tapKey.currentState?.hasSelection ?? false;

    if (profile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowOnboarding(profile));
    }

    final isBusy = pipeline.status == PipelineStatus.analyzing ||
                   pipeline.status == PipelineStatus.matching   ||
                   pipeline.status == PipelineStatus.saving     ||
                   video is VideoAnalyzing;

    final showVideoSection = video is VideoLoaded  ||
                             video is VideoCacheHit ||
                             video is VideoAnalyzing ||
                             video is VideoError;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Image.asset(
          'assets/shoplens-logo-nobckg.png',
          height: 50,
          fit: BoxFit.contain,
        ),
        actions: [
          shoppingList.when(
            loading: () => const SizedBox.shrink(),
            error:   (_, __) => const SizedBox.shrink(),
            data:    (_) => const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SyncIndicator(connected: true),
            ),
          ),
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined,
                  color: Color(0xFF34D399)),
              tooltip: 'Admin portal',
              onPressed: () => context.push('/admin'),
            ),
          IconButton(
            icon: const Icon(Icons.person_outline, color: Color(0xFF94A3B8)),
            onPressed: () => context.push('/profile'),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF94A3B8)),
            color: const Color(0xFF1E293B),
            onSelected: (value) {
              if (value == 'about') context.push('/about');
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF94A3B8), size: 18),
                    SizedBox(width: 12),
                    Text('About', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          PipelineStatusBar(
            status:        pipeline.status,
            errorMessage:  pipeline.errorMessage,
            errorCode:     pipeline.errorCode,
            isRetryable:   pipeline.isRetryable,
            foundProducts: pipeline.status == PipelineStatus.success
                ? (shoppingList.value?.isNotEmpty == true
                    ? true
                    : _productCheckSettled ? false : null)
                : null,
            warnings:      pipeline.warnings,
          ),

          // Image section
          if (pipeline.imageBytes != null) ...[
            if (_imageCollapsed)
              _buildCollapsedImageStrip(pipeline.imageBytes!)
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: Stack(
                      children: [
                        TapTargetDetector(
                          key:               _tapKey,
                          imageBytes:        pipeline.imageBytes!,
                          boxFit:            BoxFit.contain,
                          onIdentify:        _onTapIdentify,
                          onSelectionChanged: () => setState(() {}),
                          child: Image.memory(
                            pipeline.imageBytes!,
                            width: double.infinity,
                            fit: BoxFit.contain,
                          ),
                        ),
                        if (isBusy)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withValues(alpha: 0.5),
                              child: const Center(
                                child: CircularProgressIndicator(color: Color(0xFF34D399)),
                              ),
                            ),
                          ),
                        if (pipeline.status == PipelineStatus.success)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _CollapseButton(
                              icon: Icons.expand_less,
                              onTap: () => setState(() => _imageCollapsed = true),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!isBusy)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton.icon(
                          onPressed: (pipeline.fromLiveScan && !hasSelection)
                              ? null
                              : () async {
                                  final tap = _tapKey.currentState;
                                  if (tap != null && tap.hasSelection) {
                                    await tap.analyzeSelection();
                                  } else if (!pipeline.fromLiveScan) {
                                    // Manual re-entry (e.g. after backing out of the dots
                                    // screen without scanning) — picking normally jumps here
                                    // automatically now that detection is on-device ML Kit.
                                    context.push('/gallery-scan', extra: ScanReviewArgs(
                                      imageBytes: pipeline.imageBytes!,
                                      mime: _mimeType ?? 'image/jpeg',
                                      imagePath: _imagePath,
                                    ));
                                  }
                                },
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: Text(
                            pipeline.fromLiveScan ? 'Crop Image' : 'Scan Image',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF34D399),
                            foregroundColor: const Color(0xFF0F172A),
                            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InfoTooltipIcon(
                          message: pipeline.fromLiveScan
                              ? 'Tap an object first. Crop Image identifies only the selected object.'
                              : 'Scan Image identifies everything in the image. To identify a specific item, tap it first.',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],

          // Video section
          if (showVideoSection) _buildVideoSection(video),

          Expanded(
            child: shoppingList.when(
              loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF34D399))),
              error: (e, _) => Center(
                child: Text('Connection error: $e', style: const TextStyle(color: Color(0xFFF87171), fontSize: 13)),
              ),
              data: (products) {
                final ranked = rankProducts(products, shoppingCategories,
                    isExactMatchSource: true);

                if (ranked.isEmpty) {
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        _emptyState(),
                        RecentSearchesList(onTap: _reScan),
                      ],
                    ),
                  );
                }

                return SingleChildScrollView(
                  child: Column(
                    children: [
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        itemCount: ranked.length,
                        itemBuilder: (_, i) => ProductCard(
                          product:            ranked[i],
                          shoppingCategories: shoppingCategories,
                        ),
                      ),
                      RecentSearchesList(onTap: _reScan),
                      const SizedBox(height: 100),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),

      bottomNavigationBar: Container(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).padding.bottom + 16,
          top: 12,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: 'Gallery',
                child: OutlinedButton(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF34D399),
                    side: BorderSide(color: const Color(0xFF34D399).withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Icon(Icons.photo_library_outlined, size: 24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: 'Live Scan',
                child: OutlinedButton(
                  onPressed: () {
                    ref.read(videoProvider.notifier).reset();
                    ref.read(pipelineProvider.notifier).resetImage();
                    context.push('/live-scan');
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF34D399),
                    side: BorderSide(color: const Color(0xFF34D399).withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Icon(Icons.videocam_outlined, size: 24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: 'Video',
                child: OutlinedButton(
                  onPressed: _pickVideo,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF34D399),
                    side: BorderSide(color: const Color(0xFF34D399).withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Icon(Icons.video_library_outlined, size: 24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Clear list',
              child: OutlinedButton(
                onPressed: () {
                  ref.read(pipelineProvider.notifier).clearSession();
                  ref.read(videoProvider.notifier).reset();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF34D399),
                  side: BorderSide(color: const Color(0xFF34D399).withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: const Icon(Icons.delete_outline, size: 24),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: const ChatbotFab(),
    );
  }

  String? _mimeType;
  String? _imagePath;

  Widget _buildVideoSection(VideoState video) {
    final thumbnail = switch (video) {
      VideoLoaded(:final thumbnail)    => thumbnail,
      VideoCacheHit(:final thumbnail)  => thumbnail,
      VideoAnalyzing(:final thumbnail) => thumbnail,
      VideoError(:final thumbnail)     => thumbnail,
      _                                => null,
    };

    final fileName = switch (video) {
      VideoLoaded(:final fileName)    => fileName,
      VideoCacheHit(:final fileName)  => fileName,
      VideoAnalyzing(:final fileName) => fileName,
      VideoError(:final fileName)     => fileName,
      _                               => '',
    };

    final String statusText;
    final Color  statusColor;
    final bool   isAnalyzing = video is VideoAnalyzing;

    if (video is VideoCacheHit) {
      statusText  = 'Cached ✓';
      statusColor = const Color(0xFF34D399);
    } else if (video is VideoAnalyzing) {
      statusText  = _videoStepLabel(video.step);
      statusColor = const Color(0xFF94A3B8);
    } else if (video is VideoError) {
      statusText  = video.message;
      statusColor = const Color(0xFFF87171);
    } else {
      statusText  = 'Not yet analyzed';
      statusColor = const Color(0xFF64748B);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumbnail != null
                      ? Image.memory(thumbnail, width: 72, height: 72, fit: BoxFit.cover)
                      : Container(
                          width: 72,
                          height: 72,
                          color: const Color(0xFF0F172A),
                          child: const Icon(Icons.videocam_outlined, color: Color(0xFF475569), size: 28),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (isAnalyzing) ...[
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF34D399)),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              statusText,
                              style: TextStyle(color: statusColor, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (video is VideoCacheHit) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => ref.read(videoProvider.notifier).loadCachedProducts(),
                icon: const Icon(Icons.bolt_outlined, size: 18),
                label: const Text('Load Cached Products', style: TextStyle(fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF34D399),
                  foregroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ),
          ] else if (video is VideoLoaded) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VideoPlayerScreen(
                      videoPath:   video.videoPath,
                      fileName:    video.fileName,
                      annotations: video.annotations,
                    ),
                  ),
                ),
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: const Text('Watch Video', style: TextStyle(fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF34D399),
                  foregroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _videoStepLabel(VideoStep step) => switch (step) {
    VideoStep.analyzing => 'Analyzing frame...',
    VideoStep.matching  => 'Matching products...',
    VideoStep.saving    => 'Saving to your list...',
  };

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final file   = await picker.pickImage(
      source:                source,
      imageQuality:          85,
      maxWidth:              1024,
      maxHeight:             1024,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file == null) return;

    ref.read(videoProvider.notifier).reset();
    final bytes = await file.readAsBytes();
    _mimeType   = getMimeType(file.path);
    _imagePath  = file.path;
    await ref.read(pipelineProvider.notifier).setImage(bytes, _mimeType!);

    // Gallery pick only (this is the only call site) — detection is now
    // on-device ML Kit, so there's no reason to make the user tap "Scan
    // Image" first; jump straight to the dots screen the instant the image
    // is loaded.
    if (!mounted) return;
    context.push('/gallery-scan', extra: ScanReviewArgs(
      imageBytes: bytes,
      mime: _mimeType!,
      imagePath: _imagePath,
    ));
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final file   = await picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return;

    await ref.read(pipelineProvider.notifier).clearSession();
    await ref.read(videoProvider.notifier).videoLoaded(file.path, file.name);
  }

  Widget _emptyState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            Icon(Icons.shopping_cart_outlined, size: 52, color: Colors.white.withValues(alpha: 0.15)),
            const SizedBox(height: 14),
            const Text(
              'Matched products will appear here',
              style: TextStyle(color: Color(0xFF475569), fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );

  Future<void> _onTapIdentify(Uint8List croppedBytes) =>
      ref.read(pipelineProvider.notifier).identifyTappedObject(croppedBytes);

  Widget _buildCollapsedImageStrip(Uint8List imageBytes) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Material(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _imageCollapsed = false),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(imageBytes, width: 40, height: 40, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'View photo',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const Icon(Icons.expand_more, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),
        ),
      );
}

class _CollapseButton extends StatelessWidget {
  const _CollapseButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}
