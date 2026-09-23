import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_descriptor.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/rule_schema.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/source_repository.dart';

import 'fixtures/fake_http_client.dart';
import 'fixtures/test_database.dart';

/// 预录结果的 JS 引擎替身：验证 JsSource 的映射、能力探测与错误分类，
/// 不依赖原生库（真实引擎另有 `t2_js_engine_test.dart`）。
class FakeJsRuntime implements JsRuntime {
  FakeJsRuntime({
    this.functions = const <String>{},
    Map<String, Object?> responses = const <String, Object?>{},
    this.errors = const <String, String>{},
    this.loadError,
  }) : responses = Map<String, Object?>.of(responses);

  /// 脚本「导出」了哪些函数。
  final Set<String> functions;

  /// 函数名 → 返回值（JSON 可序列化）；测试可随时改写。
  final Map<String, Object?> responses;

  /// 函数名 → 抛出的 JS 错误消息。
  final Map<String, String> errors;

  /// 加载阶段就失败（模拟语法错 / 引擎不可用）。
  final String? loadError;

  JsHostBridge? bridge;
  String? loadedScript;
  String? loadedBaseUrl;
  final List<({String function, List<Object?> args})> calls =
      <({String function, List<Object?> args})>[];
  bool disposed = false;

  @override
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  }) async {
    if (loadError != null) throw JsRuntimeError(loadError!);
    loadedScript = script;
    this.bridge = bridge;
    loadedBaseUrl = baseUrl;
  }

  @override
  Future<bool> hasFunction(String function) async =>
      functions.contains(function);

  @override
  Future<Object?> call(String function, List<Object?> args) async {
    calls.add((function: function, args: args));
    final message = errors[function];
    if (message != null) {
      throw JsRuntimeError(
        message,
        hostError: decodeHostError(message, sourceId: 'js-source'),
      );
    }
    return responses[function];
  }

  @override
  void dispose() => disposed = true;
}

String jsRuleText({
  String script = 'async function discover(url, page) { return []; }',
  Object? feeds,
  String? engine = 'js',
}) => jsonEncode(<String, Object?>{
  'id': 'js-source',
  'name': 'JS 测试源',
  'type': 'manga',
  'lang': 'zh',
  'baseUrl': 'https://example.com',
  'engine': ?engine,
  'feeds':
      feeds ??
      <Object?>[
        <String, Object?>{
          'id': 'hot',
          'name': '热门',
          'url': '/list?page={page}',
        },
      ],
  'script': script,
});

void main() {
  group('JS 规则格式', () {
    test('engine=js + script 解析为脚本规则，feeds 取自顶层', () {
      final rule = SourceRule.parseJson(jsRuleText());
      expect(rule.isScript, isTrue);
      expect(rule.jsCode, isNotNull);
      expect(rule.feeds, hasLength(1));
      expect(rule.feeds.first.id, 'hot');
      // JS 规则的声明式字段为空。
      expect(rule.search, isNull);
      expect(rule.discover, isNull);
    });

    test('只写 script 不写 engine 也按 JS 规则处理', () {
      final rule = SourceRule.parseJson(jsRuleText(engine: null));
      expect(rule.isScript, isTrue);
    });

    test('engine=js 但缺 script 要报可读错误', () {
      final text = jsonEncode(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'type': 'manga',
        'engine': 'js',
      });
      expect(
        () => SourceRule.parseJson(text),
        throwsA(
          isA<RuleFormatException>().having(
            (error) => error.message,
            'message',
            contains('script'),
          ),
        ),
      );
    });

    test('不支持的 engine 要报错', () {
      final text = jsonEncode(<String, Object?>{
        'id': 'x',
        'name': 'X',
        'type': 'manga',
        'engine': 'wasm',
      });
      expect(
        () => SourceRule.parseJson(text),
        throwsA(
          isA<RuleFormatException>().having(
            (error) => error.message,
            'message',
            contains('wasm'),
          ),
        ),
      );
    });

    test('声明式规则不受影响', () {
      final text = jsonEncode(<String, Object?>{
        'id': 'plain',
        'name': '声明式',
        'type': 'manga',
        'capabilities': <String>['search'],
        'search': <String, Object?>{
          'url': '/s?q={keyword}',
          'list': '.item',
          'fields': <String, Object?>{'title': 'a', 'remoteId': 'a'},
        },
      });
      final rule = SourceRule.parseJson(text);
      expect(rule.isScript, isFalse);
      expect(rule.search, isNotNull);
    });
  });

  group('能力探测', () {
    Future<JsSource> sourceWith(
      FakeJsRuntime runtime, {
      SourceHttpClient? http,
    }) async {
      final source = JsSource(
        rule: SourceRule.parseJson(jsRuleText()),
        runtime: runtime,
        http: http ?? routingHttpClient(const <String, String>{}),
      );
      await source.initialize();
      return source;
    }

    test('只导出 search/detail 时能力恰为这两个', () async {
      final source = await sourceWith(
        FakeJsRuntime(functions: const <String>{'search', 'detail'}),
      );
      expect(source.descriptor.capabilities, <SourceCapability>{
        SourceCapability.search,
        SourceCapability.detail,
      });
      expect(source.isReady, isTrue);
    });

    test('导出全部四个函数时四项能力齐备', () async {
      final source = await sourceWith(
        FakeJsRuntime(
          functions: const <String>{'discover', 'search', 'detail', 'content'},
        ),
      );
      expect(source.descriptor.capabilities, hasLength(4));
      expect(source.descriptor.supports(SourceCapability.content), isTrue);
    });

    test('一个函数都没导出时不具备任何能力', () async {
      final source = await sourceWith(FakeJsRuntime());
      expect(source.descriptor.capabilities, isEmpty);
    });

    test('baseUrl 传给引擎（供 triomi.baseUrl 使用）', () async {
      final runtime = FakeJsRuntime(functions: const <String>{'search'});
      await sourceWith(runtime);
      expect(runtime.loadedBaseUrl, 'https://example.com');
    });
  });

  group('JsSource 结果映射', () {
    late FakeJsRuntime runtime;
    late JsSource source;

    setUp(() async {
      runtime = FakeJsRuntime(
        functions: const <String>{'discover', 'search', 'detail', 'content'},
      );
      source = JsSource(
        rule: SourceRule.parseJson(jsRuleText()),
        runtime: runtime,
        http: routingHttpClient(const <String, String>{}),
      );
      await source.initialize();
    });

    test('列表：JSON → MediaItem，含 tags / rating / 可选字段', () async {
      runtime.responses['discover'] = <Object?>[
        <String, Object?>{
          'remoteId': '12',
          'title': '测试漫画',
          'url': 'https://example.com/manga/12',
          'coverUrl': 'https://example.com/c/12.jpg',
          'author': '作者',
          'description': '简介',
          'tags': <Object?>['热血', '  ', '冒险'],
          'rating': '8.5',
          'status': '连载中',
        },
        <String, Object?>{'remoteId': '13', 'title': '第二条'},
        // remoteId 缺失 → 丢弃
        <String, Object?>{'title': '没有 id'},
      ];

      final items = await source.discover(source.feeds.first);

      expect(items, hasLength(2));
      final first = items.first;
      expect(first.sourceId, 'js-source');
      expect(first.remoteId, '12');
      expect(first.type, MediaType.manga);
      expect(first.tags, <String>['热血', '冒险']);
      expect(first.rating, 8.5);
      expect(first.status, '连载中');
      // 第二条只给了必要字段，其余为 null 而不是空串。
      expect(items[1].coverUrl, isNull);
      expect(items[1].author, isNull);
      expect(items[1].tags, isEmpty);
    });

    test('榜单地址的 {page} 由宿主渲染并补全为绝对地址', () async {
      runtime.responses['discover'] = const <Object?>[];

      await source.discover(source.feeds.first, page: 3);

      final call = runtime.calls.single;
      expect(call.function, 'discover');
      expect(call.args.first, 'https://example.com/list?page=3');
      expect(call.args[1], 3);
    });

    test('搜索透传关键字与页码', () async {
      runtime.responses['search'] = const <Object?>[];

      await source.search('关键字', page: 2);

      final call = runtime.calls.single;
      expect(call.function, 'search');
      expect(call.args, <Object?>['关键字', 2]);
    });

    test('详情 + 目录一次调用返回，且按地址缓存不重复请求', () async {
      runtime.responses['detail'] = <String, Object?>{
        'item': <String, Object?>{'title': '补全后的标题'},
        'chapters': <Object?>[
          <String, Object?>{
            'remoteId': 'c1',
            'title': '第 1 话',
            'url': '/chapter/c1',
          },
          <String, Object?>{
            'url': 'https://example.com/chapter/c2',
            'locked': true,
          },
        ],
      };
      final item = MediaItem(
        sourceId: 'js-source',
        remoteId: '12',
        type: MediaType.manga,
        title: '列表页标题',
        url: 'https://example.com/manga/12',
      );

      final detail = await source.detail(item);
      final chapters = await source.chapters(item);

      expect(runtime.calls, hasLength(1), reason: '详情与目录应共用一次调用');
      expect(detail.title, '补全后的标题');
      // 未给出的字段沿用列表页的值。
      expect(detail.remoteId, item.remoteId);
      expect(detail.url, item.url);
      expect(chapters, hasLength(2));
      expect(chapters[0].sourceId, 'js-source');
      expect(chapters[0].url, 'https://example.com/chapter/c1');
      expect(chapters[0].number, 1);
      // 没给标题时按顺序兜底。
      expect(chapters[1].title, '第 2 话');
      expect(chapters[1].locked, isTrue);
    });

    test('正文：图片补全绝对地址，线路与弹幕地址映射正确', () async {
      runtime.responses['content'] = <String, Object?>{
        'images': <Object?>['/img/1.jpg', 'https://cdn.test/2.jpg'],
        'playSources': <Object?>[
          <String, Object?>{'name': '线路一', 'url': '/play/1'},
        ],
        'danmakuUrl': '/danmaku/1.json',
      };
      final chapter = _chapter();

      final content = await source.content(chapter);

      expect(content.images, <String>[
        'https://example.com/img/1.jpg',
        'https://cdn.test/2.jpg',
      ]);
      expect(content.playSources.single.name, '线路一');
      expect(content.playSources.single.url, 'https://example.com/play/1');
      expect(content.danmakuUrl, 'https://example.com/danmaku/1.json');
    });

    test('正文：文本型内容原样透传', () async {
      runtime.responses['content'] = <String, Object?>{'text': '正文内容'};
      final content = await source.content(_chapter());
      expect(content.text, '正文内容');
      expect(content.images, isEmpty);
    });
  });

  group('错误分类', () {
    Future<JsSource> sourceWith(FakeJsRuntime runtime) async {
      final source = JsSource(
        rule: SourceRule.parseJson(jsRuleText()),
        runtime: runtime,
        http: routingHttpClient(const <String, String>{}),
      );
      await source.initialize();
      return source;
    }

    test('JS 异常 → parse，消息里带函数名', () async {
      final runtime = FakeJsRuntime(
        functions: const <String>{'search'},
        errors: const <String, String>{
          'search': "Cannot read property 'body' of undefined",
        },
      );
      final source = await sourceWith(runtime);

      await expectLater(
        source.search('x'),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.parse)
              .having((e) => e.message, 'message', contains('search'))
              .having((e) => e.sourceId, 'sourceId', 'js-source'),
        ),
      );
    });

    test('宿主 fetch 的 auth 错误原样透传，不降级成 parse', () async {
      final runtime = FakeJsRuntime(
        functions: const <String>{'search'},
        errors: const <String, String>{
          'search': '${jsHostErrorPrefix}auth|HTTP 401',
        },
      );
      final source = await sourceWith(runtime);

      await expectLater(
        source.search('x'),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.auth)
              .having((e) => e.message, 'message', 'HTTP 401'),
        ),
      );
    });

    test('宿主超时错误同样透传', () async {
      final runtime = FakeJsRuntime(
        functions: const <String>{'search'},
        errors: const <String, String>{
          'search': '${jsHostErrorPrefix}timeout|请求超时',
        },
      );
      final source = await sourceWith(runtime);

      await expectLater(
        source.search('x'),
        throwsA(
          isA<SourceException>().having(
            (e) => e.type,
            'type',
            SourceErrorType.timeout,
          ),
        ),
      );
    });

    test('调用了未导出的函数时给出可读错误', () async {
      final runtime = FakeJsRuntime(
        functions: const <String>{'search'},
        errors: const <String, String>{'content': 'TRIOMI_NO_FUNCTION|content'},
      );
      final source = await sourceWith(runtime);

      await expectLater(
        source.content(_chapter()),
        throwsA(
          isA<SourceException>()
              .having((e) => e.type, 'type', SourceErrorType.parse)
              .having((e) => e.message, 'message', contains('content')),
        ),
      );
    });
  });

  group('宿主桥（选择器复用声明式引擎）', () {
    late JsHostBridge bridge;

    setUp(() async {
      final runtime = FakeJsRuntime(functions: const <String>{'search'});
      final source = JsSource(
        rule: SourceRule.parseJson(jsRuleText()),
        runtime: runtime,
        http: routingHttpClient(const <String, String>{}),
      );
      await source.initialize();
      bridge = runtime.bridge!;
    });

    const html = '''
      <div class="list">
        <div class="item">
          <a class="title" href="/manga/12">第一条</a>
          <img class="cover" data-src="/c/12.jpg">
          <span class="author">作者甲</span>
        </div>
        <div class="item">
          <a class="title" href="/manga/13">第二条</a>
          <img class="cover" data-src="/c/13.jpg">
          <span class="author">作者乙</span>
        </div>
      </div>
    ''';

    test('selectRows 按字段表提取对象数组并补全地址', () {
      final rows = bridge.selectRows(html, '.list .item', <Object?, Object?>{
        'title': 'a.title',
        'url': <Object?, Object?>{
          'selector': 'a.title',
          'attr': 'href',
          'absolute': true,
        },
        'coverUrl': <Object?, Object?>{
          'selector': 'img.cover',
          'attr': 'data-src',
          'absolute': true,
        },
      }, 'https://example.com');

      expect(rows, hasLength(2));
      expect(rows[0]['title'], '第一条');
      expect(rows[0]['url'], 'https://example.com/manga/12');
      expect(rows[0]['coverUrl'], 'https://example.com/c/12.jpg');
      expect(rows[1]['title'], '第二条');
    });

    test('不给字段表时回退为文本', () {
      final rows = bridge.selectRows(html, '.list .item .author', null, null);
      expect(rows.map((row) => row['text']).toList(), <String>['作者甲', '作者乙']);
    });

    test('selectValue / selectValues 支持 XPath 与属性', () {
      expect(
        bridge.selectValue(html, '.list .item a.title', 'text', null),
        '第一条',
      );
      expect(
        bridge.selectValues(html, '//a[@class="title"]/@href', 'text', null),
        <String>['/manga/12', '/manga/13'],
      );
      expect(
        bridge.selectValues(
          html,
          '.list .item img.cover',
          'data-src',
          'https://example.com',
        ),
        <String>[
          'https://example.com/c/12.jpg',
          'https://example.com/c/13.jpg',
        ],
      );
    });
  });

  group('注册表双轨', () {
    test('JS 规则加载成功后进入来源列表，能力来自探测', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(
        id: 'js-source',
        name: 'JS 测试源',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
      );

      final registry = SourceRegistry(
        repository: repository,
        http: routingHttpClient(const <String, String>{}),
        jsRuntimeFactory: () =>
            FakeJsRuntime(functions: const <String>{'discover', 'search'}),
      );
      final snapshot = await registry.load();

      expect(snapshot.failures, isEmpty);
      final entry = snapshot.entries.single;
      expect(entry.descriptor.id, 'js-source');
      expect(entry.supports(SourceCapability.search), isTrue);
      expect(entry.supports(SourceCapability.content), isFalse);
    });

    test('脚本语法错 → 进失败列表（坏规则不能静默消失）', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(
        id: 'js-broken',
        name: '坏规则',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(script: 'function ( {'),
      );

      final registry = SourceRegistry(
        repository: repository,
        http: routingHttpClient(const <String, String>{}),
        jsRuntimeFactory: () =>
            FakeJsRuntime(loadError: 'SyntaxError: unexpected token'),
      );
      final snapshot = await registry.load();

      expect(snapshot.entries, isEmpty);
      expect(snapshot.failures, hasLength(1));
      expect(snapshot.failures.single.id, 'js-broken');
      expect(snapshot.failures.single.message, contains('SyntaxError'));
    });

    test('引擎不可用 → 同样进失败列表而不是崩溃', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(
        id: 'js-source',
        name: 'JS 测试源',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
      );

      final registry = SourceRegistry(
        repository: repository,
        http: routingHttpClient(const <String, String>{}),
        jsRuntimeFactory: () => throw UnsupportedError('当前平台不支持原生 JS 引擎'),
      );
      final snapshot = await registry.load();

      expect(snapshot.failures.single.message, contains('原生 JS 引擎'));
    });

    test('声明式与 JS 规则可以并存', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repository = SourceRepository(db);
      await repository.upsert(
        id: 'js-source',
        name: 'JS 测试源',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsRuleText(),
      );
      await repository.upsert(
        id: 'plain-source',
        name: '声明式源',
        type: MediaType.manga,
        kind: SourceKind.plugin,
        ruleText: jsonEncode(<String, Object?>{
          'id': 'plain-source',
          'name': '声明式源',
          'type': 'manga',
          'capabilities': <String>['search'],
          'search': <String, Object?>{
            'url': '/s?q={keyword}',
            'list': '.item',
            'fields': <String, Object?>{'title': 'a', 'remoteId': 'a'},
          },
        }),
      );

      final registry = SourceRegistry(
        repository: repository,
        http: routingHttpClient(const <String, String>{}),
        jsRuntimeFactory: () =>
            FakeJsRuntime(functions: const <String>{'search'}),
      );
      final snapshot = await registry.load();

      expect(snapshot.failures, isEmpty);
      expect(
        snapshot.entries.map((entry) => entry.descriptor.id).toSet(),
        <String>{'js-source', 'plain-source'},
      );
    });
  });
}

Chapter _chapter() => Chapter(
  sourceId: 'js-source',
  remoteId: 'c1',
  title: '第 1 话',
  url: 'https://example.com/chapter/c1',
);
