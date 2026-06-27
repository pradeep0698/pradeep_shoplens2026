import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_assistant_overlay.dart';

/// Persistent floating entry point to the voice search assistant, reachable
/// from the main screen at any time. Preference capture only ever happens
/// once, via the forced first-run onboarding overlay (isOnboarding: true) —
/// this FAB always opens the search conversation instead, so there is no
/// "preferences not set yet" affordance to surface here anymore.
class ChatbotFab extends ConsumerWidget {
  const ChatbotFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatingActionButton(
      backgroundColor: const Color(0xFF34D399),
      foregroundColor: const Color(0xFF0F172A),
      tooltip: 'Voice search',
      onPressed: () => showVoiceAssistantOverlay(context, isOnboarding: false),
      child: const Icon(Icons.smart_toy_outlined),
    );
  }
}
