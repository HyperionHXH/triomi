import 'package:flutter/foundation.dart';

import 'source_diagnostics_redaction.dart';

/// A safe, allowlisted diagnostic category. It never contains the raw error,
/// URL, request headers, response body or user query.
enum SourceDiagnosticsCategory {
  success('成功'),
  auth('登录 / 凭据问题'),
  permission('访问被拒绝'),
  rateLimited('请求过于频繁'),
  timeout('请求超时'),
  dns('域名解析失败'),
  tls('TLS / 证书失败'),
  connection('连接失败'),
  httpStatus('HTTP 状态异常'),
  parser('解析失败'),
  notFound('内容不存在'),
  network('网络异常'),
  cancelled('请求已取消'),
  unknown('未知错误');

  const SourceDiagnosticsCategory(this.label);

  final String label;

  bool get isFailure => this != success;

  static SourceDiagnosticsCategory? tryParse(String? value) {
    if (value == null) return null;
    for (final category in values) {
      if (category.name == value) return category;
    }
    return null;
  }
}

/// UI-facing reason a diagnostic operation did not produce a search outcome.
enum SourceDiagnosticsRunStatus {
  success('搜索成功'),
  failure('搜索失败'),
  sourceDisabled('来源已停用'),
  unsupported('不支持搜索'),
  invalidSource('来源规则无效'),
  sourceUnavailable('来源不可用'),
  registryError('来源注册表不可用'),
  busy('已有测试进行中'),
  throttled('操作过于频繁'),
  cancelled('已取消'),
  keywordRequired('需要测试关键词');

  const SourceDiagnosticsRunStatus(this.label);

  final String label;

  bool get isRecordable => this == success || this == failure;
}

@immutable
class SourceDiagnosticsTestResult {
  const SourceDiagnosticsTestResult({
    required this.status,
    required this.sourceId,
    required this.at,
    this.category,
    this.statusCode,
    this.latency = Duration.zero,
    this.resultCount,
    this.appVersion,
    this.pluginVersion,
  });

  final SourceDiagnosticsRunStatus status;
  final String sourceId;
  final DateTime at;
  final SourceDiagnosticsCategory? category;
  final int? statusCode;
  final Duration latency;
  final int? resultCount;
  final String? appVersion;
  final String? pluginVersion;

  bool get isSuccess => status == SourceDiagnosticsRunStatus.success;

  bool get shouldRecord =>
      status == SourceDiagnosticsRunStatus.success ||
      (status == SourceDiagnosticsRunStatus.failure &&
          category != SourceDiagnosticsCategory.cancelled);
}

/// Persisted run summary. Every field below is safe to show/export.
@immutable
class SourceDiagnosticsRunRecord {
  const SourceDiagnosticsRunRecord({
    required this.at,
    required this.category,
    required this.appVersion,
    this.statusCode,
    this.latencyMs = 0,
    this.resultCount,
    this.pluginVersion,
  });

  final DateTime at;
  final SourceDiagnosticsCategory category;
  final int? statusCode;
  final int latencyMs;
  final int? resultCount;
  final String appVersion;
  final String? pluginVersion;

  bool get isSuccess => category == SourceDiagnosticsCategory.success;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toUtc().toIso8601String(),
    'outcome': isSuccess ? 'success' : 'failure',
    'category': category.name,
    if (statusCode != null) 'statusCode': statusCode,
    'latencyMs': latencyMs,
    if (resultCount != null) 'resultCount': resultCount,
    'appVersion': appVersion,
    if (pluginVersion != null) 'pluginVersion': pluginVersion,
  };

  static SourceDiagnosticsRunRecord? fromJson(Object? value) {
    final json = _stringMap(value);
    if (json == null) return null;
    final at = DateTime.tryParse('${json['at'] ?? ''}');
    final category = SourceDiagnosticsCategory.tryParse(
      json['category']?.toString(),
    );
    final outcome = json['outcome']?.toString();
    if (at == null ||
        category == null ||
        category == SourceDiagnosticsCategory.cancelled ||
        (outcome != 'success' && outcome != 'failure') ||
        (outcome == 'success') !=
            (category == SourceDiagnosticsCategory.success)) {
      return null;
    }
    final statusCode = _boundedInt(json['statusCode'], 100, 599);
    final resultCount = _boundedInt(json['resultCount'], 0, 1000000);
    return SourceDiagnosticsRunRecord(
      at: at,
      category: category,
      statusCode: statusCode,
      latencyMs: _boundedInt(json['latencyMs'], 0, 3600000) ?? 0,
      resultCount: resultCount,
      appVersion: sanitizeDiagnosticsAppVersion(json['appVersion']),
      pluginVersion: sanitizeDiagnosticsVersion(json['pluginVersion']),
    );
  }
}

@immutable
class SourceDiagnosticsSourceRecord {
  const SourceDiagnosticsSourceRecord({
    required this.sourceId,
    required this.label,
    required this.updatedAt,
    required this.runs,
    this.lastSuccess,
    this.lastFailure,
  });

  final String sourceId;
  final String label;
  final DateTime updatedAt;

  /// Newest first, bounded by the store.
  final List<SourceDiagnosticsRunRecord> runs;
  final SourceDiagnosticsRunRecord? lastSuccess;
  final SourceDiagnosticsRunRecord? lastFailure;

  SourceDiagnosticsSourceRecord merge(SourceDiagnosticsRunRecord run) {
    final isSuccess = run.isSuccess;
    return SourceDiagnosticsSourceRecord(
      sourceId: sourceId,
      label: label,
      updatedAt: run.at,
      lastSuccess: isSuccess ? run : lastSuccess,
      lastFailure: isSuccess ? lastFailure : run,
      runs: <SourceDiagnosticsRunRecord>[run, ...runs],
    );
  }

  SourceDiagnosticsSourceRecord withLabel(String value) =>
      SourceDiagnosticsSourceRecord(
        sourceId: sourceId,
        label: sanitizeDiagnosticsLabel(value, sourceId: sourceId),
        updatedAt: updatedAt,
        lastSuccess: lastSuccess,
        lastFailure: lastFailure,
        runs: runs,
      );
}

@immutable
class SourceDiagnosticsHistory {
  const SourceDiagnosticsHistory({this.sources = const {}});

  final Map<String, SourceDiagnosticsSourceRecord> sources;

  SourceDiagnosticsSourceRecord? forSource(String sourceId) =>
      sources[sourceId];

  List<SourceDiagnosticsSourceRecord> get orderedSources {
    final values = sources.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return values;
  }

  bool get isEmpty => sources.isEmpty;
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

int? _boundedInt(Object? value, int min, int max) {
  final parsed = value is int ? value : int.tryParse('${value ?? ''}');
  if (parsed == null || parsed < min || parsed > max) return null;
  return parsed;
}