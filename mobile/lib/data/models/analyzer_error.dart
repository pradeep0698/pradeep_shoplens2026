import 'package:dio/dio.dart';

/// Mirrors the `error_code` values returned by services/ai-analyzer.
enum AnalyzerErrorCode {
  invalidRequest,
  imageDecodeFailed,
  imageFetchFailed,
  geminiQuotaExceeded,
  geminiUnavailable,
  geminiTimeout,
  geminiAuthError,
  geminiInvalidInput,
  geminiError,
  upstreamError,
  internalError,
  requestError,
  networkTimeout,
  networkError,
  unknown;

  static AnalyzerErrorCode fromWire(String? code) => switch (code) {
        'INVALID_REQUEST'       => AnalyzerErrorCode.invalidRequest,
        'IMAGE_DECODE_FAILED'   => AnalyzerErrorCode.imageDecodeFailed,
        'IMAGE_FETCH_FAILED'    => AnalyzerErrorCode.imageFetchFailed,
        'GEMINI_QUOTA_EXCEEDED' => AnalyzerErrorCode.geminiQuotaExceeded,
        'GEMINI_UNAVAILABLE'    => AnalyzerErrorCode.geminiUnavailable,
        'GEMINI_TIMEOUT'        => AnalyzerErrorCode.geminiTimeout,
        'GEMINI_AUTH_ERROR'     => AnalyzerErrorCode.geminiAuthError,
        'GEMINI_INVALID_INPUT'  => AnalyzerErrorCode.geminiInvalidInput,
        'GEMINI_ERROR'          => AnalyzerErrorCode.geminiError,
        'UPSTREAM_ERROR'        => AnalyzerErrorCode.upstreamError,
        'INTERNAL_ERROR'        => AnalyzerErrorCode.internalError,
        'REQUEST_ERROR'         => AnalyzerErrorCode.requestError,
        _                       => AnalyzerErrorCode.unknown,
      };
}

/// Thrown by [AnalyzerApi] in place of raw [DioException]s, carrying the
/// backend's `error_code` (when available) so the UI can show a specific
/// message and decide whether retrying makes sense.
class AnalyzerException implements Exception {
  const AnalyzerException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final AnalyzerErrorCode code;
  final String message;
  final int? statusCode;

  factory AnalyzerException.fromDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const AnalyzerException(
          code: AnalyzerErrorCode.networkTimeout,
          message: 'Taking longer than usual — try again in a moment!',
        );
      case DioExceptionType.connectionError:
        return const AnalyzerException(
          code: AnalyzerErrorCode.networkError,
          message: 'Could not reach the server — check your connection and try again.',
        );
      default:
        break;
    }

    final body = e.response?.data;
    final detail = body is Map ? body['detail'] : null;
    final codeStr = body is Map ? body['error_code'] as String? : null;
    return AnalyzerException(
      code: AnalyzerErrorCode.fromWire(codeStr),
      message: detail?.toString() ?? e.message ?? 'Something went wrong',
      statusCode: e.response?.statusCode,
    );
  }

  /// User-facing message. Falls back to friendlier wording for backend codes
  /// whose `detail` is a raw exception string not meant for end users.
  String get displayMessage => switch (code) {
        AnalyzerErrorCode.geminiQuotaExceeded => 'Our AI is busy right now — please try again in a minute.',
        AnalyzerErrorCode.geminiUnavailable   => 'The AI service is temporarily unavailable — please try again shortly.',
        AnalyzerErrorCode.geminiTimeout       => 'That took too long to process — please try again.',
        AnalyzerErrorCode.geminiAuthError     => 'The AI service is misconfigured — please contact support.',
        AnalyzerErrorCode.geminiInvalidInput  => "That image couldn't be processed — please try a different photo.",
        AnalyzerErrorCode.geminiError         => 'The AI service hit an error — please try again.',
        AnalyzerErrorCode.upstreamError       => 'The AI service is temporarily unavailable — please try again shortly.',
        AnalyzerErrorCode.imageFetchFailed    => 'Could not load that image — please try a different one.',
        AnalyzerErrorCode.imageDecodeFailed   => "That image couldn't be read — please try a different photo.",
        AnalyzerErrorCode.networkTimeout      => message,
        AnalyzerErrorCode.networkError        => message,
        _                                      => 'Something went wrong — please try again.',
      };

  /// Whether retrying the same request without changes is likely to help.
  bool get isRetryable => switch (code) {
        AnalyzerErrorCode.geminiQuotaExceeded ||
        AnalyzerErrorCode.geminiUnavailable ||
        AnalyzerErrorCode.geminiTimeout ||
        AnalyzerErrorCode.geminiError ||
        AnalyzerErrorCode.upstreamError ||
        AnalyzerErrorCode.networkTimeout ||
        AnalyzerErrorCode.networkError =>
          true,
        _ => false,
      };

  @override
  String toString() => displayMessage;
}
