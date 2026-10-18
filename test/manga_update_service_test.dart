import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/features/library/data/library_category.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/manga_update_background.dart';
import 'package:triomi/features/library/data/manga_update_execution_lock.dart';
import 'package:triomi/features/library/data/manga_update_service.dart';

import 'fixtures/test_database.dart';

class UpdateSource extends DetailProvider {
  UpdateSource(this.id, this.fetch);
  final String id;
  final Future<List<Chapter>> Function(MediaItem) fetch;
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: MediaType.manga,
    kind: SourceKind.builtin,
  );
  @override
  bool get isReady => true;
  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) => fetch(item);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late LibraryRepository library;
  late List<SourceEntry> sources;
  late List<MangaUpdateService> services;
  setUp(() {
    db = openTestDatabase();
    library = LibraryRepository(db);
    sources = [];
    services = [];
  });
  tearDown(() async {
    for (final s in services) {
      await s.dispose();
    }
    await db.close();
  });
  Future<void> seed(String source, String remote, {String? status}) async {
    await library.addToLibrary(
      MediaItem(
        sourceId: source,
        remoteId: remote,
        type: MediaType.manga,
        title: remote,
        status: status,
      ),
    );
    await library.saveChapters(
      itemSourceId: source,
      itemRemoteId: remote,
      chapters: [
        Chapter(sourceId: source, remoteId: '$remote-old', title: 'old'),
      ],
    );
    await (db.update(db.libraryEntries)
          ..where((t) => t.sourceId.equals(source) & t.remoteId.equals(remote)))
        .write(const LibraryEntriesCompanion(unreadCount: Value(5)));
  }

  void add(UpdateSource s, {bool enabled = true}) => sources.add(
    SourceEntry(descriptor: s.descriptor, source: s, enabled: enabled),
  );
  MangaUpdateService service({
    MangaUpdateOptions options = const MangaUpdateOptions(),
    Future<bool> Function()? allow,
    Future<void> Function(MediaItem, List<Chapter>, Set<String>)? download,
  }) {
    final s = MangaUpdateService(
      db: db,
      snapshot: () async =>
          SourceRegistrySnapshot(entries: List.of(sources), failures: []),
      options: options,
      constraintsAllow: allow ?? () async => true,
      downloadNew: download,
    );
    services.add(s);
    return s;
  }

  test('update provider receives source-only manga rather than local display fields', () async {
    await seed('s', 'source-title');
    await library.setMangaMetadata(
      's',
      'source-title',
      title: 'local-title',
      author: 'local-author',
      description: 'local-description',
    );
    var called = false;
    add(
      UpdateSource('s', (item) async {
        called = true;
        expect(item.title, 'source-title');
        expect(item.author, isNull);
        expect(item.description, isNull);
        expect(item.localMangaMetadata, isNull);
        return [
          const Chapter(
            sourceId: 's',
            remoteId: 'source-title-old',
            title: 'old',
          ),
        ];
      }),
    );
    final updates = service();
    await updates.enqueue();
    await updates.run();
    expect(called, isTrue);
    expect(
      (await library.itemByKey('s', 'source-title'))!.title,
      'local-title',
    );
  });

  test('category update selection evaluates scoped dynamic rules instead of stale links', () async {
    await seed('s', 'included');
    await seed('s', 'excluded');
    final manga = await library.saveCategory(
      type: MediaType.manga,
      name: '本模块',
      rule: const LibraryCategoryRule(query: 'included'),
    );
    final novel = await library.saveCategory(
      type: MediaType.novel,
      name: '其他模块',
      rule: const LibraryCategoryRule(matchAll: true),
    );
    var calls = 0;
    add(
      UpdateSource('s', (item) async {
        calls++;
        return [
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-old',
            title: 'old',
          ),
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-new',
            title: 'new',
          ),
        ];
      }),
    );
    final wrongScope = service(
      options: MangaUpdateOptions(categories: {novel}),
    );
    await wrongScope.enqueue();
    expect(await db.select(db.mangaUpdates).get(), isEmpty);
    final scoped = service(options: MangaUpdateOptions(categories: {manga}));
    await scoped.enqueue();
    expect(
      (await db.select(db.mangaUpdates).get()).single.remoteId,
      'included',
    );
    await scoped.run();
    expect(calls, 1);
    expect((await db.select(db.mangaUpdates).get()).single.status, 'success');
  });

  test('legacy hidden categories do not exclude books from refresh', () async {
    await seed('s', 'legacy');
    final categoryId = await library.saveCategory(
      type: MediaType.manga,
      name: 'Legacy category',
      hidden: true,
      rule: const LibraryCategoryRule(matchAll: true),
    );
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    expect(
      (await container.read(mangaUpdateLibraryProvider.future))
          .map((entry) => entry.item.remoteId),
      ['legacy'],
    );
    var calls = 0;
    add(
      UpdateSource('s', (_) async {
        calls++;
        return [
          const Chapter(sourceId: 's', remoteId: 'legacy-old', title: 'old'),
          const Chapter(sourceId: 's', remoteId: 'legacy-new', title: 'new'),
        ];
      }),
    );
    final updates = service();
    await updates.enqueue();
    await updates.run();
    expect(calls, 1);
    expect((await db.select(db.mangaUpdates).get()).single.status, 'success');
    final category = await (db.select(
      db.categories,
    )..where((row) => row.id.equals(categoryId))).getSingle();
    expect(category.hidden, isTrue);
  });

  test('empty or disabled sources preserve cached directory and unread while another source succeeds', () async {
    await seed('empty', 'a');
    await seed('disabled', 'b');
    await seed('good', 'c');
    add(UpdateSource('empty', (_) async => []));
    add(
      UpdateSource(
        'disabled',
        (_) async => throw StateError('must not request'),
      ),
      enabled: false,
    );
    add(
      UpdateSource(
        'good',
        (item) async => [
          Chapter(sourceId: 'good', remoteId: 'c-old', title: 'old'),
          Chapter(sourceId: 'good', remoteId: 'c-new', title: 'new'),
        ],
      ),
    );
    final s = service();
    await s.enqueue();
    await s.run();
    for (final key in [('empty', 'a'), ('disabled', 'b')]) {
      expect(
        (await library.loadChapters(key.$1, key.$2)).map((c) => c.remoteId),
        ['${key.$2}-old'],
      );
      expect(
        (await library.listLibrary())
            .firstWhere((e) => e.item.sourceId == key.$1)
            .entry
            .unreadCount,
        5,
      );
    }
    expect(
      (await library.listLibrary())
          .firstWhere((e) => e.item.sourceId == 'good')
          .entry
          .unreadCount,
      6,
    );
    expect(
      (await db.select(db.mangaUpdates).get()).map((r) => r.status),
      containsAll(['failed', 'failed', 'success']),
    );
  });
  test(
    'cancel rejects late catalog and constraints defer without a request',
    () async {
      await seed('s', 'a');
      final pending = Completer<List<Chapter>>(), entered = Completer<void>();
      add(
        UpdateSource('s', (_) {
          entered.complete();
          return pending.future;
        }),
      );
      final s = service();
      await s.enqueue();
      final running = s.run();
      await entered.future;
      s.cancel();
      pending.complete([
        const Chapter(sourceId: 's', remoteId: 'late', title: 'late'),
      ]);
      await running;
      expect((await library.loadChapters('s', 'a')).single.remoteId, 'a-old');
      expect((await db.select(db.mangaUpdates).get()).single.status, 'queued');
      final deferred = service(allow: () async => false);
      await deferred.run();
      expect(
        (await db.select(db.mangaUpdates).get()).single.status,
        'deferred',
      );
      expect(deferred.completed, 1);
    },
  );
  test('per-source concurrency is bounded and auto-download failure does not undo a successful catalog', () async {
    for (var i = 0; i < 6; i++) {
      await seed('s', '$i');
    }
    var active = 0, max = 0;
    final downloaded = <String>{};
    add(
      UpdateSource('s', (item) async {
        active++;
        if (active > max) max = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return [
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-old',
            title: 'old',
          ),
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-new',
            title: 'new',
          ),
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-locked',
            title: 'locked',
            locked: true,
          ),
        ];
      }),
    );
    final s = service(
      options: const MangaUpdateOptions(perSource: 2, autoDownload: true),
      download: (_, _, ids) async {
        downloaded.addAll(ids);
        throw StateError('disk full');
      },
    );
    await s.enqueue();
    await s.run();
    expect(max, 2);
    expect(downloaded, {for (var i = 0; i < 6; i++) '$i-new'});
    for (final row in await db.select(db.mangaUpdates).get()) {
      expect(row.status, 'success');
      expect(row.added, 2);
    }
    expect(
      (await library.listLibrary()).every((e) => e.entry.unreadCount == 7),
      true,
    );
    await s.enqueue();
    await s.run();
    expect(
      (await library.listLibrary()).every((e) => e.entry.unreadCount == 7),
      true,
    );
  });
  test('category/source/completed filtering and single-item run do not consume unrelated queued work', () async {
    await seed('s', 'a');
    await seed('s', 'b');
    await seed('s', 'done', status: 'completed');
    await seed('other', 'c');
    final category = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: 'selected'));
    for (final remote in ['a', 'done']) {
      await db
          .into(db.libraryCategoryLinks)
          .insert(
            LibraryCategoryLinksCompanion.insert(
              sourceId: 's',
              remoteId: remote,
              categoryId: category,
            ),
          );
    }
    final s = service(
      options: MangaUpdateOptions(categories: {category}, sources: {'s'}),
    );
    await s.enqueue();
    expect((await db.select(db.mangaUpdates).get()).map((r) => r.remoteId), [
      'a',
    ]);
    await db
        .into(db.mangaUpdates)
        .insert(MangaUpdatesCompanion.insert(sourceId: 's', remoteId: 'b'));
    add(
      UpdateSource(
        's',
        (item) async => [
          Chapter(
            sourceId: 's',
            remoteId: '${item.remoteId}-old',
            title: 'old',
          ),
        ],
      ),
    );
    await s.run(itemKeys: {'s\u0000a'});
    expect(
      (await db.select(db.mangaUpdates).get())
          .firstWhere((r) => r.remoteId == 'b')
          .status,
      'queued',
    );
  });
  test(
    'source disabled during request cannot publish a late catalog',
    () async {
      await seed('s', 'a');
      final entered = Completer<void>(), response = Completer<List<Chapter>>();
      add(
        UpdateSource('s', (_) {
          entered.complete();
          return response.future;
        }),
      );
      final s = service();
      await s.enqueue();
      final running = s.run();
      await entered.future;
      sources = [];
      response.complete([
        const Chapter(sourceId: 's', remoteId: 'late', title: 'late'),
      ]);
      await running;
      expect((await library.loadChapters('s', 'a')).single.remoteId, 'a-old');
      expect((await library.listLibrary()).single.entry.unreadCount, 5);
      expect((await db.select(db.mangaUpdates).get()).single.status, 'failed');
    },
  );
  test('notification is emitted once across container reopen and new catalog generation permits the next one', () async {
    await seed('s', 'a');
    var deliveries = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('triomi/platform'), (
          call,
        ) async {
          if (call.method == 'canNotifyMangaUpdates') return true;
          if (call.method == 'notifyMangaUpdate') {
            deliveries++;
            return true;
          }
          throw StateError('unexpected platform call');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('triomi/platform'),
            null,
          ),
    );
    final generation = DateTime(2026, 1, 1);
    await db
        .into(db.mangaUpdates)
        .insert(
          MangaUpdatesCompanion.insert(
            sourceId: 's',
            remoteId: 'a',
            status: const Value('success'),
            added: const Value(1),
            checkedAt: Value(generation),
            generation: const Value(1),
          ),
        );
    var container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    await notifyMangaUpdates(container);
    container.dispose();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    try {
      await notifyMangaUpdates(container);
      expect(deliveries, 1);
      await (db.update(db.mangaUpdates))
          .write(MangaUpdatesCompanion(generation: const Value(2)));
      await notifyMangaUpdates(container);
      expect(deliveries, 2);
    } finally {
      container.dispose();
    }
  });
  test('execution lease rejects overlapping callers and allows the next owner after release', () async {
    final dir = await Directory.systemTemp.createTemp('triomi-update-lease-');
    try {
      final first = await MangaUpdateExecutionLock.acquire(directory: dir.path);
      expect(first, isNotNull);
      expect(
        await MangaUpdateExecutionLock.acquire(directory: dir.path),
        isNull,
      );
      await first!();
      final next = await MangaUpdateExecutionLock.acquire(directory: dir.path);
      expect(next, isNotNull);
      await next!();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
