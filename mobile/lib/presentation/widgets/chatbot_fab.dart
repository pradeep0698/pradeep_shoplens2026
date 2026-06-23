import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/profile_provider.dart';
import 'voice_assistant_overlay.dart';

/// Persistent floating entry point to the voice assistant, reachable from
/// the main screen at any time. Shows a small reminder dot while the current
/// profile has zero shopping categories/preference terms/ignore terms —
/// computed live from [profileProvider], no extra persisted flag needed.
class ChatbotFab extends ConsumerWidget {
  const ChatbotFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final hasNoPreferences = profile == null ||
        (profile.shoppingCategories.isEmpty &&
            profile.preferenceTerms.isEmpty &&
            profile.ignoreTerms.isEmpty);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        FloatingActionButton(
          backgroundColor: const Color(0xFF34D399),
          foregroundColor: const Color(0xFF0F172A),
          tooltip: 'Voice assistant',
          onPressed: () => showVoiceAssistantOverlay(context, isOnboarding: false),
          child: const Icon(Icons.smart_toy_outlined),
        ),
        if (hasNoPreferences)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: const Color(0xFFF87171),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF0F172A), width: 2),
              ),
            ),
          ),
      ],
    );
  }
}
