import 'dart:async';

import '../../../core/storage/preferences.dart';
import 'source_diagnostics_models.dart';
import 'source_diagnostics_redaction.dart';

/// Bounded, persistent per-source diagnostics summaries.
///
/// The stored document contains only allowlisted fields: timestamps, category
/// names, HTTP status codes, latency, result counts and app/source versions.
/// User queries, raw error text, URLs, headers, response bodies and
/// credentials are never written here.
class SourceDiagnosticsStore {
  SourceDiagnosticsStore(this._preferences);

  static const String preferencesKey = 'source.diagnostics.v1';
  static const int schemaVersion = 1;
  static const int maxSources = 100;
  static const int maxRunsPerSource = 20;

  final Preferences _preferences;
  Future<void> _tail = Future<void>.value();

  Future<SourceDiagnosticsHistory> load() async {
    await _tail;
    return _read();
  }

  Future<SourceDiagnosticsSourceRecord?> recordRun({
    required String sourceId,
    required String label,
    required SourceDiagnosticsRunRecord run,
  }) {
    if (sourceId.isEmpty || sourceId.length > 512) {
      return Future<SourceDiagnosticsSourceRecord?>.value(null);
    }
    return _serialize(() async {
      final history = _read();
      final previous = history.sources[sourceId];
      final sanitized = sanitizeDiagnosticsLabel(label, sourceId: sourceId);
      var updated = previous == null
          ? SourceDiagnosticsSourceRecord(
              sourceId: sourceId,
              label: sanitized,
              updatedAt: run.at,
              lastSuccess: run.isSuccess ? run : null,
              lastFailure: run.isSuccess ? null : run,
              runs: <SourceDiagnosticsRunRecord>[run],
            )
          : previous.withLabel(sanitized).merge(run);
      final runs = <SourceDiagnosticsRunRecord>[
        ...updated.runs,
      ].take(maxRunsPerSource).toList();
      updated = SourceDiagnosticsSourceRecord(
        sourceId: sourceId,
        label: sanitized,
        updatedAt: updated.updatedAt,
        lastSuccess: updated.lastSuccess,
        lastFailure: updated.lastFailure,
        runs: runs,
      );
      final sources = <String, SourceDiagnosticsSourceRecord>{
        ...history.sources,
        sourceId: updated,
      };
      final bounded = _boundedSources(sources);
      await _write(bounded);
      return bounded[sourceId];
    });
  }

  Future<void> clearSource(String sourceId) => _serialize(() async {
    final history = _read();
    if (!history.sources.containsKey(sourceId)) return;
    final sources = <String, SourceDiagnosticsSourceRecord>{
      ...history.sources,
    }..remove(sourceId);
    await _write(sources);
  });

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  SourceDiagnosticsHistory _read() {
    final root = _stringMap(_preferences.get<Object?>(preferencesKey));
    if (root == null) return const SourceDiagnosticsHistory();
    final version = _intValue(root['version']);
    if (version != null && version != schemaVersion) {
      return const SourceDiagnosticsHistory();
    }
    final rawSources = root['sources'];
    if (rawSources is! Map) return const SourceDiagnosticsHistory();
    final sources = <String, SourceDiagnosticsSourceRecord>{};
    for (final entry in rawSources.entries) {
      final sourceId = entry.key;
      if (sourceId is! String ||
          sourceId.isEmpty ||
          sourceId.length > 512) {
        continue;
      }
      final record = _readSource(sourceId, entry.value);
      if (record != null) sources[sourceId] = record;
    }
    return SourceDiagnosticsHistory(sources: _boundedSources(sources));
  }

  SourceDiagnosticsSourceRecord? _readSource(String sourceId, Object? value) {
    final json = _stringMap(value);
    if (json == null) return null;
    final runs = <SourceDiagnosticsRunRecord>[];
    final rawRuns = json['runs'];
    if (rawRuns is List) {
      for (final raw in rawRuns) {
        final run = SourceDiagnosticsRunRecord.fromJson(raw);
        if (run != null) runs.add(run);
      }
    }
    runs.sort((a, b) => b.at.compareTo(a.at));
    final lastSuccessRaw = SourceDiagnosticsRunRecord.fromJson(
      json['lastSuccess'],
    );
    final lastFailureRaw = SourceDiagnosticsRunRecord.fromJson(
      json['lastFailure'],
    );
    final lastSuccess =
        lastSuccessRaw != null && lastSuccessRaw.isSuccess
        ? lastSuccessRaw
        : null;
    final lastFailure =
        lastFailureRaw != null && !lastFailureRaw.isSuccess
        ? lastFailureRaw
        : null;
    final updatedAt =
        DateTime.tryParse('${json['updatedAt'] ?? ''}') ??
        (runs.isNotEmpty
            ? runs.first.at
            : lastSuccess?.at ?? lastFailure?.at);
    if (updatedAt == null) return null;
    return SourceDiagnosticsSourceRecord(
      sourceId: sourceId,
      label: sanitizeDiagnosticsLabel(
        '${json['label'] ?? ''}',
        sourceId: sourceId,
      ),
      updatedAt: updatedAt,
      lastSuccess: lastSuccess,
      lastFailure: lastFailure,
      runs: runs.take(maxRunsPerSource).toList(),
    );
  }

  Map<String, SourceDiagnosticsSourceRecord> _boundedSources(
    Map<String, SourceDiagnosticsSourceRecord> sources,
  ) {
    final ordered = sources.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return <String, SourceDiagnosticsSourceRecord>{
      for (final source in ordered.take(maxSources)) source.sourceId: source,
    };
  }

  Future<void> _write(
    Map<String, SourceDiagnosticsSourceRecord> sources,
  ) => _preferences.set(preferencesKey, <String, Object?>{
    'version': schemaVersion,
    'sources': <String, Object?>{
      for (final entry in _boundedSources(sources).entries)
        entry.key: <String, Object?>{
          'label': sanitizeDiagnosticsLabel(
            entry.value.label,
            sourceId: entry.key,
          ),
          'updatedAt': entry.value.updatedAt.toUtc().toIso8601String(),
          if (entry.value.lastSuccess != null)
            'lastSuccess': entry.value.lastSuccess!.toJson(),
          if (entry.value.lastFailure != null)
            'lastFailure': entry.value.lastFailure!.toJson(),
          'runs': <Object?>[
            for (final run in entry.value.runs.take(maxRunsPerSource))
              run.toJson(),
          ],
        },
    },
  });
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

int? _intValue(Object? value) => value is int
    ? value
    : int.tryParse('${value ?? ''}');