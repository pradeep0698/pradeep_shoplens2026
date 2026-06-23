import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/api_constants.dart';

// Three separate Dio instances — one per existing Cloud Run service
Dio _buildDio(String baseUrl, {Duration receiveTimeout = const Duration(seconds: 60)}) => Dio(
      BaseOptions(
        baseUrl:        baseUrl,
        connectTimeout: const Duration(seconds: 60),
        receiveTimeout: receiveTimeout,
        headers:        {'Content-Type': 'application/json'},
      ),
    )..interceptors.add(LogInterceptor(responseBody: true));

// Analyzer gets a longer timeout — it runs Gemini + imgbb + Lens per product
final analyzerDioProvider = Provider<Dio>((_) => _buildDio(ApiConstants.analyzerBaseUrl, receiveTimeout: const Duration(minutes: 5)));
final matcherDioProvider  = Provider<Dio>((_) => _buildDio(ApiConstants.matcherBaseUrl));
final stateDioProvider    = Provider<Dio>((_) => _buildDio(ApiConstants.stateBaseUrl));

// voice-assistant is the first backend service that requires auth — it's the
// first one that writes UserProfiles server-side. Fetch a fresh Firebase ID
// token per request rather than baking one into baseOptions (tokens expire).
final voiceDioProvider = Provider<Dio>((_) {
  final dio = _buildDio(ApiConstants.voiceAssistantBaseUrl);
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token != null) options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    },
  ));
  return dio;
});
