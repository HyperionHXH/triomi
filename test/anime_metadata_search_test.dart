import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/router/app_router.dart';
import 'package:triomi/core/source/bangumi_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/features/detail/detail_page.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/player/episode_selector.dart';
import 'package:triomi/features/player/player_page.dart';
import 'package:triomi/features/search/search_page.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

SourceResponse _results(String name, {int id = 42}) => SourceResponse(
  statusCode: 200,
  body: jsonEncode({
    'total': 1,
    'data': [
      {'id': id, 'type': 2, 'name_cn': name},
    ],
  }),
);

Future<void> _advance(WidgetTester tester) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var index = 0; index < 100 && !ready(); index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Wait for the observable native search result',
  );
}

Future<void> _search(WidgetTester tester, String value) async {
  final field = find.byType(TextField);
  // Submission unfocuses the field; native input must reconnect before editing.
  await tester.tap(field);
  await tester.pump();
  await tester.enterText(field, value);
  expect(
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
    isTrue,
  );
  expect(tester.widget<TextField>(field).controller!.text, value);
  await tester.tap(find.byTooltip('搜索'));
  await _advance(tester);
}

Future<ProviderContainer> _render(
  WidgetTester tester,
  FakeHttpClient http, {
  List<SourceEntry> entries = const [],
  List<SourceFailure> failures = const [],
  bool sourceLoadFails = false,
  GoRouter? router,
}) async {
  final db = openTestDatabase();
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(http),
      sourcesProvider.overrideWith(
        () => _Sources(
          SourceRegistrySnapshot(entries: entries, failures: failures),
          fail: sourceLoadFails,
        ),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    router?.dispose();
    container.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router == null
          ? MaterialApp(
              theme: AppTheme.light(),
              home: const SearchPage(type: MediaType.anime),
            )
          : MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await _advance(tester);
  return container;
}

void main() {
  for (final state in ['missing', 'disabled', 'metadata', 'load-error']) {
    testWidgets('anime metadata search survives $state plugin state', (
      tester,
    ) async {
      final http = FakeHttpClient((_) async => _results('公开资料结果'));
      final entries = <SourceEntry>[];
      if (state == 'disabled') {
        final rule = SourceRule.parseJson(
          await rootBundle.loadString('assets/rules/bangumi-anime.json'),
        );
        final source = BangumiSource(rule: rule, http: http);
        entries.add(
          SourceEntry(
            descriptor: source.descriptor,
            source: source,
            enabled: false,
          ),
        );
      }
      await _render(
        tester,
        http,
        entries: entries,
        sourceLoadFails: state == 'load-error',
        failures: state == 'metadata'
            ? const [
                SourceFailure(
                  id: 'bangumi-anime',
                  name: 'Bangumi',
                  type: MediaType.anime,
                  message: '仅有来源信息，尚未安装规则',
                ),
              ]
            : const [],
      );
      await _search(tester, '公开资料');
      debugPrint(
        'DBG state=$state errorView=${find.text('无法准备搜索来源，请重试').evaluate().length} retry=${find.text('重试').evaluate().length}',
      );
      expect(http.requests, hasLength(1));
      expect(http.requests.single.method, 'POST');
      expect(
        Uri.parse(http.requests.single.url).path,
        endsWith('/search/subjects'),
      );
      final body = jsonDecode(http.requests.single.body!) as Map;
      expect(body['keyword'], '公开资料');
      expect((body['filter'] as Map)['type'], [2]);
      expect(find.text('公开资料结果'), findsOneWidget);
      expect(find.text('已完成 1 / 1 个来源'), findsOneWidget);
      expect(find.text('没有可搜索的番剧来源'), findsNothing);
    });
  }

  testWidgets('metadata HTTP failure remains visible and can retry', (
    tester,
  ) async {
    var attempts = 0;
    final http = FakeHttpClient((_) async {
      if (++attempts == 1) {
        return const SourceResponse(statusCode: 503, body: '{}');
      }
      return _results('重试后资料');
    });
    await _render(tester, http);
    await _search(tester, '资料');
    expect(attempts, 1);
    expect(find.textContaining('503'), findsOneWidget);
    expect(find.text('没有找到匹配内容'), findsNothing);
    expect(find.text('没有可搜索的番剧来源'), findsNothing);
    await tester.tap(find.text('重试本站'));
    await _advance(tester);
    expect(attempts, 2);
    expect(find.text('重试后资料'), findsOneWidget);
    expect(find.textContaining('503'), findsNothing);
  });

  testWidgets('metadata query change cancels and rejects late response', (
    tester,
  ) async {
    final pending = Completer<SourceResponse>();
    final http = FakeHttpClient((request) {
      final query = (jsonDecode(request.body!) as Map)['keyword'];
      return query == 'old'
          ? pending.future
          : Future.value(_results('新资料结果', id: 43));
    });
    final site = _Site();
    await _render(tester, http, entries: [_entry(site)]);
    await _search(tester, 'old');
    expect(http.requests, hasLength(1));
    final owner = http.requests.single.cancellation!;
    expect(owner.cancelled, isFalse);
    await _search(tester, 'new');
    await _until(tester, () => http.requests.length == 2);
    expect(
      http.requests.map(
        (request) => (jsonDecode(request.body!) as Map)['keyword'],
      ),
      ['old', 'new'],
    );
    await _until(tester, () => find.text('新资料结果').evaluate().isNotEmpty);
    expect(find.text('新资料结果'), findsOneWidget);
    expect(owner.cancelled, isTrue);
    pending.complete(_results('过期资料结果'));
    await _advance(tester);
    expect(find.text('过期资料结果'), findsNothing);
    expect(find.text('新资料结果'), findsOneWidget);
  });

  testWidgets('metadata search opens subject then selects site and episode', (
    tester,
  ) async {
    final site = _Site();
    PlayerArgs? opened;
    final http = FakeHttpClient((request) async {
      if (Uri.parse(request.url).path.endsWith('/search/subjects')) {
        return _results('公开资料作品');
      }
      return const SourceResponse(
        statusCode: 200,
        body: '{"id":42,"type":2,"name_cn":"公开资料作品","summary":"资料简介"}',
      );
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const SearchPage(type: MediaType.anime),
        ),
        GoRoute(
          path: '/anime/detail',
          builder: (_, state) => DetailPage(item: state.extra! as MediaItem),
        ),
        GoRoute(
          path: AppRoutes.player,
          builder: (_, state) {
            opened = state.extra! as PlayerArgs;
            return const Scaffold(body: Text('消费选定剧集'));
          },
        ),
      ],
    );
    final container = await _render(
      tester,
      http,
      entries: [_entry(site)],
      router: router,
    );
    await _search(tester, '资料作品');
    await tester.tap(find.text('公开资料作品'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(site.queries, isEmpty);
    expect(site.contentRequests, 0);
    await tester.tap(find.text('开始 / 继续观看'));
    await tester.pumpAndSettle();
    expect(site.queries, ['公开资料作品']);
    await tester.tap(find.text('本站作品'));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    expect(site.contentRequests, 0);
    final episodeSheet = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(EpisodeSelector),
    );
    expect(episodeSheet, findsOneWidget);
    Navigator.of(tester.element(episodeSheet), rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(episodeSheet, findsNothing);
    expect(find.byType(EpisodeSelector), findsOneWidget);
    expect(find.byType(DetailPage), findsOneWidget);
    await tester.ensureVisible(find.text('第二集'));
    await tester.pumpAndSettle();
    expect(find.text('第二集').hitTestable(), findsOneWidget);
    await tester.tap(find.text('第二集'));
    await tester.pumpAndSettle();
    expect(opened!.item.sourceId, site.descriptor.id);
    expect(opened!.item.remoteId, 'site-work');
    expect(opened!.chapters[opened!.initialIndex].remoteId, 'two');
    final identity = AnimeIdentityRepository(container.read(databaseProvider));
    expect((await identity.subjectFor(site.item))!.sourceId, 'bangumi-anime');
    expect((await identity.subjectFor(site.item))!.remoteId, '42');
    expect(find.text('消费选定剧集'), findsOneWidget);
  });
}

SourceEntry _entry(ContentSource source, {bool enabled = true}) => SourceEntry(
  descriptor: source.descriptor,
  source: source,
  enabled: enabled,
);

class _Sources extends SourceRegistryController {
  _Sources(this.snapshot, {this.fail = false});
  final SourceRegistrySnapshot snapshot;
  final bool fail;
  @override
  Future<SourceRegistrySnapshot> build() async {
    if (fail) throw StateError('Isolated plugin registry load failure');
    return snapshot;
  }
}

class _SearchOnly implements SearchProvider {
  _SearchOnly(this.id, this.type);
  final String id;
  final MediaType type;
  final queries = <String>[];
  @override
  SourceDescriptor get descriptor => SourceDescriptor(
    id: id,
    name: id,
    type: type,
    kind: SourceKind.plugin,
    capabilities: const {SourceCapability.search},
  );
  @override
  bool get isReady => true;
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    queries.add(keyword);
    return [];
  }
}

class _Site extends _SearchOnly implements DetailProvider, ContentProvider {
  _Site({String id = 'playable-site'}) : super(id, MediaType.anime);
  @override
  SourceDescriptor get descriptor => super.descriptor.copyWith(
    capabilities: const {
      SourceCapability.search,
      SourceCapability.detail,
      SourceCapability.content,
    },
  );
  MediaItem get item => MediaItem(
    sourceId: id,
    remoteId: 'site-work',
    type: MediaType.anime,
    title: '本站作品',
  );
  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    queries.add(keyword);
    return [item];
  }

  @override
  Future<MediaItem> detail(MediaItem item) async => item;
  @override
  Future<List<Chapter>> chapters(MediaItem item) async => [
    Chapter(sourceId: id, remoteId: 'one', title: '第一集', volumeTitle: '主线路'),
    Chapter(sourceId: id, remoteId: 'two', title: '第二集', volumeTitle: '主线路'),
  ];
  int contentRequests = 0;
  @override
  Future<ChapterContent> content(Chapter chapter) async {
    contentRequests++;
    throw StateError('Resolve only after the player consumes an episode');
  }
}
