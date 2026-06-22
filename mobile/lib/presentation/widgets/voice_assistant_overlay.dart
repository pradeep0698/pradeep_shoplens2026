import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/voice_session.dart';
import '../providers/voice_assistant_provider.dart';

const _kBg = Color(0xFF0F172A);
const _kSurface = Color(0xFF1E293B);
const _kAccent = Color(0xFF34D399);
const _kMuted = Color(0xFF94A3B8);
const _kFaint = Color(0xFF64748B);
const _kError = Color(0xFFF87171);

// Language picker is a UI stub for v1 — selecting one only updates local
// widget state. Not threaded into the backend's Gemini session config yet
// (hook point is LiveConnectConfig.speech_config on the backend).
const _languageOptions = ['English', 'Spanish', 'French', 'Hindi', 'German', 'Mandarin'];

const _suggestionChips = [
  'I like minimalist design',
  'No plastic items',
  'Show me smart tech',
];

/// Shows the assistant as a dimmed-background sheet over whatever screen is
/// active — used both for the forced first-run onboarding and for the
/// dismissible overlay opened from [ChatbotFab].
Future<void> showVoiceAssistantOverlay(BuildContext context, {required bool isOnboarding}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => VoiceAssistantOverlay(isOnboarding: isOnboarding),
  );
}

class VoiceAssistantOverlay extends ConsumerStatefulWidget {
  const VoiceAssistantOverlay({super.key, required this.isOnboarding});

  final bool isOnboarding;

  @override
  ConsumerState<VoiceAssistantOverlay> createState() => _VoiceAssistantOverlayState();
}

class _VoiceAssistantOverlayState extends ConsumerState<VoiceAssistantOverlay> {
  final _textController = TextEditingController();
  String _language = 'English';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(voiceAssistantProvider.notifier).start();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _submitText() {
    ref.read(voiceAssistantProvider.notifier).sendText(_textController.text);
    _textController.clear();
  }

  void _showLanguagePicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _kSurface,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _languageOptions
              .map((lang) => ListTile(
                    title: Text(lang, style: const TextStyle(color: Colors.white)),
                    trailing: lang == _language ? const Icon(Icons.check, color: _kAccent) : null,
                    onTap: () {
                      setState(() => _language = lang);
                      Navigator.of(context).pop();
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(voiceAssistantProvider);

    ref.listen<VoiceAssistantState>(voiceAssistantProvider, (prev, next) {
      if (next.status == VoiceStatus.done && prev?.status != VoiceStatus.done) {
        final navigator = Navigator.of(context);
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted && navigator.canPop()) navigator.pop();
        });
      }
    });

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Container(
        decoration: const BoxDecoration(
          color: _kBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _header(),
              Expanded(child: _body(state)),
              if (state.status != VoiceStatus.review &&
                  state.status != VoiceStatus.saving &&
                  state.status != VoiceStatus.done)
                _inputRow(state),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.smart_toy_outlined, color: _kAccent, size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'ShopLens AI',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.language, color: _kMuted),
              tooltip: 'Language: $_language',
              onPressed: _showLanguagePicker,
            ),
            IconButton(
              icon: const Icon(Icons.close, color: _kMuted),
              onPressed: () {
                ref.read(voiceAssistantProvider.notifier).cancel();
                final navigator = Navigator.of(context);
                if (navigator.canPop()) navigator.pop();
              },
            ),
          ],
        ),
      );

  Widget _body(VoiceAssistantState state) {
    switch (state.status) {
      case VoiceStatus.idle:
      case VoiceStatus.connecting:
        return const Center(child: CircularProgressIndicator(color: _kAccent));
      case VoiceStatus.review:
        return _reviewBody(state);
      case VoiceStatus.saving:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: _kAccent),
              SizedBox(height: 14),
              Text('Saving your preferences...', style: TextStyle(color: _kMuted, fontSize: 13)),
            ],
          ),
        );
      case VoiceStatus.done:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline, color: _kAccent, size: 48),
              SizedBox(height: 12),
              Text('Preferences saved!', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
        );
      case VoiceStatus.error:
        return _errorBody(state);
      case VoiceStatus.listening:
      case VoiceStatus.speaking:
        return _conversationBody(state);
    }
  }

  Widget _conversationBody(VoiceAssistantState state) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Text(
              widget.isOnboarding ? "Let's personalize\nyour profile" : 'How can I help?',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tell me about your shopping interests, brands you like, or products you want to ignore.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _kMuted, fontSize: 13),
            ),
            const SizedBox(height: 24),
            _MicVisualizer(isSpeaking: state.status == VoiceStatus.speaking, isRecording: state.isRecording),
            const SizedBox(height: 24),
            if (state.transcript.length <= 1) ...[
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: _suggestionChips
                    .map((s) => _SuggestionChip(label: s, onTap: () => ref.read(voiceAssistantProvider.notifier).sendText(s)))
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
            if (!state.patch.isEmpty) ...[
              _PreferencePreview(patch: state.patch),
              const SizedBox(height: 16),
            ],
            if (state.transcript.isNotEmpty) _TranscriptList(transcript: state.transcript),
            const SizedBox(height: 8),
          ],
        ),
      );

  Widget _errorBody(VoiceAssistantState state) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _kError, size: 40),
              const SizedBox(height: 12),
              Text(
                state.errorMessage ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _kMuted, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.read(voiceAssistantProvider.notifier).start(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  foregroundColor: _kBg,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      );

  Widget _reviewBody(VoiceAssistantState state) {
    final proposal = state.finalizeProposal ?? const VoiceProfilePatch();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Here's what I'll save", style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (proposal.summary.isNotEmpty)
            Text(proposal.summary, style: const TextStyle(color: _kMuted, fontSize: 13)),
          const SizedBox(height: 18),
          _editableCategoryChips(proposal),
          const SizedBox(height: 16),
          _editableTermChips('You like', proposal.preferenceTerms, _kAccent,
              (terms) => ref.read(voiceAssistantProvider.notifier).updateReviewProposal(proposal.copyWith(preferenceTerms: terms))),
          const SizedBox(height: 16),
          _editableTermChips('Avoid', proposal.ignoreTerms, _kError,
              (terms) => ref.read(voiceAssistantProvider.notifier).updateReviewProposal(proposal.copyWith(ignoreTerms: terms))),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    ref.read(voiceAssistantProvider.notifier).cancel();
                    final navigator = Navigator.of(context);
                    if (navigator.canPop()) navigator.pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kMuted,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => ref.read(voiceAssistantProvider.notifier).confirm(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kAccent,
                    foregroundColor: _kBg,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _editableCategoryChips(VoiceProfilePatch proposal) {
    if (proposal.shoppingCategories.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: proposal.shoppingCategories
          .map((cat) => InputChip(
                label: Text(cat),
                labelStyle: const TextStyle(color: _kAccent, fontSize: 13),
                backgroundColor: _kAccent.withValues(alpha: 0.15),
                side: const BorderSide(color: _kAccent),
                onDeleted: () => ref.read(voiceAssistantProvider.notifier).updateReviewProposal(
                      proposal.copyWith(
                        shoppingCategories: proposal.shoppingCategories.where((c) => c != cat).toList(),
                      ),
                    ),
              ))
          .toList(),
    );
  }

  Widget _editableTermChips(String label, List<String> terms, Color color, void Function(List<String>) onChanged) {
    if (terms.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _kMuted, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: terms
              .map((term) => InputChip(
                    label: Text(term),
                    labelStyle: TextStyle(color: color, fontSize: 13),
                    backgroundColor: color.withValues(alpha: 0.12),
                    side: BorderSide(color: color.withValues(alpha: 0.5)),
                    onDeleted: () => onChanged(terms.where((t) => t != term).toList()),
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _inputRow(VoiceAssistantState state) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _holdToTalkButton(state),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => ref.read(voiceAssistantProvider.notifier).finishNow(),
              child: const Text(
                "I'm done — review what I've shared",
                style: TextStyle(color: _kMuted, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    onSubmitted: (_) => _submitText(),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Or type your answer...',
                      hintStyle: const TextStyle(color: _kFaint),
                      filled: true,
                      fillColor: _kSurface,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, color: _kAccent),
                  onPressed: _submitText,
                ),
              ],
            ),
          ],
        ),
      );

  /// Hold-to-talk: press down starts streaming mic audio for one turn,
  /// release ends it — Gemini's own voice-activity detection is disabled
  /// server-side, so this button is what marks the turn boundaries instead
  /// of relying on (unreliable, over resampled web mic audio) automatic
  /// silence detection.
  Widget _holdToTalkButton(VoiceAssistantState state) {
    final notifier = ref.read(voiceAssistantProvider.notifier);
    final disabled = state.status == VoiceStatus.review ||
        state.status == VoiceStatus.saving ||
        state.status == VoiceStatus.done;
    return Listener(
      onPointerDown: disabled ? null : (_) => notifier.beginSpeaking(),
      onPointerUp: disabled ? null : (_) => notifier.endSpeaking(),
      onPointerCancel: disabled ? null : (_) => notifier.endSpeaking(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: state.isRecording ? _kAccent : _kAccent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _kAccent.withValues(alpha: disabled ? 0.3 : 1)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.mic, color: state.isRecording ? _kBg : _kAccent.withValues(alpha: disabled ? 0.5 : 1), size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                state.isRecording ? "Listening… release when you're done" : 'Hold to answer',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: state.isRecording ? _kBg : _kAccent.withValues(alpha: disabled ? 0.5 : 1),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MicVisualizer extends StatelessWidget {
  const _MicVisualizer({required this.isSpeaking, required this.isRecording});
  final bool isSpeaking;
  final bool isRecording;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _kAccent.withValues(alpha: (isSpeaking || isRecording) ? 0.22 : 0.12),
        border: Border.all(color: _kAccent.withValues(alpha: 0.4)),
      ),
      child: Icon(
        isRecording ? Icons.mic : (isSpeaking ? Icons.graphic_eq : Icons.mic_none),
        color: _kAccent,
        size: 34,
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Text('"$label"', style: const TextStyle(color: _kMuted, fontSize: 12.5)),
      ),
    );
  }
}

class _PreferencePreview extends StatelessWidget {
  const _PreferencePreview({required this.patch});
  final VoiceProfilePatch patch;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      ...patch.shoppingCategories.map((c) => _previewChip(c, _kAccent)),
      ...patch.preferenceTerms.map((t) => _previewChip(t, _kAccent)),
      ...patch.ignoreTerms.map((t) => _previewChip(t, _kError)),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: chips);
  }

  Widget _previewChip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12)),
      );
}

class _TranscriptList extends StatelessWidget {
  const _TranscriptList({required this.transcript});
  final List<VoiceTranscriptTurn> transcript;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: transcript
          .map((turn) => Align(
                alignment: turn.role == 'user' ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  constraints: const BoxConstraints(maxWidth: 280),
                  decoration: BoxDecoration(
                    color: turn.role == 'user' ? _kAccent.withValues(alpha: 0.15) : _kSurface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(turn.text, style: const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ))
          .toList(),
    );
  }
}
