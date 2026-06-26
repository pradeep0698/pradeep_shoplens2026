import 'package:flutter/material.dart';

/// A vertical pill of quick zoom-level buttons (0.5x/1x/2x/3x), similar to a
/// native phone camera app. Presets outside the device's supported zoom
/// range are clamped by the caller rather than hidden, so the button still
/// reacts predictably on single-lens devices.
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
    final available = _presets.where((p) => p <= maxZoom + 0.01).toList();

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: available.map((preset) {
          final isActive = (currentZoom - preset.clamp(minZoom, maxZoom)).abs() < 0.05;
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
                  preset == preset.roundToDouble()
                      ? '${preset.toInt()}x'
                      : '${preset}x',
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
