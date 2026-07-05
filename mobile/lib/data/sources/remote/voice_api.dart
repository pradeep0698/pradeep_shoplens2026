import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/analyzer_error.dart';
import '../../models/voice_session.dart';
import 'dio_client.dart';

class VoiceApi {
  final Dio _dio;
  VoiceApi(this._dio);

  // Calls POST /voice/session/start on the voice-assistant Cloud Run service.
  // mode "preferences" is the forced first-run onboarding conversation that
  // learns/saves shopping preferences; "search" (every other session) is a
  // conversational product search instead — see live_session.py's SessionState.mode.
  Future<VoiceSessionStartResponse> startSession({required bool isOnboarding}) async {
    try {
      final response = await _dio.post('/voice/session/start', data: {
        'mode': isOnboarding ? 'preferences' : 'search',
      });
      return VoiceSessionStartResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  // Calls POST /voice/session/finalize — writes the confirmed patch to UserProfiles.
  Future<VoiceFinalizeResult> finalizeSession(String sessionId, VoiceProfilePatch confirmedPatch) async {
    try {
      final response = await _dio.post('/voice/session/finalize', data: {
        'session_id':      sessionId,
        'confirmed_patch': confirmedPatch.toJson(),
      });
      return VoiceFinalizeResult.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  // Mints an ephemeral Gemini Live auth token for the direct-connect
  // transport (native platforms only, see gemini_live_socket_client.dart) —
  // POST /voice/session/token.
  Future<VoiceSessionTokenResponse> mintToken(String sessionId) async {
    try {
      final response = await _dio.post('/voice/session/token', data: {'session_id': sessionId});
      return VoiceSessionTokenResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  // The following three reroute tool-call side effects through REST for the
  // direct-connect transport, instead of the WS-proxy relay handling them
  // server-side — see services/voice-assistant/main.py's /voice/tool/* routes.
  Future<Map<String, dynamic>> recordPreference(String sessionId, Map<String, dynamic> args) async {
    try {
      final response = await _dio.post('/voice/tool/record_preference', data: {'session_id': sessionId, ...args});
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  Future<Map<String, dynamic>> searchProducts(String sessionId, String query) async {
    try {
      final response = await _dio.post('/voice/tool/search_products', data: {'session_id': sessionId, 'query': query});
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  Future<Map<String, dynamic>> readyToFinalize(String sessionId, String summary) async {
    try {
      final response = await _dio.post('/voice/tool/ready_to_finalize', data: {'session_id': sessionId, 'summary': summary});
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }
}

final voiceApiProvider = Provider((ref) => VoiceApi(ref.read(voiceDioProvider)));
