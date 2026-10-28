import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/tracking/data/bangumi_client.dart';

import 'fixtures/fake_http_client.dart';

/// D8 追踪网络边界回归：把 Bangumi 真实故障模式固化成网络层契约。
///
/// 两条请求路径必须等价（真实 dio 网络层把非 2xx 抛成 SourceException，
/// 测试替身直接返回响应），这里对抛异常的路径单独建用例。
void main() {
  /// 模拟真实网络层的替身：非 2xx 抛分类异常（与 DioSourceHttpClient 一致），
  /// 2xx 返回响应体。
  FakeHttpClient realLikeClient({
    Map<String, SourceException Function(SourceRequest)> throws =
        const <String, SourceException Function(SourceRequest)>{},
    Map<String, String> bodies = const <String, String>{},
    Map<String, int> statuses = const <String, int>{},
  }) {
    return FakeHttpClient((request) async {
      for (final entry in throws.entries) {
        if (request.url.contains(entry.key)) throw entry.value(request);
      }
      var status = 200;
      var body = '';
      for (final entry in statuses.entries) {
        if (request.url.contains(entry.key)) status = entry.value;
      }
      for (final entry in bodies.entries) {
        if (request.url.contains(entry.key)) body = entry.value;
      }
      return SourceResponse(statusCode: status, body: body, url: request.url);
    });
  }

  group('BangumiClient 网络边界', () {
    test('未收藏（404 以异常抛出，真实网络层路径）返回 null 而不是抛错', () async {
      // DioSourceHttpClient 对 404 是抛 SourceException(notFound)；
      // 只测「返回 404 响应」的替身路径盖不住设备上真正走的这条。
      final http = realLikeClient(
        bodies: {'/v0/me': '{"id":99}'},
        throws: <String, SourceException Function(SourceRequest)>{
          '/collections/12': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.notFound,
            message: 'HTTP 404',
          ),
        },
      );
      final collection = await BangumiClient(http: http)
          .collection(12, token: 't');
      expect(collection, isNull);
    });

    for (final status in [301, 302, 303, 307, 308]) {
      test(
        'write HTTP $status cannot report a successful no-content update',
        () async {
          final http = FakeHttpClient(
            (request) async => SourceResponse(
              statusCode: request.method == 'GET' ? 200 : status,
              body: request.method == 'GET' ? '{"id":99}' : '',
              headers: const {'location': 'https://untrusted.test/account'},
            ),
          );
          await expectLater(
            BangumiClient(http: http)
                .upsertCollection(12, token: 'fixture-token', status: 'doing'),
            throwsA(isA<SourceException>()),
          );
          expect(http.requests.last.followRedirects, isFalse);
          expect(http.requests.last.method, 'POST');
          expect(
            http.requests.every(
              (request) => Uri.parse(request.url).host == 'api.bgm.tv',
            ),
            isTrue,
          );
        },
      );
    }

    for (final type in [SourceErrorType.network, SourceErrorType.timeout]) {
      test(
        'official $type is preserved without third-party account fallback',
        () async {
          final http = realLikeClient(
            throws: {
              'official.test': (_) => SourceException(
                sourceId: BangumiClient.sourceId,
                type: type,
                message: 'official failed',
              ),
            },
          );
          final bangumi = BangumiClient(
            http: http,
            baseUrl: 'https://official.test',
          );
          await expectLater(
            bangumi.me('t'),
            throwsA(
              isA<SourceException>().having(
                (error) => error.type,
                'type',
                type,
              ),
            ),
          );
          expect(http.requests, hasLength(1));
          expect(http.requests.single.url, 'https://official.test/v0/me');
          expect(http.requests.single.followRedirects, isFalse);
        },
      );
    }

    test('429 归类为限流，且不因限流换到镜像', () async {
      final http = realLikeClient(statuses: <String, int>{'/v0/me': 429});
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
      );

      await expectLater(
        bangumi.me('t'),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.rateLimited,
          ),
        ),
      );
      // 限流换地址也一样，只发一次。
      expect(http.requests, hasLength(1));
    });

    test('空响应体不能冒充空搜索、零进度或空目录', () async {
      final bangumi = BangumiClient(http: realLikeClient());
      final parseError = throwsA(
        isA<SourceException>().having(
          (error) => error.type,
          'type',
          SourceErrorType.parse,
        ),
      );
      await expectLater(
        bangumi.search('Naruto', type: MediaType.anime),
        parseError,
      );
      await expectLater(
        bangumi.watchedEpisodeCount(12, token: 't'),
        parseError,
      );
      await expectLater(bangumi.episodes(12, token: 't'), parseError);
    });
    test('合法空列表与缺失列表字段有不同结果', () async {
      for (final body in ['{}', '[]', '{"data":null}', '{"data":{}}']) {
        final http = realLikeClient(
          bodies: {
            '/v0/search/subjects': body,
            '/v0/episodes': body,
            '/episodes?limit': body,
          },
        );
        final bangumi = BangumiClient(http: http);
        final parseError = throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        );
        await expectLater(
          bangumi.search('Naruto', type: MediaType.anime),
          parseError,
        );
        await expectLater(bangumi.episodes(12), parseError);
        await expectLater(
          bangumi.watchedEpisodeCount(12, token: 't'),
          parseError,
        );
      }
      final bangumi = BangumiClient(
        http: realLikeClient(
          bodies: {
            '/v0/search/subjects': '{"data":[]}',
            '/v0/episodes': '{"data":[]}',
            '/episodes?limit': '{"data":[]}',
          },
        ),
      );
      expect(await bangumi.search('Naruto', type: MediaType.anime), isEmpty);
      expect(await bangumi.episodes(12), isEmpty);
      expect(await bangumi.watchedEpisodeCount(12, token: 't'), 0);
    });

    test('非法 JSON 归类为解析错误，错误信息带请求路径', () async {
      final http = realLikeClient(
        bodies: <String, String>{'/v0/search/subjects': '<html>oops</html>'},
      );
      await expectLater(
        BangumiClient(http: http).search('Naruto', type: MediaType.anime),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.parse)
              .having(
                (error) => error.message,
                'message',
                contains('/v0/search/subjects'),
              ),
        ),
      );
    });

    test('失败信息不把 token 写出去（回退路径也一样）', () async {
      const token = 'very-secret-token-value';
      final http = realLikeClient(
        throws: <String, SourceException Function(SourceRequest)>{
          'official.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: '连接被拒绝',
          ),
          'mirror.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.auth,
            message: 'HTTP 401',
          ),
        },
      );
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
      );

      SourceException? caught;
      try {
        await bangumi.me(token);
      } on SourceException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      // token 确实发出去了（回退不改请求内容），但错误文本里不能出现它。
      expect(http.requests.last.headers['Authorization'], 'Bearer $token');
      expect('${caught?.message}', isNot(contains(token)));
      expect(caught?.userMessage, isNot(contains(token)));
      expect(caught.toString(), isNot(contains(token)));
      expect(http.requests, hasLength(1));
      expect(http.requests.single.url, 'https://official.test/v0/me');
    });
  });

  group('SourceException', () {
    test('wrap 按错误文本分类（超时/凭据/不存在/限流/其余归网络）', () {
      expect(
        SourceException.wrap(
          Exception('connection timeout after 20s'),
          sourceId: 'x',
        ).type,
        SourceErrorType.timeout,
      );
      expect(
        SourceException.wrap(Exception('HTTP 401'), sourceId: 'x').type,
        SourceErrorType.auth,
      );
      expect(
        SourceException.wrap(Exception('HTTP 403'), sourceId: 'x').type,
        SourceErrorType.auth,
      );
      expect(
        SourceException.wrap(Exception('HTTP 404'), sourceId: 'x').type,
        SourceErrorType.notFound,
      );
      expect(
        SourceException.wrap(Exception('HTTP 429'), sourceId: 'x').type,
        SourceErrorType.rateLimited,
      );
      expect(
        SourceException.wrap(
          Exception('connection refused'),
          sourceId: 'x',
        ).type,
        SourceErrorType.network,
      );
    });

    test('wrap 对已经是 SourceException 的错误原样返回（不二次包装）', () {
      const original = SourceException(
        sourceId: 'bangumi',
        type: SourceErrorType.rateLimited,
        message: 'HTTP 429',
      );
      expect(SourceException.wrap(original, sourceId: 'other'), same(original));
    });

    test('userMessage 组合类型标签与补充信息；空信息只留标签', () {
      const withMessage = SourceException(
        sourceId: 'lk',
        type: SourceErrorType.auth,
        message: 'HTTP 401',
      );
      expect(withMessage.userMessage, contains('登录'));
      expect(withMessage.userMessage, contains('HTTP 401'));

      const noMessage = SourceException(
        sourceId: 'lk',
        type: SourceErrorType.timeout,
      );
      expect(noMessage.userMessage, isNotEmpty);
    });
  });
}
