import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/missing_source_actions.dart';
import 'package:triomi/features/profile/data/synced_source_hint.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _item = MediaItem(
  sourceId: 'mihon:org.example.reader:123',
  remoteId: '/manga/42',
  type: MediaType.manga,
  title: '同步漫画',
);

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    support = await Directory.systemTemp.createTemp('missing-source-ui-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => support.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    await support.delete(recursive: true);
  });
  testWidgets(
    'missing plugin displays exact imported identity without loading plugins',
    (tester) async {
      final db = openTestDatabase();
      final preferences = memoryPreferences();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(preferences),
          sourceRegistryProvider.overrideWith(
            (ref) => throw StateError('metadata UI must not load plugins'),
          ),
        ],
      );
      await tester.runAsync(() async {
        await LibraryRepository(db).cacheItem(_item);
        await storeSyncedSourceHint(
          db,
          _item.remoteId,
          const SyncedSourceHint(
            sourceId: 'mihon:org.example.reader:123',
            name: '原漫画来源',
            packageName: 'org.example.reader',
            repoUrl: 'https://plugins.example.org/index.json',
          ),
        );
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: MissingSourceNotice(item: _item)),
          ),
        ),
      );
      await _advance(tester);
      expect(find.text('此设备缺少原来源'), findsOneWidget);
      await tester.tap(find.text('安装 / 管理来源或搜索迁移'));
      await _advance(tester);
      expect(find.text('mihon:org.example.reader:123'), findsOneWidget);
      expect(find.text('org.example.reader'), findsOneWidget);
      expect(
        find.text('https://plugins.example.org/index.json'),
        findsOneWidget,
      );
      expect(find.text('打开插件库 / 管理'), findsOneWidget);
      expect(find.text('搜索其他来源并迁移'), findsOneWidget);
      expect(preferences.get<Object?>('mihon.repositories'), isNull);
      expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
      await tester.ensureVisible(find.text('打开插件库 / 管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开插件库 / 管理'));
      await _advance(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'org.example.reader',
      );
      await tester.tap(find.byType(BackButton));
      await _advance(tester);
      await tester.pumpAndSettle();
      expect(find.byType(MissingSourceNotice), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(db.close);
    },
  );

  testWidgets('installed disabled plugin is distinct from missing plugin', (
    tester,
  ) async {
    final db = openTestDatabase();
    final preferences = memoryPreferences();
    await preferences.set('mihon.installedPackages', {
      'org.example.reader': '1.0',
    });
    await preferences.set('mihon.hostStatus', {
      'org.example.reader': {
        'ok': true,
        'sources': [
          {'id': '123', 'name': '本机漫画来源'},
        ],
      },
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        sourceRegistryProvider.overrideWith(
          (ref) => throw StateError('metadata UI must not load plugins'),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: MissingSourceNotice(item: _item)),
        ),
      ),
    );
    await _advance(tester);
    expect(find.text('来源已停用'), findsOneWidget);
    expect(find.text('此设备缺少原来源'), findsNothing);
    expect(preferences.get<Object?>('mihon.enabledPackages'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.runAsync(db.close);
  });

  testWidgets('enabled metadata causes no loading screen or recovery prompt', (
    tester,
  ) async {
    final db = openTestDatabase();
    final preferences = memoryPreferences();
    await preferences.set('mihon.installedPackages', {
      'org.example.reader': '1.0',
    });
    await preferences.set('mihon.enabledPackages', ['org.example.reader']);
    await preferences.set('mihon.hostStatus', {
      'org.example.reader': {
        'ok': true,
        'sources': [
          {'id': '123', 'name': '本机漫画来源'},
        ],
      },
    });
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        sourceRegistryProvider.overrideWith(
          (ref) => throw StateError('metadata UI must not load plugins'),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: MissingSourceNotice(item: _item)),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _advance(tester);
    expect(find.text('安装 / 管理来源或搜索迁移'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.runAsync(db.close);
  });
  testWidgets(
    'canonical anime detail offers recovery for its restored missing playback station',
    (tester) async {
      const subject = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '123',
        type: MediaType.anime,
        title: '动画资料',
      );
      const playback = MediaItem(
        sourceId: 'kazumi:missing-station',
        remoteId: '/show/123',
        type: MediaType.anime,
        title: '本站动画',
      );
      const episode = Chapter(
        sourceId: 'kazumi:missing-station',
        remoteId: '/episode/1',
        title: '第一集',
      );
      final db = openTestDatabase();
      final library = LibraryRepository(db);
      final identity = AnimeIdentityRepository(db);
      await tester.runAsync(() async {
        await library.cacheItem(subject);
        await library.cacheItem(playback);
        await library.saveChapters(
          itemSourceId: playback.sourceId,
          itemRemoteId: playback.remoteId,
          chapters: [episode],
        );
        await identity.confirm(subject, playback);
        await identity.recordSelection(playback, episode);
        await storeSyncedSourceHint(
          db,
          playback.remoteId,
          const SyncedSourceHint(
            sourceId: 'kazumi:missing-station',
            name: '原播放站',
            repoUrl: 'https://rules.example.org/index.json',
          ),
        );
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourcesProvider.overrideWith(_EmptySources.new),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async =>
                  const SourceResponse(statusCode: 503, body: 'offline'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DetailPage(item: subject)),
        ),
      );
      await _advance(tester);
      final recovery = find.text('安装 / 管理来源或搜索迁移');
      await tester.scrollUntilVisible(
        recovery,
        200,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await _advance(tester);
      await tester.tap(recovery);
      await _advance(tester);
      expect(find.text('kazumi:missing-station'), findsOneWidget);
      expect(find.text('搜索其他播放站'), findsOneWidget);
      expect(find.text('打开来源管理 / 插件库'), findsOneWidget);
      final restoredSubject = await tester.runAsync(
        () => identity.subjectFor(playback),
      );
      expect(restoredSubject?.sourceId, subject.sourceId);
      expect(restoredSubject?.remoteId, subject.remoteId);
      await tester.pumpWidget(const SizedBox.shrink());
      await _advance(tester);
      container.dispose();
      await _advance(tester);
      await tester.runAsync(db.close);
    },
  );
}

class _EmptySources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async =>
      const SourceRegistrySnapshot(entries: [], failures: []);
}
