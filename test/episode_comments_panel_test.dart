import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/db/database_provider.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/features/library/data/anime_identity_repository.dart';
import 'package:triomi/features/player/episode_comments_panel.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

const subject = MediaItem(
  sourceId: 'bangumi-anime',
  remoteId: '42',
  type: MediaType.anime,
  title: '动画',
);
const site = MediaItem(
  sourceId: 'playback-site',
  remoteId: 'site-42',
  type: MediaType.anime,
  title: '播放站动画',
);
const chapter = Chapter(
  sourceId: 'playback-site',
  remoteId: 'NOT-BANGUMI-ID',
  title: '第2集',
);
SourceResponse response(Object value) =>
    SourceResponse(statusCode: 200, body: jsonEncode(value));
Map<String, Object?> episode(int id, num sort, {int type = 0}) => {
  'id': id,
  'sort': sort,
  'type': type,
  'name_cn': '分集$id',
};
Map<String, Object?> comment(
  String content,
  int time, {
  List<Object?> replies = const [],
}) => {
  'id': time,
  'content': content,
  'createdAt': time,
  'user': {'nickname': '作者$time', 'avatar': <String, Object?>{}},
  'replies': replies,
};

Future<ProviderContainer> mount(
  WidgetTester tester,
  FakeHttpClient http, {
  MediaItem item = subject,
  Chapter selected = chapter,
  bool mapped = false,
}) async {
  final db = openTestDatabase();
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (mapped) await AnimeIdentityRepository(db).confirm(subject, site);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      sourceHttpClientProvider.overrideWithValue(http),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await db.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: EpisodeCommentsPanel(item: item, chapter: selected),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets(
    'subject replacement discards late discussion from previous canonical subject',
    (tester) async {
      final late = Completer<SourceResponse>();
      final started = Completer<void>();
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        if (uri.path == '/v0/episodes') {
          return response({
            'total': 1,
            'data': [
              episode(
                uri.queryParameters['subject_id'] == '42' ? 1002 : 2002,
                2,
              ),
            ],
          });
        }
        if (uri.path == '/p1/episodes/1002/comments') {
          started.complete();
          return late.future;
        }
        expect(uri.path, '/p1/episodes/2002/comments');
        return response([comment('新作品讨论', 100)]);
      });
      final container = await mount(tester, http);
      for (var i = 0; i < 30 && !started.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(started.isCompleted, isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: EpisodeCommentsPanel(
                item: MediaItem(
                  sourceId: 'bangumi-anime',
                  remoteId: '43',
                  type: MediaType.anime,
                  title: '另一作品',
                ),
                chapter: chapter,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新作品讨论'), findsOneWidget);
      late.complete(response([comment('旧作品讨论', 100)]));
      await tester.pumpAndSettle();
      expect(find.text('旧作品讨论'), findsNothing);
      expect(find.text('新作品讨论'), findsOneWidget);
    },
  );

  testWidgets(
    'confirmed canonical subject loads all episode pages then anonymous real thread shape',
    (tester) async {
      final http = FakeHttpClient((request) async {
        final uri = Uri.parse(request.url);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('authorization')),
        );
        if (uri.path == '/v0/episodes') {
          expect(uri.queryParameters['subject_id'], '42');
          expect(uri.queryParameters['type'], isNull);
          final offset = uri.queryParameters['offset'];
          return response({
            'total': 2,
            'data': offset == '0' ? [episode(1001, 1)] : [episode(1002, 2)],
          });
        }
        expect(uri.host, 'next.bgm.tv');
        expect(uri.path, '/p1/episodes/1002/comments');
        expect(uri.query, isEmpty);
        return response([
          comment('较早讨论', 100, replies: [comment('嵌套回复', 101)]),
          comment('最新讨论', 200),
        ]);
      });
      await mount(tester, http, item: site, mapped: true);
      await tester.pumpAndSettle();
      expect(
        http.requests.where((request) => request.url.contains('/v0/episodes')),
        hasLength(2),
      );
      expect(find.text('嵌套回复'), findsOneWidget);
      expect(find.text('作者101'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('最新讨论')).dy,
        lessThan(tester.getTopLeft(find.text('较早讨论')).dy),
      );
      await tester.tap(find.text('最新优先'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('较早讨论')).dy,
        lessThan(tester.getTopLeft(find.text('最新讨论')).dy),
      );
      expect(http.requests, hasLength(3));
    },
  );

  testWidgets(
    'ambiguous normal episodes require explicit selection and specials remain selectable',
    (tester) async {
      final http = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 3,
            'data': [
              episode(1002, 2),
              episode(1003, 2),
              episode(9001, 2, type: 1),
            ],
          });
        }
        expect(Uri.parse(request.url).path, '/p1/episodes/9001/comments');
        return response([comment('SP真实讨论', 100)]);
      });
      await mount(tester, http);
      await tester.pumpAndSettle();
      expect(http.requests, hasLength(1));
      expect(find.textContaining('未找到唯一对应'), findsOneWidget);
      await tester.tap(find.text('选择分集讨论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SP 2 · 分集9001'));
      await tester.pumpAndSettle();
      expect(find.text('SP真实讨论'), findsOneWidget);
    },
  );

  testWidgets(
    'explicit SP title with parsed number cannot auto-match a normal episode',
    (tester) async {
      final http = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 2,
            'data': [episode(1002, 2), episode(9001, 2, type: 1)],
          });
        }
        expect(Uri.parse(request.url).path, '/p1/episodes/9001/comments');
        return response([comment('指定SP讨论', 100)]);
      });
      await mount(
        tester,
        http,
        selected: const Chapter(
          sourceId: 'playback-site',
          remoteId: 'special-two',
          title: 'SP2',
          number: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(http.requests, hasLength(1));
      expect(find.textContaining('未找到唯一对应'), findsOneWidget);
      await tester.tap(find.text('选择分集讨论'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SP 2 · 分集9001'));
      await tester.pumpAndSettle();
      expect(find.text('指定SP讨论'), findsOneWidget);
      expect(
        http.requests.any(
          (request) => request.url.contains('/episodes/1002/comments'),
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'chapter change cancels stale episode response without using playback remote id',
    (tester) async {
      final late = Completer<SourceResponse>();
      final started = Completer<void>();
      final http = FakeHttpClient((request) async {
        final path = Uri.parse(request.url).path;
        if (path == '/v0/episodes') {
          return response({
            'total': 2,
            'data': [episode(1002, 2), episode(1003, 3)],
          });
        }
        if (path == '/p1/episodes/1002/comments') {
          started.complete();
          return late.future;
        }
        expect(path, '/p1/episodes/1003/comments');
        return response([comment('新集讨论', 100)]);
      });
      final container = await mount(tester, http);
      for (var i = 0; i < 30 && !started.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(started.isCompleted, isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: EpisodeCommentsPanel(
                item: subject,
                chapter: Chapter(
                  sourceId: 'playback-site',
                  remoteId: 'third',
                  title: '第3集',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('新集讨论'), findsOneWidget);
      late.complete(response([comment('旧集迟到讨论', 100)]));
      await tester.pumpAndSettle();
      expect(find.text('旧集迟到讨论'), findsNothing);
      expect(find.text('新集讨论'), findsOneWidget);
    },
  );

  testWidgets(
    'errors retry independently and failed refresh retains visible discussions',
    (tester) async {
      var attempts = 0;
      final http = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 1,
            'data': [episode(1002, 2)],
          });
        }
        attempts++;
        if (attempts == 1 || attempts == 3) {
          return const SourceResponse(statusCode: 503, body: '{}');
        }
        return response([comment('保留讨论', 100)]);
      });
      await mount(tester, http);
      await tester.pumpAndSettle();
      expect(find.textContaining('本集评论加载失败'), findsOneWidget);
      await tester.tap(find.text('重试本集评论'));
      await tester.pumpAndSettle();
      expect(find.text('保留讨论'), findsOneWidget);
      await tester.tap(find.byTooltip('刷新本集评论'));
      await tester.pumpAndSettle();
      expect(find.text('保留讨论'), findsOneWidget);
      expect(find.textContaining('刷新失败，已保留现有讨论'), findsOneWidget);
      await tester.tap(find.text('重试本集评论'));
      await tester.pumpAndSettle();
      expect(attempts, 4);
      expect(find.text('保留讨论'), findsOneWidget);
    },
  );

  testWidgets(
    'connection replacement retries failed comments on the selected episode',
    (tester) async {
      final oldHttp = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 1,
            'data': [episode(1002, 2)],
          });
        }
        return const SourceResponse(statusCode: 503, body: '{}');
      });
      final container = await mount(tester, oldHttp);
      await tester.pumpAndSettle();
      expect(find.textContaining('本集评论加载失败'), findsOneWidget);
      final replacement = FakeHttpClient((request) async {
        expectSync(Uri.parse(request.url).path, '/p1/episodes/1002/comments');
        return response([comment('切换连接后恢复讨论', 200)]);
      });
      container.updateOverrides([
        databaseProvider.overrideWithValue(container.read(databaseProvider)),
        sourceHttpClientProvider.overrideWithValue(replacement),
      ]);
      for (
        var attempt = 0;
        attempt < 30 && find.text('切换连接后恢复讨论').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('切换连接后恢复讨论'), findsOneWidget);
      expect(find.textContaining('本集评论加载失败'), findsNothing);
      expect(replacement.requests, hasLength(1));
    },
  );

  testWidgets(
    'connection replacement cancels pending comments and rejects late old response',
    (tester) async {
      final pending = Completer<SourceResponse>();
      final oldHttp = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 1,
            'data': [episode(1002, 2)],
          });
        }
        return pending.future;
      });
      final container = await mount(tester, oldHttp);
      for (
        var attempt = 0;
        attempt < 30 && oldHttp.requests.length < 2;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(oldHttp.requests, hasLength(2));
      final replacement = FakeHttpClient(
        (_) async => response([comment('新连接讨论', 200)]),
      );
      container.updateOverrides([
        databaseProvider.overrideWithValue(container.read(databaseProvider)),
        sourceHttpClientProvider.overrideWithValue(replacement),
      ]);
      for (
        var attempt = 0;
        attempt < 30 && find.text('新连接讨论').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(oldHttp.requests.last.cancellation!.cancelled, isTrue);
      expect(find.text('新连接讨论'), findsOneWidget);
      pending.complete(response([comment('旧连接迟到讨论', 100)]));
      await tester.pumpAndSettle();
      expect(find.text('旧连接迟到讨论'), findsNothing);
      expect(find.text('新连接讨论'), findsOneWidget);
    },
  );

  testWidgets(
    'empty discussion is distinguished from malformed protocol response',
    (tester) async {
      var malformed = true;
      final http = FakeHttpClient((request) async {
        if (Uri.parse(request.url).path == '/v0/episodes') {
          return response({
            'total': 1,
            'data': [episode(1002, 2)],
          });
        }
        return malformed
            ? response({'data': <Object?>[]})
            : response(<Object?>[]);
      });
      await mount(tester, http);
      await tester.pumpAndSettle();
      expect(find.textContaining('本集评论加载失败'), findsOneWidget);
      malformed = false;
      await tester.tap(find.text('重试本集评论'));
      await tester.pumpAndSettle();
      expect(find.text('本集还没有讨论'), findsOneWidget);
    },
  );

  testWidgets('unbound playback item never guesses subject or episode ids', (
    tester,
  ) async {
    final http = FakeHttpClient(
      (_) async => throw StateError('must not access network'),
    );
    await mount(tester, http, item: site);
    await tester.pumpAndSettle();
    expect(find.textContaining('尚未关联 Bangumi 动画条目'), findsOneWidget);
    expect(find.text('查找 Bangumi 动画条目'), findsOneWidget);
    expect(http.requests, isEmpty);
  });
}
