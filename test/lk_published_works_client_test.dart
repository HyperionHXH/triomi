import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/secure_store.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/fake_preferences.dart';

String _envelope(Object? data) =>
    jsonEncode(<String, Object?>{'code': 0, 'message': '', 'data': data});

LkClient _client(FakeHttpClient http, {bool loggedIn = true}) {
  final store = MemorySecureStore();
  if (loggedIn) {
    // MemorySecureStore 更新缓存是异步 API；测试先放入 Hive 回退值，
    // 避免 publishedWorks 读取时依赖未等待的写入。
    final preferences = memoryPreferences();
    preferences.set('lk.securityKey', 'session-key-1');
    return LkClient(
      http: http,
      preferences: preferences,
      secureStore: store,
      mainBase: 'https://lk.example/api/pc-proxy/',
    );
  }
  return LkClient(
    http: http,
    preferences: memoryPreferences(),
    secureStore: store,
    mainBase: 'https://lk.example/api/pc-proxy/',
  );
}

void main() {
  group('LK 发布管理解析', () {
    test('解析列表、状态、审核和分页兼容字段', () {
      final page = LkClient.parsePublishedWorksPage(
        <Object?, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'bookId': 101,
              'title': '已完结作品',
              'coverUrl': 'https://img.example/101.jpg',
              'authorName': '作者甲',
              'longSummary': '简介',
              'metaJson': <String, Object?>{
                'type': '原创',
                'serialize_status': '已完结',
              },
              'reviewState': <String, Object?>{'reviewStatus': 'pending'},
              'volumeCount': 2,
              'chapterCount': 18,
              'wordCount': 12000,
              'updatedAt': '2026-10-08',
            },
            <String, Object?>{
              'id': 102,
              'title': '审核通过作品',
              'isCompleted': true,
              'review_status': 'approved',
              'review_state': <String, Object?>{'progress_text': '已进入推荐池'},
            },
            <String, Object?>{'book_id': 103, 'title': '隐藏作品', 'status': 2},
            <String, Object?>{'book_id': 104, 'title': '草稿作品', 'status': 0},
            <String, Object?>{'book_id': 105, 'title': '连载作品', 'status': 1},
            <String, Object?>{'book_id': 0, 'title': '无效作品'},
          ],
          'pageInfo': <String, Object?>{
            'total': 21,
            'pageSize': 5,
            'hasNext': true,
          },
        },
        2,
        5,
      );

      expect(page.page, 2);
      expect(page.total, 21);
      expect(page.hasMore, isTrue);
      expect(page.items, hasLength(5));

      final first = page.items[0];
      expect(first.id, 101);
      expect(first.coverUrl, 'https://img.example/101.jpg');
      expect(first.author, '作者甲');
      expect(first.summary, '简介');
      expect(first.type, '原创');
      expect(first.status, '已完本');
      expect(first.reviewStatus, 'pending');
      expect(first.reviewText, '审核中');
      expect(first.volumeCount, 2);
      expect(first.chapterCount, 18);
      expect(first.wordCount, 12000);

      expect(page.items[1].status, '已完本');
      expect(page.items[1].reviewText, '已进入推荐池');
      expect(page.items[2].status, '已隐藏');
      expect(page.items[3].status, '草稿中');
      expect(page.items[4].status, '连载中');
    });

    test('没有分页信息时按本页大小推断是否还有下一页', () {
      final page = LkClient.parsePublishedWorksPage(
        <Object?, Object?>{
          'list': <Object?>[
            <String, Object?>{'book_id': 1, 'title': '作品一'},
            <String, Object?>{'book_id': 2, 'title': '作品二'},
          ],
        },
        1,
        2,
      );

      expect(page.total, 2);
      expect(page.hasMore, isTrue);
    });
  });

  group('LK 发布管理请求', () {
    test('登录后发送已验证端点和会话参数', () async {
      final http = FakeHttpClient(
        (request) async => SourceResponse(
          statusCode: 200,
          body: _envelope(<String, Object?>{
            'list': <Object?>[
              <String, Object?>{'book_id': 7, 'title': '我的作品'},
            ],
            'pagination': <String, Object?>{'total': 1, 'has_more': false},
          }),
          url: request.url,
        ),
      );

      final page = await _client(http).publishedWorks(page: 3, pageSize: 25);

      expect(page.page, 3);
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
      expect(page.items.single.title, '我的作品');
      expect(http.requests, hasLength(1));
      final request = http.requests.single;
      expect(
        request.url,
        'https://lk.example/api/pc-proxy/api/bff/longform-book-list-v1',
      );
      final body = jsonDecode(request.body!) as Map<Object?, Object?>;
      expect(body['security_key'], 'session-key-1');
      expect(body['page'], 3);
      expect(body['pageSize'], 25);
    });

    test('未登录时返回 auth 错误且不发网络请求', () async {
      final http = FakeHttpClient(
        (_) async => const SourceResponse(statusCode: 200, body: '{}'),
      );

      await expectLater(
        _client(http, loggedIn: false).publishedWorks(),
        throwsA(
          isA<SourceException>().having(
            (error) => error.type,
            'type',
            SourceErrorType.auth,
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });
  });
}
