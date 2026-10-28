import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/bangumi_route_policy.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';
import 't2_js_source_test.dart' show FakeJsRuntime, jsRuleText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'public mirror change preserves registry and active JS source',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
        enabled: true,
      );
      final engine = FakeJsRuntime(functions: {'search'});
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => throw StateError('No network expected'),
            ),
          ),
          sourceJsRuntimeFactoryProvider.overrideWithValue(() => engine),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(sourceRegistryProvider);
      final source = (await registry.load()).entries.single.source as JsSource;
      await source.initialize();
      expect(registry.bangumiPublicClient!.routes.mirrorEnabled, isTrue);
      await container
          .read(bangumiMirrorEnabledProvider.notifier)
          .setEnabled(false);
      expect(
        identical(container.read(sourceRegistryProvider), registry),
        isTrue,
      );
      expect(
        identical((await registry.load()).entries.single.source, source),
        isTrue,
      );
      expect(engine.disposed, isFalse);
      expect(registry.bangumiPublicClient!.routes.mirrorEnabled, isFalse);
    },
  );

  test('disabled JS stays visible without running top-level code', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final repository = SourceRepository(db);
    final registry = SourceRegistry(
      repository: repository,
      http: FakeHttpClient(
        (_) async => throw StateError('No network expected'),
      ),
      jsRuntimeFactory: () =>
          FakeJsRuntime(loadError: 'top-level script executed while disabled'),
    );
    addTearDown(registry.dispose);
    await repository.upsert(
      id: 'js-source',
      name: 'JS',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      ruleText: jsRuleText(script: 'throw new Error("disabled");'),
      enabled: false,
    );
    final snapshot = await registry.load();
    expect(snapshot.failures, isEmpty);
    final entry = snapshot.entries.single;
    expect(entry.descriptor.id, 'js-source');
    expect(entry.enabled, false);
    expect(entry.source.isReady, false);
    expect(entry.descriptor.capabilities, isEmpty);
    expect(snapshot.enabledEntries, isEmpty);
  });
  test(
    'disabling releases the source; enabling loads a fresh script',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      final engines = <FakeJsRuntime>[];
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('No network expected'),
        ),
        jsRuntimeFactory: () {
          final engine = FakeJsRuntime(functions: {'search'});
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(registry.dispose);
      await repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
        enabled: true,
      );
      final active = (await registry.load()).entries.single;
      await (active.source as JsSource).initialize();
      expect(active.source.isReady, true);
      await registry.setEnabled('js-source', enabled: false);
      final stopped = await registry.load();
      expect(stopped.entries.single.enabled, false);
      expect(stopped.enabledEntries, isEmpty);
      expect(engines.single.disposed, true);
      expect(active.source.isReady, false);
      await registry.setEnabled('js-source', enabled: true);
      final restarted = (await registry.load()).entries.single;
      await (restarted.source as JsSource).initialize();
      expect(restarted.source.isReady, true);
      expect(restarted.supports(SourceCapability.search), true);
      expect(identical(active.source, restarted.source), false);
      expect(engines.last.disposed, false);
    },
  );
  test(
    'disabling during initialization cannot publish a late source',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      final started = Completer<void>();
      final release = Completer<void>();
      final engine = _DelayedJsRuntime(started, release);
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('No network expected'),
        ),
        jsRuntimeFactory: () => engine,
      );
      addTearDown(registry.dispose);
      await repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
        enabled: true,
      );
      final active = (await registry.load()).entries.single;
      final loading = (active.source as JsSource).initialize();
      final rejected = expectLater(loading, throwsStateError);
      await started.future;
      await registry.setEnabled('js-source', enabled: false);
      expect(engine.disposed, true);
      release.complete();
      await rejected;
      final stopped = await registry.load();
      expect(stopped.failures, isEmpty);
      expect(stopped.entries.single.source.isReady, false);
    },
  );
  test(
    'refresh reuses engines; update/removal/dispose retire only owned engines',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      final engines = <FakeJsRuntime>[];
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('No network expected'),
        ),
        jsRuntimeFactory: () {
          final engine = FakeJsRuntime(functions: {'search'});
          engines.add(engine);
          return engine;
        },
      );
      Future<void> put(String script) => repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(script: script),
        enabled: true,
      );
      await put('function search() { return []; }');
      final first = await registry.load();
      await (first.entries.single.source as JsSource).initialize();
      final second = await registry.load();
      expect(engines, hasLength(1));
      expect(
        identical(first.entries.single.source, second.entries.single.source),
        true,
      );
      await put('function search() { return [1]; }');
      final replacement = await registry.load();
      await (replacement.entries.single.source as JsSource).initialize();
      expect(engines, hasLength(2));
      expect(engines.first.disposed, true);
      expect(engines.last.disposed, false);
      await repository.remove('js-source');
      await registry.load();
      await Future<void>.delayed(Duration.zero);
      expect(engines.last.disposed, true);
      await put('function search() { return [2]; }');
      await registry.load();
      await ((await registry.load()).entries.single.source as JsSource)
          .initialize();
      registry.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(engines.every((e) => e.disposed), true);
      await expectLater(registry.load(), throwsStateError);
    },
  );
  test(
    'lazy initialization failure stays local and the source can retry',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      final engine = _RetryRuntime();
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('No network expected'),
        ),
        jsRuntimeFactory: () => engine,
      );
      await repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
        enabled: true,
      );
      final active = (await registry.load()).entries.single;
      await expectLater(
        (active.source as SearchProvider).search('probe'),
        throwsA(isA<SourceException>()),
      );
      final results = await (active.source as SearchProvider).search('probe');
      expect(results.single.remoteId, 'recovered');
      registry.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(engine.disposed, true);
    },
  );
  test(
    'changing JS to invalid or declarative rules retires the engine',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      final engines = <FakeJsRuntime>[];
      final registry = SourceRegistry(
        repository: repository,
        http: FakeHttpClient(
          (_) async => throw StateError('No network expected'),
        ),
        jsRuntimeFactory: () {
          final engine = FakeJsRuntime(functions: {'search'});
          engines.add(engine);
          return engine;
        },
      );
      addTearDown(registry.dispose);
      Future<void> put(String text) => repository.upsert(
        id: 'js-source',
        name: 'JS',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: text,
        enabled: true,
      );
      await put(jsRuleText());
      await ((await registry.load()).entries.single.source as JsSource)
          .initialize();
      await put('{broken');
      expect((await registry.load()).failures, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(engines.single.disposed, true);
      await put(jsRuleText());
      await ((await registry.load()).entries.single.source as JsSource)
          .initialize();
      await put(
        '{"id":"js-source","name":"Plain","type":"manga","version":"1","baseUrl":"https://example.com","search":{"url":"/search?q={keyword}","list":".item","fields":{"title":".title","remoteId":"a@href"}}}',
      );
      expect((await registry.load()).failures, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(engines.last.disposed, true);
    },
  );
}

class _DelayedJsRuntime extends FakeJsRuntime {
  _DelayedJsRuntime(this.started, this.release);

  final Completer<void> started;
  final Completer<void> release;

  @override
  Future<bool> hasFunction(String function) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return super.hasFunction(function);
  }
}

class _RetryRuntime extends FakeJsRuntime {
  _RetryRuntime()
    : super(
        functions: {'search'},
        responses: {
          'search': [
            {'remoteId': 'recovered', 'title': 'Recovered book'},
          ],
        },
      );
  bool failed = false;
  @override
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  }) {
    if (!failed) {
      failed = true;
      throw const JsRuntimeError('transient engine failure');
    }
    return super.load(script, name: name, bridge: bridge, baseUrl: baseUrl);
  }
}
