import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/app_database.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/manga/manga_source_layout.dart';
import 'package:triomi/features/manga/manga_source_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const _layoutLabels = ['松散网格', '全景松散网格', '紧凑网格', '列表'];
const _layoutNames = ['comfortable', 'panorama', 'compact', 'list'];
const _coverUrl = 'https://layout.test/cover.png';
String _title(int index) => '漫画 $index：足够长的作品名称用于检查两行标题与大字体布局';

class _LayoutSource implements DiscoverProvider {
  @override
  SourceDescriptor get descriptor => const SourceDescriptor(
    id: 'layout-catalog',
    name: '漫画目录',
    type: MediaType.manga,
    kind: SourceKind.plugin,
  );

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => const [
    DiscoverFeed(id: 'popular', name: '热门漫画'),
  ];

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async =>
      page != 1
      ? const []
      : [
          for (var index = 0; index < 24; index++)
            MediaItem(
              sourceId: descriptor.id,
              remoteId: '$index',
              type: MediaType.manga,
              title: _title(index),
              coverUrl: _coverUrl,
            ),
        ];
}

class _LayoutSources extends SourceRegistryController {
  _LayoutSources(this.source);
  final _LayoutSource source;

  @override
  Future<SourceRegistrySnapshot> build() async => SourceRegistrySnapshot(
    entries: [
      SourceEntry(descriptor: source.descriptor, source: source, enabled: true),
    ],
    failures: const [],
  );
}

class _LayoutHarness {
  _LayoutHarness(this.tester, this.container, this.database);
  final WidgetTester tester;
  final ProviderContainer container;
  final AppDatabase database;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() async {
      container.dispose();
      await database.close();
    });
  }
}

Future<_LayoutHarness> _openCatalog(
  WidgetTester tester, {
  Preferences? preferences,
  double textScale = 1,
}) async {
  final database = openTestDatabase();
  final source = _LayoutSource();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final http = FakeHttpClient((request) async {
    throw StateError('Unexpected catalogue HTTP request: ${request.url}');
  })..bytesHandler = (_) => png;
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      preferencesProvider.overrideWithValue(preferences ?? memoryPreferences()),
      sourcesProvider.overrideWith(() => _LayoutSources(source)),
      sourceHttpClientProvider.overrideWithValue(http),
    ],
  );
  final harness = _LayoutHarness(tester, container, database);
  addTearDown(harness.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: MangaSourcePage(sourceId: source.descriptor.id),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text(_title(0)), findsOneWidget);
  return harness;
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _tile(int index) => find
    .ancestor(of: find.text(_title(index)), matching: find.byType(InkWell))
    .first;

Finder _cover(int index) =>
    find.descendant(of: _tile(index), matching: find.byType(MediaCover));

Future<void> _chooseLayout(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('显示布局'));
  await tester.pumpAndSettle();
  for (final option in _layoutLabels) {
    expect(find.text(option), findsOneWidget);
  }
  await tester.tap(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(CheckedPopupMenuItem<MangaSourceLayout>),
    ),
  );
  await tester.pumpAndSettle();
}

BoxFit? _imageFit(WidgetTester tester, int index) => tester
    .widget<Image>(
      find.descendant(of: _cover(index), matching: find.byType(Image)),
    )
    .fit;

void _expectPresentation(WidgetTester tester, String label) {
  final cover = tester.getRect(_cover(0));
  final title = tester.getRect(find.text(_title(0)));
  final tile = tester.getRect(_tile(0));
  expect(cover.width, greaterThan(0));
  expect(cover.height, greaterThan(0));
  expect(title.left, greaterThanOrEqualTo(tile.left));
  expect(title.right, lessThanOrEqualTo(tile.right));
  expect(title.bottom, lessThanOrEqualTo(tile.bottom + 0.01));
  if (label == '列表') {
    expect(title.left, greaterThanOrEqualTo(cover.right));
    expect(cover.width, lessThan(tile.width / 3));
    expect(tester.getRect(_cover(1)).top, greaterThan(cover.bottom));
    expect(_imageFit(tester, 0), BoxFit.cover);
  } else {
    expect(cover.left, closeTo(tile.left, 0.01));
    expect(cover.right, closeTo(tile.right, 0.01));
    expect(cover.width / cover.height, closeTo(2 / 3, 0.001));
    if (label == '紧凑网格') {
      expect(title.overlaps(cover), isTrue);
      expect(cover.bottom, closeTo(tile.bottom, 0.01));
      expect(_imageFit(tester, 0), BoxFit.cover);
    } else {
      expect(title.top, greaterThanOrEqualTo(cover.bottom));
      expect(
        _imageFit(tester, 0),
        label == '全景松散网格' ? BoxFit.contain : BoxFit.cover,
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() {
    // Bypass device-local cover storage; image bytes come only from FakeHttpClient.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async {
          throw MissingPluginException(
            'No device cover storage in layout tests',
          );
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final width in [360.0, 412.0]) {
    testWidgets(
      'phone $width uses two equal full-width covers with symmetric margins',
      (tester) async {
        _setViewport(tester, Size(width, 1000));
        await _openCatalog(tester);
        final first = tester.getRect(_cover(0));
        final second = tester.getRect(_cover(1));
        final third = tester.getRect(_cover(2));
        expect(first.top, closeTo(second.top, 0.01));
        expect(third.top, greaterThan(first.bottom));
        expect(first.width, closeTo(second.width, 0.01));
        expect(first.width, greaterThan(width * 0.4));
        expect(first.left, greaterThan(0));
        expect(first.left, closeTo(width - second.right, 0.01));
        expect((first.left + second.right) / 2, closeTo(width / 2, 0.01));
        expect(first.width, closeTo(tester.getSize(_tile(0)).width, 0.01));
        expect(second.width, closeTo(tester.getSize(_tile(1)).width, 0.01));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop fills multiple equal columns with symmetric outer margins',
    (tester) async {
      const width = 1200.0;
      _setViewport(tester, const Size(width, 1000));
      await _openCatalog(tester);
      final covers = tester.getRect(_cover(0));
      final firstRow = <Rect>[];
      for (var index = 0; index < 24; index++) {
        if (_cover(index).evaluate().isEmpty) break;
        final rect = tester.getRect(_cover(index));
        if ((rect.top - covers.top).abs() > 0.01) break;
        firstRow.add(rect);
      }
      expect(firstRow.length, greaterThan(2));
      expect(firstRow.first.left, greaterThan(0));
      expect(firstRow.first.left, closeTo(width - firstRow.last.right, 0.01));
      final gap = firstRow[1].left - firstRow[0].right;
      expect(gap, greaterThan(0));
      for (var index = 0; index < firstRow.length; index++) {
        expect(firstRow[index].width, closeTo(firstRow.first.width, 0.01));
        expect(
          firstRow[index].width,
          closeTo(tester.getSize(_tile(index)).width, 0.01),
        );
        if (index > 0) {
          expect(
            firstRow[index].left - firstRow[index - 1].right,
            closeTo(gap, 0.01),
          );
        }
      }
      expect(
        tester.getRect(_cover(firstRow.length)).top,
        greaterThan(covers.bottom),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all four popup choices change the visible catalogue presentation',
    (tester) async {
      _setViewport(tester, const Size(412, 1000));
      await _openCatalog(tester);
      // Enter from another mode so comfortable is exercised through the menu too.
      await _chooseLayout(tester, '列表');
      _expectPresentation(tester, '列表');
      await _chooseLayout(tester, '松散网格');
      _expectPresentation(tester, '松散网格');
      final comfortableHeight = tester.getSize(_tile(0)).height;
      final comfortableCover = tester.getRect(_cover(0));
      await _chooseLayout(tester, '全景松散网格');
      _expectPresentation(tester, '全景松散网格');
      expect(tester.getRect(_cover(0)), comfortableCover);
      await _chooseLayout(tester, '紧凑网格');
      _expectPresentation(tester, '紧凑网格');
      expect(tester.getSize(_tile(0)).height, lessThan(comfortableHeight));
      await _chooseLayout(tester, '列表');
      _expectPresentation(tester, '列表');
      expect(tester.takeException(), isNull);
    },
  );

  for (var index = 0; index < _layoutLabels.length; index++) {
    final label = _layoutLabels[index];
    final savedName = _layoutNames[index];
    testWidgets(
      '$label selection survives reopening the page and provider scope',
      (tester) async {
        _setViewport(tester, const Size(412, 1000));
        final preferences = memoryPreferences();
        final initial = await _openCatalog(tester, preferences: preferences);
        await _chooseLayout(tester, label == '列表' ? '紧凑网格' : '列表');
        await _chooseLayout(tester, label);
        expect(preferences.get<String>('manga.source.layout'), savedName);
        await initial.close();
        await _openCatalog(tester, preferences: preferences);
        _expectPresentation(tester, label);
        await tester.tap(find.byTooltip('显示布局'));
        await tester.pumpAndSettle();
        final selected = tester.widgetList<CheckedPopupMenuItem<dynamic>>(
          find.byWidgetPredicate(
            (widget) => widget is CheckedPopupMenuItem && widget.checked,
          ),
        );
        expect(selected, hasLength(1));
        expect(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is CheckedPopupMenuItem && widget.checked,
            ),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.ancestor(
            of: find.text(label),
            matching: find.byType(CheckedPopupMenuItem<MangaSourceLayout>),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$label remains usable at 320dp with double-sized text', (
      tester,
    ) async {
      _setViewport(tester, const Size(320, 900));
      await _openCatalog(tester, textScale: 2);
      await _chooseLayout(tester, label);
      _expectPresentation(tester, label);
      final viewport = tester.getRect(find.byType(MangaSourcePage));
      final cover = tester.getRect(_cover(0));
      final title = tester.getRect(find.text(_title(0)));
      expect(cover.left, greaterThanOrEqualTo(viewport.left));
      expect(cover.right, lessThanOrEqualTo(viewport.right));
      expect(title.left, greaterThanOrEqualTo(viewport.left));
      expect(title.right, lessThanOrEqualTo(viewport.right));
      expect(find.byTooltip('显示布局').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
