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
    return SourceException(
      sourceId: sourceId,
      type: _classify(error),
      message: url == null ? '$error' : '$url：$error',
      cause: error,
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
