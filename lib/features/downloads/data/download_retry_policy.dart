import 'dart:async';
import 'dart:io';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';

/// Only transient transport failures are retried, never source access controls.
class DownloadRetryPolicy {
  static const maxRetries = 3;
  static const delays = [
    Duration(seconds: 2),
    Duration(seconds: 8),
    Duration(seconds: 30),
  ];

  static bool transient(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is! SourceException) return false;
    final text = (error.message ?? '').toLowerCase();
    if (RegExp(r'captcha|challenge|cloudflare|登录|登陆|验证|付费|锁定|解锁')
        .hasMatch(text)) {
      return false;
    }
    if (error.type != SourceErrorType.network &&
        error.type != SourceErrorType.timeout &&
        error.type != SourceErrorType.rateLimited) {
      return false;
    }
    final status = error.statusCode;
    if (status != null) {
      return status == 408 || status == 429 || status >= 500 && status <= 599;
    }
    return true;
  }

  static DateTime nextAttempt(
    int previousRetries,
    Object error, {
    DateTime? now,
  }) {
    final instant = now ?? DateTime.now();
    final minimum = instant.add(
      delays[previousRetries.clamp(0, delays.length - 1)],
    );
    final server = error is SourceException ? error.retryAfter : null;
    return server != null && server.isAfter(minimum) ? server : minimum;
  }
}
