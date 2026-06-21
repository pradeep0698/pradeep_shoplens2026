import 'dart:convert';

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

  // Calls POST /analyze/stream — same detection as /analyze, but yields one
  // event per item as its Lens search completes instead of waiting for the
  // slowest item before returning anything. Event shapes (by "type"):
  //   {"type": "items", "items": [...]}
  //   {"type": "match", "name": ..., "products": [...], "warnings": [...]}
  //   {"type": "done", "warnings": [...]}
  //   {"type": "error", "detail": ..., "error_code": ...}
  Stream<Map<String, dynamic>> analyzeStream(AnalyzeRequest request) async* {
    ResponseBody body;
    try {
      final response = await _dio.post<ResponseBody>(
        '/analyze/stream',
        data: request.toJson(),
        options: Options(responseType: ResponseType.stream),
      );
      body = response.data!;
    } on DioException catch (e) {
      throw AnalyzerException.fromDioException(e);
    }

    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      yield jsonDecode(line) as Map<String, dynamic>;
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
