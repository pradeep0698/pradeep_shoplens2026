import 'package:flutter/material.dart';
import '../../data/models/analyzer_error.dart';
import '../providers/pipeline_provider.dart';

class PipelineStatusBar extends StatelessWidget {
  const PipelineStatusBar({
    super.key,
    required this.status,
    this.errorMessage,
    this.errorCode,
    this.isRetryable = false,
    this.warnings = const [],
    this.foundProducts,
  });

  final PipelineStatus status;
  final String?        errorMessage;
  final AnalyzerErrorCode? errorCode;
  final bool           isRetryable;
  final List<String>   warnings;
  final bool?          foundProducts;

  @override
  Widget build(BuildContext context) {
    if (status == PipelineStatus.idle) return const SizedBox.shrink();

    final isError   = status == PipelineStatus.error ||
        (status == PipelineStatus.success && warnings.contains('SERP_QUOTA_EXCEEDED'));
    final isSuccess = (status == PipelineStatus.success && foundProducts != null)
        || status == PipelineStatus.timeout;
    final label     = _label(status, errorMessage, foundProducts, warnings);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isError
            ? const Color(0xFF450A0A)
            : isSuccess
                ? const Color(0xFF052E16)
                : const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? const Color(0xFF991B1B)
              : isSuccess
                  ? const Color(0xFF166534)
                  : const Color(0xFF1E3A5F),
        ),
      ),
      child: Row(
        children: [
          if (!isError && !isSuccess)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF34D399),
              ),
            )
          else
            Icon(
              isError ? _errorIcon(errorCode) : Icons.check_circle_outline,
              size:  16,
              color: isError ? const Color(0xFFF87171) : const Color(0xFF34D399),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isError
                    ? const Color(0xFFFCA5A5)
                    : isSuccess
                        ? const Color(0xFF6EE7B7)
                        : const Color(0xFF94A3B8),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (isError && isRetryable) ...[
            const SizedBox(width: 10),
            const Icon(Icons.refresh, size: 14, color: Color(0xFFFCA5A5)),
          ],
        ],
      ),
    );
  }

  static IconData _errorIcon(AnalyzerErrorCode? code) => switch (code) {
        AnalyzerErrorCode.networkTimeout      => Icons.timer_outlined,
        AnalyzerErrorCode.networkError        => Icons.wifi_off,
        AnalyzerErrorCode.geminiQuotaExceeded => Icons.hourglass_bottom,
        AnalyzerErrorCode.geminiUnavailable   => Icons.cloud_off,
        AnalyzerErrorCode.geminiTimeout       => Icons.timer_outlined,
        _                                       => Icons.error_outline,
      };

  /// Friendlier "no products found" message based on the soft-failure
  /// warning codes the backend returned alongside a 200 OK response.
  static String _noResultsLabel(List<String> warnings) {
    if (warnings.contains('GEMINI_BLOCKED')) {
      return "This image couldn't be processed — try a different photo.";
    }
    if (warnings.contains('GEMINI_PARSE_FAILED') || warnings.contains('GEMINI_TRUNCATED')) {
      return 'Had trouble analyzing this image — try again.';
    }
    if (warnings.contains('SERP_QUOTA_EXCEEDED')) {
      return 'Search service is temporarily unavailable — please contact support.';
    }
    return 'No matching products found';
  }

  static String _label(PipelineStatus status, String? errorMessage, bool? foundProducts, List<String> warnings) =>
      switch (status) {
        PipelineStatus.analyzing => 'Analyzing image...',
        PipelineStatus.matching  => 'Matching products...',
        PipelineStatus.saving    => 'Saving to your list...',
        PipelineStatus.success   => switch (foundProducts) {
          null  => 'Loading results...',
          false => _noResultsLabel(warnings),
          _     => 'Done!',
        },
        PipelineStatus.timeout   => errorMessage ?? 'Taking longer than usual — try again in a moment!',
        PipelineStatus.error     => errorMessage ?? 'Something went wrong',
        PipelineStatus.idle      => '',
      };
}
