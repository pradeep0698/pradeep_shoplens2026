import 'dart:typed_data';

import '../../models/voice_session.dart';

sealed class VoiceSocketFrame {
  const VoiceSocketFrame();
}

/// Raw model speech audio: 16-bit PCM, little-endian, 24kHz, mono (Gemini
/// Live API's fixed output format). Played back via flutter_sound's
/// stream-playback API in VoiceAssistantNotifier.
class VoiceAudioFrame extends VoiceSocketFrame {
  const VoiceAudioFrame(this.data);
  final Uint8List data;
}

/// Any JSON control frame — either relayed from the backend (proxy
/// transport, see services/voice-assistant/live_session.py) or synthesized
/// locally from a direct Gemini Live message (direct-connect transport, see
/// gemini_live_socket_client.dart) — both use the identical `type` vocabulary
/// (transcript, preference_patch, search_started, product_results,
/// finalize_proposal, interrupted, auto_saved, session_timeout) so
/// VoiceAssistantNotifier's _handleControlFrame needs no transport-specific logic.
class VoiceControlFrame extends VoiceSocketFrame {
  const VoiceControlFrame(this.json);
  final Map<String, dynamic> json;
}

/// [code]/[reason] are the underlying WebSocket close code/reason when the
/// transport has them (both dart:io's WebSocket and web_socket_channel
/// expose these once the socket closes) — surfaced so a dropped connection
/// can be diagnosed from the in-app error message alone, without a device
/// console attached (the direct-connect transport in particular bypasses
/// the backend entirely, so server logs show nothing about why it closed).
class VoiceSocketClosed extends VoiceSocketFrame {
  const VoiceSocketClosed({this.code, this.reason});
  final int? code;
  final String? reason;
}

/// Common surface both the WS-proxy transport (VoiceSocketClient) and the
/// native-only direct-connect transport (GeminiLiveSocketClient) implement,
/// so VoiceAssistantNotifier can be constructed against either one
/// interchangeably — see voice_transport_selector.dart for how the choice
/// is made per-platform/per-flag.
abstract class VoiceTransport {
  Stream<VoiceSocketFrame> get frames;

  /// [wsUrl] is the backend-supplied relative proxy path
  /// (VoiceSessionStartResponse.wsUrl) — only the proxy transport uses it.
  /// [sessionId] is always passed too since the direct-connect transport
  /// needs it to call the tool REST endpoints; the proxy transport ignores it.
  ///
  /// [existingProfile]/[mode]/[language]/[resumeTranscript] are only consumed
  /// by the direct-connect transport, which builds its own `setup` JSON
  /// client-side (see gemini_live_setup_builder.dart) instead of fetching one
  /// from the backend — the proxy transport ignores them, mirroring the
  /// existing precedent where the direct client already ignores [wsUrl].
  Future<void> connect({
    required String sessionId,
    required String wsUrl,
    required VoiceProfilePatch existingProfile,
    required String mode,
    required String language,
    required List<VoiceTranscriptTurn> resumeTranscript,
  });

  void sendAudio(Uint8List chunk);

  void sendText(String text);

  /// Declares the real mic capture rate — required before any audio bytes
  /// on the proxy transport; a no-op on the direct-connect transport, which
  /// embeds the mime type per audio chunk instead (see realtime_input's wire
  /// shape in gemini_live_socket_client.dart).
  void sendAudioFormat(int sampleRate);

  void sendSpeechStart();

  void sendSpeechEnd();

  Future<void> close();

  void dispose();
}
