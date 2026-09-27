/// 轻书架（LNS）响应的宽松取值工具。
///
/// 站点不同版本的字段拼写不一致（`Id/id`、`SortNum/sortNum`），统一在这里
/// 兼容；与 `lk_client.dart` 的取值族保持同一风格。所有函数对缺失字段返回
/// null / 空集合，由调用方决定「缺字段」是解析错误还是可降级。
library;

Object? pick(Map<Object?, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) return value;
  }
  return null;
}

Map<Object?, Object?>? asObj(Object? value) => value is Map ? value : null;

Map<Object?, Object?>? objOf(Map<Object?, Object?> map, List<String> keys) =>
    asObj(pick(map, keys));

String? strOf(Map<Object?, Object?> map, List<String> keys) {
  final value = pick(map, keys);
  final text = value?.toString().trim();
  return (text == null || text.isEmpty) ? null : text;
}

int? intOf(Map<Object?, Object?> map, List<String> keys) {
  final value = pick(map, keys);
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool? boolOf(Map<Object?, Object?> map, List<String> keys) {
  final value = pick(map, keys);
  if (value is bool) return value;
  if (value is num) return value != 0;
  switch (value?.toString().toLowerCase()) {
    case '1' || 'true' || 'yes':
      return true;
    case '0' || 'false' || 'no':
      return false;
  }
  return null;
}

/// 取第一个是数组的字段，元素规范化为对象列表（非对象元素丢弃）。
List<Map<Object?, Object?>> listOf(
  Map<Object?, Object?> map,
  List<String> keys,
) {
  final value = pick(map, keys);
  return nodesOf(value);
}

/// 原样取数组（元素不做类型过滤，用于看书架这类元素是标量的场景）。
List<Object?> rawListOf(Map<Object?, Object?> map, List<String> keys) {
  final value = pick(map, keys);
  return value is List ? value : const <Object?>[];
}

/// 把「数组或单个对象」规范化为对象列表；其他类型返回空列表。
List<Map<Object?, Object?>> nodesOf(Object? value) {
  if (value is List) {
    return <Map<Object?, Object?>>[
      for (final item in value)
        if (item is Map) item,
    ];
  }
  if (value is Map) return <Map<Object?, Object?>>[value];
  return const <Map<Object?, Object?>>[];
}

/// 字符串列表：数组里的标量取字符串，对象取 name/title。
List<String> stringListOf(Object? value) {
  if (value is! List) return const <String>[];
  final result = <String>[];
  for (final item in value) {
    if (item is String) {
      if (item.trim().isNotEmpty) result.add(item.trim());
      continue;
    }
    if (item is Map) {
      final label = strOf(item, const <String>[
        'Name',
        'name',
        'Title',
        'title',
      ]);
      if (label != null) result.add(label);
    }
  }
  return result;
}

/// 文本内容：可能是裸字符串，也可能是 `{Html: ...}` 这类包装对象。
String asTextContent(Object? value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  if (value is Map) {
    return strOf(value, const <String>[
          'Html',
          'html',
          'Content',
          'content',
          'Text',
          'text',
        ]) ??
        '';
  }
  return '';
}

/// 简介：数组/详情接口既可能是裸字符串，也可能是文本包装对象。
String? asOptionalText(Object? value) {
  if (value == null) return null;
  final text = asTextContent(value);
  return text.isEmpty ? null : text;
}

/// 清理网页编辑器带回来的标记（详情页用纯文本渲染简介）。
///
/// 对齐 Mixn `cleanShelfHtml`：保留换行语义，去掉其余标签与转义。
String cleanShelfHtml(String value) => value
    .replaceAll('\\r\\n', '\n')
    .replaceAll('\\n', '\n')
    .replaceAll('\\r', '')
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</(p|div|h[1-6]|li)>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<(p|div|h[1-6]|li)\b[^>]*>', caseSensitive: false), '')
    .replaceAll(RegExp('<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll(RegExp('\n{3,}'), '\n\n')
    .trim();

/// 封面地址规范化：占位图参数里的 `#` 要转义（否则被当成 fragment 截断）。
String? normalizeShelfCoverUrl(String? value) {
  if (value == null || value.isEmpty) return null;
  final queryStart = value.indexOf('?');
  if (queryStart < 0) return value;
  var pairStart = queryStart + 1;
  while (pairStart <= value.length) {
    final nextAmp = value.indexOf('&', pairStart);
    final pairEnd = nextAmp < 0 ? value.length : nextAmp;
    final separator = value.indexOf('=', pairStart);
    if (separator >= pairStart &&
        separator < pairEnd &&
        value.substring(pairStart, separator) == 'placeholder') {
      final valueStart = separator + 1;
      final rawPlaceholder = value.substring(valueStart, pairEnd);
      if (!rawPlaceholder.contains('#')) return value;
      return value.replaceRange(
        valueStart,
        pairEnd,
        rawPlaceholder.replaceAll('#', '%23'),
      );
    }
    if (nextAmp < 0) break;
    pairStart = pairEnd + 1;
  }
  return value;
}
