import 'dart:async';
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
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/text/zh_converter.dart';
import 'package:triomi/core/widgets/image_viewer.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/novel/reader/novel_reader_page.dart';
import 'package:triomi/features/novel/reader/novel_reader_settings.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/png_image.dart';
import 'fixtures/test_database.dart';

const _sourceId = 'novel-illustration-regression';
const _chapters = [
  Chapter(
    sourceId: _sourceId,
    remoteId: 'one',
    title: 'First chapter',
    url: 'https://novel.example/books/one',
  ),
  Chapter(
    sourceId: _sourceId,
    remoteId: 'two',
    title: 'Second chapter',
    url: 'https://novel.example/books/two',
    sortIndex: 1,
  ),
];

Map<String, String> _headers(int chapter) => {
  'Referer': _chapters[chapter].url!,
  'User-Agent': 'Novel images/1',
};

const _unavailable = SourceException(
  sourceId: _sourceId,
  type: SourceErrorType.network,
  statusCode: 503,
  message: 'HTTP 503 from https://images.example/page.png?secret=hidden',
);

typedef _ImageRequest = ({
  String url,
  String sourceId,
  Map<String, String> headers,
});

class _Images extends FakeHttpClient {
  _Images(this.respond)
    : super((_) async => throw StateError('Unexpected metadata request'));

  Future<List<int>> Function(_ImageRequest request) respond;
  final images = <_ImageRequest>[];

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const {},
    String method = 'GET',
  }) {
    final request = (
      url: url,
      sourceId: sourceId,
      headers: Map<String, String>.of(headers),
    );
    images.add(request);
    return respond(request);
  }
}

class _Novel extends ContentProvider {
  _Novel(this.html);
  final String html;
  int calls = 0;

  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: _sourceId,
    name: 'Illustration regression',
    type: MediaType.novel,
    kind: SourceKind.builtin,
    capabilities: {SourceCapability.content},
  );

  @override
  bool get isReady => true;

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    calls++;
    return ChapterContent(
      html: html,
      imageHeaders: _headers(chapter.remoteId == 'one' ? 0 : 1),
    );
  }
}

class _Sources extends SourceRegistryController {
  _Sources(this.source);
  final _Novel source;

  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const [],
  );
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _decoded(WidgetTester tester, Finder tile) async {
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 5)) {
    await tester.pump(const Duration(milliseconds: 30));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    final images = tester.widgetList<RawImage>(
      find.descendant(of: tile, matching: find.byType(RawImage)),
    );
    if (images.any((image) => image.image != null)) return;
  }
  fail('The retried illustration did not decode');
}

Future<void> _expectPixel(WidgetTester tester, Finder tile, int red) async {
  await _decoded(tester, tile);
  final image = tester
      .widget<RawImage>(
        find.descendant(of: tile, matching: find.byType(RawImage)),
      )
      .image!;
  final pixels = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  expect(pixels.buffer.asUint8List(), [red, 0, 0, 255]);
}

String? _indicator(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .whereType<String>()
    .where((text) => RegExp(r'^\d+ / \d+$').hasMatch(text))
    .firstOrNull;

Future<({ProviderContainer container, List<Uint8List> saved})> _open(
  WidgetTester tester, {
  required _Images images,
  required _Novel source,
  NovelReadingMode mode = NovelReadingMode.paged,
}) async {
  await tester.runAsync(ZhConverter.instance);
  final db = openTestDatabase();
  final preferences = memoryPreferences();
  await NovelReaderSettings(mode: mode, keepScreenOn: false).save(preferences);
  final docs = Directory.systemTemp.createTempSync('novel_illustration_');
  final saved = <Uint8List>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const platform = MethodChannel('triomi/platform');
  messenger.setMockMethodCallHandler(paths, (_) async => docs.path);
  messenger.setMockMethodCallHandler(platform, (call) async {
    if (call.method == 'saveImageToGallery') {
      saved.add((call.arguments as Map)['bytes'] as Uint8List);
      return 'gallery/saved.png';
    }
    return null;
  });
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(preferences),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourcesProvider.overrideWith(() => _Sources(source)),
      sourceHttpClientProvider.overrideWithValue(images),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await _advance(tester);
    container.dispose();
    await db.close();
    docs.deleteSync(recursive: true);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(platform, null);
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: NovelReaderPage(
          args: NovelReaderArgs(
            item: const MediaItem(
              sourceId: _sourceId,
              remoteId: 'book',
              title: 'Illustrations',
              type: MediaType.novel,
            ),
            chapters: _chapters,
            initialIndex: 0,
          ),
        ),
      ),
    ),
  );
  await _advance(tester);
  return (container: container, saved: saved);
}

void main({Future<void> Function(String name)? capture}) {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in NovelReadingMode.values) {
    testWidgets(
      '${mode.name}: manual retry decodes source bytes without reflow',
      (tester) async {
        final (html, expectedUrl) = switch (mode) {
          NovelReadingMode.paged => (
            '<img src="http://images.example/page.png?token=a%2Fb&amp;redirect=https://novel.example/origin" alt="A > B" width=400 height=300>',
            'http://images.example/page.png?token=a%2Fb&redirect=https://novel.example/origin',
          ),
          NovelReadingMode.card => (
            '<img src="https://images.example/placeholder.gif" data-src="//images.example/page.png?token=a%2Fb&amp;size=large" width=400 height=300>',
            'https://images.example/page.png?token=a%2Fb&size=large',
          ),
          NovelReadingMode.scroll => (
            '<img src="data:image/gif;base64,placeholder" data-original="../art/page.png?token=a%2Fb&amp;size=large" width=400 height=300>',
            'https://novel.example/art/page.png?token=a%2Fb&size=large',
          ),
        };
        final source = _Novel(html);
        var available = false;
        final png = onePixelPng(173);
        final images = _Images((_) async {
          if (!available) throw _unavailable;
          return png;
        });
        final harness = await _open(
          tester,
          images: images,
          source: source,
          mode: mode,
        );
        final tile = find.byType(RetryableImage);
        expect(find.text('重新加载'), findsOneWidget);
        expect(find.textContaining('HTTP 503'), findsOneWidget);
        expect(find.textContaining('secret=hidden'), findsNothing);
        expect(images.images, hasLength(1));
        expect(images.images.single.url, expectedUrl);
        expect(images.images.single.sourceId, _sourceId);
        expect(images.images.single.headers, _headers(0));
        final geometry = tester.getRect(tile);
        final indicator = _indicator(tester);
        final library = harness.container.read(libraryRepositoryProvider);
        final position = await tester.runAsync(
          () => library.chapterPositionOf(_sourceId, 'book', 'one'),
        );
        await _advance(tester);
        expect(images.images, hasLength(1), reason: 'No automatic retry loop');
        if (mode == NovelReadingMode.paged) {
          await capture?.call('novel-image-failed');
        }

        available = true;
        await tester.tap(find.text('重新加载'));
        await _expectPixel(tester, tile, 173);
        expect(find.text('插图加载失败'), findsNothing);
        expect(tester.getRect(tile), geometry);
        expect(_indicator(tester), indicator);
        expect(images.images, hasLength(2));
        expect(images.images.last.url, expectedUrl);
        expect(images.images.last.sourceId, _sourceId);
        expect(images.images.last.headers, _headers(0));
        expect(source.calls, 1, reason: 'Retry must not reload the chapter');
        if (mode == NovelReadingMode.paged) {
          await capture?.call('novel-image-retried');
        }
        expect(
          await tester.runAsync(
            () => library.chapterPositionOf(_sourceId, 'book', 'one'),
          ),
          position,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('full-screen retry and gallery save preserve chapter identity', (
    tester,
  ) async {
    var available = false;
    final png = onePixelPng(91);
    final images = _Images((_) async {
      if (!available) throw _unavailable;
      return png;
    });
    final harness = await _open(
      tester,
      images: images,
      source: _Novel('<img src="https://images.example/page.png">'),
    );
    final inline = find.byType(RetryableImage);
    final bounds = tester.getRect(inline);
    await tester.tapAt(bounds.topLeft + const Offset(12, 12));
    await _advance(tester);
    final viewer = find.descendant(
      of: find.byType(InteractiveViewer),
      matching: find.byType(RetryableImage),
    );
    final retry = find.descendant(of: viewer, matching: find.text('重新加载'));
    expect(retry, findsOneWidget);
    expect(images.images, hasLength(2));
    await tester.longPressAt(tester.getTopLeft(viewer) + const Offset(24, 80));
    await _advance(tester);
    expect(harness.saved, isEmpty);
    expect(find.textContaining('图片数据获取失败：').hitTestable(), findsOneWidget);
    expect(find.textContaining('secret=hidden'), findsNothing);
    expect(images.images, hasLength(3));
    available = true;
    await tester.tap(retry);
    await _expectPixel(tester, viewer, 91);
    await capture?.call('novel-fullscreen-retried');
    expect(images.images, hasLength(4));
    await tester.longPress(viewer);
    await _advance(tester);
    expect(harness.saved.single, orderedEquals(png));
    expect(images.images, hasLength(5));
    for (final request in images.images) {
      expect(request.url, 'https://images.example/page.png');
      expect(request.sourceId, _sourceId);
      expect(request.headers, _headers(0));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late retried bytes from a previous chapter never replace the next',
    (tester) async {
      final delayed = Completer<List<int>>();
      var firstAttempts = 0;
      final images = _Images((request) async {
        if (request.headers['Referer'] == _chapters[1].url) {
          return onePixelPng(202);
        }
        if (++firstAttempts == 1) throw _unavailable;
        return delayed.future;
      });
      final source = _Novel('<img src="https://images.example/shared.png">');
      await _open(tester, images: images, source: source);
      await tester.tap(find.text('重新加载'));
      await _advance(tester);
      expect(firstAttempts, 2);
      final reader = tester.getRect(find.byType(NovelReaderPage));
      await tester.tapAt(reader.bottomRight - const Offset(24, 120));
      await _advance(tester);
      final tile = find.byType(RetryableImage);
      await _expectPixel(tester, tile, 202);
      delayed.complete(onePixelPng(17));
      await _advance(tester);
      await _expectPixel(tester, tile, 202);
      expect(source.calls, 2);
      expect(images.images.map((request) => request.headers['Referer']), [
        _chapters[0].url,
        _chapters[0].url,
        _chapters[1].url,
      ]);
      expect(find.text('重新加载'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
