import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConstants {
  // Prefer compile-time dart-define (set via --dart-define-from-file) so that
  // environment-specific builds (e.g. cookshop-dev) don't require swapping .env.
  // Falls back to the runtime .env file for local development.
  static String get analyzerBaseUrl =>
      const String.fromEnvironment('ANALYZER_API_URL').isNotEmpty
          ? const String.fromEnvironment('ANALYZER_API_URL')
          : dotenv.env['ANALYZER_API_URL']!;

  static String get matcherBaseUrl =>
      const String.fromEnvironment('MATCHER_API_URL').isNotEmpty
          ? const String.fromEnvironment('MATCHER_API_URL')
          : dotenv.env['MATCHER_API_URL']!;

  static String get stateBaseUrl =>
      const String.fromEnvironment('STATE_API_URL').isNotEmpty
          ? const String.fromEnvironment('STATE_API_URL')
          : dotenv.env['STATE_API_URL']!;

  static String get voiceAssistantBaseUrl =>
      const String.fromEnvironment('VOICE_ASSISTANT_API_URL').isNotEmpty
          ? const String.fromEnvironment('VOICE_ASSISTANT_API_URL')
          : dotenv.env['VOICE_ASSISTANT_API_URL']!;

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
