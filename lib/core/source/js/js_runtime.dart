import '../../models/media_type.dart';
import '../../models/source_exception.dart';

/// JS 侧发起的请求（`triomi.fetch` 的参数）。
class JsFetchRequest {
  const JsFetchRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.bodyType,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// 请求体类型（`json` / `form`），来自 JS 侧的 `bodyType`。
  final String? bodyType;

  static JsFetchRequest fromJson(Map<Object?, Object?> json) {
    final headers = <String, String>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key == null || entry.value == null) continue;
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return JsFetchRequest(
      url: json['url']?.toString() ?? '',
      method: (json['method']?.toString() ?? 'GET').toUpperCase(),
      headers: headers,
      body: json['body']?.toString(),
      bodyType: json['bodyType']?.toString(),
    );
  }
}

/// 宿主回给 JS 的响应。
class JsFetchResponse {
  const JsFetchResponse({
    required this.status,
    required this.body,
    this.url = '',
  });

  final int status;
  final String body;

  /// 实际地址（跟随重定向后的），供相对地址补全使用。
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'body': body,
    'url': url,
  };
}

/// 宿主能力桥：JS 侧 `triomi.*` 的落地实现。
///
/// 只有 [fetch] 需要 IO；选择器三个方法是纯计算，直接复用
/// [HtmlSelector]（见 `js_source.dart` 的实现）。
abstract class JsHostBridge {
  /// 走 [SourceHttpClient]（统一 UA / 超时 / 错误分类）。
  /// 失败抛 [SourceException]，分类会被原样带回 JS 侧。
  Future<JsFetchResponse> fetch(JsFetchRequest request);

  /// 列表解析：选择器命中多个节点，按字段表提取为对象数组。
  ///
  /// [fields] 为 null 时每个节点回退为 `{text: 节点文本}`。
  List<Map<String, String>> selectRows(
    String html,
    String selector,
    Map<Object?, Object?>? fields,
    String? baseUrl,
  );

  /// 取第一个命中值（按 [attr]：`text` / `html` / 属性名）。
  String? selectValue(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  );

  /// 取全部命中值（图片列表这类多值字段）。
  List<String> selectValues(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  );
}

/// JS 引擎抽象：把「加载脚本 / 探测导出 / 调用函数」与具体引擎解耦。
///
/// 之所以抽出来，是因为真实引擎（flutter_js）在宿主与设备上的可用性不同，
/// 单测必须能注入替身（见 `test/t2_js_source_test.dart` 的 FakeJsRuntime）。
abstract class JsRuntime {
  /// 加载规则源码并注入宿主函数。
  ///
  /// 同一实例内可重复调用（后加载的覆盖前者），全局状态也随之重置。
  /// [baseUrl] 会作为 `triomi.baseUrl` 暴露给脚本（拼地址用）。
  Future<void> load(
    String script, {
    required String name,
    required JsHostBridge bridge,
    String? baseUrl,
  });

  /// 脚本是否导出了某函数（用于能力探测）。
  Future<bool> hasFunction(String function);

  /// 调用导出函数。[args] 为 JSON 可序列化值，返回 JSON 解码后的结果。
  ///
  /// JS 抛异常时抛 [JsRuntimeError]；若异常源自宿主（fetch 失败），
  /// 原始分类保留在 [JsRuntimeError.hostError] 里供上层透传。
  Future<Object?> call(String function, List<Object?> args);

  void dispose();
}

/// JS 侧错误（含宿主错误分类）。
class JsRuntimeError implements Exception {
  const JsRuntimeError(this.message, {this.hostError});

  final String message;

  /// 由宿主失败（fetch 等）引起时保留原始分类，上层应原样透传，
  /// 不要一律降级成 parse 错误。
  final SourceException? hostError;

  @override
  String toString() => message;
}

/// 宿主错误在 JS 文本通道里的标记前缀。
///
/// 通道只能传字符串，因此把「分类 + 消息」编码成
/// `TRIOMI_HOST_ERROR|<type>|<message>` 穿过 JS 再解回来。
const String jsHostErrorPrefix = 'TRIOMI_HOST_ERROR|';

String encodeHostError(SourceException error) =>
    '$jsHostErrorPrefix${error.type.name}|${error.message}';

/// 解析 [encodeHostError] 写下的标记；不是宿主错误时返回 null。
SourceException? decodeHostError(String message, {required String sourceId}) {
  if (!message.startsWith(jsHostErrorPrefix)) return null;
  final rest = message.substring(jsHostErrorPrefix.length);
  final separator = rest.indexOf('|');
  final rawType = separator < 0 ? rest : rest.substring(0, separator);
  final detail = separator < 0 ? '' : rest.substring(separator + 1);
  return SourceException(
    sourceId: sourceId,
    type: _errorTypeOf(rawType),
    message: detail,
  );
}

SourceErrorType _errorTypeOf(String name) {
  for (final type in SourceErrorType.values) {
    if (type.name == name) return type;
  }
  return SourceErrorType.network;
}
