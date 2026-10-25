import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/source/bangumi_ech_adapter.dart';
import 'package:triomi/core/source/bangumi_public_client.dart';
import 'package:triomi/core/source/bangumi_route_policy.dart';
import 'package:triomi/core/source/bangumi_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_providers.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/discover/anime_recommendations.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';
import 'package:triomi/features/schedule/data/schedule_providers.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancellation,
  ) async {
    requests++;
    return ResponseBody.fromString('[]', 200);
  }

  @override
  void close({bool force = false}) => closed = true;
}

void main() {
  test('one persisted choice refreshes public consumers without replacing transport', () async {
    final preferences = memoryPreferences();
    final http = FakeHttpClient((_) async {
      return const SourceResponse(statusCode: 200, body: '{"id":42}');
    });
    final scope = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        sourceHttpClientProvider.overrideWithValue(http),
      ],
    );
    addTearDown(scope.dispose);
    expect(scope.read(bangumiMirrorEnabledProvider), isTrue);
    final first = scope.read(bangumiPublicClientProvider);
    final schedule = scope.read(scheduleClientProvider);
    final recommendations = scope.read(animeRecommendationRepositoryProvider);
    expect(first.routes.mirrorEnabled, isTrue);
    expect(schedule.routes.mirrorEnabled, isTrue);
    expect(recommendations.usesMirror, isTrue);

    await scope.read(bangumiMirrorEnabledProvider.notifier).setEnabled(false);
    expect(preferences.get<bool>(BangumiMirrorController.key), isFalse);
    expect(
      scope.read(bangumiPublicClientProvider).routes.mirrorEnabled,
      isFalse,
    );
    expect(scope.read(scheduleClientProvider).routes.mirrorEnabled, isFalse);
    expect(
      scope.read(animeRecommendationRepositoryProvider).usesMirror,
      isFalse,
    );
    expect(first.routes.mirrorEnabled, isTrue);
    expect(schedule.routes.mirrorEnabled, isTrue);
    expect(recommendations.usesMirror, isTrue);

    final reopened = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(reopened.dispose);
    expect(reopened.read(bangumiMirrorEnabledProvider), isFalse);
  });

  for (final mirror in [false, true]) {
    test(
      'all public consumers follow choice $mirror and never add session credentials',
      () async {
        final routes = BangumiRoutePolicy(mirrorEnabled: mirror);
        final http = FakeHttpClient((request) async {
          final uri = Uri.parse(request.url);
          final Object body;
          if (uri.path == '/p1/calendar') {
            body = {for (var day = 1; day <= 7; day++) '$day': <Object>[]};
          } else if (uri.path.endsWith('/comments')) {
            body = uri.path.contains('/episodes/')
                ? <Object>[]
                : {'data': <Object>[], 'total': 0};
          } else if (uri.path.endsWith('/characters') ||
              uri.path.endsWith('/subjects') &&
                  request.method == 'GET' &&
                  uri.path.contains('/v0/subjects/')) {
            body = <Object>[];
          } else if (uri.path.endsWith('/episodes') ||
              uri.path.endsWith('/search/subjects') ||
              uri.path.contains('/popular/') ||
              uri.path.contains('/trending/')) {
            body = {'data': <Object>[], 'total': 0};
          } else {
            body = {'id': 42, 'type': 2};
          }
          return SourceResponse(statusCode: 200, body: jsonEncode(body));
        });
        final client = BangumiPublicClient(http, routes: routes);
        await client.subject('42');
        await client.subjectP1('42');
        await client.character('42');
        await client.section('42', 'characters');
        await client.section('42', 'subjects');
        await client.section('42', 'comments');
        await client.episodes('42');
        await client.allEpisodes('42');
        await client.episodeComments('42');
        await client.search(keyword: 'test');
        final source = BangumiSource(
          rule: SourceRule.parseJson(
            File('assets/rules/bangumi-anime.json').readAsStringSync(),
          ),
          http: http,
          publicClient: client,
        );
        await source.search('same policy');
        await client.popular();
        await BangumiScheduleClient(http: http, routes: routes).fetchWeekly();
        for (final request in http.requests) {
          final uri = Uri.parse(request.url);
          final comments = uri.path.endsWith('/comments');
          expect(
            uri.host,
            comments
                ? 'next.bgm.tv'
                : uri.path.startsWith('/v0/')
                ? (mirror ? 'api.bgmapi.com' : 'api.bgm.tv')
                : mirror
                ? 'api.kazumi.fyi'
                : 'next.bgm.tv',
          );
          expect(request.followRedirects, isFalse);
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(
              anyOf(
                contains('authorization'),
                contains('cookie'),
                contains('x-appid'),
                contains('x-signature'),
              ),
            ),
          );
        }
        final popular = http.requests.firstWhere(
          (request) =>
              request.url.contains('popular') ||
              request.url.contains('trending'),
        );
        if (!mirror) {
          expect(Uri.parse(popular.url).queryParameters['type'], '2');
        }
      },
    );
  }

  test('cover mappings are explicit, switchable and preserve private or arbitrary URLs', () {
    const on = BangumiRoutePolicy();
    const off = BangumiRoutePolicy(mirrorEnabled: false);
    for (final url in [
      'https://lain.bgm.tv/pic/cover/l/a.jpg',
      'https://lain.bgm.tv/r/400/pic/crt/l/a.jpg',
      'https://api.bgm.tv/v0/subjects/42/image?type=small',
    ]) {
      expect(Uri.parse(on.coverRequestUrl(url)).host, 'wsrv.nl');
      expect(off.coverRequestUrl(url), url);
    }
    for (final url in [
      'https://lain.bgm.tv/pic/user/l/a.jpg',
      'https://lain.bgm.tv/pic/cover/l/a.jpg?token=secret',
      'https://other.example/pic/cover/l/a.jpg',
      'https://user:secret@api.bgm.tv/v0/subjects/42/image',
      'https://api.bgm.tv/v0/users/42/avatar',
    ]) {
      expect(on.coverRequestUrl(url), url);
    }
  });

  test('malformed error payloads never become empty successful metadata or discussions', () async {
    final http = FakeHttpClient(
      (_) async =>
          const SourceResponse(statusCode: 200, body: '{"error":"denied"}'),
    );
    final client = BangumiPublicClient(http);
    await expectLater(client.subject('42'), throwsA(isA<FormatException>()));
    await expectLater(client.episodes('42'), throwsA(isA<FormatException>()));
    await expectLater(
      client.section('42', 'comments'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      client.episodeComments('42'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(client.popular(), throwsA(isA<FormatException>()));
  });

  test(
    'ECH excludes credentials, writes, unrelated hosts and account paths',
    () {
      const routes = BangumiRoutePolicy();
      final comments = Uri.parse('https://next.bgm.tv/p1/episodes/42/comments');
      expect(routes.permitsEch(comments, 'GET', const []), isTrue);
      for (final header in [
        'Authorization',
        'Cookie',
        'X-AppId',
        'X-Signature',
      ]) {
        expect(routes.permitsEch(comments, 'GET', [header]), isFalse);
      }
      expect(routes.permitsEch(comments, 'POST', const []), isFalse);
      expect(
        routes.permitsEch(
          Uri.parse('https://next.bgm.tv/p1/users/me'),
          'GET',
          const [],
        ),
        isFalse,
      );
      expect(
        routes.permitsEch(
          Uri.parse('https://other.example/p1/episodes/42/comments'),
          'GET',
          const [],
        ),
        isFalse,
      );
      expect(
        const BangumiRoutePolicy(mirrorEnabled: false)
            .permitsEch(comments, 'GET', const []),
        isFalse,
      );
    },
  );

  test('explicit and OS proxy routes retain the existing transport', () async {
    for (final explicit in ['', 'http://127.0.0.1:7890']) {
      final fallback = _Adapter();
      var resolves = 0;
      final adapter = BangumiEchAdapter(
        fallback: fallback,
        policy: const BangumiRoutePolicy(),
        explicitProxy: explicit,
        resolveProxy: (_) async {
          resolves++;
          return 'PROXY 127.0.0.1:7890; DIRECT';
        },
      );
      final response = await adapter.fetch(
        RequestOptions(path: 'https://next.bgm.tv/p1/episodes/42/comments'),
        null,
        null,
      );
      await response.stream.drain<void>();
      expect(fallback.requests, 1);
      expect(resolves, explicit.isEmpty ? 1 : 0);
      adapter.close(force: true);
      expect(fallback.closed, isTrue);
    }
  });

  test('closing ECH transport cancels pending route resolution without opening a socket', () async {
    final fallback = _Adapter();
    final unresolved = Completer<String>();
    final adapter = BangumiEchAdapter(
      fallback: fallback,
      policy: const BangumiRoutePolicy(),
      resolveProxy: (_) => unresolved.future,
    );
    final request = adapter.fetch(
      RequestOptions(path: 'https://next.bgm.tv/p1/episodes/42/comments'),
      null,
      null,
    );
    final rejected = expectLater(
      request,
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    adapter.close(force: true);
    await rejected;
    expect(fallback.requests, 0);
    unresolved.complete('DIRECT');
  });
}
