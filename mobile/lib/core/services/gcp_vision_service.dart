import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';

import 'vision_service.dart';

/// Google Cloud Vision REST API implementation of [VisionService].
///
/// To migrate to Vertex AI / Gemini Flash:
///   1. Subclass this and override [buildPayload] with the Gemini request shape.
///   2. Override [parseResponse] to extract labels from the Gemini response.
///   3. Pass a different [endpoint] and auth header to the constructor.
///   Everything in the widget layer stays untouched.
class GCPVisionService implements VisionService {
  GCPVisionService({
    required this.apiKey,
    this.endpoint = 'https://vision.googleapis.com/v1/images:annotate',
    this.maxResults = 5,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  final String apiKey;
  final String endpoint;
  final int maxResults;
  final Dio _dio;

  @override
  Future<VisionResult> identify(Uint8List croppedImageBytes) async {
    final payload = buildPayload(croppedImageBytes);
    final response = await _dio.post<Map<String, dynamic>>(
      '$endpoint?key=$apiKey',
      data: payload,
      options: Options(
        headers: {'Content-Type': 'application/json'},
        responseType: ResponseType.json,
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      throw Exception('Vision API ${response.statusCode}: ${response.data}');
    }
    return parseResponse(response.data!);
  }

  /// Override to change the request format (e.g. Vertex AI / Gemini).
  Map<String, dynamic> buildPayload(Uint8List bytes) => {
        'requests': [
          {
            'image': {'content': base64Encode(bytes)},
            'features': [
              {'type': 'OBJECT_LOCALIZATION', 'maxResults': maxResults},
              {'type': 'LABEL_DETECTION', 'maxResults': maxResults},
            ],
          }
        ],
      };

  /// Override to parse a different response shape.
  VisionResult parseResponse(Map<String, dynamic> body) {
    final res =
        ((body['responses'] as List).first) as Map<String, dynamic>;

    List<VisionLabel> extract(String key, String nameKey) =>
        ((res[key] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map((e) {
              Rect? box;
              final poly = e['boundingPoly']?['normalizedVertices'] as List?;
              if (poly != null && poly.length == 4) {
                final verts = poly.cast<Map<String, dynamic>>();
                final xs = verts.map((v) => (v['x'] as num?)?.toDouble() ?? 0.0);
                final ys = verts.map((v) => (v['y'] as num?)?.toDouble() ?? 0.0);
                box = Rect.fromLTRB(
                  xs.reduce(min), ys.reduce(min),
                  xs.reduce(max), ys.reduce(max),
                );
              }
              return VisionLabel(
                description: e[nameKey] as String,
                score: (e['score'] as num).toDouble(),
                boundingBox: box,
              );
            })
            .toList();

    return VisionResult(
      objects: extract('localizedObjectAnnotations', 'name'),
      labels: extract('labelAnnotations', 'description'),
    );
  }
}
