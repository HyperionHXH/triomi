import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/features/reader/reader_work_settings.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _PendingDownloads extends DownloadRepository {
  _PendingDownloads(super.db);
  final result = Completer<String?>();
  @override
  Future<String?> localImageDir(String sourceId, String chapterRemoteId) =>
      result.future;
}

void main() {
  late Preferences preferences;
  setUp(() => preferences = memoryPreferences());

  testWidgets('正文加载与失败时零张图片不使页码滑杆越界', (tester) async {
    final AppDatabase db = openTestDatabase();
    final downloads = _PendingDownloads(db);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(MemorySecureStore()),
        downloadRepositoryProvider.overrideWithValue(downloads),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        container.dispose();
        await db.close();
      });
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MangaReaderPage(
            args: MangaReaderArgs(
              item: MediaItem(
                sourceId: 'reader',
                remoteId: 'book',
                type: MediaType.manga,
                title: '慢速漫画',
              ),
              chapters: [
                Chapter(
                  sourceId: 'reader',
                  remoteId: 'chapter',
                  title: '第一话',
                  sortIndex: 0,
                  url: 'https://example.test/chapter',
                ),
              ],
              initialIndex: 0,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载章节…'), findsOneWidget);
    expect(find.text('0/0'), findsNothing);
    expect(find.byType(Slider), findsNothing);

    // The live desktop found a stale snapshot in the modal sheet. Selection
    // must update while the sheet stays open, and persist through provider
    // invalidation without forcing the user to close/reopen the panel.
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    const work = (sourceId: 'reader', remoteId: 'book');
    final oldMode = container.read(readerWorkSettingsProvider(work)).base.mode;
    final targetMode = oldMode == ReadingMode.ltr
        ? ReadingMode.rtl
        : ReadingMode.ltr;
    await tester.tap(find.text(targetMode.label));
    await tester.pump();
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, targetMode.label),
    );
    expect(chip.selected, true);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    container.invalidate(readerWorkOverridesProvider(work));
    expect(
      container.read(readerWorkSettingsProvider(work)).base.mode,
      targetMode,
    );
    expect(container.read(readerSettingsProvider).mode, oldMode);
    Navigator.of(tester.element(find.text(targetMode.label))).pop();
    await tester.pump(const Duration(milliseconds: 400));

    downloads.result.completeError(StateError('模拟正文读取失败'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('模拟正文读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('章节未加载'), findsOneWidget);
    expect(find.text('0/0'), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });
}
