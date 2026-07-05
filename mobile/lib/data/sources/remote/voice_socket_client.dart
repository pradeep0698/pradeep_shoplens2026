import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/constants/api_constants.dart';
import 'voice_transport.dart';

/// Thin wrapper around [WebSocketChannel] for the voice-assistant relay —
/// the WS-proxy transport (client -> backend -> Gemini Live). Used on all
/// platforms today; on native platforms it's superseded by
/// GeminiLiveSocketClient when direct-connect is enabled (see
/// voice_transport_selector.dart), but always used on web since browsers
/// can't set the custom auth headers a direct connection needs.
///
/// Owned by VoiceAssistantNotifier for the lifetime of a single session —
/// not a shared/singleton provider, since each conversation gets its own socket.
class VoiceSocketClient implements VoiceTransport {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _frames = StreamController<VoiceSocketFrame>.broadcast();

  @override
  Stream<VoiceSocketFrame> get frames => _frames.stream;

  @override
  Future<void> connect({required String sessionId, required String wsUrl}) async {
    final channel = WebSocketChannel.connect(Uri.parse(ApiConstants.voiceAssistantWsUrl(wsUrl)));
    await channel.ready;
    _channel = channel;
    _subscription = channel.stream.listen(
      (event) {
        if (event is List<int>) {
          _frames.add(VoiceAudioFrame(Uint8List.fromList(event)));
          return;
        }
        if (event is String) {
          try {
            _frames.add(VoiceControlFrame(jsonDecode(event) as Map<String, dynamic>));
          } catch (_) {
            // Malformed/non-JSON text frame — ignore rather than crash the session.
          }
        }
      },
      onDone: () => _frames.add(const VoiceSocketClosed()),
      onError: (Object error, StackTrace _) => _frames.addError(error),
    );
  }

  @override
  void sendAudio(Uint8List chunk) => _channel?.sink.add(chunk);

  @override
  void sendText(String text) =>
      _channel?.sink.add(jsonEncode({'type': 'text', 'text': text}));

  /// Declares the real mic capture rate to the backend — must be sent before
  /// any audio bytes. On web the actual rate the browser ends up using is
  /// outside our control (see web_audio_sample_rate_web.dart), so the backend
  /// can't safely assume 16000 for every client.
  @override
  void sendAudioFormat(int sampleRate) =>
      _channel?.sink.add(jsonEncode({'type': 'audio_format', 'sample_rate': sampleRate}));

  /// Marks the start/end of a hold-to-talk turn — required because the
  /// backend disables Gemini's own voice-activity detection in favor of
  /// explicit client-driven turn boundaries (see live_session.py's
  /// realtime_input_config).
  @override
  void sendSpeechStart() => _channel?.sink.add(jsonEncode({'type': 'speech_start'}));

  @override
  void sendSpeechEnd() => _channel?.sink.add(jsonEncode({'type': 'speech_end'}));

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    close();
    _frames.close();
  }
}
