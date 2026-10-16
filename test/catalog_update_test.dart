import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/catalog_installer.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

class _ChunkedHttp extends FakeHttpClient {
  _ChunkedHttp() : super((_) async => throw StateError('unused'));
  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async => SourceByteStream(
    url: url,
    stream: Stream.fromIterable([
      List.filled(CatalogInstaller.maxBytes, 32),
      [32],
    ]),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capabilities = {SourceCapability.search};
  String rule({
    String id = 'upgrade',
    String version = '1.1.0',
    String type = 'manga',
  }) => jsonEncode({
    'id': id,
    'name': 'Update fixture',
    'type': type,
    'version': version,
    'baseUrl': 'https://example.test',
    'response': 'html',
    'capabilities': ['search'],
    'search': {
      'url': '/search?q={keywordEncoded}',
      'list': 'a',
      'fields': {'title': '.'},
    },
  });
  SourceCatalogEntry entry({String? hash}) => SourceCatalogEntry(
    id: 'upgrade',
    name: 'Update fixture',
    type: MediaType.manga,
    version: const CatalogVersion(1, 1, 0),
    url: 'https://example.test/rule.json',
    capabilities: capabilities,
    hash: hash,
  );
  test('SemVer prerelease ordering, build metadata and invalid versions', () {
    final versions = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ];
    for (var i = 1; i < versions.length; i++) {
      expect(
        CatalogVersion.tryParse(versions[i])!
            .isNewerThan(CatalogVersion.tryParse(versions[i - 1])!),
        isTrue,
      );
    }
    expect(
      CatalogVersion.tryParse('1.0.0+build.2'),
      CatalogVersion.tryParse('1.0.0'),
    );
    for (final bad in ['01.0.0', '1.0.0-01', '1.0', '1.0.0-']) {
      expect(CatalogVersion.tryParse(bad), isNull);
    }
  });
  for (final scenario in [
    'success',
    'identity',
    'type',
    'version',
    'capability',
    'hash',
    'download',
    'syntax',
    'js-syntax',
    'chunked-size',
    'size',
    'edit',
    'delete',
  ]) {
    test('transactional update: $scenario', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = SourceRepository(db);
      await repo.upsert(
        id: 'upgrade',
        name: 'Old',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        version: '1.0.0',
        ruleText: rule(version: '1.0.0'),
        enabled: false,
      );
      final old = await repo.byId('upgrade');
      final library = LibraryRepository(db);
      const item = MediaItem(
        sourceId: 'upgrade',
        remoteId: 'book',
        title: 'Kept',
        type: MediaType.manga,
      );
      const chapter = Chapter(
        sourceId: 'upgrade',
        remoteId: 'c1',
        title: 'Kept chapter',
      );
      await library.addToLibrary(item);
      await library.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: [chapter],
      );
      await library.recordHistory(
        sourceId: item.sourceId,
        remoteId: item.remoteId,
        chapter: chapter,
        position: 7,
      );
      final savedHistory = await db.select(db.histories).get();
      final savedShelf = await db.select(db.libraryEntries).get();
      final gate = Completer<SourceResponse>();
      final http = FakeHttpClient((request) async {
        if (scenario == 'download') throw StateError('offline');
        if (scenario == 'edit' || scenario == 'delete') return gate.future;
        return SourceResponse(
          statusCode: 200,
          url: request.url,
          body: switch (scenario) {
            'identity' => rule(id: 'another'),
            'type' => rule(type: 'novel'),
            'version' => rule(version: '2.0.0'),
            'capability' => jsonEncode({
              'id': 'upgrade',
              'name': 'x',
              'type': 'manga',
              'version': '1.1.0',
              'baseUrl': 'https://example.test',
              'content': {
                'url': '/',
                'images': ['img'],
              },
            }),
            'syntax' => '{invalid',
            'js-syntax' => jsonEncode({
              'id': 'upgrade',
              'name': 'broken JS',
              'type': 'manga',
              'version': '1.1.0',
              'engine': 'js',
              'baseUrl': 'https://example.test',
              'script': 'async function search( { definitely invalid',
            }),
            'size' => 'x' * (CatalogInstaller.maxBytes + 1),
            _ => rule(),
          },
        );
      });
      final install = CatalogInstaller(
        SourceRegistry(
          repository: repo,
          http: scenario == 'chunked-size' ? _ChunkedHttp() : http,
        ),
      );
      if (scenario == 'edit' || scenario == 'delete') {
        final pending = install.install(entry());
        final assertion = expectLater(pending, throwsStateError);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (scenario == 'edit') {
          await repo.setEnabled('upgrade', enabled: true);
        } else {
          await repo.remove('upgrade');
        }
        gate.complete(SourceResponse(statusCode: 200, body: rule()));
        await assertion;
        final current = await repo.byId('upgrade');
        if (scenario == 'edit') {
          expect(current!.version, '1.0.0');
          expect(current.enabled, isTrue);
        } else {
          expect(current, isNull);
        }
      } else if (scenario == 'success') {
        await install.install(entry());
        final updated = (await repo.byId('upgrade'))!;
        expect(updated.version, '1.1.0');
        expect(updated.enabled, isFalse);
        expect(updated.kind, old!.kind);
        await expectLater(install.install(entry()), throwsStateError);
      } else {
        await expectLater(
          install.install(entry(hash: scenario == 'hash' ? '0' * 64 : null)),
          throwsA(anything),
        );
        expect(
          await repo.byId('upgrade'),
          old,
          reason: 'failed updates preserve the entire old row',
        );
      }
      expect(await db.select(db.histories).get(), savedHistory);
      expect(await db.select(db.libraryEntries).get(), savedShelf);
      expect(await library.chapterPositionOf('upgrade', 'book', 'c1'), 7);
    });
  }
}
