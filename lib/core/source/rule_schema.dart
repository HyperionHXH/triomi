import 'dart:convert';

import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import 'http_client.dart';
import 'selector_engine.dart';
import 'source_api.dart';

/// 规则格式错误：导入时要给出能看懂的原因，而不是抛一个泛化异常。
class RuleFormatException implements Exception {
  const RuleFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 响应格式：HTML 站点用 css / xpath，JSON 接口用点路径。
enum ResponseFormat {
  html,
  json;

  static ResponseFormat parse(String? value) {
    for (final format in ResponseFormat.values) {
      if (format.name == value) return format;
    }
    return ResponseFormat.html;
  }
}

/// 一次请求的模板。
class RuleRequest {
  const RuleRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const <String, String>{},
    this.body,
    this.bodyType = RequestBodyType.none,
    this.pageSize = 20,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final RequestBodyType bodyType;

  /// 每页条数，用于把 `{page}` 换算成 `{offset}`。
  final int pageSize;

  static RuleRequest? parse(Object? value) {
    if (value is! Map) return null;
    final url = value['url']?.toString() ?? '';
    if (url.trim().isEmpty) return null;
    return RuleRequest(
      url: url,
      method: (value['method']?.toString() ?? 'GET').toUpperCase(),
      headers: _stringMap(value['headers']),
      body: value['body']?.toString(),
      bodyType: RequestBodyType.parse(value['bodyType']?.toString()),
      pageSize: int.tryParse(value['pageSize']?.toString() ?? '') ?? 20,
    );
  }

  /// 渲染实际请求。[itemUrl] 供详情 / 正文页使用。
  SourceRequest render({
    required String baseUrl,
    String? keyword,
    int page = 1,
    String? itemUrl,
    String? id,
  }) {
    final values = <String, String>{
      'page': '$page',
      'offset': '${(page - 1) * pageSize}',
      'keyword': keyword ?? '',
      'keywordEncoded': Uri.encodeComponent(keyword ?? ''),
      'url': itemUrl == null ? '' : Uri.encodeComponent(itemUrl),
      'urlRaw': itemUrl ?? '',
      'id': id ?? '',
    };
    // 先替换占位符再补全相对地址：反过来会把 `{urlRaw}` 当成路径转义掉。
    final renderedUrl = renderTemplate(url.trim(), values);
    final absoluteUrl = renderedUrl.isEmpty
        ? baseUrl
        : (resolveUrl(baseUrl, renderedUrl) ?? renderedUrl);
    return SourceRequest(
      url: absoluteUrl,
      method: method,
      headers: <String, String>{
        for (final entry in headers.entries)
          entry.key: renderTemplate(entry.value, values),
      },
      body: body == null ? null : renderTemplate(body!, values),
      bodyType: bodyType,
    );
  }
}

/// 列表解析规则：HTML 用选择器，JSON 用点路径。
class RuleList {
  const RuleList({
    required this.listSelector,
    required this.fields,
    this.request,
  });

  final String listSelector;
  final Map<String, FieldSpec> fields;

  /// 为 null 表示在当前文档里解析（例如章节列表就在详情页上）。
  final RuleRequest? request;

  static RuleList? parse(Object? value) {
    if (value is! Map) return null;
    final selector = value['list']?.toString() ?? '';
    if (selector.trim().isEmpty) return null;
    return RuleList(
      listSelector: selector,
      fields: parseFields(value['fields']),
      request: RuleRequest.parse(value),
    );
  }
}

/// 详情规则。
class RuleDetail {
  const RuleDetail({this.request, this.fields = const {}, this.chapters});

  final RuleRequest? request;
  final Map<String, FieldSpec> fields;
  final RuleList? chapters;

  static RuleDetail? parse(Object? value) {
    if (value is! Map) return null;
    return RuleDetail(
      request: RuleRequest.parse(value),
      fields: parseFields(value['fields']),
      chapters: RuleList.parse(value['chapters']),
    );
  }
}

/// 正文规则。
class RuleContent {
  const RuleContent({
    this.imageSelectors = const <String>[],
    this.textSelector,
    this.playSources,
    this.danmaku,
  });

  /// 依次尝试的图片选择器（很多站点会把地址放在 data-src / data-original 上）。
  final List<String> imageSelectors;
  final String? textSelector;

  /// 番剧播放线路列表（同一元素上取 name + url）。
  final RuleList? playSources;

  /// 番剧弹幕数据地址模板（返回弹弹play 格式 JSON）。
  /// 可用 `{id}`（章节 remoteId）与 `{urlRaw}` 等占位符。
  final String? danmaku;

  static RuleContent? parse(Object? value) {
    if (value is! Map) return null;
    return RuleContent(
      imageSelectors: <String>[
        for (final item
            in (value['images'] as List<Object?>? ?? const <Object?>[]))
          if (item != null && item.toString().trim().isNotEmpty)
            item.toString(),
      ],
      textSelector: value['text']?.toString(),
      playSources: RuleList.parse(value['playSources']),
      danmaku: value['danmaku']?.toString(),
    );
  }
}

/// 一份声明式来源规则。
class SourceRule {
  const SourceRule({
    required this.descriptor,
    this.response = ResponseFormat.html,
    this.headers = const <String, String>{},
    this.feeds = const <DiscoverFeed>[],
    this.discover,
    this.search,
    this.detail,
    this.content,
    this.jsCode,
  });

  final SourceDescriptor descriptor;
  final ResponseFormat response;
  final Map<String, String> headers;
  final List<DiscoverFeed> feeds;
  final RuleList? discover;
  final RuleList? search;
  final RuleDetail? detail;
  final RuleContent? content;

  /// JS 规则的源码（声明式规则为 null）。
  final String? jsCode;

  bool get isScript => jsCode != null;

  String get baseUrl => descriptor.baseUrl ?? '';

  /// 从 JSON 文本解析规则（仅声明式规则）。
  static SourceRule parseJson(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (error) {
      throw RuleFormatException('不是合法的 JSON：$error');
    }
    if (decoded is! Map) throw const RuleFormatException('规则根节点必须是 JSON 对象');
    return parseMap(decoded);
  }

  static SourceRule parseMap(Map<Object?, Object?> map) {
    final id = map['id']?.toString().trim() ?? '';
    final name = map['name']?.toString().trim() ?? '';
    if (id.isEmpty) throw const RuleFormatException('缺少 id');
    if (name.isEmpty) throw const RuleFormatException('缺少 name');

    final type = MediaType.tryParse(map['type']?.toString());
    if (type == null) {
      throw const RuleFormatException('type 必须是 anime / manga / novel 之一');
    }

    final capabilities = <SourceCapability>{};
    for (final entry
        in (map['capabilities'] as List<Object?>? ?? const <Object?>[])) {
      final parsed = _capabilityOf(entry?.toString());
      if (parsed != null) capabilities.add(parsed);
    }

    final feeds = <DiscoverFeed>[];
    final discoverMap = map['discover'];
    if (discoverMap is Map) {
      for (final feed
          in (discoverMap['feeds'] as List<Object?>? ?? const <Object?>[])) {
        if (feed is! Map) continue;
        final feedId = feed['id']?.toString() ?? '';
        final feedUrl = feed['url']?.toString() ?? '';
        if (feedId.isEmpty || feedUrl.isEmpty) continue;
        feeds.add(
          DiscoverFeed(
            id: feedId,
            name: feed['name']?.toString() ?? feedId,
            urlTemplate: feedUrl,
          ),
        );
      }
    }

    final rule = SourceRule(
      descriptor: SourceDescriptor(
        id: id,
        name: name,
        type: type,
        kind: SourceKind.plugin,
        lang: map['lang']?.toString() ?? 'zh',
        baseUrl: map['baseUrl']?.toString(),
        version: map['version']?.toString(),
        requireLogin: map['requireLogin']?.toString() == 'true',
        capabilities: capabilities,
      ),
      response: ResponseFormat.parse(map['response']?.toString()),
      headers: _stringMap(map['headers']),
      feeds: feeds,
      discover: RuleList.parse(discoverMap),
      search: RuleList.parse(map['search']),
      detail: RuleDetail.parse(map['detail']),
      content: RuleContent.parse(map['content']),
    );

    rule.validate();
    return rule;
  }

  /// 结构层面的自检：能力声明与实际规则要对得上。
  void validate() {
    final problems = <String>[];
    if (descriptor.capabilities.contains(SourceCapability.discover)) {
      if (feeds.isEmpty) problems.add('声明了 discover 能力但没有 discover.feeds');
      if (discover == null) problems.add('声明了 discover 能力但没有 discover.list');
    }
    if (descriptor.capabilities.contains(SourceCapability.search) &&
        search == null) {
      problems.add('声明了 search 能力但没有 search.list');
    }
    if (descriptor.capabilities.contains(SourceCapability.detail) &&
        detail == null &&
        search == null) {
      problems.add('声明了 detail 能力但没有 detail 规则');
    }
    if (descriptor.capabilities.contains(SourceCapability.content) &&
        content == null) {
      problems.add('声明了 content 能力但没有 content 规则');
    }
    if (response == ResponseFormat.json &&
        descriptor.capabilities.contains(SourceCapability.content) &&
        (content?.imageSelectors.isNotEmpty ?? false)) {
      problems.add('JSON 响应不支持图片选择器');
    }
    if (problems.isNotEmpty) {
      throw RuleFormatException('规则自检失败：${problems.join('；')}');
    }
  }
}

/// `{key}` 模板渲染。可用键见 [RuleRequest.render]。
String renderTemplate(String template, Map<String, String> values) {
  var result = template;
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}

/// 解析字段表：`{"title": ".title", "cover": {"selector": "img", "attr": "src"}}`。
Map<String, FieldSpec> parseFields(Object? value) {
  if (value is! Map) return const <String, FieldSpec>{};
  final fields = <String, FieldSpec>{};
  for (final entry in value.entries) {
    final key = entry.key?.toString();
    if (key == null || key.isEmpty) continue;
    final spec = FieldSpec.parse(entry.value);
    if (spec != null) fields[key] = spec;
  }
  return fields;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      if (entry.key != null && entry.value != null)
        entry.key.toString(): entry.value.toString(),
  };
}

SourceCapability? _capabilityOf(String? name) {
  if (name == null) return null;
  for (final capability in SourceCapability.values) {
    if (capability.name == name) return capability;
  }
  return null;
}
