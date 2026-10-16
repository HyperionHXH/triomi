import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/flutter_js_runtime.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

void main() {
  Future<JsSource> prepare(String file, FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(File('assets/rules/$file').readAsStringSync()),
      runtime: FlutterJsRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  test('MangaDex 随包脚本在真实 JS 引擎中发现/搜索/章节/正文 URL 正确', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.host, 'api.mangadex.org');
      expect(uri.path, isNot(contains('https:')));
      final node = {
        'id': 'm1',
        'attributes': {
          'title': {'zh': '漫画'},
        },
        'relationships': <Object?>[],
      };
      final Object result;
      if (uri.path == '/manga') {
        result = {
          'data': [node],
        };
      } else if (uri.path == '/manga/m1') {
        result = {'data': node};
      } else if (uri.path == '/manga/m1/feed') {
        result = {
          'data': [
            {
              'id': 'c1',
              'attributes': {'chapter': '1'},
            },
          ],
        };
      } else if (uri.path == '/at-home/server/c1') {
        result = {
          'baseUrl': 'https://images.test',
          'chapter': {
            'hash': 'hash',
            'data': ['page.jpg'],
          },
        };
      } else {
        fail('unexpected request: ${request.url}');
      }
      return SourceResponse(statusCode: 200, body: jsonEncode(result));
    });
    final source = await prepare('mangadex-api-js.json', http);
    final items = await source.discover(source.feeds.first, page: 2);
    expect(Uri.parse(http.requests.first.url).queryParameters['offset'], '20');
    expect(items.single.title, '漫画');
    expect((await source.search('测试', page: 3)).single.remoteId, 'm1');
    expect(Uri.parse(http.requests[1].url).queryParameters['offset'], '40');
    final chapters = await source.chapters(items.single);
    final content = await source.content(chapters.single);
    expect(content.images, ['https://images.test/data/hash/page.jpg']);
  });

  test('AGE 真实 JS 引擎贯通发现搜索目录和网页播放元数据', () async {
    final source = await prepare(
      'age-anime-js.json',
      FakeHttpClient((request) async {
        final path = Uri.parse(request.url).path;
        return SourceResponse(
          statusCode: 200,
          body: path.startsWith('/play/')
              ? '<iframe id="iframeForVideo" src="https://player.test/watch"></iframe>'
              : path.startsWith('/detail/')
              ? '<div class="video_detail_desc">芙莉莲简介</div><ul class="video_detail_episode"><li><a href="/play/20230207/2/8">第08集</a></li></ul>'
              : '<div class="video_item"><div class="video_item-title"><a href="/detail/20230207">葬送的芙莉莲</a></div></div>',
        );
      }),
    );
    final item = (await source.discover(source.feeds.first)).single;
    expect((await source.search('葬送的芙莉莲')).single.remoteId, item.remoteId);
    final chapters = await source.chapters(item);
    expect(chapters.single.remoteId, '20230207/2/8');
    expect(chapters.single.number, 8);
    final content = await source.content(chapters.single);
    final line = content.playSources.single;
    expect(line.webPage, isTrue);
    expect(line.url, 'https://player.test/watch');
    expect(line.headers['Referer'], contains('/play/20230207/2/8'));
    expect(line.unavailableVideoUrls.single, endsWith('cdb1f81a39c6b0.mp4'));
    final restored = ChapterContent.fromJson(content.toJson())!
        .playSources
        .single;
    expect(restored.webPage, isTrue);
    expect(restored.headers, line.headers);
    expect(restored.unavailableVideoUrls, line.unavailableVideoUrls);
  });

  test('Archive 随包脚本接受绝对榜单 URL，搜索限动画，返回真实条目 MP4 地址', () async {
    final http = FakeHttpClient((request) async {
      final uri = Uri.parse(request.url);
      expect(uri.host, 'archive.org');
      final Object result;
      if (uri.path == '/advancedsearch.php') {
        expect(uri.queryParameters['q'], contains('collection:animation'));
        result = {
          'response': {
            'docs': [
              {'identifier': 'animation-id', 'title': '馆藏动画'},
            ],
          },
        };
      } else if (uri.path == '/metadata/animation-id') {
        result = {
          'metadata': {'title': '馆藏动画'},
          'files': [
            {'name': 'movie file.mp4', 'format': 'MPEG4'},
            {'name': 'info.txt', 'format': 'Text'},
          ],
        };
      } else {
        fail('unexpected request: ${request.url}');
      }
      return SourceResponse(statusCode: 200, body: jsonEncode(result));
    });
    final source = await prepare('archive-animation-js.json', http);
    final item = (await source.discover(source.feeds.first, page: 2)).single;
    expect(Uri.parse(http.requests.first.url).queryParameters['page'], '2');
    expect((await source.search('动画')).single.remoteId, item.remoteId);
    final chapters = await source.chapters(item);
    final content = await source.content(chapters.single);
    expect(
      content.playSources.single.url,
      'https://archive.org/download/animation-id/movie%20file.mp4',
    );
  });
}
