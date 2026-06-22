import 'package:flutter/material.dart';

/// A small info icon that, on tap, shows a short explanation in a popover
/// bubble anchored just above the icon. Tap elsewhere (or wait) to dismiss.
class InfoTooltipIcon extends StatefulWidget {
  const InfoTooltipIcon({
    super.key,
    required this.message,
    this.color = const Color(0xFF94A3B8),
  });

  final String message;
  final Color color;

  @override
  State<InfoTooltipIcon> createState() => _InfoTooltipIconState();
}

class _InfoTooltipIconState extends State<InfoTooltipIcon> {
  final _layerLink = LayerLink();
  OverlayEntry? _entry;

  void _toggle() {
    if (_entry != null) {
      _dismiss();
      return;
    }

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismiss,
            ),
          ),
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -8),
            child: _InfoBubble(message: widget.message),
          ),
        ],
      ),
    );

    _entry = entry;
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 5), _dismiss);
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: IconButton(
        icon: Icon(Icons.info_outline, size: 18, color: widget.color),
        onPressed: _toggle,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      ),
    );
  }
}

class _InfoBubble extends StatelessWidget {
  const _InfoBubble({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)],
        ),
        child: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.3),
        ),
      ),
    );
  }
}
