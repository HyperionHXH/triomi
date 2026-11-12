import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/ehentai/ehentai_source.dart';
import 'package:triomi/core/source/jmcomic/jmcomic_js_source.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/picacomic/picacomic_js_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_filters.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';
import 'fixtures/test_database.dart';
import 't2_js_source_test.dart' show FakeJsRuntime;

class _Files extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => Platform.isIOS
      ? rootBundle.load(key)
      : ByteData.sublistView(await File(key).readAsBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sourceRuleTest('reader ports install from bundled catalog and production registry chooses isolated adapters', () async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final http = FakeHttpClient(
      (_) async =>
          throw StateError('Catalog/install must not request site data'),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(memoryPreferences()),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        sourceHttpClientProvider.overrideWithValue(http),
        sourceJsRuntimeFactoryProvider.overrideWithValue(
          () => FakeJsRuntime(
            functions: {'discover', 'search', 'detail', 'content'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final registry = container.read(sourceRegistryProvider);
    final installer = CatalogInstaller(registry, bundle: _Files());
    final catalog = SourceCatalogIndex.parse(
      await readSourceRuleAsset('assets/catalog/index.json'),
    );
    for (final id in ['picacomic', 'wnacg', 'jmcomic', 'ehentai']) {
      final entry = catalog.singleWhere((e) => e.id == id);
      expect(entry.nsfw, true);
      expect(SourceContentRestriction.excludeNsfw.matches(entry.nsfw), false);
      expect((await installer.install(entry)).id, id);
    }
    final snapshot = await registry.load();
    expect(snapshot.failures, isEmpty);
    final sources = {
      for (final entry in snapshot.entries) entry.descriptor.id: entry.source,
    };
    expect(sources['picacomic'], isA<PicacomicJsSource>());
    expect(sources['picacomic'], isA<AccountProvider>());
    expect(sources['jmcomic'], isA<JmcomicJsSource>());
    expect(sources['jmcomic'], isNot(isA<AccountProvider>()));
    expect(sources['wnacg'], isA<JsSource>());
    expect(sources['wnacg'], isNot(isA<AccountProvider>()));
    expect(sources['ehentai'], isA<EhentaiSource>());
    expect(sources['ehentai'], isA<AccountProvider>());
    for (final id in ['picacomic', 'wnacg', 'jmcomic', 'ehentai']) {
      final entry = snapshot.entries.singleWhere((e) => e.descriptor.id == id);
      expect(entry.descriptor.nsfw, true);
      expect(entry.enabled, true);
      expect(entry.descriptor.requireLogin, id == 'picacomic');
      expect(
        entry.descriptor.capabilities,
        containsAll([
          SourceCapability.discover,
          SourceCapability.search,
          SourceCapability.detail,
          SourceCapability.content,
        ]),
      );
    }
    expect(http.requests, isEmpty);
  });
}
