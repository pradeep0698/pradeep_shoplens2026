import 'package:flutter/material.dart';

/// A small vertical bar for continuously scrubbing zoom from [minZoom] to
/// [maxZoom], docked to one side instead of sprawled across the camera
/// preview like a full-width horizontal bar. Built from a horizontal
/// [Slider] rotated 90° — RotatedBox swaps the layout constraints for odd
/// quarter turns, so the outer [SizedBox]'s width/height below are the
/// actual on-screen thickness/length of the bar. Dragging up zooms in
/// (max at the top), matching how a native camera app's zoom rocker reads.
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
  static const _kTrackLength = 130.0;
  static const _kThickness = 28.0;

  String _label(double zoom) =>
      zoom == zoom.roundToDouble() ? '${zoom.toInt()}x' : '${zoom.toStringAsFixed(1)}x';

  @override
  Widget build(BuildContext context) {
    if (maxZoom <= minZoom) return const SizedBox.shrink();
    final value = currentZoom.clamp(minZoom, maxZoom);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_label(maxZoom), style: const TextStyle(color: Colors.white70, fontSize: 10)),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: _kGreen,
              inactiveTrackColor: Colors.white24,
              thumbColor: _kGreen,
              valueIndicatorColor: const Color(0xFF0F172A),
              valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            child: SizedBox(
              width: _kThickness,
              height: _kTrackLength,
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  value: value,
                  min: minZoom,
                  max: maxZoom,
                  label: _label(value),
                  onChanged: onZoomChanged,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(_label(minZoom), style: const TextStyle(color: Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }
}
