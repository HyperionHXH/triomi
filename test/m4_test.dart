import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/storage/preferences.dart';
import 'package:triomi/features/novel/data/lk/lk_client.dart';
import 'package:triomi/features/novel/data/lk/lk_source.dart';
import 'package:triomi/features/novel/reader/novel_blocks.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  late Preferences preferences;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('triomi_m4_test');
    Hive.init(tempDir.path);
    preferences = await Preferences.open();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('小说正文解析', () {
    test('HTML：段落、标题、插图与缩进标记', () {
      const html = '''
<html><body>
<h1>第一章 启程</h1>
<p class="ln-paragraph--indent">少年踏出村庄的第一步。</p>
<p>他说：<b>「走吧」</b>&amp;回头。</p>
<p><img src="//img.example.com/a.png" width="400" height="300" /></p>
</body></html>''';

      final blocks = ReaderContentParser.parse(bodyHtml: html, bodyText: '');
      expect(blocks, hasLength(4));
      expect(blocks[0], isA<HeadingBlock>());
      expect((blocks[0] as HeadingBlock).text, '第一章 启程');

      final p1 = blocks[1] as ParagraphBlock;
      expect(p1.firstLineIndent, isTrue);
      expect(p1.text, '少年踏出村庄的第一步。');

      final p2 = blocks[2] as ParagraphBlock;
      expect(p2.firstLineIndent, isFalse);
      expect(p2.text, '他说：「走吧」&回头。');

      final illustration = blocks[3] as IllustrationBlock;
      // 协议相对地址补全为 https
      expect(illustration.url, 'https://img.example.com/a.png');
      expect(illustration.aspectRatio, closeTo(400 / 300, 0.001));
    });

    test('纯文本兜底：[res] 标记替换为占位提示', () {
      final blocks = ReaderContentParser.parse(
        bodyHtml: '',
        bodyText: '第一段。\n[res]img[/res]\n第二段。',
      );
      expect(blocks, hasLength(3));
      expect((blocks[1] as ParagraphBlock).text, '【插图暂时无法加载】');
    });

    test('空正文给出可读占位', () {
      final blocks = ReaderContentParser.parse(bodyHtml: '', bodyText: '');
      expect(blocks, hasLength(1));
      expect((blocks[0] as ParagraphBlock).text, '本章暂无正文');
    });
  });

  group('小说分页器', () {
    TextStyle paragraph() => const TextStyle(fontSize: 16, height: 1.5);
    TextStyle heading() => const TextStyle(fontSize: 20, height: 1.5);

    PaginationStyle style({double height = 300, double width = 320}) =>
        PaginationStyle(
          paragraphStyle: paragraph(),
          headingStyle: heading(),
          pageWidth: width,
          pageHeight: height,
          spacing: 12,
        );

    testWidgets('长段落跨页切分且不丢字', (tester) async {
      final longText = '一个很长的段落。' * 60;
      final pages = paginateReaderBlocks(<ReaderBlock>[
        ParagraphBlock(longText, firstLineIndent: false),
      ], style());
      expect(pages.length, greaterThan(1));

      // 所有页的文本拼回去应该等于原文（首行缩进前缀除外）。
      final joined = <String>[
        for (final page in pages)
          for (final element in page.elements)
            if (element is TextElement) element.text,
      ].join();
      expect(joined, longText);
    });

    testWidgets('插图放不下时顺延到下一页', (tester) async {
      final pages = paginateReaderBlocks(<ReaderBlock>[
        const ParagraphBlock('开头一段。', firstLineIndent: false),
        const IllustrationBlock(
          'https://example.com/i.png',
          width: 400,
          height: 300,
        ),
      ], style(height: 120));
      // 第一页只有文本，插图被挤到下一页。
      expect(pages.length, 2);
      expect(pages[0].elements.single, isA<TextElement>());
      expect(pages[1].elements.single, isA<IllustrationElement>());
    });

    testWidgets('块序号保持原文顺序，供进度回传定位', (tester) async {
      final pages = paginateReaderBlocks(<ReaderBlock>[
        const HeadingBlock('标题'),
        const ParagraphBlock('段落一', firstLineIndent: false),
        const ParagraphBlock('段落二', firstLineIndent: false),
      ], style(height: 300));
      final indices = <int>[
        for (final page in pages)
          for (final element in page.elements) element.blockIndex,
      ];
      expect(indices, everyElement(anyOf(0, 1, 2)));
      expect(indices, orderedEquals(indices..sort()));
    });
  });

  group('轻之国度客户端', () {
    LkClient clientOf(FakeHttpClient http) =>
        LkClient(http: http, preferences: preferences);

    test('信封解析：code != 0 抛出可读错误', () async {
      final http = routingHttpClient({
        '/home-feed-v1': jsonEncode({'code': 401, 'message': '请先登录'}),
      });
      final client = clientOf(http);
      await expectLater(
        client.discover('hot', 1),
        throwsA(
          isA<SourceException>().having(
            (error) => error.userMessage,
            'message',
            contains('请先登录'),
          ),
        ),
      );
    });

    test('booksPage 兼容多候选列表键与 10 分制评分折算', () async {
      final http = routingHttpClient({
        '/home-feed-v1': jsonEncode({
          'code': 0,
          'data': {
            'list': [
              {
                'book_id': 1001,
                'title': '夹具小说',
                'author_name': '作者甲',
                'summary_short': '简介',
                'rating_score_10': 8.6,
                'visible_tags': [
                  '奇幻',
                  {'label': '轻小说'},
                ],
              },
            ],
            'page_info': {'cur': 1, 'count': 1, 'has_more': false},
          },
        }),
      });
      final client = clientOf(http);
      final books = await client.discover('hot', 1);

      expect(books, hasLength(1));
      final book = books.single;
      expect(book.id, 1001);
      expect(book.title, '夹具小说');
      expect(book.score, closeTo(4.3, 0.001));
      expect(book.tags, containsAll(<String>['奇幻', '轻小说']));
    });

    test('章节正文返回 HTML 与纯文本，锁定章节可被解锁记录覆盖', () async {
      // 解锁与目录请求都需要会话；直接预置一个已登录的 key。
      await preferences.set('lk.securityKey', 'k-test-session');
      final http = routingHttpClient({
        '/get-chapter-detail': jsonEncode({
          'code': 0,
          'data': {
            'chapter_id': 7,
            'volume_id': 2,
            'title': '第 3 章',
            'locked': true,
            'book_title': '夹具小说',
            'volume_title': '第一卷',
            'body': {'body_html': '<p>正文内容。</p>', 'body_text': '正文内容。'},
          },
        }),
        '/unlock-chapter': jsonEncode({
          'code': 0,
          'data': {'success': true},
        }),
      });
      final client = clientOf(http);

      final detail = await client.chapter(1001, 7);
      expect(detail.chapter.locked, isTrue);
      expect(detail.bodyHtml, '<p>正文内容。</p>');

      await client.unlockChapter(7);
      final afterUnlock = await client.chapter(1001, 7);
      expect(afterUnlock.chapter.locked, isFalse);
    });

    test('解锁失败（服务端业务拒绝）不写本地已解锁标记', () async {
      final http = routingHttpClient({
        '/unlock-chapter': jsonEncode({
          'code': 0,
          'data': {'success': false, 'message': '轻币不足'},
        }),
      });
      final client = clientOf(http);
      await expectLater(
        client.unlockChapter(9),
        throwsA(isA<SourceException>()),
      );
    });

    test('登录成功后凭据进安全存储，正文请求带上会话', () async {
      // 前面的测试可能预置过会话；本测试从「未登录」状态开始。
      await preferences.set('lk.securityKey', '');
      var loginCalls = 0;
      final http = FakeHttpClient((request) async {
        if (request.url.contains('auth-password-login-v1')) {
          loginCalls += 1;
          return SourceResponse(
            statusCode: 200,
            body: jsonEncode({
              'code': 0,
              'data': {
                'auth': {'security_key': 'k-test-123', 'uid': 42},
                'user': {'nickname': '夹具用户'},
              },
            }),
            url: request.url,
          );
        }
        return SourceResponse(
          statusCode: 200,
          body: jsonEncode({
            'code': 0,
            'data': {
              'list': <Object?>[],
              'page_info': {'has_more': false},
            },
          }),
          url: request.url,
        );
      });
      final client = clientOf(http);

      expect(client.isLoggedIn, isFalse);
      final session = await client.login('user', 'pass');
      expect(session.loggedIn, isTrue);
      expect(session.uid, 42);
      expect(client.isLoggedIn, isTrue);

      // 带会话的发现请求应包含 security_key。
      await client.discover('hot', 1);
      expect(loginCalls, 1);
      final last = http.requests.last;
      final body = jsonDecode(last.body!) as Map<String, Object?>;
      expect(body['security_key'], 'k-test-123');

      await client.logout();
      expect(client.isLoggedIn, isFalse);
    });
  });

  group('轻之国度来源映射', () {
    test('卷→章两级目录展开为带卷标题的章节列表', () async {
      final http = routingHttpClient({
        '/get-book-volumes': jsonEncode({
          'code': 0,
          'data': {
            'list': [
              {'volume_id': 1, 'title': '第一卷'},
              {'volume_id': 2, 'title': '第二卷'},
            ],
          },
        }),
        '/get-volume-chapters': jsonEncode({
          'code': 0,
          'data': {
            'list': [
              {
                'chapter_id': 11,
                'volume_id': 1,
                'title': '第 1 章',
                'chapter_no': 1,
              },
              {
                'chapter_id': 12,
                'volume_id': 1,
                'title': '第 2 章',
                'chapter_no': 2,
                'locked': true,
              },
            ],
          },
        }),
      });
      final source = LkSource(
        client: LkClient(http: http, preferences: preferences),
      );

      const item = MediaItem(
        sourceId: LkSource.id,
        remoteId: '1001',
        type: MediaType.novel,
        title: '夹具小说',
      );
      final chapters = await source.chapters(item);

      expect(chapters, hasLength(4));
      // 每卷的章节都带卷标题，排序索引连续。
      expect(chapters[0].volumeTitle, '第一卷');
      expect(chapters[2].volumeTitle, '第二卷');
      expect(chapters.map((chapter) => chapter.sortIndex), [0, 1, 2, 3]);
      // 付费章节只标注，不绕过。
      expect(chapters[1].locked, isTrue);
      expect(chapters[1].remoteId, '12');
    });

    test('正文映射：HTML 优先，纯文本兜底', () async {
      final http = routingHttpClient({
        '/get-chapter-detail': jsonEncode({
          'code': 0,
          'data': {
            'chapter_id': 11,
            'title': '第 1 章',
            'body': {'body_html': '<p>HTML 正文</p>', 'body_text': '纯文本正文'},
          },
        }),
      });
      final source = LkSource(
        client: LkClient(http: http, preferences: preferences),
      );

      const chapter = Chapter(
        sourceId: LkSource.id,
        remoteId: '11',
        title: '第 1 章',
      );
      final content = await source.content(chapter);
      expect(content.html, '<p>HTML 正文</p>');
      expect(content.text, isNull);
    });
  });
}
