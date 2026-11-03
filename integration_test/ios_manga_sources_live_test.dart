// Anonymous upstream acceptance, not a fixture/protocol unit test. Run on iOS:
// flutter test integration_test/ios_manga_sources_live_test.dart -d <simulator>
// Every source is required: network errors are failures, never skips. Production
// UI/screenshots/video are a separate gate; this suite cannot certify those.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/ios_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/widgets/source_network_image.dart';

import '../test/fixtures/fake_preferences.dart';
import 'fixtures/ios_test_binding.dart';
import 'fixtures/manga_sources_live.dart';

Future<Map<String, Object?>> _decodePage(
  SourceNetworkImage provider,
  int pageIndex,
) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final decoded = Completer<ImageInfo>();
  final listener = ImageStreamListener(
    (image, synchronousCall) {
      if (!decoded.isCompleted) decoded.complete(image.clone());
    },
    onError: (Object error, StackTrace? stack) {
      if (!decoded.isCompleted) decoded.completeError(error, stack);
    },
  );
  ImageInfo? image;
  stream.addListener(listener);
  try {
    image = await decoded.future.timeout(const Duration(seconds: 35));
    expect(image.image.width, greaterThan(32));
    expect(image.image.height, greaterThan(32));
    final pixels = await image.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(pixels, isNotNull, reason: 'The actual iOS decoder must expose pixels');
    final bytes = pixels!.buffer.asUint8List(
      pixels.offsetInBytes,
      pixels.lengthInBytes,
    );
    final uri = Uri.parse(provider.url);
    return {
      'pageIndex': pageIndex,
      'host': uri.host,
      'path': uri.path,
      // Do not persist signed URLs/query strings, image files or credentials.
      // This is explicitly the decoded pixel hash, not an HTTP body hash.
      'decodedRgbaBytes': bytes.length,
      'decodedRgbaSha256': sha256.convert(bytes).toString(),
      'width': image.image.width,
      'height': image.image.height,
      'requestHeaderNames': provider.headers.keys.toList()..sort(),
    };
  } finally {
    stream.removeListener(listener);
    image?.dispose();
    await provider.evict();
  }
}

MediaItem _selectItem(MangaSourceLiveCase sample, List<MediaItem> items) {
  final candidates = items.where((item) {
    if (sample.remoteId != null) return item.remoteId == sample.remoteId;
    return RegExp(sample.titlePattern!, caseSensitive: false).hasMatch(item.title);
  }).toList()..sort((a, b) => a.remoteId.compareTo(b.remoteId));
  expect(candidates, isNotEmpty,
      reason: '${sample.id}: live results must contain the specified ordinary work');
  return candidates.first;
}

Chapter _selectChapter(MangaSourceLiveCase sample, List<Chapter> chapters) {
  final candidates = chapters.where((chapter) => !chapter.locked &&
      (sample.chapterId == null || chapter.remoteId == sample.chapterId)).toList();
  candidates.sort((a, b) {
    final number = (a.number ?? double.infinity).compareTo(b.number ?? double.infinity);
    if (number != 0) return number;
    final order = a.sortIndex.compareTo(b.sortIndex);
    return order != 0 ? order : a.remoteId.compareTo(b.remoteId);
  });
  expect(candidates, isNotEmpty,
      reason: '${sample.id}: the specified public chapter must remain readable');
  return candidates.first;
}

void main() {
  initializeIosIntegrationBinding();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final records = <Map<String, Object?>>[];

  Map<String, Object?> summary() => {
    'environment': 'iOS production SourceRegistry + JsSource + IosJsRuntime + '
        'sourceHttpClientProvider + SourceNetworkImage / actual image decoder',
    'accounts': 'Empty isolated preferences and secure store; no account writes',
    'expectedSourceIds': [for (final sample in mangaSourcesLiveCases) sample.id],
    'complete': records.length == mangaSourcesLiveCases.length,
    'passed': records.where((record) => record['status'] == 'passed').length,
    'failed': records.where((record) => record['status'] == 'failed').length,
    'sources': records,
    'notValidated': ['production UI/visual tour', 'signed device install',
      'account/login/paid access', 'full Android feature parity'],
  };

  for (final sample in mangaSourcesLiveCases) {
    testWidgets('live public manga reading: ${sample.id}', (tester) async {
      final record = <String, Object?>{
        'source': sample.id,
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'status': 'running',
        'stage': 'platform',
        'selection': {
          'query': sample.query,
          'expectedRemoteId': sample.remoteId,
          'expectedTitlePattern': sample.titlePattern,
          'expectedChapterId': sample.chapterId,
        },
      };
      final cancellation = SourceRequestCancellation();
      AppDatabase? database;
      ProviderContainer? container;
      final elapsed = Stopwatch()..start();
      try {
        expect(Platform.isIOS, isTrue,
            reason: 'A desktop engine cannot certify the native iOS port');
        record['stage'] = 'installProductionRegistry';
        final ruleText = await rootBundle.loadString(sample.asset);
        final rule = SourceRule.parseJson(ruleText);
        expect(rule.descriptor.id, sample.id);
        record['ruleSha256'] = sha256.convert(utf8.encode(ruleText)).toString();
        database = AppDatabase.forTesting(NativeDatabase.memory());
        container = ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(database),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
        ]);
        final scope = container;
        await cancellation.run(() async {
          await scope.read(sourceRepositoryProvider).upsert(
            id: sample.id,
            name: rule.descriptor.name,
            type: MediaType.manga,
            kind: SourceKind.plugin,
            lang: rule.descriptor.lang,
            version: rule.descriptor.version,
            ruleText: ruleText,
            enabled: true,
          );
          final registry = scope.read(sourceRegistryProvider);
          final snapshot = await registry.load();
          expect(snapshot.failures, isEmpty);
          final entry = snapshot.enabledEntries.single;
          expect(entry.source, isA<JsSource>());
          final source = entry.source as JsSource;
          expect(source.runtime, isA<IosJsRuntime>());
          final http = scope.read(sourceHttpClientProvider);
          expect(http, isA<DioSourceHttpClient>());
          record['stage'] = 'initialize';
          await source.initialize();
          record['capabilities'] = [
            for (final capability in source.descriptor.capabilities) capability.name,
          ]..sort();
          expect(source.feeds, isNotEmpty);
          record['stage'] = 'discover';
          final discovered = await source.discover(source.feeds.first);
          record['discoverCount'] = discovered.length;
          expect(discovered, isNotEmpty,
              reason: 'Empty discovery is not a live reading pass');
          final supportsSearch = source.descriptor.supports(SourceCapability.search);
          record['searchSupported'] = supportsSearch;
          late final MediaItem item;
          if (sample.query != null) {
            expect(supportsSearch, isTrue,
                reason: 'A formerly supported search cannot silently disappear');
            record['stage'] = 'search';
            final searched = await source.search(sample.query!);
            record['searchCount'] = searched.length;
            item = _selectItem(sample, searched);
          } else {
            expect(supportsSearch, isFalse,
                reason: 'Update this acceptance contract if public search is restored');
            // Pinned observed public URL, not an invented response. Discovery
            // still ran above; detail and all pages must now come from upstream.
            item = MediaItem(
              sourceId: sample.id, remoteId: sample.remoteId!,
              title: sample.title!, url: sample.url!, type: MediaType.manga,
            );
            record['selectionRoute'] = 'observed canonical URL (browse-only source)';
          }
          record['stage'] = 'detail';
          final detail = await source.detail(item);
          expect(detail.remoteId, item.remoteId);
          expect(detail.title.trim(), isNotEmpty);
          record['item'] = {
            'id': detail.remoteId, 'title': detail.title, 'url': detail.url,
          };
          record['stage'] = 'chapters';
          final chapters = await source.chapters(item);
          record['chapterCount'] = chapters.length;
          expect(chapters, isNotEmpty);
          final chapter = _selectChapter(sample, chapters);
          record['chapter'] = {
            'id': chapter.remoteId, 'title': chapter.title, 'url': chapter.url,
          };
          record['stage'] = 'content';
          final content = await source.content(chapter);
          record['pageCount'] = content.images.length;
          expect(content.images, isNotEmpty,
              reason: 'A chapter must resolve actual page URLs, not website-only success');
          for (final image in content.images) {
            final uri = Uri.parse(image);
            expect(uri.scheme, 'https');
            expect(uri.host, isNotEmpty);
            expect(uri.userInfo, isEmpty);
          }
          final pageIndices = <int>{0, content.images.length ~/ 2,
            content.images.length - 1}.toList()..sort();
          final images = <Map<String, Object?>>[];
          record['images'] = images;
          for (final index in pageIndices) {
            record['stage'] = 'decodeImage:$index';
            images.add(await _decodePage(SourceNetworkImage(
              content.images[index], http: http, sourceId: sample.id,
              headers: content.imageHeaders,
            ), index));
          }
          record['status'] = 'passed';
          record['stage'] = 'complete';
        }).timeout(const Duration(minutes: 4), onTimeout: () {
          cancellation.cancel('Live source acceptance deadline exceeded');
          throw TimeoutException('${sample.id}: public reading exceeded four minutes');
        });
      } catch (error) {
        record['status'] = 'failed';
        record['error'] = SourceException.sanitizeMessage('$error');
        rethrow;
      } finally {
        cancellation.cancel('Live source acceptance finished');
        container?.dispose();
        await database?.close();
        elapsed.stop();
        record['elapsedMilliseconds'] = elapsed.elapsedMilliseconds;
        records.add(record);
        binding.reportData = {'mangaSourcesLive': summary()};
        final documents = await getApplicationDocumentsDirectory();
        final directory = Directory('${documents.path}/manga-sources-live');
        await directory.create(recursive: true);
        await File('${directory.path}/runtime-${sample.id}.json').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(record)}\n', flush: true,
        );
        await File('${documents.path}/manga-sources-live.json').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(summary())}\n', flush: true,
        );
        // ignore: avoid_print
        print('MANGA_SOURCE_LIVE ${jsonEncode(record)}');
        // Give native session-disposal messages a turn before the next source.
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('all seventeen production iOS public reading contracts are required', () {
    expect(mangaSourcesLiveCases, hasLength(17));
    expect(records, hasLength(17), reason: 'Missing sources cannot count as a pass');
    expect(records.map((record) => record['source']).toSet(),
        {for (final sample in mangaSourcesLiveCases) sample.id});
    expect(records.where((record) => record['status'] != 'passed'), isEmpty,
        reason: 'Network or decode failures are release blockers, not skips');
  });
}
