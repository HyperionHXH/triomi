import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/lk_account.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

/// 已登录的客户端（会话存在安全存储里）。
LkClient loggedInClient(FakeHttpClient http) {
  final store = MemorySecureStore();
  store.set('lk.securityKey', 'session-key-1');
  return LkClient(
    http: http,
    preferences: memoryPreferences(),
    secureStore: store,
    mainBase: 'https://lk.example/api/pc-proxy/',
  );
}

String envelope(Object? data) =>
    jsonEncode(<String, Object?>{'code': 0, 'message': '', 'data': data});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LK 评论配图上传', () {
    test('multipart 请求体：字段、文件名、MIME 与边界都按站点要求组', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{
            'image': <String, Object?>{
              'url': 'https://res.lightnovel.fun/comment/a.png',
              'width': 640,
              'height': 480,
              'res_id': 'r-9',
            },
          }),
          url: request.url,
        ),
      );

      final media = await loggedInClient(http).uploadCommentImage(
        bytes: const <int>[1, 2, 3, 4],
        fileName: 'shot.png',
        mimeType: 'image/png',
      );

      expect(media.url, 'https://res.lightnovel.fun/comment/a.png');
      expect(media.width, 640);
      expect(media.height, 480);
      expect(media.resourceId, 'r-9');

      expect(http.uploads, hasLength(1));
      final upload = http.uploads.single;
      expect(upload.method, 'POST');
      expect(
        upload.url,
        'https://lk.example/api/pc-proxy/api/dynamic/upload-image-v1',
      );
      final contentType = upload.headers['Content-Type'] ?? '';
      expect(contentType, startsWith('multipart/form-data; boundary='));
      final boundary = contentType.split('boundary=').last;

      final body = utf8.decode(upload.bytes);
      expect(body, contains('--$boundary\r\n'));
      expect(
        body,
        contains(
          'Content-Disposition: form-data; name="security_key"\r\n\r\nsession-key-1',
        ),
      );
      expect(
        body,
        contains(
          'Content-Disposition: form-data; name="scene"\r\n\r\nbook_comment',
        ),
      );
      expect(
        body,
        contains(
          'Content-Disposition: form-data; name="file"; filename="shot.png"',
        ),
      );
      expect(body, contains('Content-Type: image/png'));
      // 文件字节原样在末尾，且以结束边界收尾。
      expect(body, endsWith('\r\n--$boundary--\r\n'));
    });

    test('响应没有图片地址：报解析错误', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{'image': <String, Object?>{}}),
          url: request.url,
        ),
      );

      await expectLater(
        loggedInClient(http).uploadCommentImage(
          bytes: const <int>[1],
          fileName: 'a.jpg',
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('未返回图片地址'),
          ),
        ),
      );
    });

    test('未登录：直接报认证错误，不发请求', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{}),
          url: request.url,
        ),
      );
      final client = LkClient(
        http: http,
        preferences: memoryPreferences(),
        secureStore: MemorySecureStore(),
        mainBase: 'https://lk.example/api/pc-proxy/',
      );

      await expectLater(
        client.uploadCommentImage(
          bytes: const <int>[1],
          fileName: 'a.jpg',
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(http.uploads, isEmpty);
    });

    test('空图片内容：报解析错误', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(null),
          url: request.url,
        ),
      );

      await expectLater(
        loggedInClient(http).uploadCommentImage(
          bytes: const <int>[],
          fileName: 'a.jpg',
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('图片内容为空'),
          ),
        ),
      );
    });
  });

  group('发表评论带配图', () {
    Future<Map<String, Object?>> publishBody(
      LkClient client,
      FakeHttpClient http, {
      required String text,
      required List<LkCommentMedia> media,
    }) async {
      await client.publishComment(1001, text: text, media: media);
      return jsonDecode(http.lastRequest.body!) as Map<String, Object?>;
    }

    test('media_json 是站点要的数组字符串（含尺寸与 res_id）', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{
            'comment': <String, Object?>{'id': 5},
          }),
          url: request.url,
        ),
      );

      final body = await publishBody(
        loggedInClient(http),
        http,
        text: '看图',
        media: const <LkCommentMedia>[
          LkCommentMedia(
            url: 'https://res.lightnovel.fun/comment/a.png',
            width: 640,
            height: 480,
            resourceId: 'r-9',
          ),
        ],
      );

      expect(
        body['media_json'],
        jsonEncode(<Object?>[
          <String, Object?>{
            'url': 'https://res.lightnovel.fun/comment/a.png',
            'width': 640,
            'height': 480,
            'res_id': 'r-9',
          },
        ]),
      );
      expect(body['content'], '看图');
      expect(body['mention_uids'], isEmpty);
    });

    test('只有图片没有文字：允许发表，content 为空串', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{
            'comment': <String, Object?>{'id': 6},
          }),
          url: request.url,
        ),
      );

      final body = await publishBody(
        loggedInClient(http),
        http,
        text: '   ',
        media: const <LkCommentMedia>[
          LkCommentMedia(url: 'https://res.lightnovel.fun/comment/b.png'),
        ],
      );

      expect(body['content'], '');
      expect(body['media_json'], contains('b.png'));
      // 未提供尺寸 / res_id 时不要塞空字段（站点按项校验）。
      expect(body['media_json'], isNot(contains('width')));
      expect(body['media_json'], isNot(contains('res_id')));
    });

    test('既没有文字也没有图片：报错且不发请求', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(null),
          url: request.url,
        ),
      );

      await expectLater(
        loggedInClient(http).publishComment(1001, text: '  '),
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('评论内容不能为空'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('不带图时 media_json 仍是空数组', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: envelope(<String, Object?>{
            'comment': <String, Object?>{'id': 7},
          }),
          url: request.url,
        ),
      );

      final body = await publishBody(
        loggedInClient(http),
        http,
        text: '纯文字',
        media: const <LkCommentMedia>[],
      );

      expect(body['media_json'], '[]');
    });
  });
}
