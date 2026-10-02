import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/chapter.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/js/js_source.dart';
import 'package:triomi/core/source/js/runtime/js_runtime_factory_io.dart';
import 'package:triomi/core/source/rule_schema.dart';


/// D22：真实 flutter_js 运行时的生命周期与异常边界。
///
/// 与 `t2_js_source_test.dart`（假引擎上的映射/分类）、`t2_js_engine_test.dart`
/// （真实引擎的基础能力）互补；本文件用**真实 quickjs + 真实宿主桥**验证
/// 并发、reject、dispose 竞态等只有真引擎才暴露的行为。
/// 引擎不可用的环境按既有机制整体跳过（原因 + 数量见交付文档）。
SourceRule jsRule({
  required String id,
  required String script,
  Map<String, String> headers = const <String, String>{},
}) => SourceRule.parseMap(<Object?, Object?>{
  'id': id,
  'name': 'D22 源 $id',
  'type': 'manga',
  'lang': 'zh',
  'baseUrl': 'https://example.com',
  'engine': 'js',
  'headers': headers,
  'script': script,
});

/// 记录请求的假网络层；按序回放响应或抛出真实层风格的异常。
class ScriptedHttp implements SourceHttpClient {
  final List<SourceRequest> requests = <SourceRequest>[];

  /// 每个请求依次弹出：返回响应，或抛异常。
  final List<Object?> script = <Object?>[];

  /// 手动放行门（fetch 挂起用）。
  Completer<void>? gate;

  @override
  Future<SourceResponse> send(SourceRequest request, {required String sourceId}) async {
    requests.add(request);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final value = script.isEmpty ? null : script.removeAt(0);
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

/// 探测真实引擎是否可用（不可用时调用方整体 skip）。
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

  setUpAll(() {
    if (!available) {
      // ignore: avoid_print
      print('D22: flutter_js 原生库在宿主不可用，本文件全部用例跳过');
    }
  });

  test('真实引擎在宿主可用（不可用则本文件其余用例跳过）', () {
    if (!available) {
      markTestSkipped('flutter_js 原生库在宿主不可用');
      return;
    }
    expect(available, isTrue);
  });

  group('真实宿主桥（quickjs + triomi 通道）', () {
    test('多个异步 fetch 乱序返回：结果与请求一一对应', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = ScriptedHttp()
        ..script.addAll(<Object?>[
          jsonEncode(<String, Object?>{'name': '慢的先发'}),
          jsonEncode(<String, Object?>{'name': '快的后发'}),
        ]);
      final rule = jsRule(
        id: 'd22-order',
        script: r'''
async function search(keyword, page) {
  const first = triomi.fetch('https://example.com/slow?q=' + keyword);
  const second = triomi.fetch('https://example.com/fast?q=' + keyword);
  const fast = JSON.parse((await second).body).name;
  const slow = JSON.parse((await first).body).name;
  return [
    { remoteId: '2', title: fast },
    { remoteId: '1', title: slow },
  ];
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

      final items = await source.search('火影');
      expect(items.map((item) => item.title).toList(), <String>[
        '快的后发',
        '慢的先发',
      ], reason: '乱序完成不影响一一对应');
      expect(
        http.requests.map((request) => request.url),
        <String>[
          'https://example.com/slow?q=火影',
          'https://example.com/fast?q=火影',
        ],
      );
    });

    test('Promise reject（宿主 auth）后引擎仍可继续调用，分类原样透传', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = ScriptedHttp()
        ..script.addAll(<Object?>[
          const SourceException(
            sourceId: 'd22-reject',
            type: SourceErrorType.auth,
            message: 'HTTP 401',
          ),
          jsonEncode(<String, Object?>{
            'remoteId': '1',
            'title': '恢复后',
          }),
        ]);
      final rule = jsRule(
        id: 'd22-reject',
        script: r'''
async function search(keyword, page) {
  const response = await triomi.fetch('https://example.com/api');
  const data = JSON.parse(response.body);
  return [data];
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
              .having((error) => error.type, 'type', SourceErrorType.auth)
              .having((error) => error.sourceId, 'sourceId', 'd22-reject'),
        ),
      );

      final items = await source.search('x');
      expect(items.single.title, '恢复后', reason: 'reject 后引擎仍然可用');
    });

    test('dispose 后晚到的 fetch 结果不再进入引擎（不崩溃）', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final http = ScriptedHttp();
      final rule = jsRule(
        id: 'd22-dispose',
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
      await source.initialize();

      final gate = Completer<void>();
      http.gate = gate;
      final pending = source.search('x');
      await pumpEventQueue();

      // 先释放运行时，再让 fetch 完成：晚到的结果必须被丢弃。
      source.dispose();
      gate.complete();
      // 释放时立即取消调用，不再等待插件的 30 秒 Promise 超时。
      await expectLater(
        pending,
        throwsA(
          isA<SourceException>().having(
            (error) => error.message,
            'message',
            contains('已释放'),
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 45)));

    test('未导出函数：可读错误且 sourceId 正确', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final rule = jsRule(
        id: 'd22-missing',
        script: 'async function search(keyword, page) { return []; }',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: ScriptedHttp(),
      );
      addTearDown(source.dispose);
      await source.initialize();
      // 只导出了 search：content 未导出。
      await expectLater(
        source.content(
          const Chapter(
            sourceId: 'd22-missing',
            remoteId: '1:1',
            title: '第 1 章',
          ),
        ),
        throwsA(
          isA<SourceException>()
              .having((error) => error.type, 'type', SourceErrorType.parse)
              .having((error) => error.sourceId, 'sourceId', 'd22-missing')
              .having(
                (error) => error.message,
                'message',
                contains('规则没有导出 content'),
              ),
        ),
      );
    });

    test('返回 undefined 的导出函数按 null 处理（不产生非 JSON 错误）', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final rule = jsRule(
        id: 'd22-undefined',
        script: 'function search(keyword, page) { return undefined; }',
      );
      final source = JsSource(
        rule: rule,
        runtime: createFlutterJsRuntime(),
        http: ScriptedHttp(),
      );
      addTearDown(source.dispose);
      await source.initialize();
      expect(await source.search('x'), isEmpty);
    });

    test('规则级 headers 与实例隔离：两个源各带各的头', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      final httpA = ScriptedHttp()
        ..script.add(jsonEncode(<String, Object?>{'name': '源 A 的结果'}));
      final httpB = ScriptedHttp()
        ..script.add(jsonEncode(<String, Object?>{'name': '源 B 的结果'}));
      const searchScript = '''
async function search(keyword, page) {
  const response = await triomi.fetch('https://example.com/api');
  return [{ remoteId: '1', title: JSON.parse(response.body).name }];
}
''';
      final ruleA = jsRule(
        id: 'd22-a',
        script: searchScript,
        headers: const <String, String>{'Referer': 'https://a.example.com'},
      );
      final ruleB = jsRule(
        id: 'd22-b',
        script: searchScript,
        headers: const <String, String>{'Referer': 'https://b.example.com'},
      );
      final sourceA = JsSource(
        rule: ruleA,
        runtime: createFlutterJsRuntime(),
        http: httpA,
      );
      final sourceB = JsSource(
        rule: ruleB,
        runtime: createFlutterJsRuntime(),
        http: httpB,
      );
      addTearDown(sourceA.dispose);
      addTearDown(sourceB.dispose);
      await sourceA.initialize();
      await sourceB.initialize();

      await sourceA.search('x');
      await sourceB.search('x');
      expect(httpA.requests.single.headers['Referer'], 'https://a.example.com');
      expect(httpB.requests.single.headers['Referer'], 'https://b.example.com');
      expect(httpA.requests, hasLength(1), reason: '实例间互不串扰');
      expect(httpB.requests, hasLength(1));
    });

    test('连接失败的错误文本不携带 URL 查询串里的凭据（缺陷回归，当前失败）', () async {
      if (!available) {
        markTestSkipped('flutter_js 原生库在宿主不可用');
      }
      // 真实网络层对连接类错误用 `SourceException.wrap`，消息 = 「url：原因」。
      // 规则的请求 URL 带 token 时，这段消息会原样透传到来源失败列表。
      final http = ScriptedHttp()
        ..script.add(
          const SourceException(
            sourceId: 'd22-leak',
            type: SourceErrorType.network,
            message:
                'https://example.com/api?token=super-secret-token-value：连接被拒绝',
          ),
        );
      final rule = jsRule(
        id: 'd22-leak',
        script: r'''
async function search(keyword, page) {
  await triomi.fetch('https://example.com/api?token=super-secret-token-value');
  return [];
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

      SourceException caught;
      try {
        await source.search('x');
        fail('应当抛出');
      } on SourceException catch (error) {
        caught = error;
      }
      expect(
        '${caught.message}',
        isNot(contains('super-secret-token-value')),
        reason: '错误输出必须剥掉 URL 查询串（或整段 URL），凭据不能进失败列表',
      );
    });
  });
}
