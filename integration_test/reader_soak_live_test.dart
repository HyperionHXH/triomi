// Real persisted account content and production sources. No provider overrides.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('five minute real reader/source soak', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final preferences = container.read(preferencesProvider);
    final library = container.read(libraryRepositoryProvider);
    final snapshot = await container.read(sourcesProvider.future);
    final watch = Stopwatch()..start();
    var turns = 0;
    var pages = 0;
    var networkSuccess = 0;
    var networkFailures = 0;
    final indicator = find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^\d+ / \d+$').hasMatch(w.data ?? ''),
    );
    while (watch.elapsed < const Duration(minutes: 5)) {
      final kind = turns.isEven ? 'lk' : 'lns';
      final id = kind == 'lk' ? LkSource.id : LnsSource.id;
      final saved = preferences.get<Map<dynamic, dynamic>>(
        'acceptance.novel.$kind.item',
      );
      expect(saved, isNotNull);
      final item = MediaItem.fromJson(
        saved!.cast<String, Object?>(),
        sourceId: id,
      );
      final chapters = await library.loadChapters(id, item.remoteId);
      final chapter = chapters
          .where(
            (c) => !c.locked && !RegExp(r'封面|目录|插画|彩页|书籍信息').hasMatch(c.title),
          )
          .first;
      final router = container.read(routerProvider);
      unawaited(
        router.push<void>(
          AppRoutes.novelReader,
          extra: NovelReaderArgs(
            item: item,
            chapters: chapters,
            initialIndex: chapters.indexOf(chapter),
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (indicator.evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(indicator, findsOneWidget);
      for (var i = 0; i < 8; i++) {
        final rect = tester.getRect(find.byType(NovelReaderPage));
        await tester.tapAt(
          Offset(
            rect.left + rect.width * (i.isEven ? .85 : .15),
            rect.top + rect.height * .5,
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(indicator, findsOneWidget);
        pages++;
      }
      router.pop();
      await tester.pump(const Duration(milliseconds: 500));
      final source =
          snapshot.entries.firstWhere((e) => e.descriptor.id == id).source
              as DiscoverProvider;
      try {
        expect(await source.discover(source.feeds.first), isNotEmpty);
        networkSuccess++;
      } catch (_) {
        networkFailures++;
      }
      // Leave time for the external ADB monitor to exercise real HOME/resume.
      final until = DateTime.now().add(const Duration(seconds: 16));
      while (DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      turns++;
    }
    final record = {
      'elapsedMs': watch.elapsedMilliseconds,
      'readerEntries': turns,
      'pageActions': pages,
      'sourceSuccess': networkSuccess,
      'sourceFailures': networkFailures,
      'sources': ['lk', 'lns'],
      'status': 'passed',
      'scope': 'five-minute smoke soak; not hours-long endurance',
    };
    expect(turns, greaterThanOrEqualTo(8));
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/reader-soak-live.json')
        .writeAsString(jsonEncode(record), flush: true);
    // ignore: avoid_print
    print('READER_SOAK_EVIDENCE ${jsonEncode(record)}');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
