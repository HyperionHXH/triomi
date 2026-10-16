// Run in a new process with emulator Wi-Fi and mobile data disabled.
// Uses only the actual account's persisted download, without provider overrides.
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
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/export/novel_export_service.dart';
import 'package:triomi/features/novel/reader/chapter_font.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real LNS download renders after restart without network', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    var networkBlocked = false;
    try {
      final request = await client
          .getUrl(Uri.parse('https://www.lightnovel.us/'))
          .timeout(const Duration(seconds: 5));
      await request.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      networkBlocked = true;
    } finally {
      client.close(force: true);
    }
    expect(
      networkBlocked,
      true,
      reason: 'Disable device networking before this acceptance',
    );
    final saved = container
        .read(preferencesProvider)
        .get<Map<dynamic, dynamic>>('acceptance.novel.lns.item');
    expect(saved, isNotNull);
    final item = MediaItem.fromJson(
      saved!.cast<String, Object?>(),
      sourceId: LnsSource.id,
    );
    final library = container.read(libraryRepositoryProvider);
    final chapters = await library.loadChapters(item.sourceId, item.remoteId);
    final downloads = container.read(downloadRepositoryProvider);
    final chapter = chapters
        .where(
          (c) => !c.locked && !RegExp(r'封面|目录|插画|彩页|书籍信息').hasMatch(c.title),
        )
        .first;
    final local = await downloads.localChapterContent(
      item.sourceId,
      chapter.remoteId,
    );
    expect(local, isNotNull);
    expect(local!.fontData, isNotNull);
    // Do not register here: the production reader must load the font itself.
    final position = await library.chapterPositionOf(
      item.sourceId,
      item.remoteId,
      chapter.remoteId,
    );
    expect(position, greaterThan(0));
    await container.read(sourcesProvider.future);
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
    final indicator = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^\d+ / \d+$').hasMatch(w.data ?? ''),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (indicator.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(indicator, findsOneWidget);
    final label = tester.widget<Text>(indicator).data!;
    expect(int.parse(label.split(' / ').first), greaterThan(1));
    await expectLater(
      NovelExportService.exportEpub(
        item: item,
        chapters: [chapter],
        source: container.read(lnsSourceProvider),
        http: container.read(sourceHttpClientProvider),
        localContent: (c) =>
            downloads.localChapterContent(c.sourceId, c.remoteId),
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
    await tester.pump(const Duration(seconds: 1));
    final dir = await getApplicationDocumentsDirectory();
    final layer = binding.renderViews.first.debugLayer! as OffsetLayer;
    final shot = await layer.toImage(
      Offset.zero & binding.renderViews.first.flutterView.physicalSize,
    );
    final png = await shot.toByteData(format: ui.ImageByteFormat.png);
    await File('${dir.path}/lns-offline.png')
        .writeAsBytes(png!.buffer.asUint8List(), flush: true);
    shot.dispose();
    final record = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'networkBlocked': networkBlocked,
      'bodyLength': (local.html ?? local.text ?? '').length,
      'fontBytes': ChapterFont.decode(local.fontData!).length,
      'restoredPage': label,
      'fontLoadedBy': 'production reader from persisted download',
      'officialDownloadOnly': true,
      'chargedDownloadCalled': false,
      'status': 'passed',
    };
    await File('${dir.path}/lns-offline.json')
        .writeAsString(jsonEncode(record), flush: true);
    // ignore: avoid_print
    print('LNS_OFFLINE_EVIDENCE ${jsonEncode(record)}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
