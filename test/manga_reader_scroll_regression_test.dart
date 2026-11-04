import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/downloads/data/download_providers.dart';
import 'package:triomi/features/downloads/data/download_repository.dart';
import 'package:triomi/features/reader/manga_page_image.dart';
import 'package:triomi/features/reader/manga_reader_page.dart';
import 'package:triomi/features/reader/reader_settings.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

class _Pages implements ContentSource, ContentProvider {
  @override
  final descriptor = const SourceDescriptor(
    id: 'scroll-regression',
    name: 'Isolated pages',
    type: MediaType.manga,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.content},
  );
  @override
  bool get isReady => true;
  @override
  Future<ChapterContent> content(Chapter chapter) async => ChapterContent(
    images: [for (var i = 0; i < 176; i++) 'https://pages.invalid/$i.png'],
  );
}

class _Sources extends SourceRegistryController {
  @override
  Future<SourceRegistrySnapshot> build() async {
    final source = _Pages();
    return SourceRegistrySnapshot(
      entries: [
        SourceEntry(
          descriptor: source.descriptor,
          source: source,
          enabled: true,
        ),
      ],
      failures: const [],
    );
  }
}

class _Downloads extends DownloadRepository {
  _Downloads(super.db);
  @override
  Future<String?> localImageDir(
    String sourceId,
    String chapterRemoteId,
  ) async => null;
}

class _DelayedImages extends FakeHttpClient {
  _DelayedImages() : super((_) async => throw StateError('No metadata HTTP'));
  final pending = <String, Completer<List<int>>>{};
  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) => pending.putIfAbsent(url, Completer<List<int>>.new).future;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await _settle(tester);
  }
  expect(
    ready(),
    true,
    reason: 'Reader must reach the requested fixture state',
  );
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  String description,
) async {
  const raw = String.fromEnvironment('TRIOMI_READER_PORT_CAPTURE_URL');
  if (raw.isEmpty) return;
  final base = Uri.parse(raw);
  expect(base.host, '127.0.0.1');
  await tester.runAsync(() async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(base.resolve('/__tour/capture'));
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'name': name,
          'route': '/reader/scroll-regression',
          'description': description,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 50),
      );
      await response.drain<void>();
      expect(response.statusCode, 200);
    } finally {
      client.close(force: true);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ReadingMode.values) {
    testWidgets(
      'reader ${mode.name} bounds pending images and preserves page after decode failures',
      (tester) async {
        if (!Platform.isIOS) {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
        }
        final db = openTestDatabase();
        final http = _DelayedImages();
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(memoryPreferences()),
            secureStoreProvider.overrideWithValue(MemorySecureStore()),
            sourceHttpClientProvider.overrideWithValue(http),
            sourcesProvider.overrideWith(_Sources.new),
            downloadRepositoryProvider.overrideWithValue(_Downloads(db)),
          ],
        );
        await container.read(readerSettingsProvider.notifier).setMode(mode);
        const platform = MethodChannel('triomi/platform');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, (_) async => null);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          for (final gate in http.pending.values) {
            if (!gate.isCompleted) gate.complete(Uint8List(0));
          }
          await _settle(tester);
          await tester.runAsync(() async {
            container.dispose();
            await db.close();
          });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(platform, null);
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: MangaReaderPage(
                args: MangaReaderArgs(
                  item: MediaItem(
                    sourceId: 'scroll-regression',
                    remoteId: 'book',
                    title: 'Isolated reader',
                    type: MediaType.manga,
                  ),
                  chapters: [
                    Chapter(
                      sourceId: 'scroll-regression',
                      remoteId: 'chapter',
                      title: '176 delayed pages',
                      url: 'https://pages.invalid/chapter',
                    ),
                  ],
                  initialIndex: 0,
                ),
              ),
            ),
          ),
        );
        await _until(tester, () => find.text('1/176').evaluate().isNotEmpty);
        expect(find.text('1/176'), findsOneWidget);
        expect(
          http.pending.length,
          lessThan(12),
          reason: 'Pending tiles must not collapse and mount a chapter at once',
        );
        if (mode == ReadingMode.webtoon) {
          expect(
            tester.getSize(find.byType(MangaPageImage).first).height,
            greaterThan(300),
            reason: 'Loading and failure states reserve readable page geometry',
          );
          await _capture(
            tester,
            '07_webtoon_delayed.png',
            '176 delayed synthetic pages: viewport-sized pending tiles and bounded requests',
          );
          await tester.drag(
            find.byType(MangaReaderPage),
            const Offset(0, -250),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(http.pending.length, lessThan(12));
          expect(find.text('176/176'), findsNothing);
        } else {
          final size = tester.getSize(find.byType(PageView));
          final gesture = switch (mode) {
            ReadingMode.ltr => Offset(-size.width * .75, 0),
            ReadingMode.rtl => Offset(size.width * .75, 0),
            ReadingMode.vertical => Offset(0, -size.height * .75),
            ReadingMode.webtoon => throw StateError('Handled above'),
          };
          await tester.drag(find.byType(PageView), gesture);
          await tester.pump(const Duration(seconds: 1));
          await _settle(tester);
          expect(find.text('2/176'), findsOneWidget);
          expect(http.pending.length, lessThan(12));
        }
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.teal, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await tester.runAsync(() => picture.toImage(30, 45));
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.png),
        );
        image!.dispose();
        picture.dispose();
        for (final entry in http.pending.entries.toList()) {
          entry.value.complete(
            entry.key.endsWith('/0.png')
                ? bytes!.buffer.asUint8List()
                : Uint8List(0),
          );
        }
        await _until(tester, () => find.text('重新加载').evaluate().isNotEmpty);
        expect(tester.takeException(), isNull);
        expect(find.text('176/176'), findsNothing);
        if (mode == ReadingMode.webtoon) {
          expect(
            http.pending.length,
            lessThan(16),
            reason: 'Errors must not shrink into a request avalanche',
          );
          await _capture(
            tester,
            '08_webtoon_decode_error.png',
            'Late synthetic first image and explicit decode failures retain page geometry',
          );
          await tester.fling(
            find.byType(MangaReaderPage),
            const Offset(0, -600),
            3000,
          );
          await tester.pump(const Duration(milliseconds: 1000));
          expect(tester.takeException(), isNull);
          expect(find.text('176/176'), findsNothing);
          expect(
            http.pending.length,
            lessThan(20),
            reason: 'A fast gesture must not traverse all pending pages',
          );
          await _capture(
            tester,
            '09_webtoon_after_fling.png',
            'Fast vertical fling after decode errors: no jump to chapter end or framework exception',
          );
        }
      },
    );
  }
}
