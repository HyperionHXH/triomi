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
      hasLength(SourceRegistry.officialKazumiNames.length),
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

  test('official seed adds new plugins once without resurrecting removals or replacing custom rules', () async {
    final seeded = await registry.seedBuiltins(alreadySeeded: {});
    final removed = KazumiRule.idForName('7sefun');
    final disabled = KazumiRule.idForName('MXdm');
    await repository.remove(removed);
    await repository.setEnabled(disabled, enabled: false);
    final original = (await repository.byId(disabled))!;
    await repository.upsert(
      id: KazumiRule.idForName('DM84'),
      name: 'DM84',
      type: MediaType.anime,
      kind: SourceKind.plugin,
      ruleText: '{"my":"custom rule"}',
      version: '99.0',
      repoUrl: 'manual',
      enabled: false,
    );
    final custom = (await repository.byId(KazumiRule.idForName('DM84')))!;
    expect(await registry.seedBuiltins(alreadySeeded: seeded), isEmpty);
    expect(await repository.byId(removed), isNull);
    expect(await repository.byId(disabled), original);
    expect(await repository.byId(custom.id), custom);
    final official = (await repository.all()).where(
      (row) => row.id.startsWith('kazumi:'),
    );
    expect(official, hasLength(SourceRegistry.officialKazumiNames.length - 1));
    expect(
      official
          .where((row) => row.id != custom.id)
          .every(
            (row) => row.repoUrl == 'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json',
          ),
      isTrue,
    );
  });

  test('upgrading an existing profile does not resurrect previously repository-only removals', () async {
    final oldMarkers = {
      'assets/rules/bangumi-anime.json',
      'assets/rules/age-anime-js.json',
      'assets/rules/kazumi-7sefun.json',
      'assets/rules/kazumi-MXdm.json',
      'assets/rules/kazumi-DM84.json',
      'assets/rules/mangadex-api-js.json',
    };
    for (final name in ['MXdm', 'DM84', 'AGE']) {
      final text = File('assets/rules/kazumi-$name.json').readAsStringSync();
      final parsed = KazumiRule.parse(text).descriptor;
      await repository.upsert(
        id: parsed.id,
        name: parsed.name,
        type: parsed.type,
        kind: SourceKind.plugin,
        ruleText: text,
        version: parsed.version,
        enabled: false,
        repoUrl: 'manual',
      );
    }
    // AGE previously came from the live repo; old builds retained no marker.
    await repository.remove(KazumiRule.idForName('AGE'));
    final before = await repository.all();
    final newlyConsidered = await registry.seedBuiltins(
      alreadySeeded: oldMarkers,
    );
    expect(await repository.all(), before);
    expect(await repository.byId(KazumiRule.idForName('AGE')), isNull);
    expect(await repository.byId(KazumiRule.idForName('7sefun')), isNull);
    expect(await repository.byId(KazumiRule.idForName('aafun')), isNull);
    expect(
      newlyConsidered.where((path) => path.startsWith('assets/rules/kazumi-')),
      hasLength(15),
    );
    expect(
      await registry.seedBuiltins(
        alreadySeeded: {...oldMarkers, ...newlyConsidered},
      ),
      isEmpty,
    );
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
