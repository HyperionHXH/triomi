import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/ehentai/ehentai_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/ehentai_legacy_rule.dart';
import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';
import 'fixtures/test_database.dart';

const _id = 'ehentai';
const _base = 'https://e-hentai.org';
const _repo = 'https://example.test/compat/rules/ehentai.json';
const _gallery = MediaItem(
  sourceId: _id,
  remoteId: '101/aaaaaaaaaa',
  title: 'Gallery fixture',
  type: MediaType.manga,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  sourceRuleTest('migrates the old official rule before the first catalogue read', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final secure = MemorySecureStore();
    await secure.set('ehentai.ipb_member_id', '12345');
    final prefs = memoryPreferences();
    final http = FakeHttpClient((request) async {
      expect(request.url, '$_base/');
      // A gallery within nested tiles, not a direct legacy table/thumbnail row.
      return const SourceResponse(statusCode: 200, url: '$_base/', body: '''
<html><title>Gallery listing</title><div class="itg"><div class="wrapper">
<div class="gl1t"><a href="/g/101/aaaaaaaaaa/"><div class="glink">Fixture result</div></a></div>
</div></div></html>''');
    });
    final legacy = JsSource(
      rule: SourceRule.parseJson(ehentaiLegacyRule),
      runtime: createSourceRuleRuntime(),
      http: http,
    );
    addTearDown(legacy.dispose);
    await legacy.initialize();
    await expectLater(
      legacy.discover(legacy.feeds.singleWhere((feed) => feed.id == 'latest')),
      throwsA(isA<SourceException>().having(
        (error) => error.message, 'legacy parse failure', contains('图库列表为空或网页格式变化'),
      )),
    );
    http.requests.clear();

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      secureStoreProvider.overrideWithValue(secure),
      sourceHttpClientProvider.overrideWithValue(http),
      sourceJsRuntimeFactoryProvider.overrideWithValue(createSourceRuleRuntime),
    ]);
    addTearDown(container.dispose);
    final repository = container.read(sourceRepositoryProvider);
    await repository.upsert(
      id: _id,
      name: 'Installed fixture',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      version: '1.0.1',
      lang: 'all',
      ruleText: ehentaiLegacyRule.replaceAll('\n', '\r\n'),
      repoUrl: _repo,
    );
    final library = LibraryRepository(db);
    await library.addToLibrary(_gallery);

    final registry = container.read(sourceRegistryProvider);
    final entry = (await registry.load()).enabledEntries.singleWhere(
      (entry) => entry.descriptor.id == _id,
    );
    final source = entry.source as EhentaiSource;
    final discovered = await source.discover(source.feeds.singleWhere((feed) => feed.id == 'latest'));
    expect(discovered.single.title, 'Fixture result');
    expect(discovered.single.remoteId, _gallery.remoteId);
    expect(http.requests, hasLength(1));
    final installed = (await repository.byId(_id))!;
    expect(installed.version, '1.2.0');
    expect(installed.repoUrl, _repo);
    expect(installed.enabled, isTrue);
    expect((await library.listLibrary(type: MediaType.manga)).single.item.remoteId, _gallery.remoteId);
    expect(secure.get('ehentai.ipb_member_id'), '12345');
  });

  sourceRuleTest('leaves edited, disabled and removed gallery sources alone', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(FakeHttpClient((_) async => throw StateError('Unexpected network request'))),
      sourceJsRuntimeFactoryProvider.overrideWithValue(createSourceRuleRuntime),
    ]);
    addTearDown(container.dispose);
    final repository = container.read(sourceRepositoryProvider);
    final registry = container.read(sourceRegistryProvider);
    Future<void> install(String rule, {required bool enabled}) => repository.upsert(
      id: _id,
      name: 'Fixture',
      type: MediaType.manga,
      kind: SourceKind.plugin,
      version: '1.0.1',
      ruleText: rule,
      enabled: enabled,
    );
    await install(ehentaiLegacyRule.replaceFirst('公开图库', '自定义'), enabled: true);
    var snapshot = await registry.load();
    final custom = snapshot.enabledEntries.singleWhere((entry) => entry.descriptor.id == _id);
    expect(custom.descriptor.name, 'E-Hentai（自定义）');
    expect(custom.source, isNot(isA<EhentaiSource>()));

    await install(ehentaiLegacyRule, enabled: false);
    snapshot = await registry.load();
    expect(snapshot.enabledEntries.where((entry) => entry.descriptor.id == _id), isEmpty);
    expect((await repository.byId(_id))!.version, '1.0.1');

    await registry.remove(_id);
    snapshot = await registry.load();
    expect(snapshot.entries.where((entry) => entry.descriptor.id == _id), isEmpty);
  });
}
