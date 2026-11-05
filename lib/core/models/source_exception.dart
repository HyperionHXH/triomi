import 'package:dio/dio.dart';

import 'media_type.dart';

/// 来源层统一异常。
///
/// 聚合操作允许部分成功：每个失败都必须能说明「是哪个来源、哪一类错误」，
/// 所以这里强制携带 [sourceId] 与 [type]。
class SourceException implements Exception {
  const SourceException({
    required this.sourceId,
    required this.type,
    this.message = '',
    this.cause,
    this.statusCode,
    this.retryAfter,
  });

  final String sourceId;
  final SourceErrorType type;

  /// 面向开发者的补充信息（不直接展示给用户）。
  final String? message;

  final Object? cause;
  final int? statusCode;
  final DateTime? retryAfter;

  /// Retry-After is either delta seconds or an RFC 7231 HTTP date.
  static DateTime? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      final instant = now ?? DateTime.now();
      // Bound before multiplying: Duration uses signed integer microseconds.
      const maxMicroseconds = 8640000000000000000;
      final maximum =
          (maxMicroseconds - instant.microsecondsSinceEpoch) ~/
          Duration.microsecondsPerSecond;
      if (seconds < 0 || seconds > maximum) return null;
      return instant.add(Duration(seconds: seconds));
    }
    final match = RegExp(
      r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = months.indexOf(match[2]!);
    if (month < 0) return null;
    final year = int.parse(match[3]!), day = int.parse(match[1]!);
    final hour = int.parse(match[4]!), minute = int.parse(match[5]!);
    final second = int.parse(match[6]!);
    final date = DateTime.utc(year, month + 1, day, hour, minute, second);
    // DateTime normalizes impossible dates; an HTTP header must not do so.
    return date.year == year &&
            date.month == month + 1 &&
            date.day == day &&
            date.hour == hour &&
            date.minute == minute &&
            date.second == second
        ? date
        : null;
  }

  /// 给用户看的说明。
  String get userMessage => message != null && message!.isNotEmpty
      ? '${type.label}：$message'
      : type.label;

  /// 把任意底层异常映射为分类明确的来源异常。
  factory SourceException.wrap(
    Object error, {
    required String sourceId,
    String? url,
  }) {
    if (error is SourceException) return error;
    final safeUrl = url == null ? null : _safeUrl(url);
    return SourceException(
      sourceId: sourceId,
      type: _classify(error),
      message: safeUrl == null
          ? sanitizeMessage('$error')
          : '$safeUrl：${sanitizeMessage('$error')}',
      cause: error,
      statusCode: error is DioException ? error.response?.statusCode : null,
      retryAfter: error is DioException
          ? parseRetryAfter(error.response?.headers.value('retry-after'))
          : null,
    );
  }

  static String _safeUrl(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme.isNotEmpty && uri.host.isNotEmpty) {
        return Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        ).toString();
      }
    } catch (_) {
      // Fall through to the conservative string form below.
    }
    return value.split('?').first.split('#').first;
  }

  /// Removes credentials from error text that may contain a request URL.
  static String sanitizeMessage(String value) {
    final urlPattern = RegExp(r'https?://[^\s：]+', caseSensitive: false);
    return value.replaceAllMapped(
      urlPattern,
      (match) => _safeUrl(match.group(0)!),
    );
  }

  static SourceErrorType _classify(Object error) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return SourceErrorType.timeout;
      }
      return _httpStatusType(error.response?.statusCode);
    }
    final text = error.toString().toLowerCase();
    if (text.contains('timeout') || text.contains('超时')) {
      return SourceErrorType.timeout;
    }
    final status = RegExp(
      r'\b(?:http(?:/\d(?:\.\d)?)?|status(?:\s+code)?)\s*[:=]?\s*(401|403|404|429)\b',
    ).firstMatch(text);
    if (status != null) return _httpStatusType(int.parse(status[1]!));
    return SourceErrorType.network;
  }

  static SourceErrorType _httpStatusType(int? status) => switch (status) {
    401 || 403 => SourceErrorType.auth,
    404 => SourceErrorType.notFound,
    429 => SourceErrorType.rateLimited,
    _ => SourceErrorType.network,
  };

  @override
  String toString() => 'SourceException($sourceId, ${type.name}): $message';
}
