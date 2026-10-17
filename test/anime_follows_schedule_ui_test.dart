import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:triomi/features/anime/anime_collection_button.dart';
import 'package:triomi/features/anime/anime_follows_page.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/schedule/data/schedule_providers.dart';
import 'package:triomi/features/schedule/season_schedule.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';
import 'fixtures/test_database.dart';

const firstSeason = MediaItem(sourceId: 'bangumi-anime', remoteId: '12',
  type: MediaType.anime, title: '相同标题');

void main() {
  testWidgets('missing Bangumi account opens account settings without writing a local favourite', (tester) async {
    final db = openTestDatabase();
    final http = FakeHttpClient((_) async => const SourceResponse(statusCode: 401, body: 'missing account'));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: AnimeCollectionButton(item: firstSeason))),
      GoRoute(path: '/tracking', builder: (_, _) => const Scaffold(body: Text('账户设置目的页'))),
    ]);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
      sourceHttpClientProvider.overrideWithValue(http),
    ]);
    addTearDown(() async { router.dispose(); container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接 Bangumi 收藏'));
    await tester.pumpAndSettle();
    expect(find.text('账户设置目的页'), findsOneWidget);
    expect(http.requests, isEmpty);
    expect(await LibraryRepository(db).listAnimeFollows(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local follows remain visible without credentials and titles respect system scaling', (tester) async {
    final db = openTestDatabase();
    await LibraryRepository(db).addAnimeFollow(firstSeason);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(memoryPreferences()),
    ]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: MaterialApp(home: MediaQuery(data: const MediaQueryData(
        size: Size(400, 900), textScaler: TextScaler.linear(1.6)),
        child: const Scaffold(body: AnimeFollowsPage())))));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final title = tester.widget<Text>(find.text(firstSeason.title));
    expect(title.maxLines, 1);
    expect(title.softWrap, isFalse);
    expect(MediaQuery.textScalerOf(tester.element(find.text(firstSeason.title))).scale(10), 16);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(tester.takeException(), isNull);
    expect((await LibraryRepository(db).listLibrary(type: MediaType.anime)).single.item.remoteId, '12');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('calendar ignores legacy all bucket and changes naturally among seven weekdays', (tester) async {
    final db = openTestDatabase();
    final prefs = memoryPreferences();
    await prefs.set('anime.calendar.weekday', -1);
    final http = FakeHttpClient((_) async => SourceResponse(statusCode: 200, body: jsonEncode({
      'total': 8, 'data': [for (var day = 0; day <= 7; day++) {
        'id': day + 100, 'type': 2, 'name_cn': '星期作品$day', 'weekday': {'id': day},
      }],
    })));
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      sourceHttpClientProvider.overrideWithValue(http),
      weeklyScheduleProvider.overrideWith((_) async => []),
    ]);
    addTearDown(() async { container.dispose(); await db.close(); });
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: Scaffold(body: SeasonSchedule(embedded: true)))));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    final today = DateTime.now().weekday;
    expect(find.text('星期作品$today'), findsOneWidget);
    expect(find.text('星期作品0'), findsNothing);
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
  });
}
