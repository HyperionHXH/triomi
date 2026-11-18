import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Diagnostics records are bounded summaries, never raw request transcripts.
/// This file owns the few transformations used both for local storage labels
/// and for the exported JSON.
String diagnosticsSourceDigest(String sourceId) {
  final hash = sha256.convert(utf8.encode(sourceId)).toString();
  return 'sha256:${hash.substring(0, 16)}';
}

/// Labels come from rule metadata and are therefore untrusted. Keep only a
/// short human hint; URLs, credentials, control characters and long opaque
/// tokens are removed. The stable digest remains available for correlation.
String sanitizeDiagnosticsLabel(String value, {required String sourceId}) {
  final digest = diagnosticsSourceDigest(sourceId);
  var text = value
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'https?://[^\s]+', caseSensitive: false), '[链接已隐藏]')
      .replaceAll(
        RegExp(r'\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
        '[凭据已隐藏]',
      )
      .replaceAll(
        RegExp(r'\b(?:token|secret|password|passwd|api[_-]?key)\s*[:=]\s*\S+',
            caseSensitive: false),
        '[凭据已隐藏]',
      )
      .replaceAll(
        RegExp(r'[A-Za-z0-9+/=_-]{32,}'),
        '[长串已隐藏]',
      )
      .replaceAll(
        RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+'),
        '[邮箱已隐藏]',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length > 48) text = '${text.substring(0, 48)}…';
  if (text.isEmpty) {
    return '来源 ${digest.substring('sha256:'.length, 'sha256:'.length + 8)}';
  }
  return text;
}

/// Plugin versions are display metadata, not proof of trust. Keep a bounded
/// printable hint while refusing URLs and credential-shaped strings.
String? sanitizeDiagnosticsVersion(Object? value) {
  if (value == null) return null;
  var text = '$value'
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'https?://[^\s]+', caseSensitive: false), '[已隐藏]')
      .replaceAll(
        RegExp(r'\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
        '[已隐藏]',
      )
      .replaceAll(
        RegExp(r'\b(?:token|secret|password|passwd|api[_-]?key)\s*[:=]\s*\S+',
            caseSensitive: false),
        '[已隐藏]',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length > 64) text = '${text.substring(0, 64)}…';
  return text.isEmpty ? null : text;
}

String sanitizeDiagnosticsAppVersion(Object? value) =>
    sanitizeDiagnosticsVersion(value) ?? 'unknown';