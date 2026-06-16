import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/match_request.dart';
import '../../models/match_response.dart';
import 'dio_client.dart';

class MatcherApi {
  final Dio _dio;
  MatcherApi(this._dio);

  // Calls POST /match on the Product Matcher Cloud Run service
  Future<MatchResponse> match(MatchRequest request) async {
    final response = await _dio.post('/match', data: request.toJson());
    return MatchResponse.fromJson(response.data as Map<String, dynamic>);
  }
}

final matcherApiProvider =
    Provider((ref) => MatcherApi(ref.read(matcherDioProvider)));
