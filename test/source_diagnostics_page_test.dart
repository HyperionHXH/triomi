import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_page.dart';
import 'package:triomi/features/sources/diagnostics/source_diagnostics_providers.dart';
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

SourceEntry _entry(ContentSource source, {bool enabled = true}) => SourceEntry(
  descriptor: source.descriptor,
  source: source,
  enabled: enabled,
);

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _harness({
  required SourceRegistrySnapshot snapshot,
  required SourceDiagnosticsStore store,
  required SourceDiagnosticsService service,
  String? initialSourceId,
}) => ProviderScope(
  overrides: [
    sourceDiagnosticsStoreProvider.overrideWithValue(store),
    sourceDiagnosticsSnapshotProvider.overrideWith((ref) async => snapshot),
    sourceDiagnosticsServiceProvider.overrideWithValue(service),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: SourceDiagnosticsPage(initialSourceId: initialSourceId),
  ),
);

SourceDiagnosticsService _service(
  SourceRegistrySnapshot snapshot,
  SourceDiagnosticsStore store, {
  DateTime Function()? clock,
}) => SourceDiagnosticsService(
  snapshot: () async => snapshot,
  search: (source, keyword) => source.search(keyword),
  store: store,
  clock: clock ?? () => DateTime.utc(2026, 1, 1),
  appVersion: () async => '0.16.1+203',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'explicit manual test sends one request and empty success is valid',
    (tester) async {
      _setViewport(tester);
      final preferences = memoryPreferences();
      final store = SourceDiagnosticsStore(preferences);
      final source = _SearchSource(
        'searchable',
        (_) async => const <MediaItem>[],
      );
      final snapshot = SourceRegistrySnapshot(
        entries: <SourceEntry>[_entry(source)],
        failures: const <SourceFailure>[],
      );
      await tester.pumpWidget(
        _harness(
          snapshot: snapshot,
          store: store,
          service: _service(snapshot, store),
          initialSourceId: 'searchable',
        ),
      );
      await tester.pumpAndSettle();

      expect(source.calls, 0);
      expect(find.text('已启用 · 可搜索'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('source-diagnostics-keyword')),
        'screen-secret-query',
      );
      await tester.tap(find.byKey(const ValueKey('source-diagnostics-run')));
      await tester.pumpAndSettle();

      expect(source.calls, 1);
      expect(find.textContaining('返回 0 条结果'), findsWidgets);
      expect(find.textContaining('空结果是有效的搜索结果'), findsOneWidget);
      final stored = jsonEncode(
        preferences.get<Object?>(SourceDiagnosticsStore.preferencesKey),
      );
      expect(stored, isNot(contains('screen-secret-query')));
    },
  );

  testWidgets('loading registry is visible before metadata arrives', (
    tester,
  ) async {
    _setViewport(tester);
    final preferences = memoryPreferences();
    final store = SourceDiagnosticsStore(preferences);
    final source = _SearchSource('pending', (_) async => const <MediaItem>[]);
    final snapshot = SourceRegistrySnapshot(
      entries: <SourceEntry>[_entry(source)],
      failures: const <SourceFailure>[],
    );
    final gate = Completer<SourceRegistrySnapshot>();
    final service = _service(snapshot, store);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceDiagnosticsStoreProvider.overrideWithValue(store),
          sourceDiagnosticsSnapshotProvider.overrideWith((ref) => gate.future),
          sourceDiagnosticsServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SourceDiagnosticsPage(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('正在加载来源注册表…'), findsOneWidget);

    gate.complete(snapshot);
    await tester.pumpAndSettle();
    expect(find.text('来源诊断中心'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-diagnostics-picker-pending')),
      findsOneWidget,
    );
  });

  testWidgets('disabled source shows explanation and cannot call search', (
    tester,
  ) async {
    _setViewport(tester);
    final preferences = memoryPreferences();
    final store = SourceDiagnosticsStore(preferences);
    final source = _SearchSource('off', (_) async => const <MediaItem>[]);
    final snapshot = SourceRegistrySnapshot(
      entries: <SourceEntry>[_entry(source, enabled: false)],
      failures: const <SourceFailure>[],
    );
    await tester.pumpWidget(
      _harness(
        snapshot: snapshot,
        store: store,
        service: _service(snapshot, store),
        initialSourceId: 'off',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已停用'), findsWidgets);
    expect(find.textContaining('不会自动启用'), findsWidgets);
    expect(
      find.byKey(const ValueKey('source-diagnostics-keyword')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('source-diagnostics-run')), findsNothing);
    expect(source.calls, 0);
  });

  testWidgets('unsupported source explains the missing search capability', (
    tester,
  ) async {
    _setViewport(tester);
    final preferences = memoryPreferences();
    final store = SourceDiagnosticsStore(preferences);
    final source = _StaticSource('plain');
    final snapshot = SourceRegistrySnapshot(
      entries: <SourceEntry>[_entry(source)],
      failures: const <SourceFailure>[],
    );
    await tester.pumpWidget(
      _harness(
        snapshot: snapshot,
        store: store,
        service: _service(snapshot, store),
        initialSourceId: 'plain',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('不支持搜索'), findsWidgets);
    expect(find.textContaining('没有实现搜索能力'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('source-diagnostics-keyword')),
      findsNothing,
    );
  });

  testWidgets('invalid rule is listed without executing an invalid script', (
    tester,
  ) async {
    _setViewport(tester);
    final preferences = memoryPreferences();
    final store = SourceDiagnosticsStore(preferences);
    final snapshot = SourceRegistrySnapshot(
      entries: const <SourceEntry>[],
      failures: const <SourceFailure>[
        SourceFailure(
          id: 'broken',
          name: 'Broken source',
          message: '规则 JSON 缺少 search',
          type: MediaType.manga,
        ),
      ],
    );
    await tester.pumpWidget(
      _harness(
        snapshot: snapshot,
        store: store,
        service: _service(snapshot, store),
        initialSourceId: 'broken',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('规则无法加载'), findsWidgets);
    expect(find.textContaining('不会加载或执行此无效脚本'), findsWidgets);
    expect(
      find.byKey(const ValueKey('source-diagnostics-keyword')),
      findsNothing,
    );
  });
}
