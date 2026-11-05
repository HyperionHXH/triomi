import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_file_support.dart';
import 'package:triomi/core/backup/backup_location.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/storage_paths.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/downloads/data/image_download_checkpoint.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/profile/backup_restore_dialog.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/png_image.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('portable-policy-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => temporary.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backupDocumentsChannel, null);
    await temporary.delete(recursive: true);
  });
  test(
    'desktop picker cleanup never deletes the original on cancel or failure',
    () async {
      final original = await File('${temporary.path}/picked.zip')
          .writeAsBytes([4, 5]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            backupDocumentsChannel,
            (call) async => {'path': original.path, 'uri': original.path},
          );
      final picked = await BackupImportSource.pick();
      expect(picked!.temporary, isFalse);
      await picked.dispose();
      expect(await original.readAsBytes(), [4, 5]);
    },
  );

  test('explicit accepted delete removes only the reviewed original; unrelated files remain', () async {
    final original = await File('${temporary.path}/delete.zip')
        .writeAsBytes([7, 8, 9]);
    final other = await File('${temporary.path}/keep.zip').writeAsBytes([1]);
    final source = BackupImportSource(
      path: original.path,
      original: original.path,
    );
    await source.deleteOriginal(await hashBackupFile(original));
    expect(await original.exists(), isFalse);
    expect(await other.readAsBytes(), [1]);
  });

  test('full local default roundtrips actual manga and novel offline consumers without network', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final original = await Directory('${temporary.path}/downloads').create();
    final manga = await Directory('${original.path}/manga').create();
    await File('${manga.path}/page.png').writeAsBytes(onePixelPng(24));
    await DownloadManifest.write(
      directory: manga.path,
      files: ['page.png'],
      title: 'manga',
    );
    final novel = await Directory('${original.path}/novel').create();
    const content = ChapterContent(text: '可离线阅读的正文');
    final novelFile = await File('${novel.path}/chapter.json').writeAsString(
      jsonEncode({'version': 1, 'title': '第一章', 'content': content.toJson()}),
    );
    for (final type in [MediaType.manga, MediaType.novel]) {
      final item = MediaItem(
        sourceId: 'same-source',
        remoteId: type.name,
        type: type,
        title: type.name,
      );
      final repository = LibraryRepository(source);
      await repository.addToLibrary(item);
      await repository.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: [
          const Chapter(
            sourceId: 'same-source',
            remoteId: 'chapter',
            title: '第一章',
            number: 1,
          ),
        ],
      );
      if (type == MediaType.novel) {
        await (source.update(
          source.chapters,
        )..where((t) => t.itemRemoteId.equals(type.name))).write(
          ChaptersCompanion(contentJson: Value(jsonEncode(content.toJson()))),
        );
      }
      await source
          .into(source.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: item.sourceId,
              remoteId: item.remoteId,
              chapterSourceId: 'same-source',
              chapterRemoteId: 'chapter',
              status: 'done',
              createdAt: DateTime.utc(2026),
              path: Value(
                type == MediaType.manga ? manga.path : novelFile.path,
              ),
            ),
          );
    }
    BackupService service(AppDatabase db, Directory root) => BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: FakeHttpClient(
        (_) async => throw StateError('must remain offline'),
      ),
      downloadFiles: DownloadBackupFiles(root),
    );
    final destination = BackupLocation(
      '${temporary.path}/external',
      'external',
    );
    final backup = await service(
      source,
      original,
    ).exportPortableBackup(location: destination);
    expect(
      storagePathIdentity(backup.path),
      startsWith(storagePathIdentity(destination.value)),
    );
    expect(backup.summary.downloadedMedia, 2);
    final restore = service(target, Directory('${temporary.path}/fresh'));
    final summary = await restore.importFromFile(backup.path);
    expect(summary.downloadedMedia, 2);
    final rows = await target.select(target.downloads).get();
    final comic = rows.singleWhere((r) => r.remoteId == 'manga');
    final book = rows.singleWhere((r) => r.remoteId == 'novel');
    expect(await File('${comic.path}/page.png').readAsBytes(), onePixelPng(24));
    expect((await DownloadManifest.read(comic.path!))!.files, ['page.png']);
    expect(
      book.path,
      contains('${Platform.pathSeparator}novel${Platform.pathSeparator}'),
    );
    expect(
      (jsonDecode(await File(book.path!).readAsString())
          as Map)['content']['text'],
      content.text,
    );
    final cached = await (target.select(
      target.chapters,
    )..where((t) => t.itemRemoteId.equals('novel'))).getSingle();
    expect(
      ChapterContent.fromJson(jsonDecode(cached.contentJson!))!.text,
      content.text,
    );
    final metadata = await service(
      source,
      original,
    ).exportPortableBackup(location: destination, metadataOnly: true);
    final payload = BackupService.validatedPayload(
      await File(metadata.path).readAsBytes(),
    );
    expect(metadata.summary.downloadedMedia, 0);
    expect(
      (payload['chapterRows'] as List).where(
        (r) => (r as Map)['contentJson'] != null,
      ),
      isEmpty,
    );
  });

  test('custom and legacy download bytes are captured but device root and onboarding state never migrate', () async {
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    final prefs = memoryPreferences(), restoredPrefs = memoryPreferences();
    final custom = '${temporary.path}/custom-source';
    final targetRoot = '${temporary.path}/custom-target';
    await prefs.set('downloads.storageRootPath', custom);
    await prefs.set('setup.onboarding.state', 'pending');
    await restoredPrefs.set('downloads.storageRootPath', targetRoot);
    await restoredPrefs.set('setup.onboarding.state', 'complete');
    for (final base in [custom, temporary.path]) {
      final media = await Directory('$base/downloads/chapter')
          .create(recursive: true);
      await File('${media.path}/page.png').writeAsBytes([3, 2, 1]);
      await DownloadManifest.write(
        directory: media.path,
        files: ['page.png'],
        title: base,
      );
      await source
          .into(source.downloads)
          .insert(
            DownloadsCompanion.insert(
              sourceId: 'source',
              remoteId: base == custom ? 'new-work' : 'legacy-work',
              chapterSourceId: 'source',
              chapterRemoteId: 'chapter',
              status: 'done',
              createdAt: DateTime.utc(2026),
              path: Value(media.path),
            ),
          );
    }
    BackupService service(AppDatabase db, Preferences preferences) =>
        BackupService(
          database: db,
          preferences: preferences,
          http: FakeHttpClient((_) async => throw StateError('offline only')),
        );
    final backup = await service(source, prefs).exportPortableBackup(
      location: BackupLocation('${temporary.path}/external-root', 'external'),
    );
    expect(backup.summary.downloadedMedia, 2);
    final payload = BackupService.validatedPayload(
      await File(backup.path).readAsBytes(),
    );
    final settings = payload['settingsValues'] as Map;
    expect(settings.containsKey('downloads.storageRootPath'), isFalse);
    expect(settings.containsKey('setup.onboarding.state'), isFalse);
    await service(target, restoredPrefs).importFromFile(backup.path);
    final restored = await target.select(target.downloads).get();
    expect(restored, hasLength(2));
    expect(
      restored.every(
        (row) => storagePathIdentity(row.path!).startsWith(
          storagePathIdentity('$targetRoot${Platform.pathSeparator}downloads'),
        ),
      ),
      isTrue,
    );
    expect(restoredPrefs.get<String>('downloads.storageRootPath'), targetRoot);
    expect(restoredPrefs.get<String>('setup.onboarding.state'), 'complete');
  });

  for (final manifest in [
    ['0001.png', '0003.png'],
    ['0002.png', '0001.png'],
    ['0001.png'],
  ]) {
    test(
      'partial export validates real reader ordering and preserves checkpoint-ahead prefix $manifest',
      () async {
        final source = openTestDatabase(), target = openTestDatabase();
        addTearDown(source.close);
        addTearDown(target.close);
        final root = await Directory('${temporary.path}/prefix-source')
            .create();
        final chapter = await Directory('${root.path}/chapter').create();
        final checkpoint = await ImageDownloadCheckpoint.load(chapter);
        for (final name in ['0001.png', '0002.png', '0003.png']) {
          await File('${chapter.path}/$name').writeAsBytes(onePixelPng(24));
          await checkpoint.record(name, 'https://public.example/$name');
        }
        await DownloadManifest.write(
          directory: chapter.path,
          files: manifest,
          title: 'Partial',
          totalPages: 3,
          complete: false,
        );
        final repository = DownloadRepository(source);
        final id = await repository.enqueue(
          sourceId: 'source',
          remoteId: 'work',
          chapter: const Chapter(
            sourceId: 'source',
            remoteId: 'chapter',
            title: 'Partial',
          ),
        );
        await repository.markPath(id, chapter.path);
        await repository.markPaused(id);
        BackupService service(AppDatabase db, Directory files) => BackupService(
          database: db,
          preferences: memoryPreferences(),
          http: FakeHttpClient(
            (_) async => throw StateError('must stay offline'),
          ),
          downloadFiles: DownloadBackupFiles(files),
        );
        final backup = await service(
          source,
          root,
        ).exportToFile(includeCovers: false, includeDownloadedMedia: true);
        final valid = manifest.length == 1;
        expect(backup.summary.partialDownloads, valid ? 1 : 0);
        await service(
          target,
          Directory('${temporary.path}/prefix-restored'),
        ).importFromFile(backup.path);
        final restored = await target.select(target.downloads).getSingle();
        if (!valid) {
          expect(restored.path, isNull);
        } else {
          final path = await DownloadRepository(target)
              .localImageDir('source', 'chapter');
          expect(path, restored.path);
          final published = (await DownloadManifest.read(path!))!;
          expect(published.files, ['0001.png']);
          expect(published.totalPages, 3);
          expect(published.complete, isFalse);
          expect(
            (await ImageDownloadCheckpoint.load(Directory(path))).pages,
            hasLength(3),
          );
        }
      },
    );
  }

  test('directory selection persists and selected location is listed; revoked grants fail', () async {
    final prefs = memoryPreferences();
    final selected = await Directory('${temporary.path}/selected').create();
    await File('${selected.path}/portable.zip').writeAsBytes([1, 2]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backupDocumentsChannel, (call) async {
          if (call.method == 'pickDirectory') return selected.path;
          throw PlatformException(code: 'revoked');
        });
    final store = BackupLocationStore(prefs);
    final location = await store.choose();
    expect((await BackupLocationStore(prefs).current())!.value, selected.path);
    expect((await store.list(location!)).single.name, 'portable.zip');
    await expectLater(
      store.list(const BackupLocation('content://revoked/tree', 'revoked')),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'requested SAF failure never publishes a misleading private backup',
    () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final service = BackupService(
        database: db,
        preferences: memoryPreferences(),
        http: FakeHttpClient(
          (_) async => const SourceResponse(statusCode: 200, body: ''),
        ),
      );
      await expectLater(
        service.exportPortableBackup(
          location: const BackupLocation('content://revoked/tree', 'revoked'),
          writeToTree: (_, _, _) async =>
              throw PlatformException(code: 'permission_denied'),
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(await BackupService.localBackups(), isEmpty);
    },
  );

  testWidgets(
    'post-success delete is explicit; decline preserves original and changed originals cannot be deleted',
    (tester) async {
      final original = (await tester.runAsync(
        () => File('${temporary.path}/original.zip').writeAsBytes([1, 2, 3]),
      ))!;
      final source = BackupImportSource(
        path: original.path,
        original: original.path,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  confirmDeleteRestoredBackup(context, source.original),
              child: const Text('restored'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('restored'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留备份'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(await original.exists(), isTrue);
        await expectLater(source.deleteOriginal('0' * 64), throwsStateError);
        expect(await original.exists(), isTrue);
      });
    },
  );

  test('SAF original deletion uses original URI and reviewed hash, not the staged file', () async {
    final staged = await File('${temporary.path}/staged.zip').writeAsBytes([1]);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backupDocumentsChannel, (call) async {
          calls.add(call);
          return true;
        });
    final source = BackupImportSource(
      path: staged.path,
      original: 'content://provider/original',
      temporary: true,
    );
    await source.deleteOriginal('a' * 64);
    expect(calls.single.arguments, {
      'uri': 'content://provider/original',
      'sha256': 'a' * 64,
    });
    expect(await staged.exists(), isTrue);
    await source.dispose();
    expect(await staged.exists(), isFalse);
  });
}
