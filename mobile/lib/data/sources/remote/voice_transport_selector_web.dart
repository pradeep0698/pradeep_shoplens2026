import 'voice_api.dart';
import 'voice_socket_client.dart';
import 'voice_transport.dart';

/// Web always uses the WS proxy — browsers cannot set custom auth headers
/// on a WebSocket handshake (a W3C spec limit), which the direct-connect
/// transport's ephemeral-token auth requires. [voiceApi]/[directConnectAllowed]
/// are accepted for signature parity with the native variant but unused here.
VoiceTransport createVoiceTransport({
  required bool directConnectAllowed,
  required VoiceApi voiceApi,
}) =>
    VoiceSocketClient();
