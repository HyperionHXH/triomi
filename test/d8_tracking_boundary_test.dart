import 'dart:convert';

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

    test('官方不可达、镜像也未收藏（404）：同样返回 null', () async {
      final http = realLikeClient(
        throws: <String, SourceException Function(SourceRequest)>{
          'official.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: '连接被拒绝',
          ),
          'mirror.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.notFound,
            message: 'HTTP 404',
          ),
        },
      );
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: 'https://mirror.test',
      );

      expect(await bangumi.collection(12, token: 't'), isNull);
      expect(bangumi.usedFallback, isTrue);
      // uid 解析（官方→镜像各一跳，失败回退 `-`）+ 读收藏（官方→镜像各一跳）。
      expect(http.requests, hasLength(4));
      expect(http.requests.last.url, contains('/v0/users/-/collections/12'));
    });

    test('镜像再次失败（也连不上）：抛出错误，只有两次请求', () async {
      final http = realLikeClient(
        throws: <String, SourceException Function(SourceRequest)>{
          'official.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: '官方连接被拒绝',
          ),
          'mirror.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: '镜像连接被拒绝',
          ),
        },
      );
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: 'https://mirror.test',
      );

      await expectLater(
        bangumi.me('t'),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.network)
              .having((error) => error.message, 'message', contains('镜像')),
        ),
      );
      expect(http.requests, hasLength(2));
      expect(http.requests.last.url, startsWith('https://mirror.test'));
    });

    test('镜像带 token 搜索超时、匿名重试仍超时：如实抛出超时', () async {
      var mirrorTokenAttempt = true;
      final http = realLikeClient(
        throws: <String, SourceException Function(SourceRequest)>{
          'official.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.network,
            message: '官方不可达',
          ),
          'mirror.test': (request) {
            final hasToken =
                (request.headers['Authorization'] ?? '').isNotEmpty;
            if (hasToken && mirrorTokenAttempt) {
              mirrorTokenAttempt = false;
              return const SourceException(
                sourceId: BangumiClient.sourceId,
                type: SourceErrorType.timeout,
                message: '镜像搜索超时（带 token）',
              );
            }
            return const SourceException(
              sourceId: BangumiClient.sourceId,
              type: SourceErrorType.timeout,
              message: '镜像搜索超时（匿名重试也没救回来）',
            );
          },
        },
      );
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: 'https://mirror.test',
      );

      await expectLater(
        bangumi.search('Naruto', token: 't'),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.timeout)
              .having((error) => error.message, 'message', contains('匿名')),
        ),
      );
      // 官方 → 镜像带 token → 镜像匿名，三次为止（匿名重试只有一次）。
      expect(http.requests, hasLength(3));
      expect(http.requests.last.headers.containsKey('Authorization'), isFalse);
    });

    test('官方超时也回退镜像（不只连不上才回退）', () async {
      final http = realLikeClient(
        throws: <String, SourceException Function(SourceRequest)>{
          'official.test': (_) => const SourceException(
            sourceId: BangumiClient.sourceId,
            type: SourceErrorType.timeout,
            message: '连接超时',
          ),
        },
        bodies: <String, String>{
          '/v0/me': jsonEncode(<String, Object?>{
            'id': 1,
            'username': 'hypex',
            'nickname': 'Hypex',
          }),
        },
      );
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: 'https://mirror.test',
      );

      final me = await bangumi.me('t');
      expect(me.nickname, 'Hypex');
      expect(bangumi.usedFallback, isTrue);
    });

    test('429 归类为限流，且不因限流换到镜像', () async {
      final http = realLikeClient(statuses: <String, int>{'/v0/me': 429});
      final bangumi = BangumiClient(
        http: http,
        baseUrl: 'https://official.test',
        fallbackBaseUrl: 'https://mirror.test',
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

    test('空响应体按空数据处理，不当成错误', () async {
      final http = realLikeClient();
      final bangumi = BangumiClient(http: http);

      expect(await bangumi.search('Naruto'), isEmpty);
      expect(await bangumi.watchedEpisodeCount(12, token: 't'), 0);
      expect(await bangumi.episodes(12, token: 't'), isEmpty);
    });

    test('非法 JSON 归类为解析错误，错误信息带请求路径', () async {
      final http = realLikeClient(
        bodies: <String, String>{'/v0/search/subjects': '<html>oops</html>'},
      );
      await expectLater(
        BangumiClient(http: http).search('Naruto'),
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
        fallbackBaseUrl: 'https://mirror.test',
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
      expect(bangumi.usedFallback, isTrue);
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
