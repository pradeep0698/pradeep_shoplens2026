import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/voice_languages.dart';
import '../../data/models/voice_session.dart';
import '../../data/repositories/profile_repository.dart';
import '../providers/auth_provider.dart';
import '../providers/profile_provider.dart';
import '../providers/voice_assistant_provider.dart';
import 'product_card.dart';

const _kBg = Color(0xFF0F172A);
const _kSurface = Color(0xFF1E293B);
const _kAccent = Color(0xFF34D399);
const _kMuted = Color(0xFF94A3B8);
const _kFaint = Color(0xFF64748B);
const _kError = Color(0xFFF87171);

const _onboardingSuggestionChips = [
  'I like minimalist design',
  'No plastic items',
  'Show me smart tech',
];

const _searchSuggestionChips = [
  'Wireless headphones under \$50',
  'A black leather jacket',
  'Minimalist desk lamp',
];

/// Shows the assistant as a dimmed-background sheet over whatever screen is
/// active — used both for the forced first-run onboarding and for the
/// dismissible overlay opened from [ChatbotFab].
Future<void> showVoiceAssistantOverlay(BuildContext context, {required bool isOnboarding}) {
  if (_voiceAssistantOverlayOpen) return Future.value();
  _voiceAssistantOverlayOpen = true;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) => VoiceAssistantOverlay(isOnboarding: isOnboarding),
  ).whenComplete(() => _voiceAssistantOverlayOpen = false);
}

bool _voiceAssistantOverlayOpen = false;

class VoiceAssistantOverlay extends ConsumerStatefulWidget {
  const VoiceAssistantOverlay({super.key, required this.isOnboarding});

  final bool isOnboarding;

  @override
  ConsumerState<VoiceAssistantOverlay> createState() => _VoiceAssistantOverlayState();
}

class _VoiceAssistantOverlayState extends ConsumerState<VoiceAssistantOverlay> with WidgetsBindingObserver {
  final _textController = TextEditingController();
  String _language = 'English';
  Timer? _pauseDebounce;

  // Long enough to cover a Buy-link external-browser round trip (tap Buy ->
  // browser opens -> user glances -> taps back, typically 1-3s on a real
  // device) with margin; short enough that a genuine backgrounding still
  // pauses the live session promptly.
  static const _kPauseDebounce = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _language = ref.read(profileProvider).valueOrNull?.voiceLanguage ?? 'English';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(voiceAssistantProvider.notifier).start(isOnboarding: widget.isOnboarding, language: _language);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    // AppLifecycleState.inactive fires the instant the window/tab loses
    // focus even momentarily (e.g. url_launcher opening a product's Buy
    // link), and must not be acted on here, or it reintroduces the bug
    // described in dispose() below.
    if (lifecycleState == AppLifecycleState.paused) {
      // Tapping a Buy link (launchUrl with LaunchMode.externalApplication)
      // triggers a real `paused` transition on real devices, not just
      // `inactive` — opening an external browser is a genuine app switch.
      // Debounce so a quick round trip (tap Buy -> glance -> come back)
      // never tears down the live session; only a backgrounding that
      // outlasts the debounce actually pauses.
      _pauseDebounce?.cancel();
      _pauseDebounce = Timer(_kPauseDebounce, () {
        _pauseDebounce = null;
        unawaited(ref.read(voiceAssistantProvider.notifier).pauseForBackground());
      });
    } else if (lifecycleState == AppLifecycleState.resumed) {
      // Came back before the debounce elapsed — the live session was never
      // touched, so there's nothing to resume, just cancel the pending pause.
      _pauseDebounce?.cancel();
      _pauseDebounce = null;
    }
  }

  @override
  void dispose() {
    _pauseDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // The only full-teardown trigger now — previously a WidgetsBindingObserver
    // also cancelled on AppLifecycleState.inactive, which fires the instant
    // the window/tab loses focus (e.g. url_launcher opening a product's Buy
    // link), wiping the whole conversation even though the user never
    // closed the overlay. Exiting (closing this sheet) is the only thing
    // that should end the session now.
    unawaited(ref.read(voiceAssistantProvider.notifier).cancel());
    _textController.dispose();
    super.dispose();
  }

  void _submitText() {
    ref.read(voiceAssistantProvider.notifier).sendText(_textController.text);
    _textController.clear();
  }

  // Changing language reconnects the live session (see _selectLanguage) —
  // only meaningful while one could plausibly be active.
  bool _canChangeLanguage(VoiceAssistantState state) =>
      state.status != VoiceStatus.review &&
      state.status != VoiceStatus.saving &&
      state.status != VoiceStatus.done;

  // Restarts the live session in the new language — Gemini Live's system
  // instruction (see live_session.py's _system_prompt) is fixed for the life
  // of a connection, so a language change can only take effect by
  // reconnecting. Also persists the choice to the user's profile so it's
  // remembered the next time they open the assistant.
  void _selectLanguage(String lang) {
    if (lang == _language) return;
    setState(() => _language = lang);
    final user = ref.read(authStateProvider).value;
    final profile = ref.read(profileProvider).valueOrNull;
    if (user != null && profile != null) {
      unawaited(ref.read(profileRepositoryProvider).save(user.uid, profile.copyWith(voiceLanguage: lang)));
    }
    ref.read(voiceAssistantProvider.notifier).start(isOnboarding: widget.isOnboarding, language: lang);
  }

  void _showLanguagePicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _kSurface,
      isScrollControlled: true,
      builder: (sheetContext) {
        var query = '';
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final filtered = kVoiceLanguages.where((lang) => lang.toLowerCase().contains(query.toLowerCase())).toList();
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: TextField(
                        autofocus: true,
                        onChanged: (v) => setSheetState(() => query = v),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Search languages...',
                          hintStyle: const TextStyle(color: _kFaint),
                          prefixIcon: const Icon(Icons.search, color: _kFaint),
                          filled: true,
                          fillColor: _kBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final lang = filtered[i];
                          return ListTile(
                            title: Text(lang, style: const TextStyle(color: Colors.white)),
                            trailing: lang == _language ? const Icon(Icons.check, color: _kAccent) : null,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _selectLanguage(lang);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
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

    // isScrollControlled: true (see showVoiceAssistantOverlay) opts this sheet
    // out of Flutter's automatic keyboard-avoidance padding, so the bottom
    // inset has to be applied here manually or the keyboard covers _inputRow.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: FractionallySizedBox(
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
                _header(state),
                Expanded(child: _body(state)),
                if (state.status != VoiceStatus.review &&
                    state.status != VoiceStatus.saving &&
                    state.status != VoiceStatus.done)
                  _inputRow(state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(VoiceAssistantState state) => Padding(
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
              icon: Icon(Icons.language, color: _kMuted.withValues(alpha: _canChangeLanguage(state) ? 1 : 0.4)),
              tooltip: 'Language: $_language',
              onPressed: _canChangeLanguage(state) ? _showLanguagePicker : null,
            ),
            IconButton(
              icon: const Icon(Icons.close, color: _kMuted),
              onPressed: () async {
                await ref.read(voiceAssistantProvider.notifier).cancel();
                if (!context.mounted) return;
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
        // Keep the transcript/product results on screen instead of swapping
        // to the generic error screen whenever there's something to show —
        // covers both a dropped connection and pauseForBackground(), neither
        // of which should hide a conversation the user already built up.
        return (state.transcript.isNotEmpty || state.searchResults.isNotEmpty)
            ? _conversationBody(state)
            : _errorBody(state);
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
              widget.isOnboarding ? "Let's personalize\nyour profile" : 'What are you shopping for?',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isOnboarding
                  ? 'Tell me about your shopping interests, brands you like, or products you want to ignore.'
                  : "Tell me what you're looking for and I'll find it.",
              textAlign: TextAlign.center,
              style: const TextStyle(color: _kMuted, fontSize: 13),
            ),
            const SizedBox(height: 24),
            _MicVisualizer(isSpeaking: state.status == VoiceStatus.speaking, isRecording: state.isRecording),
            const SizedBox(height: 24),
            if (state.status == VoiceStatus.error) ...[
              _ErrorBanner(
                message: state.errorMessage ?? 'Connection lost.',
                // resume: true — this banner only shows when there's already
                // a transcript/patch worth keeping (see _body()'s error
                // branch), so reconnect should reattach to the same backend
                // session (see live_session.py's resume_session_id) instead
                // of starting a brand-new conversation from scratch.
                onReconnect: () => ref.read(voiceAssistantProvider.notifier).start(
                  isOnboarding: widget.isOnboarding,
                  language: _language,
                  resume: true,
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (state.transcript.length <= 1) ...[
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: (widget.isOnboarding ? _onboardingSuggestionChips : _searchSuggestionChips)
                    .map((s) => _SuggestionChip(label: s, onTap: () => ref.read(voiceAssistantProvider.notifier).sendText(s)))
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.isOnboarding && !state.patch.isEmpty) ...[
              _PreferencePreview(patch: state.patch),
              const SizedBox(height: 16),
            ],
            if (state.searchResults.isNotEmpty)
              _PinnedSearchSection(
                searchResults: state.searchResults,
                shoppingCategories: state.patch.shoppingCategories,
              ),
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: SelectableText(
                    state.errorMessage ?? 'Something went wrong.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _kMuted, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref
                    .read(voiceAssistantProvider.notifier)
                    .start(isOnboarding: widget.isOnboarding, language: _language),
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
                  onPressed: () async {
                    await ref.read(voiceAssistantProvider.notifier).cancel();
                    if (!context.mounted) return;
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
            _handsFreeToggleButton(state),
            const SizedBox(height: 4),
            // No review step exists in search mode — only onboarding's
            // preference flow needs an explicit "done" affordance.
            if (widget.isOnboarding)
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

  /// Hands-free toggle: one tap starts a session that stays listening for
  /// the whole conversation, another tap stops it — no per-turn button
  /// presses. Gemini's own voice-activity detection stays disabled
  /// server-side; a re-armable local VAD (Pcm16ReArmableSpeechGate, see
  /// VoiceAssistantNotifier.startHandsFree) automatically detects each
  /// utterance's start/end for the whole time the toggle is on, including
  /// while the assistant is talking — so the user can just start talking to
  /// interrupt it (barge-in), the same way ChatGPT's voice mode works.
  Widget _handsFreeToggleButton(VoiceAssistantState state) {
    final notifier = ref.read(voiceAssistantProvider.notifier);
    final disabled = state.status == VoiceStatus.review ||
        state.status == VoiceStatus.saving ||
        state.status == VoiceStatus.done ||
        state.status == VoiceStatus.error;
    final active = state.isHandsFreeActive;
    final label = !active
        ? 'Tap to talk hands-free'
        : (state.isRecording ? 'Listening…' : 'Listening — just start talking');
    return GestureDetector(
      onTap: disabled
          ? null
          : () => active ? notifier.stopHandsFree() : notifier.startHandsFree(),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: active ? _kAccent : _kAccent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _kAccent.withValues(alpha: disabled ? 0.3 : 1)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(active ? Icons.mic : Icons.mic_none, color: active ? _kBg : _kAccent.withValues(alpha: disabled ? 0.5 : 1), size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? _kBg : _kAccent.withValues(alpha: disabled ? 0.5 : 1),
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

/// Inline banner shown above the conversation when the live session has
/// stopped (dropped connection or backgrounding) but there's already a
/// transcript/results worth keeping on screen — see _body()'s error branch.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onReconnect});
  final String message;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kError.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kError.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: _kError, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: const TextStyle(color: _kMuted, fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onReconnect,
            style: OutlinedButton.styleFrom(
              foregroundColor: _kAccent,
              side: const BorderSide(color: _kAccent),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: const Text('Reconnect', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
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

/// Pins the newest search prominently at the top, collapsing any earlier
/// searches (in this session) behind an expandable "N earlier searches"
/// toggle — fixes the bug where an older, empty search stayed visible above
/// a later, successful one. [searchResults] must already be newest-first
/// (see VoiceAssistantNotifier._handleControlFrame's insert-at-front logic).
class _PinnedSearchSection extends StatefulWidget {
  const _PinnedSearchSection({required this.searchResults, required this.shoppingCategories});

  final List<VoiceSearchResult> searchResults;
  final List<String> shoppingCategories;

  @override
  State<_PinnedSearchSection> createState() => _PinnedSearchSectionState();
}

class _PinnedSearchSectionState extends State<_PinnedSearchSection> {
  // Pure ephemeral display state — no bearing on the conversation/session,
  // so it lives here rather than in the Riverpod-managed VoiceAssistantState.
  bool _historyExpanded = false;

  @override
  Widget build(BuildContext context) {
    final latest = widget.searchResults.first;
    final older = widget.searchResults.skip(1).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _searchResultBlock(latest, prominent: true),
          if (older.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _historyExpanded = !_historyExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_historyExpanded ? Icons.expand_less : Icons.expand_more, color: _kMuted, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      '${older.length} earlier search${older.length == 1 ? '' : 'es'}',
                      style: const TextStyle(color: _kMuted, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
            if (_historyExpanded)
              ...older.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _searchResultBlock(r, prominent: false),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _searchResultBlock(VoiceSearchResult result, {required bool prominent}) => Padding(
        padding: EdgeInsets.symmetric(vertical: prominent ? 8 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Results for '${result.query}'",
              style: TextStyle(
                color: _kMuted,
                fontSize: prominent ? 12 : 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            if (result.isPending)
              const Row(
                children: [
                  SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _kAccent)),
                  SizedBox(width: 8),
                  Text('Still searching…', style: TextStyle(color: _kFaint, fontSize: 12.5)),
                ],
              )
            else if (result.products.isEmpty)
              const Text(
                "Didn't find anything for that — try rephrasing.",
                style: TextStyle(color: _kFaint, fontSize: 12.5),
              )
            else
              ...result.products.map(
                (p) => ProductCard(product: p, shoppingCategories: widget.shoppingCategories),
              ),
          ],
        ),
      );
}
