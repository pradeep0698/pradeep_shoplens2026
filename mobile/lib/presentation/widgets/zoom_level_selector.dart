import 'package:flutter/material.dart';

/// A vertical pill of quick zoom-level buttons (0.5x/1x/2x/3x), similar to a
/// native phone camera app. Presets outside the device's supported zoom
/// range are hidden; if the device's real max zoom is well above 3x, it's
/// appended as an extra one-tap preset.
class ZoomLevelSelector extends StatelessWidget {
  const ZoomLevelSelector({
    super.key,
    required this.currentZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomSelected,
  });

  final double currentZoom;
  final double minZoom;
  final double maxZoom;
  final void Function(double) onZoomSelected;

  static const _presets = [0.5, 1.0, 2.0, 3.0];
  static const _kGreen = Color(0xFF34D399);

  @override
  Widget build(BuildContext context) {
    final fixed = _presets
        .where((p) => p >= minZoom - 0.01 && p <= maxZoom + 0.01)
        .toList();
    // Devices with a much higher native max (e.g. some Android phones report
    // 9x) get a one-tap shortcut straight to it, not just 0.5/1/2/3.
    final showMaxPreset = maxZoom > 3.5;
    final available = showMaxPreset ? [...fixed, maxZoom] : fixed;
    if (available.isEmpty) return const SizedBox.shrink();

    final nearest = available.reduce(
      (a, b) => (currentZoom - a).abs() <= (currentZoom - b).abs() ? a : b,
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: available.map((preset) {
          final isActive = preset == nearest;
          // The dynamic max preset displays rounded (e.g. 8.97 -> "9x") but
          // taps still pass through the precise `preset` value below.
          final isFixedPreset = _presets.contains(preset);
          final label = isFixedPreset && preset != preset.roundToDouble()
              ? '${preset}x'
              : '${preset.round()}x';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onZoomSelected(preset),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? _kGreen : Colors.transparent,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: isActive ? const Color(0xFF0F172A) : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
