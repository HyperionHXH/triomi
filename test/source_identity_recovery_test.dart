import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/bangumi_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/kazumi_repository.dart';
import 'package:triomi/core/source/kazumi_source.dart';
import 'package:triomi/core/source/source_catalog.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/detail/anime_source_sheet.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/sources/catalog_sheet.dart';
import 'package:triomi/features/sources/sources_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late SourceRepository repository;
  late SourceRegistry registry;
  var databaseClosed = false;
  final legacyText = File('assets/rules/age-anime-js.json')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final officialText = File('assets/rules/kazumi-AGE.json').readAsStringSync();
  final metadataText = File('assets/rules/bangumi-anime.json')
      .readAsStringSync();
  final ageId = KazumiRule.idForName('AGE');

  setUp(() {
    databaseClosed = false;
    db = openTestDatabase();
    repository = SourceRepository(db);
    registry = SourceRegistry(
      repository: repository,
      http: FakeHttpClient(
        (_) async => throw StateError('Must remain offline'),
      ),
    );
  });
  tearDown(() async {
    registry.dispose();
    if (!databaseClosed) await db.close();
  });

  Future<void> closeWidget(
    WidgetTester tester,
    ProviderContainer container, {
    SourceRegistry? extraRegistry,
  }) async {
    await _finishIdentityOwned(tester, container.read(sourcesProvider.future));
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await _settleIdentityIo(tester);
    extraRegistry?.dispose();
    registry.dispose();
    await tester.runAsync(() => db.close().timeout(const Duration(seconds: 5)));
    databaseClosed = true;
  }

  Future<void> installLegacy({String? text}) => repository.upsert(
    id: 'age-anime',
    name: 'AGE 番剧',
    type: MediaType.anime,
    kind: SourceKind.builtin,
    ruleText: text ?? legacyText,
    version: '1.0.1',
    enabled: false,
  );

  Future<void> installCanonical() => registry.importFromText(
    officialText,
    repoUrl: KazumiRepository.defaultRepository,
  );

  test(
    'metadata recovers from prior deletion and seeded tombstone on load',
    () async {
      final markers = await registry.seedBuiltins(alreadySeeded: {});
      await db.customStatement(
        "DELETE FROM sources WHERE id = 'bangumi-anime'",
      );
      await registry.seedBuiltins(alreadySeeded: markers);
      final restored = (await repository.byId('bangumi-anime'))!;
      expect(restored.ruleText, metadataText);
      expect(restored.enabled, isTrue);
      expect(restored.kind, SourceKind.builtin);
      await db.customStatement(
        "DELETE FROM sources WHERE id = 'bangumi-anime'",
      );
      final snapshot = await registry.load();
      final entry = snapshot.enabledEntries.singleWhere(
        (entry) => entry.descriptor.id == 'bangumi-anime',
      );
      expect(entry.source, isA<BangumiSource>());
      expect(entry.isInternal, isTrue);
      expect(snapshot.manageableEntries, isNot(contains(entry)));
      expect(entry.supports(SourceCapability.search), isTrue);
      expect(entry.supports(SourceCapability.detail), isTrue);
      expect(entry.supports(SourceCapability.content), isFalse);
      expect(snapshot.failures, isEmpty);
    },
  );

  test('metadata repairs disabled or replaced old rows without touching other rules', () async {
    await registry.seedBuiltins(alreadySeeded: {});
    final age = (await repository.byId(ageId))!;
    await db.customStatement(
      "UPDATE sources SET enabled = 0, kind = 'plugin', rule_text = '{}' WHERE id = 'bangumi-anime'",
    );
    await registry.load();
    final restored = (await repository.byId('bangumi-anime'))!;
    expect(restored.enabled, isTrue);
    expect(restored.ruleText, metadataText);
    expect(restored.kind, SourceKind.builtin);
    expect(await repository.byId(ageId), age);
  });

  test(
    'internal metadata cannot be disabled, removed or replaced by rule import',
    () async {
      await registry.load();
      final original = (await repository.byId('bangumi-anime'))!;
      await expectLater(
        registry.setEnabled(original.id, enabled: false),
        throwsStateError,
      );
      await expectLater(registry.remove(original.id), throwsStateError);
      await expectLater(
        repository.setEnabled(original.id, enabled: false),
        throwsStateError,
      );
      await expectLater(repository.remove(original.id), throwsStateError);
      await expectLater(
        registry.importFromText(metadataText),
        throwsA(isA<Exception>()),
      );
      expect(await repository.byId(original.id), original);
    },
  );

  test(
    'fresh defaults have exactly one AGE playback identity and no legacy seed',
    () async {
      final markers = await registry.seedBuiltins(alreadySeeded: {});
      expect(await repository.byId('age-anime'), isNull);
      expect(await repository.byId(ageId), isNotNull);
      expect(markers, isNot(contains('assets/rules/age-anime-js.json')));
      final rows = await repository.all();
      expect(
        rows.where((row) => row.id.startsWith('kazumi:')),
        hasLength(SourceRegistry.officialKazumiNames.length),
      );
      expect(await registry.seedBuiltins(alreadySeeded: markers), isEmpty);
      expect(await repository.all(), rows);
    },
  );

  for (final crlf in [false, true]) {
    test(
      'unused pristine ${crlf ? 'CRLF Windows' : 'LF'} legacy retires only when canonical AGE is installed',
      () async {
        await installLegacy(
          text: crlf ? legacyText.replaceAll('\n', '\r\n') : legacyText,
        );
        await installCanonical();
        final canonical = (await repository.byId(ageId))!;
        final markers = await registry.seedBuiltins(alreadySeeded: {});
        expect(await repository.byId('age-anime'), isNull);
        expect(await repository.byId(ageId), canonical);
        expect(await registry.seedBuiltins(alreadySeeded: markers), isEmpty);
        expect(await repository.byId(ageId), canonical);
      },
    );
  }

  test('archived same-site canonical AGE still retires the unused pristine duplicate', () async {
    await installLegacy();
    final archived = jsonDecode(officialText) as Map<String, dynamic>;
    archived['deprecated'] = true;
    await registry.importFromText(
      jsonEncode(archived),
      allowDeprecated: true,
      repoUrl: KazumiRepository.defaultRepository,
    );
    final canonical = (await repository.byId(ageId))!;
    expect(canonical.enabled, isFalse);
    final snapshot = await registry.load();
    expect(await repository.byId('age-anime'), isNull);
    expect(await repository.byId(ageId), canonical);
    expect(
      snapshot.manageableEntries.where(
        (entry) => entry.descriptor.type == MediaType.anime,
      ),
      hasLength(1),
    );
  });

  for (final crlf in [false, true]) {
    test(
      'favorites history downloads and confirmed playback links keep original ${crlf ? 'CRLF Windows' : 'LF'} identities',
      () async {
        await installLegacy(
          text: crlf ? legacyText.replaceAll('\n', '\r\n') : legacyText,
        );
        await installCanonical();
        await db.customStatement(
          "INSERT INTO media_items (source_id, remote_id, type, title, url) VALUES ('age-anime', '123', 'anime', '同名作品', 'https://www.agedm.io/detail/123')",
        );
        await db.customStatement(
          "INSERT INTO chapters (source_id, remote_id, item_source_id, item_remote_id, title, url) VALUES ('age-anime', '123/1/2', 'age-anime', '123', '第2集', 'https://www.agedm.io/play/123/1/2')",
        );
        await db.customStatement(
          "INSERT INTO library_entries (source_id, remote_id, type, added_at, updated_at, progress) VALUES ('age-anime', '123', 'anime', 1, 2, 2)",
        );
        await db.customStatement(
          "INSERT INTO histories (source_id, remote_id, chapter_source_id, chapter_remote_id, position, visited_at) VALUES ('age-anime', '123', 'age-anime', '123/1/2', 37, 2)",
        );
        await db.customStatement(
          "INSERT INTO downloads (source_id, remote_id, chapter_source_id, chapter_remote_id, status, path, created_at) VALUES ('age-anime', '123', 'age-anime', '123/1/2', 'done', '/preserve/age/episode.mp4', 2)",
        );
        await db.customStatement(
          "INSERT INTO anime_source_links (subject_source_id, subject_remote_id, source_id, remote_id, last_chapter_id, updated_at) VALUES ('bangumi-anime', '999', 'age-anime', '123', '123/1/2', 2)",
        );
        final tables = [
          'media_items',
          'chapters',
          'library_entries',
          'histories',
          'downloads',
          'anime_source_links',
        ];
        Future<List<List<Map<String, Object?>>>> data() async => [
          for (final table in tables)
            for (final rows in [
              await db.customSelect('SELECT * FROM $table').get(),
            ])
              [for (final row in rows) row.data],
        ];
        final before = await data();
        final legacy = (await repository.byId('age-anime'))!;
        final markers = await registry.seedBuiltins(alreadySeeded: {});
        final snapshot = await registry.load();
        expect(await data(), before);
        expect(await repository.byId('age-anime'), legacy);
        final retained = snapshot.entries.singleWhere(
          (entry) => entry.descriptor.id == 'age-anime',
        );
        expect(retained.isRetiredDefault, isTrue);
        expect(retained.isCustomLegacyAge, isFalse);
        expect(
          retained.ruleText,
          crlf ? legacyText.replaceAll('\n', '\r\n') : legacyText,
        );
        expect(retained.enabled, isFalse);
        expect(
          snapshot.manageableEntries.where(
            (entry) => entry.descriptor.id == ageId,
          ),
          hasLength(1),
        );
        expect(
          snapshot.manageableEntries.any(
            (entry) => entry.descriptor.id == 'age-anime',
          ),
          isFalse,
        );
        await registry.seedBuiltins(alreadySeeded: markers);
        expect(await data(), before);
      },
    );
  }

  test('a lone history, download or mapping prevents legacy deletion without cached item rows', () async {
    await installCanonical();
    for (final statement in [
      "INSERT INTO histories (source_id, remote_id, chapter_source_id, chapter_remote_id, visited_at) VALUES ('bangumi-anime', '999', 'age-anime', '123/1/2', 2)",
      "INSERT INTO downloads (source_id, remote_id, chapter_source_id, chapter_remote_id, status, created_at) VALUES ('bangumi-anime', '999', 'age-anime', '123/1/2', 'paused', 2)",
      "INSERT INTO anime_source_links (subject_source_id, subject_remote_id, source_id, remote_id, updated_at) VALUES ('bangumi-anime', '999', 'age-anime', '123', 2)",
    ]) {
      await installLegacy();
      await db.customStatement(statement);
      await registry.seedBuiltins(
        alreadySeeded: {'assets/rules/kazumi-AGE.json'},
      );
      expect(await repository.byId('age-anime'), isNotNull);
      await db.customStatement('DELETE FROM histories');
      await db.customStatement('DELETE FROM downloads');
      await db.customStatement('DELETE FROM anime_source_links');
    }
  });

  test('a one-byte custom script edit is not hidden or retired after CRLF normalization', () async {
    final windowsText = legacyText.replaceAll('\n', '\r\n');
    final custom = windowsText.replaceFirst('Chrome/130', 'Chrome/131');
    expect(custom, isNot(windowsText));
    expect(custom.length, windowsText.length);
    await installLegacy(text: custom);
    await installCanonical();
    final original = (await repository.byId('age-anime'))!;
    await registry.seedBuiltins(alreadySeeded: {});
    final snapshot = await registry.load();
    expect(await repository.byId('age-anime'), original);
    final retained = snapshot.manageableEntries.singleWhere(
      (entry) => entry.descriptor.id == 'age-anime',
    );
    expect(retained.ruleText, custom);
    expect(retained.isCustomLegacyAge, isTrue);
    expect(retained.isRetiredDefault, isFalse);
    expect(
      snapshot.manageableEntries.any((entry) => entry.descriptor.id == ageId),
      isTrue,
    );
  });

  test(
    'edited same-site legacy is neither deleted nor hidden or title merged',
    () async {
      final custom = jsonDecode(legacyText) as Map<String, dynamic>;
      custom['name'] = 'AGE';
      custom['customNote'] = 'user edit';
      final text = jsonEncode(custom);
      await installLegacy(text: text);
      await installCanonical();
      final before = (await repository.byId('age-anime'))!;
      await registry.seedBuiltins(alreadySeeded: {});
      final snapshot = await registry.load();
      expect(await repository.byId('age-anime'), before);
      expect(
        snapshot.manageableEntries.any(
          (entry) => entry.descriptor.id == 'age-anime',
        ),
        isTrue,
      );
      expect(
        snapshot.manageableEntries.any((entry) => entry.descriptor.id == ageId),
        isTrue,
      );
    },
  );

  test('canonical tombstone is respected until explicit install', () async {
    await installLegacy();
    const markers = {
      'assets/rules/age-anime-js.json',
      'assets/rules/kazumi-AGE.json',
    };
    await registry.seedBuiltins(alreadySeeded: markers);
    expect(await repository.byId(ageId), isNull);
    expect(await repository.byId('age-anime'), isNotNull);
    expect(
      (await registry.load()).manageableEntries.any(
        (entry) => entry.descriptor.id == 'age-anime',
      ),
      isTrue,
    );
    await installCanonical();
    await registry.seedBuiltins(alreadySeeded: markers);
    expect(await repository.byId('age-anime'), isNull);
    expect(await repository.byId(ageId), isNotNull);
  });

  test(
    'metadata-only preload does not mark a new profile as an upgrade',
    () async {
      await registry.load();
      expect(await repository.count(), 1);
      await registry.seedBuiltins(alreadySeeded: {});
      expect(
        (await repository.all()).where((row) => row.id.startsWith('kazumi:')),
        hasLength(SourceRegistry.officialKazumiNames.length),
      );
      expect(await repository.byId('age-anime'), isNull);
    },
  );

  testWidgets(
    'saved legacy AGE remains selectable while fresh candidates contain only canonical AGE',
    (tester) async {
      await installLegacy();
      await installCanonical();
      await repository.setEnabled('age-anime', enabled: true);
      const subject = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '999',
        type: MediaType.anime,
        title: '资料作品',
        url: 'https://bgm.tv/subject/999',
      );
      const legacyItem = MediaItem(
        sourceId: 'age-anime',
        remoteId: '123',
        type: MediaType.anime,
        title: '旧版已选作品',
        url: 'https://www.agedm.io/detail/123',
      );
      await AnimeIdentityRepository(db).confirm(subject, legacyItem);
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          url: request.url,
          body: '<html><body></body></html>',
        ),
      );
      final playbackRegistry = SourceRegistry(
        repository: repository,
        http: http,
      );
      final snapshot = await _finishIdentityOwned(
        tester,
        playbackRegistry.load(),
      );
      expect(
        snapshot.entries
            .singleWhere((entry) => entry.descriptor.id == 'age-anime')
            .isRetiredDefault,
        isTrue,
      );
      expect(
        snapshot.manageableEntries.where(
          (entry) => entry.descriptor.type == MediaType.anime,
        ),
        hasLength(1),
      );
      MediaItem? selected;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sourceRegistryProvider.overrideWithValue(playbackRegistry),
          sourcesProvider.overrideWith(_IdentitySources.new),
        ],
      );
      try {
        await _finishIdentityOwned(
          tester,
          container.read(sourcesProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      selected = await showModalBottomSheet<MediaItem>(
                        context: context,
                        builder: (_) => const AnimeSourceSheet(item: subject),
                      );
                    },
                    child: const Text('选择播放来源'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('选择播放来源'));
        await _waitIdentityUntil(
          tester,
          () =>
              find
                  .widgetWithText(ListTile, '最近使用 · 旧版已选作品')
                  .evaluate()
                  .isNotEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(find.text('AGE'), findsOneWidget);
        expect(find.text('AGE 番剧'), findsNothing);
        final saved = find.widgetWithText(ListTile, '最近使用 · 旧版已选作品');
        expect(tester.widget<ListTile>(saved).onTap, isNotNull);
        expect(find.text('来源已停用或移除，可选择其他来源'), findsNothing);
        expect(http.requests, hasLength(1));
        expect(http.requests.single.url, contains('/search?query='));
        expect(
          http.requests.single.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
        await tester.tap(saved);
        await _waitIdentityUntil(tester, () => selected != null);
        expect(selected?.sourceId, 'age-anime');
        expect(selected?.remoteId, '123');
        expect(
          (await AnimeIdentityRepository(db).links(subject)).single.sourceId,
          'age-anime',
        );
      } finally {
        await closeWidget(tester, container, extraRegistry: playbackRegistry);
      }
    },
  );

  testWidgets(
    'plugin page hides metadata and duplicate default but manages retained legacy explicitly',
    (tester) async {
      await installLegacy();
      await installCanonical();
      await db.customStatement(
        "INSERT INTO histories (source_id, remote_id, chapter_source_id, chapter_remote_id, visited_at) VALUES ('age-anime', '123', 'age-anime', '123/1/2', 2)",
      );
      final preferences = memoryPreferences();
      await preferences.set('kazumi.repositories', <String, bool>{});
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourceRegistryProvider.overrideWithValue(registry),
          sourcesProvider.overrideWith(_IdentitySources.new),
        ],
      );
      try {
        await _finishIdentityOwned(
          tester,
          container.read(sourcesProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: SourcesPage(initialType: MediaType.anime),
            ),
          ),
        );
        await _settleIdentityIo(tester);
        expect(find.text('Bangumi 番剧资料'), findsNothing);
        expect(find.text('AGE 番剧'), findsNothing);
        expect(find.text('AGE'), findsOneWidget);
        await tester.tap(find.byTooltip('AGE更多操作'));
        await _settleIdentityIo(tester);
        await tester.tap(find.text('旧版 AGE 记录来源'));
        await _settleIdentityIo(tester);
        expect(find.textContaining('不按标题合并'), findsOneWidget);
        final oldSwitch = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Switch),
        );
        await tester.tap(oldSwitch);
        await _settleIdentityIo(tester);
        expect((await repository.byId('age-anime'))!.enabled, isTrue);
        expect(
          (await db.customSelect('SELECT * FROM histories').get())
              .single
              .data['chapter_remote_id'],
          '123/1/2',
        );
        await tester.tap(find.text('关闭'));
        await _settleIdentityIo(tester);
      } finally {
        await closeWidget(tester, container);
      }
    },
  );

  testWidgets(
    'even a remote plugin catalog cannot list foundational metadata',
    (tester) async {
      final entries = SourceCatalogIndex.parse(
        jsonEncode({
          'sources': [
            {
              'id': 'bangumi-anime',
              'name': 'Bangumi internal plugin disguise',
              'type': 'anime',
              'version': '9.0.0',
              'url': 'https://example.test/bangumi.json',
              'capabilities': ['search', 'detail'],
            },
          ],
        }),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceCatalogLoaderProvider.overrideWithValue(() async => entries),
          sourceRegistryProvider.overrideWithValue(registry),
          sourcesProvider.overrideWith(_IdentitySources.new),
        ],
      );
      try {
        await _finishIdentityOwned(
          tester,
          container.read(sourcesProvider.future),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: CatalogSheet())),
          ),
        );
        await _settleIdentityIo(tester);
        expect(find.text('Bangumi internal plugin disguise'), findsNothing);
        expect(find.text('安装'), findsNothing);
      } finally {
        await closeWidget(tester, container);
      }
    },
  );
}

class _IdentitySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() =>
      ref.read(sourceRegistryProvider).load();
}

// Registry loads and saved-link FutureBuilders query SQLite's real worker.
// Let those replies run before settling Flutter animations, as in other source
// page tests; advancing the fake clock alone cannot complete these reads.
Future<void> _settleIdentityIo(WidgetTester tester) async {
  for (var round = 0; round < 12; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _waitIdentityUntil(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 300 && !complete(); attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(
    complete(),
    isTrue,
    reason: 'Identity consumer state must finish loading',
  );
  await _settleIdentityIo(tester);
}

Future<T> _finishIdentityOwned<T>(
  WidgetTester tester,
  Future<T> pending,
) async {
  var finished = false;
  late T result;
  Object? failure;
  StackTrace? trace;
  unawaited(
    pending.then(
      (value) {
        result = value;
        finished = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        finished = true;
      },
    ),
  );
  for (var attempt = 0; attempt < 300 && !finished; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  expect(finished, isTrue, reason: 'Identity operation must finish');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result;
}
