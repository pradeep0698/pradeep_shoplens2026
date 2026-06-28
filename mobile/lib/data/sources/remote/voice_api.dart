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
  // language is a display name from voice_languages.dart's kVoiceLanguages
  // (e.g. "Spanish") — steers live_session.py's system-instruction directive;
  // unrecognized values fall back to "English" server-side.
  Future<VoiceSessionStartResponse> startSession({required bool isOnboarding, required String language}) async {
    try {
      final response = await _dio.post('/voice/session/start', data: {
        'mode': isOnboarding ? 'preferences' : 'search',
        'language': language,
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
}

final voiceApiProvider = Provider((ref) => VoiceApi(ref.read(voiceDioProvider)));
