import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/models/media_type.dart';
import '../../../core/models/source_exception.dart';
import 'source_diagnostics_models.dart';

/// Result of inspecting only structured exception fields. The unused message
/// text is never persisted, exported or copied.
class SourceDiagnosticsDiagnosis {
  const SourceDiagnosticsDiagnosis(this.category, {this.statusCode});

  final SourceDiagnosticsCategory category;
  final int? statusCode;
}

/// Maps [SourceException] / [DioException] details (including nested causes)
/// to an honest category.
///
/// A 403 stays "access denied"; it is never upgraded to "login expired" or
/// "Cloudflare challenge" without evidence. Errors that carry no recognised
/// structure remain [SourceDiagnosticsCategory.unknown].
SourceDiagnosticsDiagnosis diagnoseSourceDiagnosticsError(Object error) =>
    _diagnose(error, 0, <Object>{});

SourceDiagnosticsDiagnosis _diagnose(
  Object error,
  int depth,
  Set<Object> visited,
) {
  if (depth > 8 || visited.contains(error)) {
    return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.unknown);
  }
  visited.add(error);
  if (error is SourceException) {
    final statusCode = error.statusCode;
    if (statusCode != null) return _fromStatus(statusCode);
    final direct = _fromSourceErrorType(error.type);
    if (direct != null) return SourceDiagnosticsDiagnosis(direct);
    final cause = error.cause;
    if (cause != null) {
      final nested = _diagnose(cause, depth + 1, visited);
      if (nested.category != SourceDiagnosticsCategory.unknown) return nested;
    }
    return SourceDiagnosticsDiagnosis(
      error.type == SourceErrorType.network
          ? SourceDiagnosticsCategory.network
          : SourceDiagnosticsCategory.unknown,
    );
  }

  if (error is DioException) {
    final status = error.response?.statusCode;
    switch (error.type) {
      case DioExceptionType.badCertificate:
        return const SourceDiagnosticsDiagnosis(
          SourceDiagnosticsCategory.tls,
        );
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const SourceDiagnosticsDiagnosis(
          SourceDiagnosticsCategory.timeout,
        );
      case DioExceptionType.badResponse:
        return status == null
            ? const SourceDiagnosticsDiagnosis(
                SourceDiagnosticsCategory.unknown,
              )
            : _fromStatus(status);
      case DioExceptionType.cancel:
        return const SourceDiagnosticsDiagnosis(
          SourceDiagnosticsCategory.cancelled,
        );
      case DioExceptionType.connectionError:
        final nested = error.error == null
            ? null
            : _diagnose(error.error!, depth + 1, visited);
        return nested != null &&
                nested.category != SourceDiagnosticsCategory.unknown
            ? nested
            : const SourceDiagnosticsDiagnosis(
                SourceDiagnosticsCategory.connection,
              );
      case DioExceptionType.unknown:
        final nested = error.error == null
            ? null
            : _diagnose(error.error!, depth + 1, visited);
        return nested ?? const SourceDiagnosticsDiagnosis(
          SourceDiagnosticsCategory.unknown,
        );
    }
  }

  if (error is TimeoutException) {
    return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.timeout);
  }
  if (error is FormatException) {
    return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.parser);
  }

  final runtimeType = error.runtimeType.toString();
  final text = error.toString();
  if (runtimeType.contains('HandshakeException') ||
      runtimeType.contains('TlsException') ||
      runtimeType.contains('CertificateException')) {
    return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.tls);
  }
  if (runtimeType.contains('SocketException') ||
      runtimeType.contains('HttpException')) {
    return SourceDiagnosticsDiagnosis(
      _looksLikeDnsFailure(text)
          ? SourceDiagnosticsCategory.dns
          : SourceDiagnosticsCategory.connection,
    );
  }
  return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.unknown);
}

SourceDiagnosticsCategory? _fromSourceErrorType(SourceErrorType type) =>
    switch (type) {
      SourceErrorType.timeout => SourceDiagnosticsCategory.timeout,
      SourceErrorType.parse => SourceDiagnosticsCategory.parser,
      SourceErrorType.permission => SourceDiagnosticsCategory.permission,
      SourceErrorType.auth => SourceDiagnosticsCategory.auth,
      SourceErrorType.rateLimited => SourceDiagnosticsCategory.rateLimited,
      SourceErrorType.notFound => SourceDiagnosticsCategory.notFound,
      SourceErrorType.network => null,
    };

SourceDiagnosticsDiagnosis _fromStatus(int statusCode) {
  if (statusCode < 100 || statusCode > 599) {
    return const SourceDiagnosticsDiagnosis(SourceDiagnosticsCategory.unknown);
  }
  final category = switch (statusCode) {
    401 || 407 => SourceDiagnosticsCategory.auth,
    // 403 means "the server refused this request". It does not prove an
    // expired login or a Cloudflare challenge.
    403 || 451 => SourceDiagnosticsCategory.permission,
    408 => SourceDiagnosticsCategory.timeout,
    429 => SourceDiagnosticsCategory.rateLimited,
    404 || 410 => SourceDiagnosticsCategory.notFound,
    _ => SourceDiagnosticsCategory.httpStatus,
  };
  return SourceDiagnosticsDiagnosis(category, statusCode: statusCode);
}

bool _looksLikeDnsFailure(String text) {
  final value = text.toLowerCase();
  return value.contains('failed host lookup') ||
      value.contains('getaddrinfo') ||
      value.contains('name or service not known') ||
      value.contains('nodename nor servname') ||
      value.contains('no address associated') ||
      value.contains('temporary failure in name resolution') ||
      value.contains('unknown host') ||
      value.contains('host not found');
}