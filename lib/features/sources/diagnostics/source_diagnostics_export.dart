import 'dart:convert';

import 'source_diagnostics_models.dart';
import 'source_diagnostics_redaction.dart';

/// Builds the only JSON shape this feature is allowed to export. Source IDs
/// are replaced with stable digests; labels are sanitized; runs contain only
/// allowlisted diagnostic summary fields.
Map<String, Object?> buildSourceDiagnosticsExport(
  SourceDiagnosticsHistory history, {
  required DateTime exportedAt,
}) => <String, Object?>{
  'schema': 'triomi.source-diagnostics',
  'version': 1,
  'exportedAt': exportedAt.toUtc().toIso8601String(),
  'sources': <Object?>[
    for (final source in history.orderedSources)
      <String, Object?>{
        'source': diagnosticsSourceDigest(source.sourceId),
        'label': sanitizeDiagnosticsLabel(
          source.label,
          sourceId: source.sourceId,
        ),
        if (source.lastSuccess != null)
          'lastSuccess': source.lastSuccess!.toJson(),
        if (source.lastFailure != null)
          'lastFailure': source.lastFailure!.toJson(),
        'runs': <Object?>[
          for (final run in source.runs.take(20)) run.toJson(),
        ],
      },
  ],
};

String encodeSourceDiagnosticsExport(
  SourceDiagnosticsHistory history, {
  required DateTime exportedAt,
}) => const JsonEncoder.withIndent(
  '  ',
).convert(buildSourceDiagnosticsExport(history, exportedAt: exportedAt));

/// Redacted, human-readable feedback for the selected source. It deliberately
/// excludes the query, raw error messages, URLs, request data and response
/// content.
String buildSourceDiagnosticsFeedback(SourceDiagnosticsSourceRecord source) {
  final lines = <String>[
    'Triomi 来源诊断（脱敏）',
    '来源：${sanitizeDiagnosticsLabel(source.label, sourceId: source.sourceId)}',
    '标识：${diagnosticsSourceDigest(source.sourceId)}',
    '',
  ];
  if (source.lastSuccess != null) {
    lines.add('最近成功：${_runSummary(source.lastSuccess!)}');
  } else {
    lines.add('最近成功：无');
  }
  if (source.lastFailure != null) {
    lines.add('最近失败：${_runSummary(source.lastFailure!)}');
  } else {
    lines.add('最近失败：无');
  }
  lines
    ..add('')
    ..add('最近 ${source.runs.take(20).length} 次记录：');
  for (final run in source.runs.take(20)) {
    lines.add('- ${_runSummary(run)}');
  }
  lines.add('');
  lines.add('此反馈不含关键词、原始错误、URL、请求头、响应内容或凭据。');
  return lines.join('\n');
}

String _runSummary(SourceDiagnosticsRunRecord run) {
  final parts = <String>[
    _formatTime(run.at),
    run.isSuccess ? '成功' : run.category.label,
  ];
  if (run.statusCode != null) parts.add('HTTP ${run.statusCode}');
  parts.add('${run.latencyMs} ms');
  if (run.resultCount != null) {
    parts.add('${run.resultCount} 条结果');
  }
  parts.add('app ${run.appVersion}');
  if (run.pluginVersion != null) parts.add('来源 ${run.pluginVersion}');
  return parts.join(' · ');
}

String _formatTime(DateTime value) {
  final time = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}