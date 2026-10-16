import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SourceRepository repository;
  late SourceRegistry registry;
  setUp(() {
    db = openTestDatabase();
    repository = SourceRepository(db);
    registry = SourceRegistry(
      repository: repository,
      jsRuntimeFactory: FlutterJsRuntime.new,
      http: FakeHttpClient((_) async => throw StateError('启动不应触网')),
    );
  });
  tearDown(() async {
    registry.dispose();
    await db.close();
  });
  test('全新数据库默认有真实漫画来源，不播种仅调试夹具', () async {
    await registry.seedBuiltins(alreadySeeded: {});
    final snapshot = await registry.load();
    addTearDown(() {
      for (final entry in snapshot.entries) {
        if (entry.source is JsSource) (entry.source as JsSource).dispose();
      }
    });
    expect(
      snapshot.enabledEntries.any((e) => e.descriptor.id == 'mangadex'),
      isTrue,
    );
    expect(
      snapshot.enabledEntries.any(
        (e) => developmentSourceIds.contains(e.descriptor.id),
      ),
      isFalse,
    );
    expect(snapshot.failures, isEmpty);
    expect(
      snapshot.enabledEntries.where((entry) => entry.source is KazumiSource),
      hasLength(3),
    );
  });
  test('新增随包播种路径保留已经安装和禁用的同id规则', () async {
    final text = File('assets/rules/mangadex-api-js.json').readAsStringSync();
    await repository.upsert(
      id: 'mangadex',
      name: '我编辑的来源',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      ruleText: text,
      version: '9.0.0',
      enabled: false,
    );
    await registry.seedBuiltins(alreadySeeded: {});
    final saved = (await repository.byId('mangadex'))!;
    expect(saved.name, '我编辑的来源');
    expect(saved.version, '9.0.0');
    expect(saved.enabled, isFalse);
    expect(saved.kind, SourceKind.plugin);
    expect(saved.ruleText, text);
  });
  test('旧数据库残留夹具可在管理页保留但不参加日常浏览搜索', () async {
    await repository.upsert(
      id: 'local-fixture',
      name: '本地夹具',
      type: MediaType.manga,
      kind: SourceKind.builtin,
      ruleText: File('assets/rules/local-fixture.json').readAsStringSync(),
      enabled: true,
    );
    await registry.seedBuiltins(alreadySeeded: {});
    final snapshot = await registry.load();
    addTearDown(() {
      for (final entry in snapshot.entries) {
        if (entry.source is JsSource) (entry.source as JsSource).dispose();
      }
    });
    expect(
      snapshot.entries.any((e) => e.descriptor.id == 'local-fixture'),
      isTrue,
    );
    expect(
      snapshot.enabledEntries.any((e) => e.descriptor.id == 'local-fixture'),
      isFalse,
    );
  });
}
