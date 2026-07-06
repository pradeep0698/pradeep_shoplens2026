import '../../../core/constants/api_constants.dart';
import 'gemini_live_socket_client.dart';
import 'voice_api.dart';
import 'voice_socket_client.dart';
import 'voice_transport.dart';

/// Picks the direct-connect transport only when BOTH the compile-time
/// dart-define flag and the server's own kill switch agree — either one
/// being off falls back to the WS proxy. Two independent signals rather
/// than one: the dart-define needs a rebuild to flip (staged mobile
/// rollout), the server flag is instant/fleet-wide (production safety net
/// if the direct path misbehaves after already shipping).
VoiceTransport createVoiceTransport({
  required bool directConnectAllowed,
  required VoiceApi voiceApi,
}) =>
    (directConnectAllowed && ApiConstants.voiceDirectConnectFlagEnabled)
        ? GeminiLiveSocketClient(voiceApi)
        : VoiceSocketClient();
