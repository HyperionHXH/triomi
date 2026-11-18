import 'dart:async';

import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/models/media_item.dart';
import '../../../core/source/http_client.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_registry.dart';
import 'source_diagnostics_classifier.dart';
import 'source_diagnostics_models.dart';
import 'source_diagnostics_redaction.dart';
import 'source_diagnostics_store.dart';

typedef SourceDiagnosticsSnapshotLoader =
    Future<SourceRegistrySnapshot> Function();
typedef SourceDiagnosticsSearcher =
    Future<List<MediaItem>> Function(SearchProvider source, String keyword);

/// Owns one manual search diagnostic at a time.
///
/// Production wiring passes the live [SourceRegistry.load] and the real
/// [SearchProvider.search]. Tests inject a fixed snapshot, fake search and
/// clock so the bounded/cancellable behavior is deterministic.
class SourceDiagnosticsService {
  SourceDiagnosticsService({
    required this.snapshot,
    required this.search,
    required this.store,
    DateTime Function()? clock,
    Future<String> Function()? appVersion,
    this.timeout = defaultTimeout,
    this.minimumInterval = defaultMinimumInterval,
  }) : _clock = clock ?? DateTime.now,
       _appVersion = appVersion ?? _defaultAppVersion;

  static const Duration defaultTimeout = Duration(seconds: 20);
  static const Duration defaultMinimumInterval = Duration(seconds: 2);

  final SourceDiagnosticsSnapshotLoader snapshot;
  final SourceDiagnosticsSearcher search;
  final SourceDiagnosticsStore store;
  final DateTime Function() _clock;
  final Future<String> Function() _appVersion;
  final Duration timeout;
  final Duration minimumInterval;

  int _generation = 0;
  int? _activeGeneration;
  SourceRequestCancellation? _cancellation;
  DateTime? _lastRequestAt;
  bool _disposed = false;

  Future<SourceDiagnosticsTestResult> testSearch({
    required String sourceId,
    required String keyword,
  }) async {
    final startedAt = _clock();
    if (_disposed) {
      return _skipped(
        SourceDiagnosticsRunStatus.cancelled,
        sourceId,
        startedAt,
      );
    }
    if (_activeGeneration != null) {
      return _skipped(SourceDiagnosticsRunStatus.busy, sourceId, startedAt);
    }
    final query = keyword.trim();
    if (query.isEmpty) {
      return _skipped(
        SourceDiagnosticsRunStatus.keywordRequired,
        sourceId,
        startedAt,
      );
    }
    final preflightAt = _clock();
    final lastRequest = _lastRequestAt;
    if (lastRequest != null &&
        preflightAt.difference(lastRequest) < minimumInterval) {
      return _skipped(
        SourceDiagnosticsRunStatus.throttled,
        sourceId,
        preflightAt,
      );
    }

    final generation = ++_generation;
    _activeGeneration = generation;
    try {
      SourceRegistrySnapshot registrySnapshot;
      try {
        registrySnapshot = await snapshot().timeout(timeout);
      } catch (_) {
        return _skipped(
          SourceDiagnosticsRunStatus.registryError,
          sourceId,
          _clock(),
        );
      }
      if (!_canPublish(generation)) {
        return _skipped(
          SourceDiagnosticsRunStatus.cancelled,
          sourceId,
          _clock(),
        );
      }

      final entry = registrySnapshot.entries
          .where((candidate) => candidate.descriptor.id == sourceId)
          .firstOrNull;
      if (entry == null) {
        final failed = registrySnapshot.failures.any(
          (failure) => failure.id == sourceId,
        );
        return _skipped(
          failed
              ? SourceDiagnosticsRunStatus.invalidSource
              : SourceDiagnosticsRunStatus.sourceUnavailable,
          sourceId,
          _clock(),
        );
      }
      if (!entry.enabled) {
        return _skipped(
          SourceDiagnosticsRunStatus.sourceDisabled,
          sourceId,
          _clock(),
        );
      }
      final source = entry.source;
      if (source is! SearchProvider) {
        return _skipped(
          SourceDiagnosticsRunStatus.unsupported,
          sourceId,
          _clock(),
        );
      }

      final now = _clock();
      _lastRequestAt = now;
      final cancellation = SourceRequestCancellation();
      _cancellation = cancellation;

      final appVersion = _readAppVersion();
      final started = now;
      try {
        final items = await cancellation
            .run(() async => search(source, query))
            .timeout(
              timeout,
              onTimeout: () {
                cancellation.cancel('诊断搜索超时');
                throw TimeoutException('诊断搜索超时');
              },
            );
        if (!_canPublish(generation)) {
          return _skipped(
            SourceDiagnosticsRunStatus.cancelled,
            sourceId,
            _clock(),
          );
        }
        final result = SourceDiagnosticsTestResult(
          status: SourceDiagnosticsRunStatus.success,
          sourceId: sourceId,
          at: _clock(),
          category: SourceDiagnosticsCategory.success,
          latency: _elapsed(started),
          resultCount: items.length,
          appVersion: await appVersion,
          pluginVersion: sanitizeDiagnosticsVersion(entry.descriptor.version),
        );
        if (!_canPublish(generation)) {
          return _skipped(
            SourceDiagnosticsRunStatus.cancelled,
            sourceId,
            _clock(),
          );
        }
        await _record(result, entry.descriptor.name, generation);
        return result;
      } on TimeoutException {
        if (!_canPublish(generation)) {
          return _skipped(
            SourceDiagnosticsRunStatus.cancelled,
            sourceId,
            _clock(),
          );
        }
        final result = SourceDiagnosticsTestResult(
          status: SourceDiagnosticsRunStatus.failure,
          sourceId: sourceId,
          at: _clock(),
          category: SourceDiagnosticsCategory.timeout,
          latency: timeout,
          appVersion: await _safeAppVersion(appVersion),
          pluginVersion: sanitizeDiagnosticsVersion(entry.descriptor.version),
        );
        await _record(result, entry.descriptor.name, generation);
        return result;
      } catch (error) {
        if (!_canPublish(generation)) {
          return _skipped(
            SourceDiagnosticsRunStatus.cancelled,
            sourceId,
            _clock(),
          );
        }
        final diagnosis = diagnoseSourceDiagnosticsError(error);
        if (diagnosis.category == SourceDiagnosticsCategory.cancelled) {
          return _skipped(
            SourceDiagnosticsRunStatus.cancelled,
            sourceId,
            _clock(),
          );
        }
        final result = SourceDiagnosticsTestResult(
          status: SourceDiagnosticsRunStatus.failure,
          sourceId: sourceId,
          at: _clock(),
          category: diagnosis.category,
          statusCode: diagnosis.statusCode,
          latency: _elapsed(started),
          appVersion: await _safeAppVersion(appVersion),
          pluginVersion: sanitizeDiagnosticsVersion(entry.descriptor.version),
        );
        await _record(result, entry.descriptor.name, generation);
        return result;
      }
    } finally {
      if (_activeGeneration == generation) {
        _activeGeneration = null;
        _cancellation = null;
      }
    }
  }

  /// Cancels the in-flight request and makes every late result unpublishable.
  void cancel() {
    if (_disposed) return;
    _generation++;
    _activeGeneration = null;
    _cancellation?.cancel('诊断已取消');
    _cancellation = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _activeGeneration = null;
    _cancellation?.cancel('诊断页面已关闭');
    _cancellation = null;
  }

  bool _canPublish(int generation) =>
      !_disposed &&
      _generation == generation &&
      _activeGeneration == generation;

  Duration _elapsed(DateTime started) {
    final elapsed = _clock().difference(started);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  Future<String> _readAppVersion() async {
    try {
      return sanitizeDiagnosticsAppVersion(await _appVersion());
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String> _safeAppVersion(Future<String> value) async {
    try {
      return sanitizeDiagnosticsAppVersion(await value);
    } catch (_) {
      return 'unknown';
    }
  }

  Future<void> _record(
    SourceDiagnosticsTestResult result,
    String label,
    int generation,
  ) async {
    if (!result.shouldRecord || !_canPublish(generation)) return;
    final category = result.category;
    if (category == null) return;
    final run = SourceDiagnosticsRunRecord(
      at: result.at,
      category: category,
      statusCode: result.statusCode,
      latencyMs: result.latency.inMilliseconds.clamp(0, 3600000).toInt(),
      resultCount: result.resultCount,
      appVersion: sanitizeDiagnosticsAppVersion(result.appVersion),
      pluginVersion: sanitizeDiagnosticsVersion(result.pluginVersion),
    );
    try {
      await store.recordRun(
        sourceId: result.sourceId,
        label: label,
        run: run,
      );
    } catch (_) {
      // A local storage failure must not turn a completed network test into a
      // source failure. The UI still shows the in-memory result.
      return;
    }
  }

  SourceDiagnosticsTestResult _skipped(
    SourceDiagnosticsRunStatus status,
    String sourceId,
    DateTime at,
  ) => SourceDiagnosticsTestResult(
    status: status,
    sourceId: sourceId,
    at: at,
  );

  static Future<String> _defaultAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }
}