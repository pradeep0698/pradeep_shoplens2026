import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConstants {
  static String get analyzerBaseUrl => dotenv.env['ANALYZER_API_URL']!;
  static String get matcherBaseUrl => dotenv.env['MATCHER_API_URL']!;
  static String get stateBaseUrl => dotenv.env['STATE_API_URL']!;

  static String get voiceAssistantBaseUrl => dotenv.env['VOICE_ASSISTANT_API_URL']!;

  // The backend returns a relative ws_url (e.g. "/voice/session/{id}/stream");
  // combine it with the host here rather than hardcoding it server-side.
  // Mirrors VOICE_ASSISTANT_API_URL's own scheme (wss for the deployed https
  // Cloud Run URL, ws for a local http://localhost:8080 override) so this
  // still works when pointed at a local backend for debugging.
  static String voiceAssistantWsUrl(String relativePath) {
    final base = Uri.parse(voiceAssistantBaseUrl);
    final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
    return '$wsScheme://${base.host}${base.hasPort ? ':${base.port}' : ''}$relativePath';
  }
}
