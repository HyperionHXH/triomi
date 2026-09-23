import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_runtime.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory.dart';
import 'package:triomi/core/source/rule_schema.dart';

import 'fixtures/fake_http_client.dart';

/// 真实 flutter_js 引擎上的全流程验证。
///
/// 与 `t2_js_source_test.dart`（替身驱动）互补：这里跑的是**随包的示例
/// JS 规则**，验证「Promise 桥 + 宿主选择器 + 错误往返」在真实引擎上成立。
///
/// 宿主可用性探测见 `js_engine_probe_test.dart`：Windows 上需要
/// `quickjs_c_bridge.dll` 在 DLL 搜索路径中（项目根目录即可），
/// 否则整个文件会被标记跳过，不影响其它测试。
/// 与示例规则 `local-fixture-js.json` 的 baseUrl 保持一致
///（该地址是模拟器访问宿主夹具的约定地址，宿主测试里仅做字符串拼接，
/// FakeHttpClient 不会真正发请求）。
const String _fixtureBase = 'http://10.0.2.2:8123';

final String _exampleRuleText = File('assets/rules/local-fixture-js.json')
    .readAsStringSync();

const String _listHtml = '''
<html><body><div class="list">
  <div class="item">
    <a class="title" href="/manga/101">夹具漫画 101</a>
    <img class="cover" data-src="/img/cover/101.png" />
    <span class="author">作者甲</span>
  </div>
  <div class="item">
    <a class="title" href="/manga/102">夹具漫画 102</a>
    <img class="cover" data-src="/img/cover/102.png" />
    <span class="author">作者乙</span>
  </div>
</div></body></html>
''';

const String _detailHtml = '''
<html><body>
<h1>夹具漫画 101</h1>
<div class="summary">这是本地夹具源的简介，用于验证详情页字段补全。</div>
<ul class="chapters">
  <li><a href="/chapter/101-1">第 1 话</a></li>
  <li><a href="/chapter/101-2">第 2 话</a></li>
</ul>
</body></html>
''';

const String _readerHtml = '''
<html><body><div id="reader">
  <img src="/img/page/101-1-1.png" />
  <img src="/img/page/101-1-2.png" />
</div></body></html>
''';

void main() {
  bool engineAvailable = false;
  String engineReason = '';

  setUpAll(() async {
    // 真实加载一次脚本，判定引擎在本机是否可用。
    final runtime = createFlutterJsRuntime();
    try {
      await runtime.load(
        'function ping() { return "pong"; }',
        name: 'probe',
        bridge: _NullBridge(),
      );
      engineAvailable = true;
    } catch (error) {
      engineReason = '$error';
    } finally {
      runtime.dispose();
    }
  });

  /// 夹具站点的响应；[onSearch] 可覆盖搜索行为（用于错误往返用例）。
  FakeHttpClient fixtureHttp({
    Future<SourceResponse> Function(SourceRequest request)? onSearch,
  }) {
    return FakeHttpClient((request) async {
      final url = request.url;
      if (url.contains('/search')) {
        if (onSearch != null) return onSearch(request);
        return SourceResponse(statusCode: 200, url: url, body: _listHtml);
      }
      if (url.contains('/chapter/')) {
        return SourceResponse(statusCode: 200, url: url, body: _readerHtml);
      }
      if (url.contains('/list')) {
        return SourceResponse(statusCode: 200, url: url, body: _listHtml);
      }
      return SourceResponse(statusCode: 200, url: url, body: _detailHtml);
    });
  }

  Future<JsSource> prepare(FakeHttpClient http) async {
    final source = JsSource(
      rule: SourceRule.parseJson(_exampleRuleText),
      runtime: createFlutterJsRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();
    return source;
  }

  test('引擎在宿主可用（不可用则本文件其余用例跳过）', () {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    expect(engineAvailable, isTrue);
  });

  test('示例规则的能力探测结果完整', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final source = await prepare(fixtureHttp());

    // 示例规则导出了 discover / search / detail / content。
    expect(
      source.descriptor.capabilities
          .map((capability) => capability.name)
          .toSet(),
      <String>{'discover', 'search', 'detail', 'content'},
    );
    expect(source.feeds.single.name, '热门漫画（JS）');
  });

  test('榜单：真实引擎跑通「fetch + select + JS 正则」', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final http = fixtureHttp();
    final source = await prepare(http);

    final items = await source.discover(source.feeds.first, page: 2);

    // 宿主把 {page} 渲染成 2 并补全为绝对地址。
    expect(http.requests.single.url, '$_fixtureBase/list?page=2');
    expect(items, hasLength(2));
    expect(items[0].sourceId, 'local-fixture-js');
    expect(items[0].remoteId, '101');
    expect(items[0].title, '夹具漫画 101');
    expect(items[0].url, '$_fixtureBase/manga/101');
    expect(items[0].coverUrl, '$_fixtureBase/img/cover/101.png');
    expect(items[0].author, '作者甲');
  });

  test('搜索：JS 侧用 triomi.baseUrl 拼地址', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final http = fixtureHttp();
    final source = await prepare(http);

    final items = await source.search('夹具', page: 1);

    expect(http.requests.single.url, contains('/search?q='));
    expect(http.requests.single.url, contains('page=1'));
    expect(items.map((item) => item.remoteId), <String>['101', '102']);
  });

  test('详情 + 目录：两次宿主调用都在同一份响应上完成', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final http = fixtureHttp();
    final source = await prepare(http);
    final item = (await source.discover(source.feeds.first)).first;
    http.requests.clear();

    final detail = await source.detail(item);
    final chapters = await source.chapters(item);

    expect(http.requests, hasLength(1), reason: '详情与目录共用一次请求');
    expect(detail.title, '夹具漫画 101');
    expect(detail.description, contains('本地夹具源'));
    expect(chapters, hasLength(2));
    expect(chapters[0].remoteId, '101-1');
    expect(chapters[0].url, '$_fixtureBase/chapter/101-1');
    expect(chapters[0].number, 1);
  });

  test('正文：data-original 无结果时回退 src', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final http = fixtureHttp();
    final source = await prepare(http);
    final item = (await source.discover(source.feeds.first)).first;
    final chapter = (await source.chapters(item)).first;

    final content = await source.content(chapter);

    // 夹具页面的图片在 src 上，示例规则先试 data-original 再回退——
    // 这条断言同时验证了「串行两次宿主调用」在真实引擎上可靠。
    expect(content.images, <String>[
      '$_fixtureBase/img/page/101-1-1.png',
      '$_fixtureBase/img/page/101-1-2.png',
    ]);
  });

  test('宿主错误分类穿过 JS 往返后仍是 auth', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    final http = fixtureHttp(
      onSearch: (request) async => throw SourceException(
        sourceId: 'local-fixture-js',
        type: SourceErrorType.auth,
        message: 'HTTP 401',
      ),
    );
    final source = await prepare(http);

    await expectLater(
      source.search('夹具'),
      throwsA(
        isA<SourceException>()
            .having((e) => e.type, 'type', SourceErrorType.auth)
            .having((e) => e.message, 'message', 'HTTP 401'),
      ),
    );
  });

  test('JS 运行时错误暴露为 parse 且带函数名', () async {
    if (!engineAvailable) {
      markTestSkipped('flutter_js 原生库在宿主不可用：$engineReason');
      return;
    }
    // 让宿主返回非法内容，触发 JS 内部 JSON.parse 失败。
    final http = FakeHttpClient(
      (request) async =>
          SourceResponse(statusCode: 200, url: request.url, body: '{"broken"'),
    );
    final source = JsSource(
      rule: SourceRule.parseJson(
        jsonEncode(<String, Object?>{
          'id': 'bad-json',
          'name': '坏 JSON 源',
          'type': 'manga',
          'engine': 'js',
          'baseUrl': _fixtureBase,
          'script':
              '''
async function search(keyword, page) {
  var res = await triomi.fetch('$_fixtureBase/search');
  return JSON.parse(res.body);
}
''',
        }),
      ),
      runtime: createFlutterJsRuntime(),
      http: http,
    );
    addTearDown(source.dispose);
    await source.initialize();

    await expectLater(
      source.search('x'),
      throwsA(
        isA<SourceException>()
            .having((e) => e.type, 'type', SourceErrorType.parse)
            .having((e) => e.message, 'message', contains('search')),
      ),
    );
  });
}

/// 探测阶段用的空桥（不发起任何请求）。
class _NullBridge implements JsHostBridge {
  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async =>
      const JsFetchResponse(status: 200, body: '');

  @override
  List<Map<String, String>> selectRows(
    String html,
    String selector,
    Map<Object?, Object?>? fields,
    String? baseUrl,
  ) => const <Map<String, String>>[];

  @override
  String? selectValue(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) => null;

  @override
  List<String> selectValues(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) => const <String>[];
}
