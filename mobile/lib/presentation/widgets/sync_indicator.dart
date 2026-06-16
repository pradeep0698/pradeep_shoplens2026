import 'package:flutter/material.dart';

class SyncIndicator extends StatefulWidget {
  const SyncIndicator({super.key, required this.connected});

  final bool connected;

  @override
  State<SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends State<SyncIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync:    this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.connected) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width:  10,
            height: 10,
            decoration: const BoxDecoration(
              color: Color(0xFF475569),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'OFFLINE',
            style: TextStyle(
              color: Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) => Container(
            width:  10,
            height: 10,
            decoration: BoxDecoration(
              color: Color.lerp(
                const Color(0xFF67E8F9),
                const Color(0xFF22D3EE),
                _pulse.value,
              ),
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'SYNCED',
          style: TextStyle(
            color: Color(0xFF67E8F9),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}
