import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/backup_service.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/cover_store.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/library/data/library_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('restored covers survive offline re-export and preserve existing local bytes', () async {
    final dir = await Directory.systemTemp.createTemp('triomi_cover_restore_');
    addTearDown(() => dir.delete(recursive: true));
    final source = openTestDatabase(), target = openTestDatabase();
    addTearDown(source.close);
    addTearDown(target.close);
    var networkReads = 0;
    final online =
        FakeHttpClient(
            (_) async => const SourceResponse(statusCode: 200, body: ''),
          )
          ..bytesHandler = (_) {
            networkReads++;
            return _png;
          };
    final offline = FakeHttpClient((_) async => throw StateError('offline'))
      ..bytesHandler = (_) => throw StateError('offline');
    const items = [
      MediaItem(
        sourceId: 'a/b',
        remoteId: 'same',
        type: MediaType.manga,
        title: 'First',
        coverUrl: 'https://covers.test/one.png',
      ),
      MediaItem(
        sourceId: 'a_b',
        remoteId: 'same',
        type: MediaType.manga,
        title: 'Second',
        coverUrl: 'https://covers.test/two.png',
      ),
    ];
    for (final item in items) {
      await LibraryRepository(source).addToLibrary(item);
    }
    BackupService service(
      AppDatabase db,
      SourceHttpClient http,
      CoverStore store,
    ) => BackupService(
      database: db,
      preferences: memoryPreferences(),
      http: http,
      coverStore: store,
    );
    final original = await service(
      source,
      online,
      CoverStore(Directory('${dir.path}/original')),
    ).exportToBytes();
    expect(networkReads, 2);
    final cache = CoverStore(Directory('${dir.path}/target'));
    await cache.putIfMissing(items.last.coverUrl!, [9, 8, 7]);
    final restored = service(target, offline, cache);
    final summary = await restored.importFromBytes(original.bytes);
    expect(summary.covers, 2);
    expect(
      await (await cache.find(items.first.coverUrl!))!.readAsBytes(),
      orderedEquals(_png),
    );
    expect(await (await cache.find(items.last.coverUrl!))!.readAsBytes(), [
      9,
      8,
      7,
    ]);
    await restored.importFromBytes(original.bytes);
    expect(await (await cache.find(items.last.coverUrl!))!.readAsBytes(), [
      9,
      8,
      7,
    ]);
    final portable = await restored.exportToBytes();
    expect(portable.summary.covers, 2);
    expect(networkReads, 2);
    expect(
      (await cache.directory.list().toList())
          .whereType<File>()
          .map((f) => f.path)
          .any((p) => p.endsWith('.part')),
      false,
    );
  });

  testWidgets(
    'restored cover owns decoded bytes without network or file lifetime dependency',
    (tester) async {
      final dir = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'triomi_cover_widget_',
        );
        await CoverStore(Directory('${directory.path}/covers'))
            .putIfMissing('https://offline.invalid/cover.png', _png);
        return directory;
      });
      const url = 'https://offline.invalid/cover.png';
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => dir!.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await tester.runAsync(() => dir!.delete(recursive: true));
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(memoryPreferences()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SizedBox(
              width: 100,
              height: 100,
              child: MediaCover(url: url),
            ),
          ),
        ),
      );
      // A real artifact lease may need a retry timer. Pumping zero-duration
      // frames leaves that fake-zone timer stalled despite real IO delays.
      final deadline = Stopwatch()..start();
      do {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      } while (find.byType(Image).evaluate().isEmpty && deadline.elapsed < const Duration(seconds: 5));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<MemoryImage>());
      await tester.runAsync(() async {
        final stored = await CoverStore(Directory('${dir!.path}/covers')).find(url);
        await stored!.delete();
        expect(await stored.exists(), isFalse);
        final bytes = (image.image as MemoryImage).bytes;
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1);
        expect(frame.image.height, 1);
        frame.image.dispose();
        codec.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
