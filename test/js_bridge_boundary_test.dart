import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';
import 'package:triomi/core/source/rule_schema.dart';


/// D22：宿主桥边界的真实路径验证（quickjs + _JsHttpBridge 全链路）。
///
/// `t2_js_source_test.dart` 的宿主桥组直接调用桥方法验证选择器；本文件从
/// **JS 侧**发起请求，覆盖请求头合并、bodyType、选择器失败容忍等只有穿过
/// 真实通道才能看到的契约。引擎不可用的环境整体跳过。
SourceRule jsRule({
  required String id,
  required String script,
  Map<String, String> headers = const <String, String>{},
}) => SourceRule.parseMap(<Object?, Object?>{
  'id': id,
  'name': 'D22 桥 $id',
  'type': 'manga',
  'lang': 'zh',
  'baseUrl': 'https://example.com',
  'engine': 'js',
  'headers': headers,
  'script': script,
});

class RecordingHttp implements SourceHttpClient {
  final List<SourceRequest> requests = <SourceRequest>[];
  Object? nextResponse = '';

  @override
  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) async {
    requests.add(request);
    final value = nextResponse;
    if (value is SourceException) throw value;
    return SourceResponse(
      statusCode: 200,
      url: request.url,
      body: value?.toString() ?? '',
    );
  }

  @override
  Future<List<int>> fetchBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
    String method = 'GET',
  }) => throw UnimplementedError();

  @override
  Future<SourceByteStream> downloadBytes(
    String url, {
    required String sourceId,
    Map<String, String> headers = const <String, String>{},
  }) => throw UnimplementedError();

  @override
  Future<SourceResponse> uploadBytes(
    String url, {
    required String sourceId,
    required List<int> bytes,
    Map<String, String> headers = const <String, String>{},
    String method = 'PUT',
  }) => throw UnimplementedError();

  @override
  void close() {}
}

bool engineAvailable() {
  try {
    final runtime = createFlutterJsRuntime();
    runtime.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final available = engineAvailable();

  test('真实引擎在宿主可用（不可用则本文件其余用例跳过）', () {
    if (!available) {
      markTestSkipped('flutter_js 原生库在宿主不可用');
    }
    expect(available, isTrue);
  });

  group('JS 侧发起的请求（穿过真实通道）', () {
    test('规则级 headers 铺底，JS 单次请求的头覆盖它', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = RecordingHttp()
        ..nextResponse = jsonEncode(<String, Object?>{
          'remoteId': '1',
          'title': '结果',
        });
      final rule = jsRule(
        id: 'd22-bridge-headers',
        headers: const <String, String>{
          'Referer': 'https://example.com',
          'X-Rule-Only': 'from-rule',
        },
        script: r'''
async function search(keyword, page) {
  const response = await triomi.fetch('https://example.com/api', {
    headers: { 'X-Per-Call': 'from-js', 'Referer': 'https://override.example.com' }
  });
  return [JSON.parse(response.body)];
}
''',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();
      await source.search('x');

      final headers = http.requests.single.headers;
      expect(headers['Referer'], 'https://override.example.com',
          reason: '单次请求的头覆盖规则头');
      expect(headers['X-Rule-Only'], 'from-rule', reason: '规则头照常铺底');
      expect(headers['X-Per-Call'], 'from-js');
    });

    test('bodyType=json 的 POST 请求体与类型标记都正确', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = RecordingHttp()
        ..nextResponse = jsonEncode(<String, Object?>{
          'remoteId': '1',
          'title': '结果',
        });
      final rule = jsRule(
        id: 'd22-bridge-post',
        script: r'''
async function search(keyword, page) {
  const response = await triomi.fetch('https://example.com/search', {
    method: 'POST',
    bodyType: 'json',
    body: JSON.stringify({ keyword: keyword, page: page })
  });
  return [JSON.parse(response.body)];
}
''',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();
      await source.search('火影', page: 2);

      final request = http.requests.single;
      expect(request.method, 'POST');
      expect(request.bodyType, RequestBodyType.json);
      expect(jsonDecode(request.body!), <String, Object?>{
        'keyword': '火影',
        'page': 2,
      });
    });

    test('选择器失败是空结果而不是异常（解析由宿主承担）', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = RecordingHttp();
      final rule = jsRule(
        id: 'd22-bridge-selector',
        script: r'''
async function search(keyword, page) {
  const html = '<ul><li data-title="甲">甲</li></ul>';
  const good = await triomi.select(html, 'li', { title: 'text' });
  const bad = await triomi.select(html, 'div.nonexistent > span[attr=x]', { title: 'text' });
  const empty = await triomi.select('', 'li', null);
  return [{ remoteId: '1', title: 'rows=' + good.length + ',' + bad.length + ',' + empty.length }];
}
''',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();

      final items = await source.search('x');
      expect(items.single.title, 'rows=1,0,0',
          reason: '坏选择器/空文档返回空集，不把解析错误抛成调用失败');
    });

    test('fetch 非对象响应（坏 JSON）以 parse 类别失败并带 sourceId', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = RecordingHttp()..nextResponse = 'not-json-at-all';
      final rule = jsRule(
        id: 'd22-bridge-badjson',
        script: r'''
async function search(keyword, page) {
  const response = await triomi.fetch('https://example.com/api');
  return [JSON.parse(response.body)];
}
''',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();

      await expectLater(
        source.search('x'),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.parse)
              .having((error) => error.sourceId, 'sourceId', 'd22-bridge-badjson'),
        ),
      );
    });

    test('content() 的章节上下文带 sourceId/remoteId（JS 侧可读）', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = RecordingHttp()
        ..nextResponse = jsonEncode(<String, Object?>{
          'images': <Object?>['/p1.jpg'],
        });
      final rule = jsRule(
        id: 'd22-bridge-context',
        script: r'''
async function content(url, chapter) {
  const response = await triomi.fetch('https://example.com/c?r=' + chapter.remoteId);
  return { images: JSON.parse(response.body).images, remoteId: chapter.remoteId };
}
''',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: http,
      );
      addTearDown(source.dispose);
      await source.initialize();

      final content = await source.content(
        const Chapter(
          sourceId: 'd22-bridge-context',
          remoteId: '1:7',
          title: '第 7 章',
          url: 'https://example.com/ch/7',
        ),
      );
      expect(content.images.single, 'https://example.com/p1.jpg',
          reason: '相对图片地址按章节 url 补全（章节 url 来自详情页，恒有值）');
      expect(
        http.requests.single.url,
        'https://example.com/c?r=1:7',
        reason: '章节上下文从 JS 侧可读',
      );
    });
  });
}
