import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

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

/// Any JSON control frame from the backend relay: transcript, preference_patch,
/// finalize_proposal, or session_timeout (see services/voice-assistant/live_session.py).
class VoiceControlFrame extends VoiceSocketFrame {
  const VoiceControlFrame(this.json);
  final Map<String, dynamic> json;
}

class VoiceSocketClosed extends VoiceSocketFrame {
  const VoiceSocketClosed();
}

/// Thin wrapper around [WebSocketChannel] for the voice-assistant relay.
/// Owned by VoiceAssistantNotifier for the lifetime of a single session —
/// not a shared/singleton provider, since each conversation gets its own socket.
class VoiceSocketClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final _frames = StreamController<VoiceSocketFrame>.broadcast();

  Stream<VoiceSocketFrame> get frames => _frames.stream;

  Future<void> connect(String wsUrl) async {
    final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
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

  void sendAudio(Uint8List chunk) => _channel?.sink.add(chunk);

  void sendText(String text) =>
      _channel?.sink.add(jsonEncode({'type': 'text', 'text': text}));

  /// Declares the real mic capture rate to the backend — must be sent before
  /// any audio bytes. On web the actual rate the browser ends up using is
  /// outside our control (see web_audio_sample_rate_web.dart), so the backend
  /// can't safely assume 16000 for every client.
  void sendAudioFormat(int sampleRate) =>
      _channel?.sink.add(jsonEncode({'type': 'audio_format', 'sample_rate': sampleRate}));

  /// Marks the start/end of a hold-to-talk turn — required because the
  /// backend disables Gemini's own voice-activity detection in favor of
  /// explicit client-driven turn boundaries (see live_session.py's
  /// realtime_input_config).
  void sendSpeechStart() => _channel?.sink.add(jsonEncode({'type': 'speech_start'}));

  void sendSpeechEnd() => _channel?.sink.add(jsonEncode({'type': 'speech_end'}));

  Future<void> close() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    close();
    _frames.close();
  }
}
