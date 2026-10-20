import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as zip;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_artifact_recovery.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/backup/download_backup_files.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/widgets/image_viewer.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/local/local_comic_importer.dart';
import 'package:triomi/features/local/local_comic_library_page.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('file URI image bytes use the shared gallery-save boundary', (tester) async {
    final bytes = _png(42);
    final setup = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('local-image-bytes-');
      final file = await File('${temp.path}/page #100%.png').writeAsBytes(bytes);
      return (temp: temp, file: file);
    }))!;
    final temp = setup.temp, file = setup.file;
    final http = FakeHttpClient((_) async => throw StateError('no network'))
      ..bytesHandler = (_) => bytes;
    const platform = MethodChannel('triomi/platform');
    Uint8List? saved;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (call) async {
      if (call.method == 'saveImageToGallery') {
        saved = (call.arguments as Map)['bytes'] as Uint8List;
        return 'content://gallery/saved';
      }
      return null;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, null);
      await tester.runAsync(() => temp.delete(recursive: true));
    });
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(overrides: [sourceHttpClientProvider.overrideWithValue(http)],
      child: MaterialApp(home: Scaffold(body: Builder(builder: (value) { context = value; return const SizedBox(); })))));
    await tester.runAsync(() async {
      expect(await loadImageBytes(file.path, sourceId: localComicSourceId), bytes);
      expect(await loadImageBytes(file.uri.toString(), sourceId: localComicSourceId), bytes);
      expect(await loadImageBytes('https://images.test/page', sourceId: 's', http: http), bytes);
      for (final invalid in ['content://provider/page', 'file:relative.png', 'file://remote/page.png', '${file.uri}?query', '${file.uri}#fragment', 'file:///bad%ZZ.png']) {
        expect(await loadImageBytes(invalid, sourceId: 's', http: http), isNull);
      }
      await saveImageWithFeedback(context, imageUrl: file.uri.toString(), sourceId: localComicSourceId);
    });
    await tester.pump();
    expect(saved, bytes);
    expect(http.requests, hasLength(1));
  });
  testWidgets('off-shelf local imports remain visible and removable from file library', (tester) async {
    final setup = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('off-shelf-local-');
      final db = openTestDatabase();
      final original = await File('${temp.path}/original.png').writeAsBytes(_png(24));
      final result = await LocalComicImporter(database: db, downloadRoot: Directory('${temp.path}/downloads'))
        .importPaths([original.path], title: 'Off shelf import');
      final library = LibraryRepository(db);
      final chapter = (await library.loadChapters(localComicSourceId, result.item.remoteId)).single;
      final path = await DownloadRepository(db).localImageDir(localComicSourceId, chapter.remoteId);
      await library.removeFromLibrary(localComicSourceId, result.item.remoteId);
      return (temp: temp, db: db, original: original, path: path, item: result.item);
    }))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => setup.temp.path);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        await setup.db.close().timeout(const Duration(seconds: 5));
        await setup.temp.delete(recursive: true).timeout(const Duration(seconds: 5));
      });
    });
    await tester.pumpWidget(ProviderScope(overrides: [databaseProvider.overrideWithValue(setup.db)],
      child: const MaterialApp(home: LocalComicLibraryPage())));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }
    await settle();
    expect(find.text('Off shelf import'), findsOneWidget);
    await tester.tap(find.byTooltip('移除此本地导入'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    await tester.tap(find.text('确认移除此导入'));
    await tester.pump();
    // Never await a DB read while deletion may own a transaction in the fake
    // zone: that read waits for a transaction that needs another widget pump.
    // Only yield real IO here, and bound every fake-time/real-time iteration.
    for (var i = 0; i < 500 && find.text('正在移除此导入').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(find.text('正在移除此导入'), findsNothing);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(find.text('Off shelf import'), findsNothing);
    await tester.runAsync(() async {
      expect(await Directory(setup.path!).exists(), false);
      expect(await setup.original.exists(), true);
      expect(await DownloadRepository(setup.db).listForItem(localComicSourceId, setup.item.remoteId), isEmpty);
      expect(await LibraryRepository(setup.db).itemByKey(localComicSourceId, setup.item.remoteId), isNull);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('imported manifests read offline and reconstruct at a saved nonzero page', (tester) async {
    final setup = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('local-reader-');
      final db = openTestDatabase();
      final input = await Directory('${temp.path}/pages').create();
      for (var i = 1; i <= 4; i++) { await File('${input.path}/$i.png').writeAsBytes(_png(i * 30)); }
      final imported = await LocalComicImporter(database: db, downloadRoot: Directory('${temp.path}/owned')).importPaths([input.path], title: 'Offline reader');
      return (temp: temp, db: db, imported: imported, chapters: await LibraryRepository(db).loadChapters(localComicSourceId, imported.item.remoteId));
    }))!;
    final temp = setup.temp, db = setup.db, imported = setup.imported, chapters = setup.chapters;
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourcesProvider.overrideWith(_NoNetworkSources.new),
    ]);
    const platform = MethodChannel('triomi/platform');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, (_) async => null);
    Future<void> settle() async {
      for (var i = 0; i < 16; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
      }
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await settle(); container.dispose();
      await tester.runAsync(() async { await db.close(); await temp.delete(recursive: true); });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(platform, null);
    });
    Widget reader() => UncontrolledProviderScope(container: container, child: MaterialApp(home: MangaReaderPage(args: MangaReaderArgs(item: imported.item, chapters: chapters, initialIndex: 0))));
    await tester.pumpWidget(reader()); await settle();
    expect(find.byType(Slider), findsOneWidget);
    tester.widget<Slider>(find.byType(Slider)).onChanged!(3);
    await settle();
    expect(await tester.runAsync(() => LibraryRepository(db).chapterPositionOf(localComicSourceId, imported.item.remoteId, chapters.single.remoteId)), 2);
    await tester.pumpWidget(const SizedBox()); await settle();
    await tester.pumpWidget(reader()); await settle();
    expect(find.text('3/4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('actual image folder publishes once with natural pages and reader manifests', () async {
    final temp = await Directory.systemTemp.createTemp('local-comic-test-');
    final db = openTestDatabase();
    addTearDown(() async { await db.close(); await temp.delete(recursive: true); });
    final input = await Directory('${temp.path}/original/Volume 1/Chapter 2').create(recursive: true);
    final png = _png(100);
    await File('${input.path}/10.png').writeAsBytes(png);
    await File('${input.path}/2.png').writeAsBytes(png);
    final documents = await Directory('${temp.path}/documents').create();
    final importer = LocalComicImporter(database: db, downloadRoot: Directory('${documents.path}/downloads'));
    final first = await importer.importPaths(['${temp.path}/original'], title: 'My comic');
    expect(first.duplicate, false);
    final library = LibraryRepository(db);
    expect((await library.listLibrary()).single.item.sourceId, localComicSourceId);
    final chapters = await library.loadChapters(localComicSourceId, first.item.remoteId);
    expect(chapters, hasLength(1));
    final path = await DownloadRepository(db).localImageDir(localComicSourceId, chapters.single.remoteId);
    final manifest = await DownloadManifest.read(path!);
    expect(manifest!.files, ['00001.png', '00002.png']);
    expect(await File('$path/${manifest.files.first}').readAsBytes(), png);
    await library.recordHistory(sourceId: first.item.sourceId, remoteId: first.item.remoteId, chapter: chapters.single, position: 1);
    await library.updateProgress(sourceId: first.item.sourceId, remoteId: first.item.remoteId, chapterNumber: 3);
    final repeated = await importer.importPaths(['${temp.path}/original'], title: 'Other title');
    expect(repeated.duplicate, true);
    expect(repeated.item.title, 'My comic');
    expect(await library.chapterPositionOf(localComicSourceId, first.item.remoteId, chapters.single.remoteId), 1);
    expect((await library.listLibrary()).single.entry.progress, 3);
    await library.removeFromLibrary(first.item.sourceId, first.item.remoteId);
    expect(await library.isInLibrary(first.item.sourceId, first.item.remoteId), false);
    final readded = await importer.importPaths(['${temp.path}/original'], title: 'Do not replace');
    expect(readded.duplicate, true);
    expect((await library.listLibrary()).single.item.title, 'My comic');
    expect(await library.chapterPositionOf(localComicSourceId, first.item.remoteId, chapters.single.remoteId), 1);
    expect(await DownloadRepository(db).localImageDir(localComicSourceId, chapters.single.remoteId), path);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      sourceHttpClientProvider.overrideWithValue(FakeHttpClient((_) async => throw StateError('offline'))),
      sourcesProvider.overrideWith(_NoNetworkSources.new),
    ]);
    addTearDown(container.dispose);
    await container.read(downloadsProvider.future);
    final downloadRepo = DownloadRepository(db);
    final manga = await Directory('${temp.path}/manga').create();
    await File('${manga.path}/page.png').writeAsBytes(png);
    await DownloadManifest.write(directory: manga.path, files: ['page.png'], title: 'Page');
    final video = await File('${temp.path}/video.mp4').writeAsBytes([1, 2, 3]);
    for (final media in [('manga', manga.path), ('video', video.path)]) {
      final id = await downloadRepo.enqueue(sourceId: 'normal', remoteId: media.$1,
        chapter: Chapter(sourceId: 'normal', remoteId: media.$1, title: media.$1));
      await downloadRepo.markDone(id, path: media.$2);
    }
    final textId = await downloadRepo.enqueue(sourceId: 'normal', remoteId: 'novel',
      chapter: const Chapter(sourceId: 'normal', remoteId: 'novel', title: 'Novel'));
    await downloadRepo.markDone(textId);
    await container.read(downloadsProvider.notifier).clearFinished();
    expect(await downloadRepo.listForItem('normal', 'novel'), isEmpty);
    expect((await downloadRepo.listForItem('normal', 'manga')).single.path, manga.path);
    expect((await downloadRepo.listForItem('normal', 'video')).single.path, video.path);
    expect(await File(video.path).readAsBytes(), [1, 2, 3]);
    expect(await downloadRepo.localImageDir('normal', 'manga'), manga.path);
    expect(await downloadRepo.localVideoPath('normal', 'video'), video.path);
    expect(await File('${manga.path}/page.png').readAsBytes(), png);
    expect((await container.read(downloadsProvider.future)).fold<int>(0, (total, group) => total + group.entries.length), 3);
    await library.removeFromLibrary(first.item.sourceId, first.item.remoteId);
    final recoveryTemp = await Directory('${temp.path}/temporary').create();
    final support = await Directory('${temp.path}/support').create();
    expect(await BackupArtifactRecovery.cleanup(database: db, preferences: memoryPreferences(),
      roots: BackupArtifactRoots(temporary: recoveryTemp, documents: documents, support: support),
      acquireGuard: () async => BackupArtifactLease(() async {})), true);
    expect(await File('$path/${manifest.files.first}').readAsBytes(), png);
    expect(await DownloadRepository(db).localImageDir(localComicSourceId, chapters.single.remoteId), path);
    expect(await File('${input.path}/2.png').readAsBytes(), png);
  });

  test('CBZ natural order and identity survive reopening, offline progress and portable media backup', () async {
    final temp = await Directory.systemTemp.createTemp('local-portable-');
    var db = AppDatabase.forTesting(NativeDatabase(File('${temp.path}/library.sqlite')));
    final target = openTestDatabase();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => temp.path);
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await db.close(); await target.close(); await temp.delete(recursive: true);
    });
    final two = _png(50), ten = _png(150);
    final archive = zip.Archive()
      ..addFile(zip.ArchiveFile('Volume 1/Chapter 2/10.png', ten.length, ten))
      ..addFile(zip.ArchiveFile('Volume 1/Chapter 2/2.png', two.length, two));
    final input = await File('${temp.path}/book.cbz').writeAsBytes(zip.ZipEncoder().encode(archive));
    final root = Directory('${temp.path}/owned');
    final progress = <LocalComicProgress>[];
    final result = await LocalComicImporter(database: db, downloadRoot: root).importPaths([input.path], title: 'Portable', onProgress: progress.add);
    final chapter = (await LibraryRepository(db).loadChapters(localComicSourceId, result.item.remoteId)).single;
    final originalPath = (await DownloadRepository(db).localImageDir(localComicSourceId, chapter.remoteId))!;
    expect(await File('$originalPath/00001.png').readAsBytes(), two);
    expect(await File('$originalPath/00002.png').readAsBytes(), ten);
    expect(chapter.volumeTitle, 'Volume 1');
    expect(progress.last.phase, '导入完成');
    expect(progress.last.pages, 2);
    expect(progress.last.bytes, greaterThan(two.length + ten.length));
    await LibraryRepository(db).recordHistory(sourceId: localComicSourceId, remoteId: result.item.remoteId, chapter: chapter, position: 1);
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(File('${temp.path}/library.sqlite')));
    expect(await LibraryRepository(db).chapterPositionOf(localComicSourceId, result.item.remoteId, chapter.remoteId), 1);
    expect(await DownloadRepository(db).localImageDir(localComicSourceId, chapter.remoteId), originalPath);
    BackupService service(AppDatabase database, Directory mediaRoot) => BackupService(
      database: database, preferences: memoryPreferences(),
      http: FakeHttpClient((_) async => throw StateError('Local comics must not request network')),
      downloadFiles: DownloadBackupFiles(mediaRoot),
    );
    final backup = await service(db, root).exportToFile(includeCovers: false, includeDownloadedMedia: true);
    final restoredRoot = Directory('${temp.path}/restored');
    final metadataOnly = await service(db, root).exportToFile(includeCovers: false);
    final targetService = service(target, restoredRoot);
    await targetService.importFromFile(metadataOnly.path);
    expect(await DownloadRepository(target).localImageDir(localComicSourceId, chapter.remoteId), null);
    final missing = (await DownloadRepository(target).listForItem(localComicSourceId, result.item.remoteId)).single;
    await DownloadRepository(target).resumePaused();
    await DownloadRepository(target).markQueued(missing.id);
    expect((await DownloadRepository(target).listForItem(localComicSourceId, result.item.remoteId)).single.status, 'paused');
    await targetService.importFromFile(backup.path);
    final restoredLibrary = LibraryRepository(target);
    expect((await restoredLibrary.listLibrary()).single.item.remoteId, result.item.remoteId);
    expect(await restoredLibrary.chapterPositionOf(localComicSourceId, result.item.remoteId, chapter.remoteId), 1);
    final restoredPath = (await DownloadRepository(target).localImageDir(localComicSourceId, chapter.remoteId))!;
    expect(restoredPath, isNot(originalPath));
    expect(await File('$restoredPath/00001.png').readAsBytes(), two);
    final duplicate = await LocalComicImporter(database: target, downloadRoot: restoredRoot).importPaths([input.path], title: 'Do not replace');
    expect(duplicate.duplicate, true);
    expect(duplicate.item.title, 'Portable');
    final renamed = zip.Archive()
      ..addFile(zip.ArchiveFile('Renamed/Chapter/02.png', two.length, two))
      ..addFile(zip.ArchiveFile('Renamed/Chapter/010.png', ten.length, ten));
    final renamedFile = await File('${temp.path}/renamed.zip').writeAsBytes(zip.ZipEncoder().encode(renamed));
    expect((await LocalComicImporter(database: target, downloadRoot: restoredRoot).importPaths([renamedFile.path], title: 'Renamed')).duplicate, true);
    await LocalComicImporter(database: target, downloadRoot: restoredRoot).remove(result.item.remoteId);
    expect(await Directory(restoredPath).exists(), false);
    expect(await File('$originalPath/00001.png').readAsBytes(), two);
    expect(await input.exists(), true);
  });

  test('unsafe, duplicate and invalid ZIP images publish neither files nor library rows', () async {
    final temp = await Directory.systemTemp.createTemp('local-rejected-');
    final db = openTestDatabase();
    addTearDown(() async { await db.close(); await temp.delete(recursive: true); });
    final root = Directory('${temp.path}/owned');
    final importer = LocalComicImporter(database: db, downloadRoot: root);
    final valid = _png(12);
    for (final names in [
      ['../escape.png'],
      ['chapter/1.png', 'chapter/1.png'],
      ['chapter/1.png', 'chapter/1.PNG'],
      [r'chapter\1.png'],
      ['chapter/invalid.png'],
    ]) {
      // The production ZipEncoder normalizes backslashes and Archive replaces
      // identical names. Build stored ZIP records directly so these genuinely
      // unsafe names/duplicates reach the importer unchanged.
      final encoded = _storedZip([
        for (final name in names) (name, name.contains('invalid') ? <int>[1, 2, 3] : valid),
      ]);
      final directoryInput = zip.InputMemoryStream(encoded);
      final directory = zip.ZipDirectory()..read(directoryInput);
      expect(directory.fileHeaders.map((header) => header.filename).toList(), names);
      final input = await File('${temp.path}/rejected.cbz').writeAsBytes(encoded);
      await expectLater(importer.importPaths([input.path], title: 'Rejected'), throwsA(isA<Exception>()), reason: 'Unsafe ZIP entries: $names');
      expect(await LibraryRepository(db).listLibrary(), isEmpty);
      expect(await root.list().toList(), isEmpty);
    }
    final invalid = await File('${temp.path}/bad.png').writeAsBytes([1, 2, 3]);
    await expectLater(importer.importPaths([invalid.path], title: 'Bad image'), throwsA(isA<Exception>()));
    final oversized = File('${temp.path}/large.png');
    final handle = await oversized.open(mode: FileMode.write);
    await handle.truncate(LocalComicImporter.maxFileBytes + 1); await handle.close();
    await expectLater(importer.importPaths([oversized.path], title: 'Too big'), throwsFormatException);
    final duplicate = await File('${temp.path}/same.png').writeAsBytes(valid);
    await expectLater(importer.importPaths([duplicate.path, duplicate.path], title: 'Same page'), throwsFormatException);
    for (final entry in [
      zip.ArchiveFile('link.png', valid.length, valid)..mode = 0xa1ff,
      zip.ArchiveFile('bomb.png', 1024 * 1024, Uint8List(1024 * 1024)),
    ]) {
      final archive = zip.Archive()..addFile(entry);
      final input = await File('${temp.path}/unsafe.zip').writeAsBytes(zip.ZipEncoder().encode(archive));
      await expectLater(importer.importPaths([input.path], title: 'Unsafe archive'), throwsFormatException);
    }
    expect(await LibraryRepository(db).listLibrary(), isEmpty);
    expect(await root.list().toList(), isEmpty);
  });

  test('late cancellation rolls back publication and preserves selected originals', () async {
    final temp = await Directory.systemTemp.createTemp('local-cancel-');
    final db = openTestDatabase();
    addTearDown(() async { await db.close(); await temp.delete(recursive: true); });
    final input = await File('${temp.path}/page.png').writeAsBytes(_png(42));
    final root = Directory('${temp.path}/owned');
    final token = LocalComicCancellation();
    await expectLater(LocalComicImporter(database: db, downloadRoot: root).importPaths([input.path], title: 'Cancelled', cancellation: token,
      onProgress: (value) { if (value.phase == '保存离线目录') token.cancel(); }), throwsA(isA<LocalComicCancelled>()));
    expect(await LibraryRepository(db).listLibrary(), isEmpty);
    expect(await db.select(db.downloads).get(), isEmpty);
    expect(await root.list().toList(), isEmpty);
    expect(await input.readAsBytes(), _png(42));
    await expectLater(LocalComicImporter(database: db, downloadRoot: root).importPaths([temp.path], title: 'Recursive'), throwsFormatException);
    expect(await root.list().toList(), isEmpty);
  });
}

Uint8List _png(int red) {
  final result = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> bytes) {
    final body = [...ascii.encode(type), ...bytes];
    final length = ByteData(4)..setUint32(0, bytes.length);
    final crc = ByteData(4)..setUint32(0, zip.getCrc32(body));
    result..add(length.buffer.asUint8List())..add(body)..add(crc.buffer.asUint8List());
  }
  final header = ByteData(13)..setUint32(0, 1)..setUint32(4, 1)..setUint8(8, 8)..setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert([0, red, 0, 0, 255]));
  chunk('IEND', []);
  return result.takeBytes();
}

class _NoNetworkSources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() => throw StateError('Local comic reader must never resolve network sources');
}

Uint8List _storedZip(List<(String, List<int>)> entries) {
  final output = BytesBuilder();
  void u16(int value) => output.add((ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List());
  void u32(int value) => output.add((ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List());
  final offsets = <int>[];
  for (final (name, bytes) in entries) {
    offsets.add(output.length);
    final encodedName = utf8.encode(name);
    u32(0x04034b50); u16(20); u16(0x800); u16(0);
    u16(0); u16(0); u32(zip.getCrc32(bytes));
    u32(bytes.length); u32(bytes.length); u16(encodedName.length); u16(0);
    output..add(encodedName)..add(bytes);
  }
  final centralOffset = output.length;
  for (var i = 0; i < entries.length; i++) {
    final (name, bytes) = entries[i];
    final encodedName = utf8.encode(name);
    u32(0x02014b50); u16(20); u16(20); u16(0x800); u16(0);
    u16(0); u16(0); u32(zip.getCrc32(bytes)); u32(bytes.length); u32(bytes.length);
    u16(encodedName.length); u16(0); u16(0); u16(0); u16(0);
    u32(0); u32(offsets[i]); output.add(encodedName);
  }
  final centralSize = output.length - centralOffset;
  u32(0x06054b50); u16(0); u16(0); u16(entries.length); u16(entries.length);
  u32(centralSize); u32(centralOffset); u16(0);
  return output.takeBytes();
}
