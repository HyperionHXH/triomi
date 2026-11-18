import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_classifier.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_export.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_models.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_redaction.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_service.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_store.dart';

import 'fixtures/fake_preferences.dart';

class _SearchSource implements SearchProvider {
  _SearchSource(this.id, this.onSearch);

  final String id;
  final Future<List<MediaItem>> Function(String keyword) onSearch;
  int calls = 0;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: '来源 $id',
    type: MediaType.manga,
    kind: SourceKind.plugin,
    version: '1.2.3',
    capabilities: const <SourceCapability>{SourceCapability.search},
  );

  @override
  bool get isReady => true;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) {
    calls++;
    return onSearch(keyword);
  }
}

class _StaticSource implements ContentSource {
  _StaticSource(this.id);

  final String id;

  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: '来源 $id',
    type: MediaType.manga,
    kind: SourceKind.plugin,
  );

  @override
  bool get isReady => true;
}

class _FakeClock {
  _FakeClock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}

MediaItem _item(String title) => MediaItem(
  sourceId: 'source',
  remoteId: title,
  type: MediaType.manga,
  title: title,
);

SourceEntry _entry(ContentSource source, {bool enabled = true}) => SourceEntry(
  descriptor: source.descriptor,
  source: source,
  enabled: enabled,
);

SourceRegistrySnapshot _snapshot(
  List<SourceEntry> entries, {
  List<SourceFailure> failures = const <SourceFailure>[],
}) => SourceRegistrySnapshot(entries: entries, failures: failures);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Preferences preferences;
  late SourceDiagnosticsStore store;
  late _FakeClock clock;

  setUp(() {
    preferences = memoryPreferences();
    store = SourceDiagnosticsStore(preferences);
    clock = _FakeClock(DateTime.utc(2026, 1, 1, 12));
  });

  SourceDiagnosticsService service({
    required SourceRegistrySnapshot snapshot,
    Future<List<MediaItem>> Function(String keyword)? search,
    SourceDiagnosticsSnapshotLoader? snapshotLoader,
    Duration timeout = const Duration(milliseconds: 50),
    Duration minimumInterval = const Duration(seconds: 2),
  }) => SourceDiagnosticsService(
    snapshot: snapshotLoader ?? () async => snapshot,
    search: (source, keyword) =>
        search?.call(keyword) ??
        source.search(keyword),
    store: store,
    clock: clock.call,
    appVersion: () async => '0.16.1+203',
    timeout: timeout,
    minimumInterval: minimumInterval,
  );

  test('403 is access denied, never assumed to be expired login', () async {
    final source = _SearchSource(
      'forbidden',
      (_) async => throw const SourceException(
        sourceId: 'forbidden',
        type: SourceErrorType.auth,
        statusCode: 403,
        message: 'https://example.test/private?token=TOPSECRET Bearer TOPSECRET',
      ),
    );
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(source)]),
    );
    final result = await diagnostics.testSearch(
      sourceId: 'forbidden',
      keyword: 'secret-query-403',
    );
    expect(result.status, SourceDiagnosticsRunStatus.failure);
    expect(result.category, SourceDiagnosticsCategory.permission);
    expect(result.statusCode, 403);

    final stored = jsonEncode(
      preferences.get<Object?>(SourceDiagnosticsStore.preferencesKey),
    );
    expect(stored, isNot(contains('TOPSECRET')));
    expect(stored, isNot(contains('secret-query-403')));
    expect(stored, isNot(contains('https://example.test')));

    final exported = encodeSourceDiagnosticsExport(
      await store.load(),
      exportedAt: clock.now,
    );
    expect(exported, isNot(contains('TOPSECRET')));
    expect(exported, isNot(contains('secret-query-403')));
    expect(exported, isNot(contains('https://example.test')));
    expect(exported, contains(diagnosticsSourceDigest('forbidden')));
  });

  test('nested Dio 403 and 429 keep their structured status', () async {
    final request = RequestOptions(path: '/private');
    final forbidden = DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response<List<int>>(
        requestOptions: request,
        statusCode: 403,
      ),
    );
    expect(
      diagnoseSourceDiagnosticsError(forbidden).category,
      SourceDiagnosticsCategory.permission,
    );
    expect(diagnoseSourceDiagnosticsError(forbidden).statusCode, 403);

    final limited = _SearchSource(
      'limited',
      (_) async => throw const SourceException(
        sourceId: 'limited',
        type: SourceErrorType.auth,
        statusCode: 429,
      ),
    );
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(limited)]),
    );
    final result = await diagnostics.testSearch(
      sourceId: 'limited',
      keyword: 'rate',
    );
    expect(result.category, SourceDiagnosticsCategory.rateLimited);
    expect(result.statusCode, 429);
  });

  test('DNS, TLS and unknown errors are classified honestly', () {
    final dns = diagnoseSourceDiagnosticsError(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
        error: SocketException('Failed host lookup: nope.invalid'),
      ),
    );
    expect(dns.category, SourceDiagnosticsCategory.dns);

    final tls = diagnoseSourceDiagnosticsError(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.badCertificate,
      ),
    );
    expect(tls.category, SourceDiagnosticsCategory.tls);

    expect(
      diagnoseSourceDiagnosticsError(StateError('unclassified failure')).category,
      SourceDiagnosticsCategory.unknown,
    );
  });

  test('timeout is bounded and a late result is discarded', () async {
    final gate = Completer<List<MediaItem>>();
    final slow = _SearchSource('slow', (_) => gate.future);
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(slow)]),
      timeout: const Duration(milliseconds: 20),
    );
    final result = await diagnostics.testSearch(
      sourceId: 'slow',
      keyword: 'late-secret-query',
    );
    expect(result.status, SourceDiagnosticsRunStatus.failure);
    expect(result.category, SourceDiagnosticsCategory.timeout);
    var record = (await store.load()).forSource('slow');
    expect(record, isNotNull);
    expect(record!.lastFailure!.category, SourceDiagnosticsCategory.timeout);
    expect(record.lastSuccess, isNull);
    expect(record.runs, hasLength(1));

    gate.complete(<MediaItem>[_item('late result')]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    record = (await store.load()).forSource('slow');
    expect(record!.runs, hasLength(1));
    expect(record.lastSuccess, isNull);
    expect(record.lastFailure!.category, SourceDiagnosticsCategory.timeout);
    expect(
      jsonEncode(
        preferences.get<Object?>(SourceDiagnosticsStore.preferencesKey),
      ),
      isNot(contains('late-secret-query')),
    );
  });

  test('cancellation discards results that arrive later', () async {
    final gate = Completer<List<MediaItem>>();
    final slow = _SearchSource('cancelled', (_) => gate.future);
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(slow)]),
      timeout: const Duration(seconds: 5),
    );
    final pending = diagnostics.testSearch(
      sourceId: 'cancelled',
      keyword: 'cancel-secret-query',
    );
    diagnostics.cancel();
    gate.complete(<MediaItem>[_item('must not persist')]);
    final result = await pending;
    expect(result.status, SourceDiagnosticsRunStatus.cancelled);
    expect((await store.load()).isEmpty, isTrue);
    expect(
      jsonEncode(
        preferences.get<Object?>(SourceDiagnosticsStore.preferencesKey),
      ),
      isNot(contains('cancel-secret-query')),
    );
  });

  test('zero query results are a successful empty search', () async {
    final source = _SearchSource('empty', (_) async => const <MediaItem>[]);
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(source)]),
    );
    final result = await diagnostics.testSearch(
      sourceId: 'empty',
      keyword: 'no matches',
    );
    expect(result.status, SourceDiagnosticsRunStatus.success);
    expect(result.category, SourceDiagnosticsCategory.success);
    expect(result.resultCount, 0);

    final record = (await store.load()).forSource('empty');
    expect(record, isNotNull);
    expect(record!.lastSuccess!.resultCount, 0);
    expect(record.lastFailure, isNull);
    expect(record.runs.single.isSuccess, isTrue);
  });

  test('disabled and unsupported sources do not execute', () async {
    final disabled = _SearchSource('off', (_) async => <MediaItem>[_item('x')]);
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(disabled, enabled: false)]),
    );
    final disabledResult = await diagnostics.testSearch(
      sourceId: 'off',
      keyword: 'not sent',
    );
    expect(disabledResult.status, SourceDiagnosticsRunStatus.sourceDisabled);
    expect(disabled.calls, 0);

    final plain = _StaticSource('plain');
    final unsupportedDiagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(plain)]),
    );
    final unsupportedResult = await unsupportedDiagnostics.testSearch(
      sourceId: 'plain',
      keyword: 'not sent',
    );
    expect(unsupportedResult.status, SourceDiagnosticsRunStatus.unsupported);
    expect((await store.load()).isEmpty, isTrue);
  });

  test('each operation loads a fresh snapshot, then rate limits duplicates', () async {
    var loads = 0;
    final source = _SearchSource('fresh', (_) async => const <MediaItem>[]);
    final snapshot = _snapshot(<SourceEntry>[_entry(source)]);
    final diagnostics = service(
      snapshot: snapshot,
      snapshotLoader: () async {
        loads++;
        return snapshot;
      },
    );
    final first = await diagnostics.testSearch(
      sourceId: 'fresh',
      keyword: 'one',
    );
    expect(first.status, SourceDiagnosticsRunStatus.success);
    expect(loads, 1);

    final throttled = await diagnostics.testSearch(
      sourceId: 'fresh',
      keyword: 'two',
    );
    expect(throttled.status, SourceDiagnosticsRunStatus.throttled);
    expect(source.calls, 1);

    clock.advance(const Duration(seconds: 2));
    final second = await diagnostics.testSearch(
      sourceId: 'fresh',
      keyword: 'three',
    );
    expect(second.status, SourceDiagnosticsRunStatus.success);
    expect(loads, 2);
    expect(source.calls, 2);
  });

  test('single-flight rejects a concurrent manual test', () async {
    final gate = Completer<List<MediaItem>>();
    final source = _SearchSource('single', (_) => gate.future);
    final diagnostics = service(
      snapshot: _snapshot(<SourceEntry>[_entry(source)]),
      timeout: const Duration(seconds: 5),
    );
    final first = diagnostics.testSearch(sourceId: 'single', keyword: 'one');
    final second = await diagnostics.testSearch(
      sourceId: 'single',
      keyword: 'two',
    );
    expect(second.status, SourceDiagnosticsRunStatus.busy);
    gate.complete(const <MediaItem>[]);
    expect((await first).status, SourceDiagnosticsRunStatus.success);
    expect(source.calls, 1);
  });

  test('store bounds runs per source and evicts old sources', () async {
    for (var index = 0; index < 25; index++) {
      clock.advance(const Duration(minutes: 1));
      await store.recordRun(
        sourceId: 'bounded',
        label: 'bounded',
        run: SourceDiagnosticsRunRecord(
          at: clock.now,
          category: index.isEven
              ? SourceDiagnosticsCategory.success
              : SourceDiagnosticsCategory.timeout,
          appVersion: 'app',
          resultCount: index.isEven ? index : null,
        ),
      );
    }
    final bounded = (await store.load()).forSource('bounded');
    expect(bounded!.runs, hasLength(SourceDiagnosticsStore.maxRunsPerSource));

    for (var index = 0; index < 105; index++) {
      clock.advance(const Duration(seconds: 1));
      await store.recordRun(
        sourceId: 'source-$index',
        label: 'source $index',
        run: SourceDiagnosticsRunRecord(
          at: clock.now,
          category: SourceDiagnosticsCategory.success,
          appVersion: 'app',
        ),
      );
    }
    final history = await store.load();
    expect(history.sources, hasLength(SourceDiagnosticsStore.maxSources));
    expect(history.sources.containsKey('source-0'), isFalse);
    expect(history.sources.containsKey('source-104'), isTrue);

    await store.clearSource('source-104');
    expect((await store.load()).sources.containsKey('source-104'), isFalse);
  });

  test('export uses digest IDs and redacted labels only', () {
    const sourceId =
        'https://user:pass@example.test/source?token=TOPSECRET&query=hidden';
    final run = SourceDiagnosticsRunRecord(
      at: clock.now,
      category: SourceDiagnosticsCategory.permission,
      statusCode: 403,
      latencyMs: 12,
      appVersion: '0.16.1+203',
      pluginVersion: '1.2.3',
    );
    final source = SourceDiagnosticsSourceRecord(
      sourceId: sourceId,
      label: 'Site https://example.test/?token=TOPSECRET Bearer TOPSECRET',
      updatedAt: clock.now,
      lastFailure: run,
      runs: <SourceDiagnosticsRunRecord>[run],
    );
    final history = SourceDiagnosticsHistory(
      sources: <String, SourceDiagnosticsSourceRecord>{sourceId: source},
    );
    final exported = encodeSourceDiagnosticsExport(
      history,
      exportedAt: clock.now,
    );
    expect(exported, isNot(contains('TOPSECRET')));
    expect(exported, isNot(contains('user:pass')));
    expect(exported, isNot(contains('https://')));
    expect(exported, isNot(contains(sourceId)));
    expect(exported, contains(diagnosticsSourceDigest(sourceId)));
    expect(exported, contains('"category": "permission"'));

    final feedback = buildSourceDiagnosticsFeedback(source);
    expect(feedback, isNot(contains('TOPSECRET')));
    expect(feedback, isNot(contains('user:pass')));
    expect(feedback, isNot(contains('https://')));
    expect(feedback, contains(diagnosticsSourceDigest(sourceId)));
  });
}