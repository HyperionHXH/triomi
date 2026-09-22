import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/declarative_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/features/player/data/dandanplay_client.dart';
import 'package:triomi/features/schedule/data/bangumi_schedule_client.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  group('Bangumi 每日放送解析', () {
    final calendarJson = jsonEncode(<Object?>[
      <String, Object?>{
        'weekday': <String, Object?>{'id': 1, 'cn': '周一'},
        'items': <Object?>[
          <String, Object?>{
            'id': 1001,
            'name': 'Original Name',
            'name_cn': '夹具新番甲',
            'air_date': '2026-09-01',
            'rating': <String, Object?>{'score': 7.8},
            'images': <String, Object?>{
              'large': 'https://example.com/cover.jpg',
            },
            'url': 'https://bgm.tv/subject/1001',
          },
          <String, Object?>{
            'id': 1002,
            'name': '只有日文名的作品',
            'name_cn': '',
            'rating': <String, Object?>{'score': '8.6'},
            'images': null,
          },
        ],
      },
      <String, Object?>{
        // weekday 缺失的天应被跳过
        'items': <Object?>[],
      },
    ]);

    BangumiScheduleClient clientOf(FakeHttpClient http) =>
        BangumiScheduleClient(
          http: http,
          baseUrl: 'http://fixture.local/calendar',
        );

    test('解析星期分组、中文名优先、评分容错', () async {
      final client = clientOf(routingHttpClient({'/calendar': calendarJson}));

      final days = await client.fetchWeekly();
      expect(days, hasLength(1));
      expect(days.first.weekday, 1);
      expect(days.first.label, '周一');
      expect(days.first.items, hasLength(2));

      final first = days.first.items.first;
      expect(first.title, '夹具新番甲');
      expect(first.rating, 7.8);
      expect(first.coverUrl, 'https://example.com/cover.jpg');

      // name_cn 为空时回退 name；字符串评分也能解析；缺图片不崩
      final second = days.first.items.last;
      expect(second.title, '只有日文名的作品');
      expect(second.rating, 8.6);
      expect(second.coverUrl, isNull);
    });

    test('返回非法 JSON 时抛出解析错误', () {
      final client = clientOf(routingHttpClient({'/calendar': 'not-json'}));
      expect(client.fetchWeekly(), throwsException);
    });
  });

  group('弹弹play 弹幕解析', () {
    test('解析 p 字段的时间/模式/颜色，跳过无效条目', () {
      final body = jsonEncode(<String, Object?>{
        'code': 0,
        'comments': <Object?>[
          <String, Object?>{'p': '1.5,1,16744448,100', 'm': '滚动弹幕'},
          <String, Object?>{'p': '2.0,5,16777215,100', 'm': '顶部弹幕'},
          <String, Object?>{'p': '3.0,4,65280,100', 'm': '底部弹幕'},
          <String, Object?>{'p': '4.0,1,16777215,100', 'm': ''},
          <String, Object?>{'m': '缺 p 字段'},
          <String, Object?>{'p': 'abc,1,0,1', 'm': '时间非法'},
        ],
      });

      final comments = DandanplayClient.parseCommentsBody(body);
      expect(comments, hasLength(3));
      expect(comments[0].time, 1.5);
      expect(comments[0].mode, 1);
      expect(comments[0].color, 16744448);
      expect(comments[1].mode, 5);
      expect(comments[2].mode, 4);
      expect(comments[2].color, 65280);
    });

    test('坏 JSON 返回空列表而不是抛异常（弹幕缺失不影响播放）', () {
      expect(DandanplayClient.parseCommentsBody('{{{'), isEmpty);
    });

    test('签名是 28 字符的 Base64（SHA1 摘要）', () {
      final signature = DandanplayClient.sign(
        '/api/v2/search/episodes',
        appId: 'testId',
        appSecret: 'testSecret',
        timestamp: '1700000000',
      );
      expect(signature.length, 28);
    });
  });

  group('番剧声明式规则：播放线路与弹幕', () {
    const detailHtml = '''
<html><body>
<h1>夹具番剧</h1>
<ul class="episodes">
  <li><a href="/play/101-1">第 1 话</a></li>
  <li><a href="/play/101-2">第 2 话</a></li>
</ul>
</body></html>''';

    const playHtml = '''
<html><body>
<div class="lines">
  <div class="line"><span class="line-name">线路A</span><a class="line-url" href="/video/sample.mp4">A 源</a></div>
  <div class="line"><span class="line-name">线路B</span><a class="line-url" href="/video/alt.mp4">B 源</a></div>
</div>
</body></html>''';

    const danmakuBody = '{"comments":[{"p":"1.0,1,16777215,1","m":"测试弹幕"}]}';

    final ruleJson = jsonEncode(<String, Object?>{
      'id': 'fixture-anime',
      'name': '夹具番剧源',
      'type': 'anime',
      'baseUrl': 'http://fixture.local',
      'capabilities': ['detail', 'content'],
      'detail': <String, Object?>{
        'url': '{urlRaw}',
        'fields': <String, Object?>{'title': 'h1'},
        'chapters': <String, Object?>{
          'list': '.episodes li',
          'fields': <String, Object?>{
            'remoteId': <String, Object?>{
              'selector': 'a',
              'attr': 'href',
              'regex': r'/play/([\w-]+)',
            },
            'title': 'a',
            'url': <String, Object?>{
              'selector': 'a',
              'attr': 'href',
              'absolute': true,
            },
          },
        },
      },
      'content': <String, Object?>{
        'playSources': <String, Object?>{
          'list': '.lines .line',
          'fields': <String, Object?>{
            'name': '.line-name',
            'url': <String, Object?>{
              'selector': 'a.line-url',
              'attr': 'href',
              'absolute': true,
            },
          },
        },
        'danmaku': '/danmaku/{id}.json',
      },
    });

    test('目录 → 播放线路（多线路）→ 弹幕地址全链路', () async {
      final http = routingHttpClient({
        '/play/': playHtml,
        '/anime/': detailHtml,
        '/danmaku/': danmakuBody,
      });
      final source = DeclarativeSource(
        rule: SourceRule.parseJson(ruleJson),
        http: http,
      );

      const item = MediaItem(
        sourceId: 'fixture-anime',
        remoteId: '101',
        type: MediaType.anime,
        title: '夹具番剧',
        url: 'http://fixture.local/anime/101',
      );

      final chapters = await source.chapters(item);
      expect(chapters, hasLength(2));
      expect(chapters.first.remoteId, '101-1');
      expect(chapters.first.url, 'http://fixture.local/play/101-1');

      final content = await source.content(chapters.first);
      expect(content.playSources, hasLength(2));
      expect(content.playSources[0].name, '线路A');
      expect(
        content.playSources[0].url,
        'http://fixture.local/video/sample.mp4',
      );
      expect(content.playSources[1].url, 'http://fixture.local/video/alt.mp4');

      // 弹幕地址里的 {id} 渲染为章节 remoteId
      expect(content.danmakuUrl, 'http://fixture.local/danmaku/101-1.json');

      // 弹幕地址返回的数据可以被同一个解析器消费（播放器就是这么接的）
      final response = await http.send(
        SourceRequest(url: content.danmakuUrl!),
        sourceId: 'fixture-anime',
      );
      final comments = DandanplayClient.parseCommentsBody(response.body);
      expect(comments, hasLength(1));
      expect(comments.first.text, '测试弹幕');
    });

    test('Chapter.parseNumber 兼容「第 12.5 话」', () {
      expect(Chapter.parseNumber('第 12.5 话'), 12.5);
      expect(Chapter.parseNumber('没有数字的标题'), isNull);
    });
  });
}
