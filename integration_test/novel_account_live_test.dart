// Real Android account acceptance. Passwords arrive once from host loopback;
// never use dart-define, assets, device files, or mock storage for credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/export/epub_exporter.dart';
import 'package:triomi/features/novel/export/novel_export_service.dart';
import 'package:triomi/features/novel/reader/chapter_font.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment(
    'NOVEL_ACCOUNT_PHASE',
    defaultValue: 'login',
  );
  const port = int.fromEnvironment(
    'NOVEL_ACCOUNT_RELAY_PORT',
    defaultValue: 18763,
  );
  testWidgets('real novel accounts: $phase', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final snapshot = await container.read(sourcesProvider.future);
    final records = <String, Object?>{};
    final preferences = container.read(preferencesProvider);
    Map<String, dynamic> credentials = {};
    if (phase == 'login') {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/credentials'),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw TestFailure('Credential relay unavailable');
        }
        credentials = jsonDecode(
          await response.transform(utf8.decoder).join(),
        ) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    }
    for (final kind in ['lk', 'lns']) {
      final id = kind == 'lk' ? LkSource.id : LnsSource.id;
      final source = snapshot.entries
          .firstWhere((e) => e.descriptor.id == id)
          .source;
      final account = source as RemoteShelfProvider;
      final record = <String, Object?>{'stage': phase, 'phase': phase};
      records[kind] = record;
      try {
        if (phase == 'login') {
          final value = credentials.remove(kind) as Map<String, dynamic>;
          await account.login(
            value['account'] as String,
            value['password'] as String,
          );
          value.clear();
        } else {
          if (!account.isLoggedIn) {
            throw TestFailure('No persisted session');
          }
          await account.restoreSession();
        }
        record['sessionAvailable'] = account.isLoggedIn;
        if (!account.isLoggedIn) {
          throw TestFailure('Session not restored');
        }
        record['stage'] = 'remoteShelf';
        final shelf = await account.remoteShelf();
        record['shelfCount'] = shelf.length;
        if (kind == 'lk') {
          record['stage'] = 'unread';
          final counts = await account.remoteUnreadCounts();
          record['unreadFieldCount'] = counts.length;
          record['nonzeroUnreadCount'] = counts.values
              .where((v) => v > 0)
              .length;
          final library = container.read(libraryRepositoryProvider);
          for (final item in shelf) {
            await library.addToLibrary(item);
          }
          await library.applyRemoteUnreadCounts(sourceId: id, counts: counts);
          Future<Map<String, int>> localCounts() async => {
            for (final view in await library.listLibrary(type: MediaType.novel))
              if (view.item.sourceId == id &&
                  counts.containsKey(view.item.remoteId))
                view.item.remoteId: view.entry.unreadCount,
          };
          expect(await localCounts(), counts);
          await library.applyRemoteUnreadCounts(sourceId: id, counts: counts);
          expect(await localCounts(), counts);
          record['repeatMergeStable'] = true;
        }
        record['stage'] = 'discover';
        final discover = source as DiscoverProvider;
        final items = await discover.discover(discover.feeds.first);
        record['discoverCount'] = items.length;
        expect(items, isNotEmpty);
        record['stage'] = 'detail';
        final provider = source as DetailProvider;
        final savedItem = preferences.get<Map<dynamic, dynamic>>(
          'acceptance.novel.$kind.item',
        );
        final selected = phase == 'resume' && savedItem != null
            ? MediaItem.fromJson(
                savedItem.cast<String, Object?>(),
                sourceId: id,
              )
            : items.first;
        final item = await provider.detail(selected);
        final chapters = await provider.chapters(item);
        record['chapterCount'] = chapters.length;
        record['lockedCount'] = chapters.where((c) => c.locked).length;
        record['stage'] = 'content';
        final chapter = chapters
            .where(
              (c) =>
                  !c.locked && !RegExp(r'封面|目录|插画|彩页|书籍信息').hasMatch(c.title),
            )
            .first;
        final content = await (source as ContentProvider).content(chapter);
        record['bodyLength'] = (content.html ?? content.text ?? '').length;
        record['fontRegistered'] = content.fontFamily != null;
        record['fontBytes'] = content.fontData == null
            ? 0
            : ChapterFont.decode(content.fontData!).length;
        expect(record['bodyLength'] as int, greaterThan(100));
        final library = container.read(libraryRepositoryProvider);
        final downloads = container.read(downloadRepositoryProvider);
        record['stage'] = 'download';
        await library.cacheItem(item);
        await library.saveChapters(
          itemSourceId: id,
          itemRemoteId: item.remoteId,
          chapters: chapters,
        );
        if (phase == 'login') {
          final task = await downloads.enqueue(
            sourceId: id,
            remoteId: item.remoteId,
            chapter: chapter,
          );
          if (task > 0) {
            final row = (await downloads.listForItem(
              id,
              item.remoteId,
            )).firstWhere((r) => r.id == task);
            await container
                .read(downloadServiceProvider)
                .run(row: row, provider: source as ContentProvider);
          }
          await preferences.set('acceptance.novel.$kind.item', item.toJson());
        }
        final local = await downloads.localChapterContent(id, chapter.remoteId);
        expect(local, isNotNull);
        expect(local!.html ?? local.text, isNotEmpty);
        if (content.fontFamily != null) {
          expect(local.fontData, isNotNull);
          await ChapterFont.register(local.fontData!);
        }
        record['offlineBodyAndFont'] = true;
        record['stage'] = 'export';
        final selectedChapters = [
          chapter,
          ...chapters.where((c) => c.locked).take(1),
        ];
        if (kind == 'lns') {
          await expectLater(
            NovelExportService.exportEpub(
              item: item,
              chapters: selectedChapters,
              source: source as ContentProvider,
              http: container.read(sourceHttpClientProvider),
              onProgress: (_, _) {},
            ),
            throwsA(
              isA<SourceException>().having(
                (e) => e.type,
                'type',
                SourceErrorType.permission,
              ),
            ),
          );
          record['officialDownloadOnly'] = true;
          record['chargedDownloadCalled'] = false;
        } else {
          final epub = await NovelExportService.exportEpub(
            item: item,
            chapters: selectedChapters,
            source: source as ContentProvider,
            http: container.read(sourceHttpClientProvider),
            onProgress: (_, _) {},
          );
          final archive = EpubExporter.decode(
            await File(epub.path).readAsBytes(),
          );
          record['epubChapters'] = epub.exportedChapters;
          record['epubSkippedLocked'] = epub.skippedChapters;
          record['epubFontAssets'] = archive.files
              .where((f) => f.name.startsWith('OEBPS/fonts/'))
              .length;
          expect(epub.exportedChapters, 1);
          if (content.fontFamily != null) {
            expect(record['epubFontAssets'], greaterThan(0));
            await expectLater(
              NovelExportService.exportTxt(
                item: item,
                chapters: selectedChapters,
                source: source as ContentProvider,
                onProgress: (_, _) {},
              ),
              throwsStateError,
            );
            record['txtStatus'] =
                'refused: substituted glyphs require EPUB font';
          } else {
            final txt = await NovelExportService.exportTxt(
              item: item,
              chapters: selectedChapters,
              source: source as ContentProvider,
              onProgress: (_, _) {},
            );
            expect(
              (await File(txt.path).readAsString()).length,
              greaterThan(100),
            );
            record['txtStatus'] = 'passed';
          }
        }
        record['stage'] = 'reader';
        final previousPosition = await library.chapterPositionOf(
          id,
          item.remoteId,
          chapter.remoteId,
        );
        if (phase == 'resume') {
          record['previousAnchor'] = previousPosition;
          expect(previousPosition, greaterThan(0));
          record['restoredAnchor'] = previousPosition;
        }
        unawaited(
          container
              .read(routerProvider)
              .push<void>(
                AppRoutes.novelReader,
                extra: NovelReaderArgs(
                  item: item,
                  chapters: chapters,
                  initialIndex: chapters.indexOf(chapter),
                ),
              ),
        );
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        final pageIndicator = find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              RegExp(r'^\d+ / \d+$').hasMatch(widget.data ?? ''),
        );
        while (pageIndicator.evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(pageIndicator, findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        if (phase == 'login') {
          final rect = tester.getRect(find.byType(NovelReaderPage));
          await tester.tapAt(
            Offset(rect.left + rect.width * 0.85, rect.top + rect.height * 0.5),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tapAt(
            Offset(rect.left + rect.width * 0.85, rect.top + rect.height * 0.5),
          );
          await tester.pump(const Duration(seconds: 2));
          final position = await library.chapterPositionOf(
            id,
            item.remoteId,
            chapter.remoteId,
          );
          expect(position, greaterThan(0));
          record['savedAnchor'] = position;
        } else {
          final label = tester.widget<Text>(pageIndicator).data!;
          expect(int.parse(label.split(' / ').first), greaterThan(1));
          record['restoredPage'] = label;
        }
        final layer = binding.renderViews.first.debugLayer! as OffsetLayer;
        final shot = await layer.toImage(
          Offset.zero & binding.renderViews.first.flutterView.physicalSize,
        );
        final png = await shot.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${(await getApplicationDocumentsDirectory()).path}/novel-$kind-$phase.png',
        ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
        shot.dispose();
        container.read(routerProvider).pop();
        await tester.pump(const Duration(milliseconds: 500));
        record['stage'] = 'complete';
        record['status'] = 'passed';
      } catch (error) {
        // Never log error.toString(), server responses, account or session objects.
        record['status'] = 'failed';
        record['errorType'] = error is SourceException
            ? error.type.name
            : error.runtimeType.toString();
        if (error is SourceException) {
          final text = error.message?.toLowerCase() ?? '';
          record['transportHint'] = [
            for (final word in [
              'handshake',
              'certificate',
              'socket',
              'connection',
              'dns',
              'timeout',
              'http 403',
              'http 401',
            ])
              if (text.contains(word)) word,
          ];
          record['causeType'] = error.cause?.runtimeType.toString();
        }
        if (error is SourceException &&
            error.userMessage.contains('Failed host lookup')) {
          record['errorCode'] = 'dns_lookup_failed';
        }
      }
    }
    credentials.clear();
    final dir = await getApplicationDocumentsDirectory();
    final evidence = {
      'environment': 'Android real production adapters and secure storage',
      'at': DateTime.now().toUtc().toIso8601String(),
      'records': records,
    };
    await File('${dir.path}/novel-account-$phase.json')
        .writeAsString(jsonEncode(evidence), flush: true);
    // Only the explicit, sanitized record is printed.
    // ignore: avoid_print
    print('NOVEL_ACCOUNT_EVIDENCE ${jsonEncode(evidence)}');
    expect(
      records.values.every((r) => (r as Map)['status'] == 'passed'),
      true,
      reason: 'See sanitized evidence for individual source status',
    );
  }, timeout: const Timeout(Duration(minutes: 8)));
}
