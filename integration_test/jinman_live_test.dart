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
import 'package:triomi/core/models/media_item.dart';
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Jinman real repository, verified APK and requests', (
    tester,
  ) async {
    await app.main();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(TriomiApp)),
    );
    final preferences = container.read(preferencesProvider);
    final record = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'environment': 'Android actual APK; no fixtures',
      'stage': 'index',
    };
    try {
      const localApk = String.fromEnvironment('JINMAN_LOCAL_APK');
      const localIndex = String.fromEnvironment('JINMAN_LOCAL_INDEX');
      final index = localIndex.isNotEmpty
          ? MihonRepositoryParser.parse(
              await File(localIndex).readAsString(),
              sourceUrl: 'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/index.json',
            )
          : await MihonRepositoryClient(
              container.read(sourceHttpClientProvider),
            ).fetch(
              'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/index.json',
            );
      final extension = index.extensions.firstWhere(
        (e) =>
            e.packageName == 'eu.kanade.tachiyomi.extension.zh.jinmantiantang',
      );
      record['packageName'] = extension.packageName;
      record['version'] = extension.versionName;
      record['apkUrl'] = extension.apkUrl;
      record['repositoryDefaultSigner'] = index.signingKey;
      record['stage'] = 'install';
      record['apkTransport'] = localApk.isEmpty
          ? 'device HTTPS'
          : 'host verified HTTPS download then adb private transfer';
      final status = localApk.isNotEmpty
          ? await platformChannel.inspectMihonExtension(
              apkPath: localApk,
              packageName: extension.packageName,
              versionCode: extension.versionCode,
              signerSha256: index.signingKey,
            )
          : await MihonInstaller(
              http: container.read(sourceHttpClientProvider),
              preferences: preferences,
            ).install(extension, signerSha256: index.signingKey);
      record['apk'] = status;
      expect(status['signatureVerified'], true);
      expect(status['executable'], true);
      if (localApk.isNotEmpty) {
        final existing =
            preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus') ?? {};
        await preferences.set('mihon.hostStatus', {
          ...existing,
          extension.packageName: status,
        });
      }
      expect(
        await platformChannel.setMihonEnabled(extension.packageName, true),
        true,
      );
      await preferences.set(
        'mihon.enabledPackages',
        <String>{
          ...?preferences
              .get<List<Object?>>('mihon.enabledPackages')
              ?.map((v) => '$v'),
          extension.packageName,
        }.toList(),
      );
      container.invalidate(sourceRegistryProvider);
      await container.read(sourcesProvider.notifier).refresh();
      final snapshot = await container.read(sourcesProvider.future);
      final source = snapshot.enabledEntries
          .map((e) => e.source)
          .whereType<MihonSource>()
          .firstWhere((s) => s.packageName == extension.packageName);
      const action = String.fromEnvironment('JINMAN_ACTION');
      if (action == 'settings') {
        expect(
          await platformChannel.openMihonSettings(
            source.packageName,
            source.hostSourceId,
          ),
          true,
        );
        record['settingsOpened'] = true;
        // ignore: avoid_print
        print('JINMAN_SETTINGS_OPENED');
        await tester.pump(const Duration(seconds: 120));
        record['status'] = 'requests-passed';
        record['readingStatus'] = 'settings only; no reading success';
        return;
      }
      record['stage'] = 'popular';
      final items = await source.discover(source.feeds.first);
      record['popularCount'] = items.length;
      expect(items, isNotEmpty);
      record['stage'] = 'search';
      final found = await source.search(items.first.title);
      record['searchCount'] = found.length;
      expect(found, isNotEmpty);
      record['stage'] = 'detail';
      const phase = String.fromEnvironment(
        'JINMAN_PHASE',
        defaultValue: 'read',
      );
      final saved = preferences.get<Map<dynamic, dynamic>>(
        'acceptance.jinman.item',
      );
      final item = await source.detail(
        phase == 'resume' && saved != null
            ? MediaItem.fromJson(
                saved.cast<String, Object?>(),
                sourceId: source.descriptor.id,
              )
            : found.first,
      );
      final chapters = await source.chapters(item);
      record['chapterCount'] = chapters.length;
      expect(chapters, isNotEmpty);
      record['stage'] = 'pages';
      final pages = await source.content(chapters.first);
      record['pageCount'] = pages.images.length;
      expect(pages.images, isNotEmpty);
      record['stage'] = 'plugin-image';
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse(pages.images[3])))
            .close()
            .timeout(const Duration(seconds: 45));
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
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File(
          '${(await getApplicationDocumentsDirectory()).path}/jinman-plugin-image.png',
        ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
        frame.image.dispose();
        codec.dispose();
      } finally {
        client.close(force: true);
      }
      final library = container.read(libraryRepositoryProvider);
      await library.cacheItem(item);
      await library.saveChapters(
        itemSourceId: item.sourceId,
        itemRemoteId: item.remoteId,
        chapters: chapters,
      );
      if (phase == 'resume') {
        expect(
          await library.chapterPositionOf(
            item.sourceId,
            item.remoteId,
            chapters.first.remoteId,
          ),
          3,
        );
      } else {
        await preferences.set('acceptance.jinman.item', item.toJson());
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
                initialIndex: 0,
              ),
            ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (find.byType(PageView).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(PageView), findsOneWidget);
      final view = tester.widget<PageView>(find.byType(PageView));
      if (phase == 'resume') {
        expect(view.controller!.page!.round(), 3);
      } else {
        view.controller!.jumpToPage(3);
      }
      await tester.pump(const Duration(seconds: 3));
      expect(
        await library.chapterPositionOf(
          item.sourceId,
          item.remoteId,
          chapters.first.remoteId,
        ),
        3,
      );
      final layer = binding.renderViews.first.debugLayer! as OffsetLayer;
      final shot = await layer.toImage(
        Offset.zero & binding.renderViews.first.flutterView.physicalSize,
      );
      final png = await shot.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${(await getApplicationDocumentsDirectory()).path}/jinman-reader-$phase.png',
      ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
      shot.dispose();
      record['persistedPage'] = 3;
      record['phase'] = phase;
      record['readingStatus'] = 'plugin image decoded and production reader page 4; visual review separate';
      record['status'] = 'requests-passed';
    } catch (error) {
      record['status'] = 'failed';
      record['errorType'] = error.runtimeType.toString();
      // APK diagnostics are non-account errors. Remove any URL query/header data.
      record['error'] = '$error'.replaceAll(RegExp(r'https?://\S+'), '[URL]');
    } finally {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/jinman-live.json')
          .writeAsString(jsonEncode(record), flush: true);
      // ignore: avoid_print
      print('JINMAN_LIVE_EVIDENCE ${jsonEncode(record)}');
    }
    expect(
      record['status'],
      'requests-passed',
      reason: 'Preserve actual APK failure as acceptance failure',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
