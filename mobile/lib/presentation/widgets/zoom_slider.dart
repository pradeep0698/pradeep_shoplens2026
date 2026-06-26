import 'package:flutter/material.dart';

/// A compact horizontal slider for continuously scrubbing zoom from
/// [minZoom] to [maxZoom], similar to a native phone camera app. Continuous
/// dragging covers the whole range in one motion, unlike discrete preset
/// buttons which require many repeated taps/pinches to reach a high max.
class ZoomSlider extends StatelessWidget {
  const ZoomSlider({
    super.key,
    required this.currentZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.onZoomChanged,
  });

  final double currentZoom;
  final double minZoom;
  final double maxZoom;
  final void Function(double) onZoomChanged;

  static const _kGreen = Color(0xFF34D399);

  String _label(double zoom) =>
      zoom == zoom.roundToDouble() ? '${zoom.toInt()}x' : '${zoom.toStringAsFixed(1)}x';

  @override
  Widget build(BuildContext context) {
    if (maxZoom <= minZoom) return const SizedBox.shrink();
    final value = currentZoom.clamp(minZoom, maxZoom);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_label(minZoom), style: const TextStyle(color: Colors.white70, fontSize: 11)),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: _kGreen,
              inactiveTrackColor: Colors.white24,
              thumbColor: _kGreen,
              valueIndicatorColor: const Color(0xFF0F172A),
              valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            child: SizedBox(
              width: 170,
              child: Slider(
                value: value,
                min: minZoom,
                max: maxZoom,
                label: _label(value),
                onChanged: onZoomChanged,
              ),
            ),
          ),
          Text(_label(maxZoom), style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
