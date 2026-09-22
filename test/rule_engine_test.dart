import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/source/declarative_source.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/json_path.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/selector_engine.dart';

import 'fixtures/fake_http_client.dart';

/// 一份「HTML 站点」的示例规则，覆盖相对/绝对地址、正则提取、多选择器兜底。
Map<String, Object?> htmlRuleJson() => <String, Object?>{
  'id': 'test-manga',
  'name': '测试漫画源',
  'type': 'manga',
  'lang': 'zh',
  'baseUrl': 'https://example.com',
  'capabilities': <String>['search', 'detail', 'content'],
  'search': <String, Object?>{
    'url': '/search?q={keyword}&page={page}',
    'list': '.list .item',
    'fields': <String, Object?>{
      'remoteId': <String, Object?>{
        'selector': 'a.title',
        'attr': 'href',
        // 从 /manga/12 里抠出 12 作为源内标识
        'regex': r'/manga/(\d+)',
      },
      'title': 'a.title',
      'url': <String, Object?>{
        'selector': 'a.title',
        'attr': 'href',
        'absolute': true,
      },
      'coverUrl': <String, Object?>{
        'selector': 'img.cover',
        'attr': 'data-src',
        'absolute': true,
      },
      'author': '.author',
    },
  },
  'detail': <String, Object?>{
    'url': '{urlRaw}',
    'fields': <String, Object?>{'title': 'h1', 'description': '.summary'},
    'chapters': <String, Object?>{
      'list': '.chapters li',
      'fields': <String, Object?>{
        'remoteId': <String, Object?>{
          'selector': 'a',
          'attr': 'href',
          'regex': r'/chapter/(\d+)',
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
    // 第一个选择器在这份夹具里取不到值，用于验证「依次尝试」的兜底
    'images': <String>['#reader img@data-original', '#reader img@src'],
    'text': '.content',
  },
};

const String searchHtml = '''
<html><body>
  <div class="list">
    <div class="item">
      <a class="title" href="/manga/12">作品甲</a>
      <img class="cover" data-src="/cover/12.jpg" />
      <span class="author">作者甲</span>
    </div>
    <div class="item">
      <a class="title" href="/manga/13">作品乙</a>
      <img class="cover" data-src="//cdn.example.com/cover/13.jpg" />
      <span class="author">作者乙</span>
    </div>
  </div>
</body></html>
''';

const String detailHtml = '''
<html><body>
  <h1>作品甲</h1>
  <div class="summary">一段简介。</div>
  <ul class="chapters">
    <li><a href="/chapter/101">第 1 话</a></li>
    <li><a href="/chapter/102">第 2 话</a></li>
  </ul>
</body></html>
''';

const String contentHtml = '''
<html><body>
  <h1>第 1 话</h1>
  <div id="reader">
    <img src="/img/1-1.jpg" />
    <img src="/img/1-2.jpg" />
  </div>
</body></html>
''';

void main() {
  group('选择器引擎', () {
    test('CSS 选择器取文本与属性', () {
      final nodes = HtmlSelector.selectAll(searchHtml, '.list .item');
      expect(nodes, hasLength(2));
      expect(
        HtmlSelector.extractWithin(
          nodes.first,
          const FieldSpec(selector: 'a.title'),
        ),
        '作品甲',
      );
      expect(
        HtmlSelector.extractWithin(
          nodes.first,
          const FieldSpec(selector: 'img.cover', attr: 'data-src'),
        ),
        '/cover/12.jpg',
      );
    });

    test('XPath 支持文档级、相对级与属性选择', () {
      expect(
        HtmlSelector.selectAll(searchHtml, '//div[@class="item"]'),
        hasLength(2),
      );
      expect(
        HtmlSelector.selectAll(
          searchHtml,
          '//div[@class="item"]/span[@class="author"]',
        ),
        hasLength(2),
      );

      // 相对查询：从列表项节点内部找标题
      final items = HtmlSelector.selectAll(searchHtml, '//div[@class="item"]');
      expect(
        HtmlSelector.extractWithin(
          items.first,
          const FieldSpec(selector: './/a'),
        ),
        '作品甲',
      );

      // `//a/@href` 由 XPath 直接返回属性值
      final attrNodes = HtmlSelector.selectAll(
        searchHtml,
        '//div[@class="item"]/a/@href',
      );
      expect(attrNodes.first.directAttribute, '/manga/12');
    });

    test('字段简写 img@data-src 会被拆成选择器 + 属性', () {
      final spec = FieldSpec.parseInline('img.cover@data-src');
      expect(spec.selector, 'img.cover');
      expect(spec.attr, 'data-src');
      expect(FieldSpec.parseInline('a.title').attr, 'text');
    });

    test('相对地址补全', () {
      expect(
        resolveUrl('https://example.com/a/b', '/c/d'),
        'https://example.com/c/d',
      );
      expect(
        resolveUrl('https://example.com/a/', '//cdn.example.com/x.jpg'),
        'https://cdn.example.com/x.jpg',
      );
      expect(
        resolveUrl('https://example.com', 'http://other.com/x'),
        'http://other.com/x',
      );
    });

    test('正文转纯文本保留段落、去掉标签并还原实体', () {
      final text = htmlToPlainText('<p>甲&amp;乙</p><p>丙<br/>丁</p>');
      expect(text, contains('甲&乙'));
      expect(text, contains('丙\n丁'));
      expect(text, isNot(contains('<p>')));
    });
  });

  group('规则解析', () {
    test('合法规则可以解析出自检通过的结构', () {
      final rule = SourceRule.parseJson(jsonEncode(htmlRuleJson()));
      expect(rule.descriptor.id, 'test-manga');
      expect(rule.descriptor.type, MediaType.manga);
      expect(rule.descriptor.capabilities, contains(SourceCapability.search));
      expect(rule.search?.fields['title']?.selector, 'a.title');
    });

    test('缺少必要字段时给出可读的报错', () {
      expect(
        () => SourceRule.parseJson(jsonEncode(<String, Object?>{'name': 'x'})),
        throwsA(
          isA<RuleFormatException>().having(
            (error) => error.message,
            'message',
            contains('缺少 id'),
          ),
        ),
      );
      expect(
        () => SourceRule.parseJson(
          jsonEncode(<String, Object?>{
            'id': 'a',
            'name': 'b',
            'type': 'music',
          }),
        ),
        throwsA(isA<RuleFormatException>()),
      );
      expect(
        () => SourceRule.parseJson('{ not json'),
        throwsA(isA<RuleFormatException>()),
      );
    });

    test('能力声明与规则内容不一致时自检失败', () {
      // 声明了 content 能力，却把 content 规则删掉 → 自检必须拦下来
      final broken = htmlRuleJson()..remove('content');
      expect(
        () => SourceRule.parseJson(jsonEncode(broken)),
        throwsA(
          isA<RuleFormatException>().having(
            (error) => error.message,
            'message',
            contains('content'),
          ),
        ),
      );
    });

    test('请求模板渲染：关键词、分页与偏移量', () {
      final rule = SourceRule.parseJson(jsonEncode(htmlRuleJson()));
      final request = rule.search!.request!.render(
        baseUrl: rule.baseUrl,
        keyword: '测试 关键词',
        page: 3,
      );
      expect(request.url, contains('q=${Uri.encodeComponent('测试 关键词')}'));
      expect(request.url, endsWith('page=3'));
    });
  });

  group('声明式来源：HTML 全链路', () {
    late DeclarativeSource source;
    late FakeHttpClient http;

    setUp(() {
      http = routingHttpClient(<String, String>{
        '/search': searchHtml,
        'https://example.com/manga/12': detailHtml,
        'https://example.com/chapter/101': contentHtml,
      });
      source = DeclarativeSource(
        rule: SourceRule.parseJson(jsonEncode(htmlRuleJson())),
        http: http,
      );
    });

    test('搜索：提取字段并补全绝对地址', () async {
      final items = await source.search('作品');
      expect(items, hasLength(2));

      final first = items.first;
      expect(first.remoteId, '12');
      expect(first.title, '作品甲');
      expect(first.url, 'https://example.com/manga/12');
      expect(first.coverUrl, 'https://example.com/cover/12.jpg');
      expect(first.author, '作者甲');
      expect(first.type, MediaType.manga);
      expect(first.sourceId, 'test-manga');

      // 协议相对地址要按当前站点协议补全
      expect(items[1].coverUrl, 'https://cdn.example.com/cover/13.jpg');
    });

    test('详情：补全简介，并解析出章节目录', () async {
      final items = await source.search('作品');
      final detail = await source.detail(items.first);
      expect(detail.title, '作品甲');
      expect(detail.description, '一段简介。');

      final chapters = await source.chapters(detail);
      expect(chapters, hasLength(2));
      expect(chapters.first.remoteId, '101');
      expect(chapters.first.title, '第 1 话');
      expect(chapters.first.url, 'https://example.com/chapter/101');
      // 章节号从标题里尽力解析
      expect(chapters.first.number, 1);
      expect(chapters.last.sortIndex, 1);
    });

    test('正文：图片选择器按顺序兜底', () async {
      final items = await source.search('作品');
      final detail = await source.detail(items.first);
      final chapters = await source.chapters(detail);

      final content = await source.content(chapters.first);
      expect(content.images, <String>[
        'https://example.com/img/1-1.jpg',
        'https://example.com/img/1-2.jpg',
      ]);
      expect(content.playSources, isEmpty);
    });
  });

  group('声明式来源：JSON 接口（Bangumi 规则）', () {
    late String ruleText;

    setUpAll(() {
      // 直接读随包分发的规则文件，确保「发出去的规则」本身是可用的
      ruleText = File('assets/rules/bangumi-anime.json').readAsStringSync();
    });

    test('随包规则可以通过解析与自检', () {
      final rule = SourceRule.parseJson(ruleText);
      expect(rule.descriptor.id, 'bangumi-anime');
      expect(rule.response, ResponseFormat.json);
      expect(rule.descriptor.type, MediaType.anime);
      expect(rule.descriptor.capabilities, contains(SourceCapability.detail));
    });

    test('搜索：POST 请求体按模板渲染，中文名缺失时用原名兜底', () async {
      final http = routingHttpClient(<String, String>{
        '/v0/search/subjects': jsonEncode(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 1001,
              'name': 'Fate/stay night',
              'name_cn': '',
              'summary': '简介一',
              'images': <String, Object?>{'large': 'https://img/1001.jpg'},
              'rating': <String, Object?>{'score': 8.6},
              'platform': 'TV',
            },
            <String, Object?>{
              'id': 1002,
              'name': 'Steins;Gate',
              'name_cn': '命运石之门',
              'images': <String, Object?>{'large': 'https://img/1002.jpg'},
              'rating': <String, Object?>{'score': 9.1},
            },
          ],
        }),
      });

      final source = DeclarativeSource(
        rule: SourceRule.parseJson(ruleText),
        http: http,
      );
      final items = await source.search('fate', page: 2);

      expect(items, hasLength(2));
      // name_cn 为空时用 name 兜底，否则这一条会被丢掉
      expect(items.first.title, 'Fate/stay night');
      expect(items.first.remoteId, '1001');
      expect(items.first.rating, 8.6);
      expect(items[1].title, '命运石之门');

      final request = http.lastRequest;
      expect(request.method, 'POST');
      expect(request.bodyType, RequestBodyType.json);
      expect(jsonDecode(request.body!), <String, Object?>{
        'keyword': 'fate',
        'filter': <String, Object?>{
          'type': <int>[2],
        },
      });
      // 第 2 页 → offset = 20
      expect(request.url, contains('offset=20'));
    });

    test('详情与剧集目录：按 {id} 拼地址', () async {
      final http = routingHttpClient(<String, String>{
        '/v0/subjects/1002': jsonEncode(<String, Object?>{
          'id': 1002,
          'name_cn': '命运石之门',
          'summary': '详情简介',
          'images': <String, Object?>{'large': 'https://img/1002.jpg'},
          'rating': <String, Object?>{'score': 9.1},
          'platform': 'TV',
        }),
        '/v0/episodes': jsonEncode(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 2001,
              'name': 'Ep1',
              'name_cn': '',
              'sort': 1,
              'airdate': '2011-04-06',
            },
            <String, Object?>{
              'id': 2002,
              'name': 'Ep2',
              'name_cn': '第二话',
              'sort': 2,
              'airdate': '',
            },
          ],
        }),
      });

      final source = DeclarativeSource(
        rule: SourceRule.parseJson(ruleText),
        http: http,
      );
      // 详情页地址由列表页带来；这里直接构造一个作品对象。
      const item = MediaItem(
        sourceId: 'bangumi-anime',
        remoteId: '1002',
        type: MediaType.anime,
        title: '命运石之门',
      );
      final detail = await source.detail(item);
      expect(detail.title, '命运石之门');
      expect(detail.description, '详情简介');

      final chapters = await source.chapters(detail);
      expect(chapters, hasLength(2));
      // name_cn 为空时用站点原名兜底，比生成「第 N 话」更有信息量
      expect(chapters.first.title, 'Ep1');
      expect(chapters.last.title, '第二话');
      expect(chapters.last.number, 2);
      expect(chapters.last.releaseDate, isNull); // 空 airdate 不产生脏数据
      // 第二次请求才是剧集目录，地址由 {id} 拼出
      expect(http.requests.last.url, contains('/v0/episodes'));
      expect(http.requests.last.url, contains('subject_id=1002'));
    });
  });

  group('JSON 点路径', () {
    test('支持嵌套、数组下标与缺失路径', () {
      final data = jsonDecode('{"a":{"b":[{"c":1},"x"]}}');
      expect(jsonPickString(data, 'a.b.0.c'), '1');
      expect(jsonPickString(data, 'a.b.1'), 'x');
      expect(jsonPickString(data, 'a.b.9'), isNull);
      expect(jsonPickString(data, 'a.none.deep'), isNull);
      expect(jsonPickList(data, 'a.b'), hasLength(2));
    });
  });
}
