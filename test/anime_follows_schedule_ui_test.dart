import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/core/theme/app_theme.dart';
import 'package:triomi/core/theme/app_tokens.dart';
import 'package:triomi/features/anime/anime_collection_button.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/anime/anime_workspace_page.dart';
import 'package:triomi/features/detail/anime_filter_dialog.dart';
import 'package:triomi/features/discover/widgets/media_item_card.dart';
import 'package:triomi/features/library/data/library_providers.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';
import 'package:triomi/features/schedule/data/schedule_providers.dart';
import 'package:triomi/features/schedule/season_schedule.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const firstSeason = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '12',
  type: MediaType.anime,
  title: '相同标题',
);

void main() {
  testWidgets(
    'narrow anime tabs stay readable on one line at system 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = openTestDatabase();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          sourceHttpClientProvider.overrideWithValue(
            FakeHttpClient(
              (_) async => const SourceResponse(
                statusCode: 200,
                body: '{"data":[],"total":0}',
              ),
            ),
          ),
          weeklyScheduleProvider.overrideWith((_) async => []),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const AnimeWorkspacePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['我的追番', '时间表', '推荐']) {
        final tab = find.text(label).first;
        await tester.ensureVisible(tab);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(tab);
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: label.length),
        );
        expect(
          boxes.map((box) => box.top).toSet(),
          hasLength(1),
          reason: '$label must not wrap',
        );
        expect(
          boxes
              .map((box) => box.right - box.left)
              .fold<double>(0, (sum, width) => sum + width),
          greaterThan(0),
        );
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local favourite works without a Bangumi account and makes no remote request',
    (tester) async {
      final db = openTestDatabase();
      final http = FakeHttpClient(
        (_) async =>
            const SourceResponse(statusCode: 401, body: 'missing account'),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const Scaffold(body: AnimeCollectionButton(item: firstSeason)),
          ),
          GoRoute(
            path: '/tracking',
            builder: (_, _) => const Scaffold(body: Text('账户设置目的页')),
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
          secureStoreProvider.overrideWithValue(MemorySecureStore()),
          sourceHttpClientProvider.overrideWithValue(http),
        ],
      );
      addTearDown(() async {
        router.dispose();
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => container.read(animeFollowsProvider.future));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收藏状态'));
      await tester.pumpAndSettle();
      final doing = find.widgetWithText(CheckedPopupMenuItem<String>, '在看');
      await tester.ensureVisible(doing);
      await tester.tap(doing);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(http.requests, isEmpty);
      expect(
        (await LibraryRepository(db).listAnimeFollows()).single.entry.status,
        'doing',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'local follows remain visible without credentials and titles respect system scaling',
    (tester) async {
      final db = openTestDatabase();
      await LibraryRepository(db).addAnimeFollow(firstSeason);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(memoryPreferences()),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(400, 900),
                textScaler: TextScaler.linear(1.6),
              ),
              child: const Scaffold(body: AnimeFollowsPage()),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final title = tester.widget<Text>(find.text(firstSeason.title));
      expect(title.maxLines, 1);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text(firstSeason.title)))
            .scale(10),
        16,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      final allStatus = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, '全部'),
      );
      expect(allStatus.side, isNotNull);
      expect(allStatus.side!.style, BorderStyle.solid);
      expect(tester.takeException(), isNull);
      expect(
        (await LibraryRepository(db).listLibrary(type: MediaType.anime))
            .single
            .item
            .remoteId,
        '12',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final (width, layout) in [
    (599.0, CoverLayout.grid),
    (600.0, CoverLayout.grid),
    (1239.0, CoverLayout.grid),
    (1240.0, CoverLayout.grid),
    (1600.0, CoverLayout.grid),
    (1240.0, CoverLayout.list),
  ]) {
    testWidgets(
      'weekday switch starts at first title and scrolls through the complete $layout at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = openTestDatabase();
        final prefs = memoryPreferences();
        await prefs.set('anime.calendar.weekday', 1);
        final http = FakeHttpClient(
          (_) async =>
              throw StateError('current calendar must not search seasons'),
        );
        var weekRequests = 0;
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            preferencesProvider.overrideWithValue(prefs),
            sourceHttpClientProvider.overrideWithValue(http),
            weeklyScheduleProvider.overrideWith((_) async {
              weekRequests++;
              return [
                for (var day = 1; day <= 7; day++)
                  ScheduleDay(
                    weekday: day,
                    label: '周$day',
                    items: [
                      for (var index = 0; index < 45; index++)
                        ScheduleEntry(
                          id: '$day-$index',
                          title: '完整星期$day作品$index',
                          airDate: '2020-01-01',
                          votes: 100 - index,
                        ),
                    ],
                  ),
              ];
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
        });
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(covers: CoverAppearance(layout: layout)),
              home: const Scaffold(body: SeasonSchedule(embedded: true)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final day in [1, 2, 3, 4, 5, 6, 7, 1]) {
          final tab = find.widgetWithText(
            TextButton,
            '周${['一', '二', '三', '四', '五', '六', '日'][day - 1]}',
          );
          await tester.ensureVisible(tab);
          await tester.tap(tab);
          await tester.pumpAndSettle();
          expect(find.text('完整星期$day作品0').hitTestable(), findsOneWidget);
          final collection = tester.widget<MediaItemCollection>(
            find.byType(MediaItemCollection),
          );
          expect(collection.items, hasLength(45));
          final scrolling = find.descendant(
            of: find.byType(MediaItemCollection),
            matching: find.byWidgetPredicate(
              (widget) => widget is Scrollable && widget.axis == Axis.vertical,
            ),
          );
          await tester.scrollUntilVisible(
            find.text('完整星期$day作品44'),
            350,
            scrollable: scrolling,
            maxScrolls: 80,
          );
          await tester.pumpAndSettle();
          expect(find.text('完整星期$day作品44').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(weekRequests, 1);
        expect(http.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'refresh requests a new public week and a late failure keeps usable entries',
    (tester) async {
      final db = openTestDatabase();
      final prefs = memoryPreferences();
      await prefs.set('anime.calendar.weekday', 1);
      final pending = Completer<SourceResponse>();
      var calls = 0;
      final http = FakeHttpClient((_) async {
        calls++;
        if (calls == 2) return pending.future;
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode([
            {
              'weekday': {'id': 1},
              'items': [
                {
                  'id': calls,
                  'name_cn': calls == 1 ? '上次完整放送表' : '真正刷新的放送表',
                  'rank': 50,
                  'rating': {'rank': 1, 'score': 8},
                },
                if (calls == 1)
                  {
                    'id': 90,
                    'name_cn': '公开排名靠前作品',
                    'rank': 5,
                    'rating': {'rank': 100, 'score': 7},
                  },
              ],
            },
          ]),
        );
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          sourceHttpClientProvider.overrideWithValue(http),
          scheduleClientProvider.overrideWithValue(
            BangumiScheduleClient(
              http: http,
              baseUrl: 'https://fixture.local/calendar',
            ),
          ),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SeasonSchedule(embedded: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('上次完整放送表'), findsOneWidget);
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(calls, 2);
      expect(find.text('上次完整放送表'), findsOneWidget);
      pending.completeError(StateError('late calendar failure'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('上次完整放送表'), findsOneWidget);
      expect(find.textContaining('公开放送资料暂不可用'), findsOneWidget);
      await tester.tap(find.byTooltip('筛选历史季度'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('热度'),
        250,
        scrollable: find.descendant(
          of: find.descendant(
            of: find.byType(AnimeFilterDialog),
            matching: find.byType(ListView),
          ),
          matching: find.byWidgetPredicate(
            (widget) => widget is Scrollable && widget.axis == Axis.vertical,
          ),
        ),
      );
      await tester.tap(find.text('热度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排名').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      final ranked = tester.widget<MediaItemCollection>(
        find.byType(MediaItemCollection),
      );
      expect(ranked.items.map((item) => item.remoteId), ['90', '1']);
      expect(find.text('上次完整放送表'), findsOneWidget);
      expect(find.textContaining('公开放送资料暂不可用'), findsOneWidget);
      expect(calls, 2, reason: '本地排序必须复用失败刷新前的完整周，不请求网络');
      final retry = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await retry;
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text('真正刷新的放送表'), findsOneWidget);
      expect(find.text('上次完整放送表'), findsNothing);
      expect(http.requests.every((request) => request.method == 'GET'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'tag filtering retains cross-season broadcasts and cancels the superseded filter',
    (tester) async {
      final db = openTestDatabase();
      final prefs = memoryPreferences();
      final now = DateTime.now();
      await prefs.set('anime.calendar.weekday', 1);
      await prefs.set('anime.calendar.filter', {
        'version': 1,
        'year': now.year,
        'quarter': (now.month - 1) ~/ 3 + 1,
        'tags': ['日常'],
      });
      final old = Completer<SourceResponse>();
      final http = FakeHttpClient((request) async {
        final filter = (jsonDecode(request.body!) as Map)['filter'] as Map;
        expect(filter.containsKey('air_date'), isFalse);
        if ((filter['tag'] as List).contains('日常')) return old.future;
        final offset = Uri.parse(request.url).queryParameters['offset'];
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'total': 2,
            'data': [
              {'id': offset == '0' ? 99 : 10, 'type': 2, 'name_cn': '服务端匹配'},
            ],
          }),
        );
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          sourceHttpClientProvider.overrideWithValue(http),
          weeklyScheduleProvider.overrideWith(
            (_) async => [
              const ScheduleDay(
                weekday: 1,
                label: '周一',
                items: [
                  ScheduleEntry(
                    id: '10',
                    title: '跨季科幻连载',
                    airDate: '2020-01-01',
                  ),
                  ScheduleEntry(id: '11', title: '不匹配作品'),
                ],
              ),
            ],
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SeasonSchedule(embedded: true)),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('跨季科幻连载'), findsOneWidget);
      expect(find.textContaining('暂显示未按题材筛选'), findsOneWidget);
      final oldRequest = http.requests.single;
      await tester.tap(find.byTooltip('筛选历史季度'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.widgetWithText(FilterChip, '日常'));
      await tester.tap(find.widgetWithText(FilterChip, '日常'));
      await tester.ensureVisible(find.widgetWithText(FilterChip, '科幻'));
      await tester.tap(find.widgetWithText(FilterChip, '科幻'));
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(oldRequest.cancellation!.cancelled, isTrue);
      expect(find.text('跨季科幻连载'), findsOneWidget);
      expect(find.text('不匹配作品'), findsNothing);
      expect(http.requests, hasLength(3));
      old.complete(
        const SourceResponse(
          statusCode: 200,
          body: '{"total":1,"data":[{"id":11,"type":2}]}',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('跨季科幻连载'), findsOneWidget);
      expect(find.text('不匹配作品'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'calendar ignores legacy all bucket and changes naturally among seven weekdays',
    (tester) async {
      final db = openTestDatabase();
      final prefs = memoryPreferences();
      await prefs.set('anime.calendar.weekday', -1);
      await prefs.set('anime.calendar.filter', {
        'version': 1,
        'year': 2020,
        'quarter': 1,
      });
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'total': 9,
            'data': Uri.parse(request.url).queryParameters['offset'] == '8'
                ? [
                    {
                      'id': 999,
                      'type': 2,
                      'name_cn': '自动加载第二页',
                      'weekday': {'id': DateTime.now().weekday},
                    },
                  ]
                : [
                    for (var day = 0; day <= 7; day++)
                      {
                        'id': day + 100,
                        'type': 2,
                        'name_cn': '星期作品$day',
                        'weekday': {'id': day},
                      },
                  ],
          }),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          preferencesProvider.overrideWithValue(prefs),
          sourceHttpClientProvider.overrideWithValue(http),
          weeklyScheduleProvider.overrideWith((_) async => []),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SeasonSchedule(embedded: true)),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      final today = DateTime.now().weekday;
      expect(find.text('星期作品$today'), findsOneWidget);
      expect(find.text('自动加载第二页'), findsOneWidget);
      expect(find.text('加载更多本季作品'), findsNothing);
      expect(find.text('星期作品0'), findsNothing);
      expect(find.text('星期未注明'), findsNothing);
      final next = today == 7 ? 1 : today + 1;
      final weekday = '周${['一', '二', '三', '四', '五', '六', '日'][next - 1]}';
      final tab = find.widgetWithText(TextButton, weekday);
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pump();
      expect(find.text('星期作品$next'), findsOneWidget);
      expect(find.text('星期作品$today'), findsNothing);
      expect(prefs.get<int>('anime.calendar.weekday'), next);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.widgetWithText(TextButton, '今天'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
