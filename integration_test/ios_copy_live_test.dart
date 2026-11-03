import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/copymanga/copymanga_js_source.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';

import '../test/fixtures/fake_preferences.dart';
import 'fixtures/ios_test_binding.dart';

// Loopback carries only native screenshot handshakes. All source/API/image
// requests below and in the production UI use real HTTPS and platform runtime.
void main() {
  initializeIosIntegrationBinding();
  testWidgets('Copy live API full catalogue and production iOS reader', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    final captureBase = Uri.parse(
      const String.fromEnvironment('TRIOMI_COPY_CAPTURE_URL'),
    );
    expect(captureBase.host, '127.0.0.1');
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = memoryPreferences();
    final secureStore = MemorySecureStore();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(preferences),
        secureStoreProvider.overrideWithValue(secureStore),
      ],
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    final evidence = <String, Object?>{
      'status': 'running',
      'groups': <Object?>[],
    };
    final documents = await getApplicationDocumentsDirectory();
    Future<void> save() =>
        File('${documents.path}/copy-live.json')
            .writeAsString(jsonEncode(evidence), flush: true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      container.dispose();
      client.close(force: true);
      await database.close();
    });
    Future<void> until(
      bool Function() ready,
      String reason, {
      int seconds = 90,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue, reason: reason);
      expect(tester.takeException(), isNull, reason: reason);
    }

    Future<void> capture(String name, String route, String description) async {
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      final request = await client.postUrl(
        captureBase.resolve('/__tour/capture'),
      );
      request.headers.contentType = ContentType.json;
      final bytes = utf8.encode(
        jsonEncode({'name': name, 'route': route, 'description': description}),
      );
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 50),
      );
      final body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: body);
    }

    Future<Map<String, dynamic>> api(String path) async {
      final request = await client.getUrl(
        Uri.parse('https://api.copy4000.com/api/v3/$path'),
      );
      const headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:114.0) Gecko/20100101 Firefox/114.0',
        'Version': '2026.08.21',
        'Origin': 'https://2025copy.com',
        'Region': '0',
        'Webp': '0',
        'platform': '1',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9,zh-TW;q=0.8,zh;q=0.7',
      };
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(
        await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 45)),
      ) as Map<String, dynamic>;
      expect(body['code'], 200);
      return body['results'] as Map<String, dynamic>;
    }

    Future<Map<String, Object?>> decodeImage(
      String url,
      Map<String, String> headers,
    ) async {
      final uri = Uri.parse(url);
      expect(uri.scheme, 'https');
      expect(uri.host, isNot(anyOf('localhost', '127.0.0.1')));
      final request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      expect(response.statusCode, 200);
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add).timeout(const Duration(seconds: 60));
      final bytes = builder.takeBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, greaterThan(100));
          expect(frame.image.height, greaterThan(100));
          return {
            'url': url,
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
            'width': frame.image.width,
            'height': frame.image.height,
          };
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }

    try {
      final text = await rootBundle.loadString(
        'assets/rules/copymanga-js.json',
      );
      final hash = sha256.convert(utf8.encode(text)).toString();
      expect(hash, const String.fromEnvironment('TRIOMI_COPY_RULE_SHA256'));
      evidence['ruleSha256'] = hash;
      final registry = container.read(sourceRegistryProvider);
      await registry.importFromText(text);
      // Prevent normal boot seeding unrelated sources into this isolated audit.
      await preferences.set(
        'sources.seededBuiltins',
        SourceRegistry.builtinRuleAssets,
      );
      final snapshot = await registry.load();
      final source = snapshot.entries
          .singleWhere((entry) => entry.descriptor.id == 'copymanga')
          .source;
      expect(source, isA<CopyMangaJsSource>());
      final copy = source as CopyMangaJsSource;
      expect(copy.isLoggedIn, isFalse);
      final results = await (source as SearchProvider)
          .search('一拳超人')
          .timeout(const Duration(seconds: 90));
      final item = results.singleWhere(
        (item) => item.remoteId == 'yiquanchaoren',
      );
      final detail = await (source as DetailProvider)
          .detail(item)
          .timeout(const Duration(seconds: 90));
      final chapters = await (source as DetailProvider)
          .chapters(detail)
          .timeout(const Duration(minutes: 3));
      final reference = await api('comic2/yiquanchaoren');
      final groups = reference['groups'] as Map<String, dynamic>;
      expect(groups.length, greaterThanOrEqualTo(2));
      final allIds = <String>{};
      final defaultIds = <String>[];
      final chapterIndices = <String, int>{};
      for (final raw in groups.values) {
        final group = raw as Map<String, dynamic>;
        final path = group['path_word'] as String;
        final ids = <String>[];
        var offset = 0;
        var total = group['count'] as int;
        while (offset < total) {
          final page = await api(
            'comic/yiquanchaoren/group/$path/chapters?limit=100&offset=$offset&_update=true',
          );
          total = page['total'] as int;
          final list = page['list'] as List;
          expect(
            list,
            isNotEmpty,
            reason: 'Full pagination must not terminate before server total',
          );
          for (final rawChapter in list) {
            ids.add('yiquanchaoren/${(rawChapter as Map)['uuid']}');
            chapterIndices[ids.last] = (rawChapter)['index'] as int;
          }
          offset += list.length;
        }
        expect(ids.length, total);
        expect(ids.toSet().length, total);
        allIds.addAll(ids);
        if (path == 'default') defaultIds.addAll(ids);
        (evidence['groups'] as List).add({
          'path': path,
          'count': total,
          'chapterIds': ids,
        });
      }
      expect(
        allIds.length,
        greaterThan(300),
        reason: 'Main comic must include its full large catalogue, not a search spin-off',
      );
      expect(chapters.map((chapter) => chapter.remoteId).toSet(), allIds);
      expect(chapters.length, allIds.length);
      final mainChapters = chapters
          .where((chapter) => defaultIds.contains(chapter.remoteId))
          .toList();
      final oldest = mainChapters.first;
      final newest = mainChapters.last;
      final chronological = defaultIds.toList()
        ..sort((a, b) => chapterIndices[a]!.compareTo(chapterIndices[b]!));
      expect(
        mainChapters.map((chapter) => chapter.remoteId).toList(),
        chronological,
        reason: 'Oldest/newest must be determined by server chapter index, not guessed list positions',
      );
      await copy.updateSetting('showChapterComments', true);
      await copy.updateSetting('commentMode', 'merge');
      final oldContent = await (source as ContentProvider)
          .content(oldest)
          .timeout(const Duration(seconds: 90));
      final latestContent = await (source as ContentProvider)
          .content(newest)
          .timeout(const Duration(seconds: 90));
      expect(oldContent.images.length, greaterThan(1));
      expect(latestContent.images, isNotEmpty);
      Future<void> compareLivePages(
        Chapter chapter,
        ChapterContent content,
      ) async {
        final uuid = chapter.remoteId.split('/').last;
        final result = await api('comic/yiquanchaoren/chapter2/$uuid');
        final raw = result['chapter'] as Map;
        final contents = raw['contents'] as List;
        final words = raw['words'] as List?;
        final order = List<int>.generate(contents.length, (index) => index);
        if (words != null && words.isNotEmpty) {
          expect(words.length, contents.length);
          order.sort((a, b) => (words[a] as num).compareTo(words[b] as num));
        }
        final expected = [
          for (final index in order)
            ((contents[index] as Map)['url'] as String).replaceFirstMapped(
              RegExp(r'\d+x\.(jpg|webp)$'),
              (match) => '1500x.${match[1]}',
            ),
        ];
        expect(
          content.images,
          expected,
          reason: 'All real pages must match live chapter2 word ordering at configured resolution',
        );
      }

      await compareLivePages(oldest, oldContent);
      await compareLivePages(newest, latestContent);
      expect(
        oldContent.comments,
        isNotEmpty,
        reason: 'Live oldest chapter must expose real native discussion data',
      );
      evidence['discussion'] = {
        'count': oldContent.comments.length,
        'firstAuthor': oldContent.comments.first.author,
        'firstText': oldContent.comments.first.text,
      };
      evidence['oldest'] = {
        'chapter': oldest.remoteId,
        'imageCount': oldContent.images.length,
        'firstImage': await decodeImage(
          oldContent.images.first,
          oldContent.imageHeaders,
        ),
      };
      evidence['latest'] = {
        'chapter': newest.remoteId,
        'imageCount': latestContent.images.length,
        'firstImage': await decodeImage(
          latestContent.images.first,
          latestContent.imageHeaders,
        ),
      };
      await save();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TriomiApp(),
        ),
      );
      final router = container.read(routerProvider);
      router.go(
        AppRoutes.searchFor(
          MediaType.manga,
          sourceId: 'copymanga',
          query: '一拳超人',
          sourceOnly: true,
        ),
      );
      await until(
        () => find.byType(MediaItemCard).evaluate().isNotEmpty,
        'Production search must finish with actual result cards',
      );
      final mainResult = find.byWidgetPredicate(
        (widget) =>
            widget is MediaItemCard &&
            widget.item.sourceId == item.sourceId &&
            widget.item.remoteId == item.remoteId,
      );
      // Results are a lazy horizontal list; the main work is not necessarily
      // among the first visible cards when similarly named spin-offs precede it.
      await tester.scrollUntilVisible(
        mainResult,
        200,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              axisDirectionToAxis(widget.axisDirection) == Axis.horizontal,
        ),
        maxScrolls: 20,
      );
      expect(mainResult.hitTestable(), findsOneWidget);
      await capture(
        '01_copy_search.png',
        '/manga/search',
        'Live Copy search production results',
      );
      router.go(AppRoutes.detailFor(detail), extra: detail);
      await until(
        () => find.textContaining(oldest.title).evaluate().isNotEmpty,
        'Production detail must load live catalogue',
      );
      await capture(
        '02_copy_detail.png',
        '/manga/detail',
        'Live main comic and full multi-group catalogue',
      );
      Future<void> openReader(Chapter chapter) async {
        unawaited(
          router.push<void>(
            AppRoutes.reader,
            extra: MangaReaderArgs(
              item: detail,
              chapters: mainChapters,
              initialIndex: mainChapters.indexOf(chapter),
            ),
          ),
        );
        final expectedPage = chapter.remoteId == oldest.remoteId
            ? oldContent.images.first
            : latestContent.images.first;
        await until(
          () => find
              .descendant(
                of: find.byWidgetPredicate(
                  (widget) =>
                      widget is MangaPageImage && widget.url == expectedPage,
                ),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is CustomPaint &&
                      widget.painter.runtimeType.toString() == '_PagePainter',
                ),
              )
              .evaluate()
              .isNotEmpty,
          'Production reader must download and decode real chapter pages',
        );
        expect(find.text('重新加载'), findsNothing);
      }

      await openReader(oldest);
      await capture(
        '03_copy_old_reader.png',
        '/reader',
        'Oldest main-group chapter real decoded page',
      );
      final slider = find.byType(Slider);
      await until(
        () => slider.evaluate().isNotEmpty,
        'Reader page slider must be available',
      );
      final readerBounds = tester.getRect(find.byType(MangaReaderPage));
      // Default RTL tap zones: left edge advances, right edge returns.
      await tester.tapAt(
        Offset(
          readerBounds.left + readerBounds.width * .15,
          readerBounds.center.dy,
        ),
      );
      await until(
        () => find.text('2/${oldContent.images.length}').evaluate().isNotEmpty,
        'Reader page must advance to second actual page',
      );
      await until(
        () => find
            .descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is MangaPageImage &&
                    widget.url == oldContent.images[1],
              ),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint &&
                    widget.painter.runtimeType.toString() == '_PagePainter',
              ),
            )
            .evaluate()
            .isNotEmpty,
        'The second page URL must actually decode, not a retained first-page painter',
      );
      await capture(
        '04_copy_page_advanced.png',
        '/reader',
        'Production page advancement to page two',
      );
      await tester.tap(find.byTooltip('吐槽'));
      await until(
        () => find
            .text(oldContent.comments.first.text, findRichText: true)
            .evaluate()
            .isNotEmpty,
        'Native comments must show actual live chapter discussion text',
      );
      await capture(
        '09_copy_native_comments.png',
        '/reader/comments',
        'Actual live discussion rendered as native selectable text',
      );
      Navigator.of(
        tester.element(
          find.text(oldContent.comments.first.text, findRichText: true).first,
        ),
      ).pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(
        Offset(
          readerBounds.left + readerBounds.width * .85,
          readerBounds.center.dy,
        ),
      );
      await until(
        () => find.text('1/${oldContent.images.length}').evaluate().isNotEmpty,
        'Page-back interaction must return to the first real page',
      );
      await tester.tap(find.byTooltip('阅读设置'));
      await until(
        () => find.text('本作品阅读设置').evaluate().isNotEmpty,
        'Production work reader settings open',
      );
      await capture(
        '05_copy_reader_settings.png',
        '/reader',
        'Production reading settings on live Copy work',
      );
      Navigator.of(tester.element(find.text('本作品阅读设置'))).pop();
      await tester.pump(const Duration(milliseconds: 400));
      final following = mainChapters[1];
      final followingContent = await (source as ContentProvider)
          .content(following)
          .timeout(const Duration(seconds: 90));
      expect(followingContent.images, isNotEmpty);
      await tester.tap(find.byTooltip('下一章'));
      await until(
        () => find.text(following.title).evaluate().isNotEmpty,
        'Production next-chapter control must change the live chapter',
      );
      await until(
        () => find
            .descendant(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is MangaPageImage &&
                    widget.url == followingContent.images.first,
              ),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint &&
                    widget.painter.runtimeType.toString() == '_PagePainter',
              ),
            )
            .evaluate()
            .isNotEmpty,
        'The next chapter must actually decode its own first page',
      );
      await capture(
        '11_copy_next_chapter.png',
        '/reader',
        'Production next chapter downloads and decodes the next actual chapter',
      );
      router.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await openReader(newest);
      await capture(
        '06_copy_latest_reader.png',
        '/reader',
        'Newest main-group chapter real decoded page',
      );
      await tester.tap(find.byTooltip('返回'));
      await until(
        () => find.byType(MangaReaderPage).evaluate().isEmpty,
        'Reader back must return to production detail',
      );
      router.go('${AppRoutes.sources}?type=manga');
      await until(
        () => find.text('站点账号').evaluate().isNotEmpty,
        'Copy account entry must remain available in production source management',
      );
      await capture(
        '07_copy_return.png',
        '/sources?type=manga',
        'Reader returned successfully; live Copy source retains native settings and account entries',
      );
      await tester.tap(find.text('站点账号').first);
      await until(
        () => find.text('登录').evaluate().isNotEmpty,
        'Native account sheet must open without credentials or remote writes',
      );
      await capture(
        '10_copy_account_entry.png',
        '/sources/account',
        'Production logged-out account entry; no credentials entered or account writes',
      );
      Navigator.of(tester.element(find.text('登录').first)).pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('${copy.descriptor.name}更多操作'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('来源设置'));
      await until(
        () => find.text('拷贝漫画设置').evaluate().isNotEmpty,
        'Actual Copy host settings sheet opens',
      );
      final resolution = find.byKey(const ValueKey('copymanga-resolution'));
      await tester.ensureVisible(resolution);
      await tester.tap(resolution);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('800').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(preferences.get<String>('sources.copymanga.resolution'), '800');
      expect(copy.settings.requestOptions['resolution'], '800');
      await capture(
        '08_copy_source_settings.png',
        '/sources/settings',
        'Production Copy settings persist selected resolution without account changes',
      );
      evidence['status'] = 'passed';
      await save();
    } catch (error) {
      evidence['status'] = 'failed';
      evidence['error'] = '$error';
      await save();
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
