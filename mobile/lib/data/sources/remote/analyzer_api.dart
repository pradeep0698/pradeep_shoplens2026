import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/analyze_request.dart';
import '../../models/analyze_response.dart';
import '../../models/analyzer_error.dart';
import 'dio_client.dart';

class AnalyzerApi {
  final Dio _dio;
  AnalyzerApi(this._dio);

  // Calls POST /analyze on the AI Analyzer Cloud Run service
  Future<AnalyzeResponse> analyze(AnalyzeRequest request) async {
    try {
      final response = await _dio.post('/analyze', data: request.toJson());
      return AnalyzeResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }

  // Calls POST /identify — skips Gemini, sends pre-cropped image directly to Lens
  Future<AnalyzeResponse> identifyCrop(AnalyzeRequest request) async {
    try {
      final response = await _dio.post('/identify', data: request.toJson());
      return AnalyzeResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }
  }
}

final analyzerApiProvider =
    Provider((ref) => AnalyzerApi(ref.read(analyzerDioProvider)));
