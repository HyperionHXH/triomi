import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_api.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lns/lns_auth.dart';
import 'package:triomi/features/novel/data/lns/lns_gateway.dart';
import 'package:triomi/features/novel/data/lns/lns_hub_connection.dart';
import 'package:triomi/features/novel/data/lns/lns_source.dart';

import 'fixtures/fake_http_client.dart';

/// 假 WebSocket：记录发出的帧，测试用 emit 驱动服务端行为。
class FakeLnsSocket implements LnsSocket {
  final StreamController<Object?> _controller = StreamController<Object?>();
  final List<String> sent = <String>[];

  @override
  Stream<Object?> get stream => _controller.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(String text) {
    if (!_controller.isClosed) _controller.add(text);
  }
}

/// 可编程 Hub 替身。
class StubHub implements LnsHubConnection {
  StubHub(this.handler);

  final Future<Object?> Function(String target, Object? params) handler;
  final List<({String target, Object? params})> calls =
      <({String target, Object? params})>[];
  int resets = 0;

  @override
  Future<Object?> invoke(String target, Object? params) {
    calls.add((target: target, params: params));
    return handler(target, params);
  }

  @override
  void reset() => resets += 1;
}

Map<Object?, Object?> envelope(Object? response) => <Object?, Object?>{
  'Success': true,
  'Response': response,
};

/// 建一条走假 socket 的 Hub 连接；`autoHandshake` 时服务端自动回 `{}`。
SignalRLnsHubConnection connectionWith(
  List<FakeLnsSocket> sockets, {
  List<Uri>? uris,
  bool autoHandshake = true,
}) {
  return SignalRLnsHubConnection(
    hubUrl: 'wss://example.test/hub/api',
    accessToken: () => 'token-abc',
    connector: (uri, headers) async {
      uris?.add(uri);
      final socket = FakeLnsSocket();
      sockets.add(socket);
      if (autoHandshake) {
        scheduleMicrotask(() => socket.emit('{}\u001e'));
      }
      return socket;
    },
    handshakeTimeout: const Duration(seconds: 5),
    invocationTimeout: const Duration(seconds: 5),
  );
}

Map<dynamic, dynamic> frameAt(FakeLnsSocket socket, int index) {
  final text = socket.sent[index].replaceAll(lnsRecordSeparator, '');
  return jsonDecode(text) as Map<dynamic, dynamic>;
}

String completion(String invocationId, {Object? result, String? error}) =>
    jsonEncode(<String, Object?>{
      'type': 3,
      'invocationId': invocationId,
      if (error != null) 'error': error else 'result': result,
    }) +
    lnsRecordSeparator;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('T4 帧协议', () {
    test('握手：先发协议帧，收到 {} 后才允许调用，且带 access_token', () async {
      final sockets = <FakeLnsSocket>[];
      final uris = <Uri>[];
      final connection = connectionWith(sockets, uris: uris);

      final future = connection.invoke('GetRank', <String, Object?>{'Days': 1});
      await pumpEventQueue();

      expect(sockets, hasLength(1));
      expect(uris.single.query, contains('access_token=token-abc'));
      final socket = sockets.single;
      expect(socket.sent, hasLength(2));
      final handshake = frameAt(socket, 0);
      expect(handshake['protocol'], 'json');
      expect(handshake['version'], 1);

      final request = frameAt(socket, 1);
      expect(request['type'], 1);
      expect(request['target'], 'GetRank');
      final arguments = request['arguments'] as List<dynamic>;
      expect((arguments[1] as Map<dynamic, dynamic>)['UseGzip'], isTrue);
      expect((arguments[0] as Map<dynamic, dynamic>)['Days'], 1);

      socket.emit(
        completion(
          request['invocationId'] as String,
          result: <String, Object?>{'ok': true},
        ),
      );
      expect(await future, <String, Object?>{'ok': true});
    });

    test('乱序完成帧按 invocationId 正确配对', () async {
      final sockets = <FakeLnsSocket>[];
      final connection = connectionWith(sockets);

      final first = connection.invoke('First', null);
      final second = connection.invoke('Second', null);
      await pumpEventQueue();

      final socket = sockets.single;
      final frames = <Map<dynamic, dynamic>>[
        for (var index = 1; index < socket.sent.length; index++)
          frameAt(socket, index),
      ];
      final firstId =
          frames.firstWhere(
                (frame) => frame['target'] == 'First',
              )['invocationId']
              as String;
      final secondId =
          frames.firstWhere(
                (frame) => frame['target'] == 'Second',
              )['invocationId']
              as String;
      expect(firstId, isNot(secondId));

      // 后发起的请求先返回。
      socket.emit(completion(secondId, result: 'second'));
      socket.emit(completion(firstId, result: 'first'));

      expect(await first, 'first');
      expect(await second, 'second');
    });

    test('粘包与拆包：一个 chunk 里的多帧 + 跨 chunk 的半帧', () async {
      final sockets = <FakeLnsSocket>[];
      final connection = connectionWith(sockets);

      final first = connection.invoke('First', null);
      final second = connection.invoke('Second', null);
      await pumpEventQueue();
      final socket = sockets.single;
      final frames = <Map<dynamic, dynamic>>[
        for (var index = 1; index < socket.sent.length; index++)
          frameAt(socket, index),
      ];
      final firstId =
          frames.firstWhere(
                (frame) => frame['target'] == 'First',
              )['invocationId']
              as String;
      final secondId =
          frames.firstWhere(
                (frame) => frame['target'] == 'Second',
              )['invocationId']
              as String;

      final firstBody = jsonEncode(<String, Object?>{
        'type': 3,
        'invocationId': firstId,
        'result': 'first',
      });
      final secondBody = jsonEncode(<String, Object?>{
        'type': 3,
        'invocationId': secondId,
        'result': 'second',
      });
      final splitAt = secondBody.length ~/ 2;

      // 粘包：两个完成帧挤在同一个 chunk；后半帧再从中间拆断。
      socket.emit('$firstBody\u001e${secondBody.substring(0, splitAt)}');
      socket.emit('${secondBody.substring(splitAt)}\u001e');

      expect(await first, 'first');
      expect(await second, 'second');
    });

    test('服务端完成帧带 error：未授权归 auth', () async {
      final sockets = <FakeLnsSocket>[];
      final connection = connectionWith(sockets);

      final future = connection.invoke('X', null);
      await pumpEventQueue();
      final socket = sockets.single;
      socket.emit(
        completion(
          frameAt(socket, 1)['invocationId'] as String,
          error: 'Unauthorized',
        ),
      );

      await expectLater(
        future,
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
    });

    test('握手失败（error 帧）暴露为来源错误', () async {
      final sockets = <FakeLnsSocket>[];
      final connection = connectionWith(sockets, autoHandshake: false);

      final future = connection.invoke('X', null);
      await pumpEventQueue();
      sockets.single.emit('{"error":"Unauthorized"}\u001e');

      await expectLater(
        future,
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
    });
  });

  group('T4 响应解包', () {
    const decoder = LnsResponseDecoder();

    test('GZIP + Base64 应答解成 JSON', () {
      final payload = jsonEncode(<String, Object?>{
        'Books': <Object?>[
          <String, Object?>{'Id': 1, 'Title': '书'},
        ],
      });
      final compressed = gzip.encode(utf8.encode(payload));
      final decoded = decoder.unwrap(<String, Object?>{
        'Success': true,
        'Response': base64Encode(compressed),
      });

      final map = decoded! as Map<dynamic, dynamic>;
      expect((map['Books'] as List<dynamic>), hasLength(1));
    });

    test('非压缩响应原样返回', () {
      final decoded = decoder.unwrap(envelope(<String, Object?>{'Page': 1}));
      expect(decoded, <String, Object?>{'Page': 1});
    });

    test('Success=false：401 归 auth，其余归 network', () {
      expect(
        () => decoder.unwrap(<String, Object?>{
          'Success': false,
          'Status': 401,
          'Msg': '未登录',
        }),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(
        () => decoder.unwrap(<String, Object?>{
          'Success': false,
          'Status': 500,
          'Msg': '服务器炸了',
        }),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.network,
          ),
        ),
      );
    });

    test('缺少成功状态视为解析错误', () {
      expect(
        () =>
            decoder.unwrap(<String, Object?>{'Response': <String, Object?>{}}),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );
    });
  });

  group('T4 限流', () {
    test('9 次直通，第 10 次等待到滑动窗口释放', () async {
      var now = 0;
      final waits = <int>[];
      final limiter = ShelfRateLimiter(
        clock: () => now,
        sleep: (duration) async {
          waits.add(duration.inMilliseconds);
          now += duration.inMilliseconds;
        },
      );

      for (var index = 0; index < 9; index++) {
        await limiter.run(() async => index);
      }
      expect(waits, isEmpty);

      final tenth = await limiter.run(() async => 10);
      expect(tenth, 10);
      expect(waits, hasLength(1));
      expect(waits.single >= 500, isTrue);
    });
  });

  group('T4 备用端降级', () {
    test('主端网络错误：重置主端并切备用端一次', () async {
      final primary = StubHub(
        (target, params) async => throw const SourceException(
          sourceId: lnsSourceId,
          type: SourceErrorType.network,
          message: '主端挂了',
        ),
      );
      var fallbackCalls = 0;
      final fallback = StubHub((target, params) async {
        fallbackCalls += 1;
        return <String, Object?>{'ok': true};
      });
      final connection = FallbackLnsHubConnection(
        primary: primary,
        fallback: fallback,
      );

      expect(await connection.invoke('X', null), <String, Object?>{'ok': true});
      expect(primary.resets, 1);
      expect(fallbackCalls, 1);
    });

    test('非网络错误不降级', () async {
      final primary = StubHub(
        (target, params) async => throw const SourceException(
          sourceId: lnsSourceId,
          type: SourceErrorType.auth,
          message: '未登录',
        ),
      );
      var fallbackCalls = 0;
      final fallback = StubHub((target, params) async {
        fallbackCalls += 1;
        return null;
      });
      final connection = FallbackLnsHubConnection(
        primary: primary,
        fallback: fallback,
      );

      await expectLater(
        connection.invoke('X', null),
        throwsA(isA<SourceException>()),
      );
      expect(fallbackCalls, 0);
      expect(primary.resets, 0);
    });

    test('备用端也失败时不再二次切换', () async {
      const error = SourceException(
        sourceId: lnsSourceId,
        type: SourceErrorType.network,
        message: '都挂了',
      );
      final primary = StubHub((target, params) async => throw error);
      var fallbackCalls = 0;
      final fallback = StubHub((target, params) async {
        fallbackCalls += 1;
        throw error;
      });
      final connection = FallbackLnsHubConnection(
        primary: primary,
        fallback: fallback,
      );

      await expectLater(
        connection.invoke('X', null),
        throwsA(isA<SourceException>()),
      );
      expect(fallbackCalls, 1);
    });
  });

  group('T4 详情与目录解析', () {
    test('Chapters 为空时回退 Chapter（旧字段也要吃到）', () async {
      final gateway = LnsGateway(
        connection: StubHub(
          (target, params) async => envelope(<String, Object?>{
            'Book': <String, Object?>{
              'Id': 7,
              'Title': '书',
              'Chapters': <Object?>[],
              'Chapter': <Object?>[
                <String, Object?>{'Id': 1, 'Title': '一', 'SortNum': 1},
                <String, Object?>{'Id': 2, 'Title': '二', 'SortNum': 2},
              ],
            },
          }),
        ),
        limiter: ShelfRateLimiter(),
      );

      final detail = await gateway.getBookDetail(7);
      expect(detail.chapters.map((chapter) => chapter.id), <int>[1, 2]);
      expect(detail.chapters.map((chapter) => chapter.sortNumber), <int>[1, 2]);
    });

    test('缺少序号时按顺序补号，且不与显式序号冲突', () async {
      final gateway = LnsGateway(
        connection: StubHub(
          (target, params) async => envelope(<String, Object?>{
            'Book': <String, Object?>{
              'Id': 1,
              'Chapters': <Object?>[
                <String, Object?>{'Id': 10, 'Title': '显式二', 'SortNum': 2},
                <String, Object?>{'Id': 11, 'Title': '无号'},
                <String, Object?>{'Id': 12, 'Title': '无号二'},
              ],
            },
          }),
        ),
        limiter: ShelfRateLimiter(),
      );

      final detail = await gateway.getBookDetail(1);
      final numbers = detail.chapters
          .map((chapter) => chapter.sortNumber)
          .toList();
      expect(numbers.toSet().length, numbers.length);
      expect(numbers.contains(2), isTrue);
    });

    test('显式序号重复：抛解析错误', () async {
      final gateway = LnsGateway(
        connection: StubHub(
          (target, params) async => envelope(<String, Object?>{
            'Book': <String, Object?>{
              'Id': 1,
              'Chapters': <Object?>[
                <String, Object?>{'Id': 1, 'Title': '甲', 'SortNum': 3},
                <String, Object?>{'Id': 2, 'Title': '乙', 'SortNum': 3},
              ],
            },
          }),
        ),
        limiter: ShelfRateLimiter(),
      );

      await expectLater(
        gateway.getBookDetail(1),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.parse,
          ),
        ),
      );
    });

    test('完全没有目录字段：抛解析错误', () async {
      final gateway = LnsGateway(
        connection: StubHub(
          (target, params) async => envelope(<String, Object?>{
            'Book': <String, Object?>{'Id': 1},
          }),
        ),
        limiter: ShelfRateLimiter(),
      );

      await expectLater(
        gateway.getBookDetail(1),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('T4 LnsSource 映射', () {
    LnsSource buildSource({
      Object? detail,
      Object? content,
      List<({String target, Object? params})>? calls,
    }) {
      final hub = StubHub((target, params) async {
        calls?.add((target: target, params: params));
        if (target == 'GetNovelContent') return envelope(content);
        return envelope(detail);
      });
      return LnsSource(
        gateway: LnsGateway(connection: hub, limiter: ShelfRateLimiter()),
        auth: LnsAuth(
          http: FakeHttpClient(
            (request) async =>
                const SourceResponse(statusCode: 200, body: '{}'),
          ),
          limiter: ShelfRateLimiter(),
          store: SecureLnsTokenStore(MemorySecureStore()),
        ),
      );
    }

    const item = MediaItem(
      sourceId: LnsSource.id,
      remoteId: '7',
      type: MediaType.novel,
      title: '夹具小说',
    );

    test('详情 / 目录 / 正文映射到统一模型', () async {
      final source = buildSource(
        detail: <String, Object?>{
          'Book': <String, Object?>{
            'Id': 7,
            'Title': '夹具小说',
            'UserName': '作者甲',
            'Cover': 'https://example.com/c.jpg',
            'Introduction': '<p>简介<br/>第二行</p>',
            'Extra': <String, Object?>{
              'classification': <String, Object?>{
                'tags': <Object?>['标签A'],
              },
            },
            'Chapters': <Object?>[
              <String, Object?>{'Id': 11, 'Title': '第 1 章', 'SortNum': 1},
            ],
          },
        },
        content: <String, Object?>{
          'Chapter': <String, Object?>{
            'Id': 11,
            'Title': '第 1 章',
            'SortNum': 1,
            'Content': '<p>正文段落</p>',
          },
        },
      );

      final detail = await source.detail(item);
      expect(detail.author, '作者甲');
      expect(detail.coverUrl, 'https://example.com/c.jpg');
      expect(detail.description, contains('第二行'));
      expect(detail.tags, <String>['标签A']);

      final chapters = await source.chapters(detail);
      expect(chapters, hasLength(1));
      // 章节键带书号：序号只在书内唯一，否则跨书会串号。
      expect(chapters.single.remoteId, '7:1');
      expect(chapters.single.volumeTitle, LnsSource.defaultVolumeTitle);
      expect(chapters.single.number, 1);

      final content = await source.content(chapters.single);
      expect(content.html, '<p>正文段落</p>');
    });

    test('专用字体获取失败：抛来源错误，不返回正文（B7）', () async {
      final http = FakeHttpClient(
        (request) async => const SourceResponse(statusCode: 200, body: '{}'),
      );
      http.bytesHandler = (url) => throw const SourceException(
        sourceId: lnsSourceId,
        type: SourceErrorType.network,
        message: '字体下载失败',
      );
      final source = LnsSource(
        gateway: LnsGateway(
          connection: StubHub(
            (target, params) async => envelope(<String, Object?>{
              'Chapter': <String, Object?>{
                'Id': 11,
                'SortNum': 1,
                'Content': '<p>混淆正文</p>',
                'Font': 'https://example.com/font.ttf',
              },
            }),
          ),
          limiter: ShelfRateLimiter(),
        ),
        auth: LnsAuth(
          http: http,
          limiter: ShelfRateLimiter(),
          store: SecureLnsTokenStore(MemorySecureStore()),
        ),
        fontChannel: LnsFontChannel(http: http),
      );

      await expectLater(
        source.content(
          const Chapter(
            sourceId: LnsSource.id,
            remoteId: '7:1',
            title: '第 1 章',
          ),
        ),
        throwsA(isA<SourceException>()),
      );
    });

    test('发现榜单：热门走 GetBookList(view)，日榜走 GetRank 本地分页', () async {
      final calls = <({String target, Object? params})>[];
      final source = buildSource(
        detail: <String, Object?>{
          'Page': 1,
          'TotalPages': 1,
          'Data': <Object?>[
            <String, Object?>{'Id': 1, 'Title': '书甲'},
            <String, Object?>{'Id': 2, 'Title': '书乙'},
          ],
        },
        calls: calls,
      );

      final popular = await source.discover(
        const DiscoverFeed(id: 'popular', name: '热门'),
      );
      expect(popular.map((entry) => entry.title), <String>['书甲', '书乙']);
      expect(calls.single.target, 'GetBookList');
      expect((calls.single.params! as Map<String, Object?>)['Order'], 'view');

      calls.clear();
      final daily = await source.discover(
        const DiscoverFeed(id: 'daily', name: '日榜'),
        page: 1,
      );
      expect(calls.single.target, 'GetRank');
      expect((calls.single.params! as Map<String, Object?>)['Days'], 1);
      // 榜单是固定快照：翻到第二页时不再重复追加。
      final beyond = await source.discover(
        const DiscoverFeed(id: 'daily', name: '日榜'),
        page: 2,
      );
      expect(daily, isNotEmpty);
      expect(beyond, isEmpty);
    });
  });
}
