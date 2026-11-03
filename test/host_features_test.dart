import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/host_features.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';
import 't2_js_source_test.dart' show FakeJsRuntime;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Host contracts are versioned and legacy native identities still require gateways', () {
    expect(SourceHostFeatures.requiredFor('jmcomic', []), {
      'jmcomic.api.v1',
      'jmcomic.image.v1',
    });
    expect(SourceHostFeatures.requiredFor('picacomic', []), {
      'picacomic.account.v1',
    });
    expect(SourceHostFeatures.requiredFor('wnacg', []), isEmpty);
    expect(
      () => SourceHostFeatures.requireSupported('jmcomic', [], available: {}),
      throwsStateError,
    );
    SourceHostFeatures.requireSupported('jmcomic', []);
  });
  for (final invalid in [
    'jmcomic.api.v1',
    [1],
    ['jmcomic.api.v1', 'jmcomic.api.v1'],
    ['bad feature'],
    List.filled(33, 'a.b'),
  ]) {
    test(
      'Host feature parser rejects malformed declaration ${invalid.hashCode}',
      () {
        expect(() => SourceHostFeatures.parse(invalid), throwsFormatException);
      },
    );
  }
  for (final scenario in ['missing-host', 'hidden-requirement', 'supported']) {
    test(
      'Catalog checks native contract before durable write $scenario',
      () async {
        final db = openTestDatabase();
        addTearDown(db.close);
        final features = ['picacomic.account.v1'];
        final http = FakeHttpClient(
          (request) async => throw StateError('No site requests'),
        );
        http.bytesHandler = (_) => utf8.encode(
          jsonEncode({
            'id': 'contract-fixture',
            'name': 'Contract fixture',
            'type': 'manga',
            'version': '1.0.0',
            'engine': 'js',
            'baseUrl': 'https://example.invalid',
            'requiresHost': features,
            'script': 'function search() { return []; }',
          }),
        );
        final registry = SourceRegistry(
          repository: SourceRepository(db),
          http: http,
          jsRuntimeFactory: () => FakeJsRuntime(functions: {'search'}),
        );
        addTearDown(registry.dispose);
        final entry = SourceCatalogEntry(
          id: 'contract-fixture',
          name: 'Contract fixture',
          type: MediaType.manga,
          version: const CatalogVersion(1, 0, 0),
          url: 'https://example.invalid/rule.json',
          capabilities: {SourceCapability.search},
          requiresHost: scenario == 'hidden-requirement' ? [] : features,
        );
        final installer = CatalogInstaller(
          registry,
          hostFeatures: scenario == 'missing-host'
              ? {}
              : SourceHostFeatures.supported,
        );
        if (scenario == 'supported') {
          await installer.install(entry);
          expect(await registry.repository.byId(entry.id), isNotNull);
        } else {
          await expectLater(installer.install(entry), throwsStateError);
          expect(await registry.repository.byId(entry.id), isNull);
          if (scenario == 'missing-host') expect(http.requests, isEmpty);
        }
      },
    );
  }
  test(
    'Manual import refuses unknown native contract without storing the rule',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final registry = SourceRegistry(
        repository: SourceRepository(db),
        http: FakeHttpClient((_) async => throw StateError('No network')),
      );
      addTearDown(registry.dispose);
      final rule = jsonEncode({
        'id': 'future',
        'name': 'Future',
        'type': 'manga',
        'engine': 'js',
        'script': 'function search() {}',
        'requiresHost': ['future.gateway.v9'],
      });
      expect(SourceRule.parseJson(rule).requiresHost, ['future.gateway.v9']);
      await expectLater(registry.importFromText(rule), throwsStateError);
      expect(await registry.repository.byId('future'), isNull);
    },
  );
}
