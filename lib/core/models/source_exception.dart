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
  });

  final String sourceId;
  final SourceErrorType type;

  /// 面向开发者的补充信息（不直接展示给用户）。
  final String? message;

  final Object? cause;

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
    final text = error.toString().toLowerCase();
    if (text.contains('timeout') || text.contains('超时')) {
      return SourceErrorType.timeout;
    }
    if (text.contains('401') || text.contains('403')) {
      return SourceErrorType.auth;
    }
    if (text.contains('404')) return SourceErrorType.notFound;
    if (text.contains('429')) return SourceErrorType.rateLimited;
    return SourceErrorType.network;
  }

  @override
  String toString() => 'SourceException($sourceId, ${type.name}): $message';
}
