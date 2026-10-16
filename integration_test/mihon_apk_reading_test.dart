import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/app.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/platform/platform_channel.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/mihon_installer.dart';
import 'package:triomi/core/source/mihon_repository.dart';
import 'package:triomi/core/source/mihon_source.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';
import 'package:triomi/main.dart' as app;

// Run install and resume in separate Android processes. Both phases use real
// APK requests; no source, HTTP, platform or storage overrides are installed.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment('MIHON_PHASE', defaultValue: 'install');
  const minPages = int.fromEnvironment('MIHON_MIN_PAGES', defaultValue: 5);
  const selection = String.fromEnvironment(
    'MIHON_SELECTION',
    defaultValue: 'search',
  );
  const targetPage = int.fromEnvironment('MIHON_TARGET_PAGE', defaultValue: 3);
  const package = String.fromEnvironment(
    'MIHON_PACKAGE',
    defaultValue: 'eu.kanade.tachiyomi.extension.all.mangadex',
  );
  const signer = String.fromEnvironment(
    'MIHON_SIGNER',
    defaultValue:
        '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
  );
  const apkUrl = String.fromEnvironment(
    'MIHON_APK_URL',
    defaultValue: 'https://github.com/keiyoushi/extensions/releases/download/8ef06cd-0/tachiyomi-all.mangadex-v1.6.0.apk',
  );
  const extensionLib = String.fromEnvironment('MIHON_ABI', defaultValue: '1.6');
  const versionCode = int.fromEnvironment(
    'MIHON_VERSION_CODE',
    defaultValue: 106000,
  );
  const versionName = String.fromEnvironment(
    'MIHON_VERSION_NAME',
    defaultValue: '1.6.0',
  );
  const sourceLanguage = String.fromEnvironment(
    'MIHON_SOURCE_LANGUAGE',
    defaultValue: 'zh-Hans',
  );
  const searchQuery = String.fromEnvironment(
    'MIHON_SEARCH_QUERY',
    defaultValue: 'Berserk',
  );
  const exactUrl = String.fromEnvironment(
    'MIHON_EXACT_URL',
    defaultValue:
        'https://mangadex.org/title/801513ba-a712-498c-8f57-cae55b38cc92',
  );

  testWidgets('real Mihon APK reading and restart: $phase', (tester) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final preferences = container.read(preferencesProvider);
    final record = <String, Object?>{
      'phase': phase,
      'at': DateTime.now().toUtc().toIso8601String(),
    };

    if (phase == 'install') {
      final status =
          await MihonInstaller(
            http: container.read(sourceHttpClientProvider),
            preferences: preferences,
          ).install(
            const MihonExtension(
              name: String.fromEnvironment(
                'MIHON_EXTENSION_NAME',
                defaultValue: 'MangaDex',
              ),
              packageName: package,
              apkUrl: apkUrl,
              iconUrl: '',
              extensionLib: extensionLib,
              versionCode: versionCode,
              versionName: versionName,
              sources: [],
            ),
            signerSha256: signer,
          );
      expect(status['executable'], true);
      record['install'] = status;
      final enabled = <String>{
        ...?preferences
            .get<List<Object?>>('mihon.enabledPackages')
            ?.map((e) => '$e'),
        package,
      };
      expect(await platformChannel.setMihonEnabled(package, true), true);
      await preferences.set('mihon.enabledPackages', enabled.toList());
    }
    container.invalidate(sourceRegistryProvider);
    await container.read(sourcesProvider.notifier).refresh();
    final snapshot = await container.read(sourcesProvider.future);
    final source = snapshot.enabledEntries
        .map((e) => e.source)
        .whereType<MihonSource>()
        .firstWhere(
          (s) =>
              s.packageName == package && s.descriptor.lang == sourceLanguage,
        );
    record['sourceId'] = source.descriptor.id;
    final library = container.read(libraryRepositoryProvider);

    final popular = await source.discover(source.feeds.first);
    record['popularCount'] = popular.length;
    final searched = await source.search(searchQuery);
    if (selection == 'search') expect(searched, isNotEmpty);
    expect(popular, isNotEmpty);
    record['keywordSearchCount'] = searched.length;
    record['selection'] = selection;
    // MangaDex's default rating filter hides Berserk, so its extension has a
    // separate URL lookup workflow. Other sources can use their search result.
    final found = selection == 'popular'
        ? popular.first
        : exactUrl.isEmpty
        ? searched.first
        : (await source.search(exactUrl)).firstWhere(
            (m) => m.remoteId.contains(Uri.parse(exactUrl).pathSegments.last),
          );
    final item = await source.detail(found);
    expect(item.type, MediaType.manga);
    final chapters = await source.chapters(item);
    expect(chapters, isNotEmpty);
    final chapter = chapters.last;
    record['title'] = item.title;
    record['chapterCount'] = chapters.length;
    record['chapterId'] = chapter.remoteId;
    await library.cacheItem(item);
    await library.saveChapters(
      itemSourceId: item.sourceId,
      itemRemoteId: item.remoteId,
      chapters: chapters,
    );
    final content = await source.content(chapter);
    expect(content.images.length, greaterThanOrEqualTo(minPages));
    expect(targetPage, lessThan(content.images.length));
    record['pageCount'] = content.images.length;

    if (phase == 'resume') {
      final saved = await library.chapterPositionOf(
        item.sourceId,
        item.remoteId,
        chapter.remoteId,
      );
      expect(saved ?? 0, targetPage);
      record['persistedPage'] = saved;
    }

    // Decode a real plugin image returned through the same lazy URL that the
    // reader/download manager uses. This also checks the native success flag.
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(
        Uri.parse(content.images[targetPage]),
      )).close();
      expect(response.statusCode, 200);
      final builder = BytesBuilder();
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      record['imageBytes'] = bytes.length;
      record['imageWidth'] = frame.image.width;
      record['imageHeight'] = frame.image.height;
      expect(frame.image.width, greaterThan(100));
      frame.image.dispose();
      codec.dispose();
    } finally {
      client.close(force: true);
    }

    await container
        .read(readerSettingsProvider.notifier)
        .setMode(ReadingMode.ltr);
    unawaited(
      container
          .read(routerProvider)
          .push<void>(
            AppRoutes.reader,
            extra: MangaReaderArgs(
              item: item,
              chapters: chapters,
              initialIndex: chapters.length - 1,
            ),
          ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.byType(PageView).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(PageView), findsOneWidget);
    final pageView = tester.widget<PageView>(find.byType(PageView));
    if (phase == 'resume') {
      expect(pageView.controller!.page!.round(), targetPage);
    } else {
      pageView.controller!.jumpToPage(targetPage);
      await tester.pump(const Duration(seconds: 1));
      final saveDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (await library.chapterPositionOf(
                item.sourceId,
                item.remoteId,
                chapter.remoteId,
              ) !=
              targetPage &&
          DateTime.now().isBefore(saveDeadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        await library.chapterPositionOf(
          item.sourceId,
          item.remoteId,
          chapter.remoteId,
        ),
        targetPage,
      );
    }
    await tester.pump(const Duration(seconds: 3));
    final layer = binding.renderViews.first.debugLayer! as OffsetLayer;
    final screenshot = await layer.toImage(
      Offset.zero & binding.renderViews.first.size,
    );
    final png = await screenshot.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${(await getApplicationSupportDirectory()).path}/mihon-$phase-page${targetPage + 1}.png',
    ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    screenshot.dispose();

    expect(await platformChannel.setMihonEnabled(package, false), true);
    final disabled = await platformChannel.mihonRequest(
      packageName: package,
      operation: 'search',
      query: searchQuery,
    );
    expect(disabled['ok'], false);
    expect('${disabled['error']}', contains('disabled'));
    expect(await platformChannel.setMihonEnabled(package, true), true);
    record['disabledRejected'] = true;
    final status =
        (preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')![package]
            as Map);
    final rejected = await platformChannel.inspectMihonExtension(
      apkPath: '${status['stagedPath']}',
      packageName: package,
      versionCode: versionCode + 1,
      signerSha256: signer,
    );
    expect(rejected['ok'], false);
    expect(
      selection == 'popular'
          ? await source.discover(source.feeds.first)
          : await source.search(searchQuery),
      isNotEmpty,
    );
    record['failedUpdateKeptOldPlugin'] = true;
    record['status'] = 'passed';
    final evidence = File(
      '${(await getApplicationSupportDirectory()).path}/mihon-$phase-evidence.json',
    );
    await evidence.writeAsString(
      const JsonEncoder.withIndent('  ').convert(record),
      flush: true,
    );
    // Test output is persisted by the host runner as acceptance evidence.
    debugPrint('MIHON_EVIDENCE ${jsonEncode(record)}');
  }, timeout: const Timeout(Duration(minutes: 12)));
}
