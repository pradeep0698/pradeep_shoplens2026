import 'package:dio/dio.dart';
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
