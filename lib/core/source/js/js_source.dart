import 'package:html/parser.dart' as html_parser;

import '../../models/chapter.dart';
import '../../models/media_item.dart';
import '../../models/media_type.dart';
import '../../models/source_descriptor.dart';
import '../../models/source_exception.dart';
import '../http_client.dart';
import '../rule_schema.dart';
import '../selector_engine.dart';
import '../source_api.dart';
import 'js_runtime.dart';

/// JS 规则导出的函数名 → 对应能力。
///
/// 能力由**运行时探测**决定（`typeof fn === 'function'`），元数据里的
/// `capabilities` 对 JS 规则不参与判定——这样规则作者少一处会写错的地方。
const Map<String, SourceCapability> jsFunctionCapabilities =
    <String, SourceCapability>{
      'discover': SourceCapability.discover,
      'search': SourceCapability.search,
      'detail': SourceCapability.detail,
      'content': SourceCapability.content,
    };

/// 用 JS 规则实现的能力集合（与 [DeclarativeSource] 同一套契约）。
///
/// 设计取舍：解析这件事**不交给 JS**——`triomi.select` 等宿主函数直接复用
/// [HtmlSelector]（CSS + XPath 双语法、声明式同款字段表），JS 只负责流程编排
/// （拼地址、翻页、条件分支）。这样两种规则共享同一套解析语义，规则作者也
/// 不必在 JS 里重造选择器。
class JsSource
    implements
        DiscoverProvider,
        SearchProvider,
        DetailProvider,
        ContentProvider {
  JsSource({required this.rule, required this.runtime, required this.http});

  final SourceRule rule;
  final JsRuntime runtime;
  final SourceHttpClient http;

  final Set<SourceCapability> _capabilities = <SourceCapability>{};
  final Map<String, _JsDetail> _detailCache = <String, _JsDetail>{};
  bool _ready = false;

  String get _id => rule.descriptor.id;

  @override
  SourceDescriptor get descriptor =>
      rule.descriptor.copyWith(capabilities: _capabilities);

  @override
  bool get isReady => _ready;

  @override
  List<DiscoverFeed> get feeds => rule.feeds;

  /// 加载脚本、注入宿主函数、探测导出能力。
  ///
  /// 失败抛 [SourceException]（[SourceErrorType.parse]），由注册表记成
  /// 可见的失败项——坏规则不能静默消失。
  Future<void> initialize() async {
    final script = rule.jsCode;
    if (script == null || script.trim().isEmpty) {
      throw SourceException(
        sourceId: _id,
        type: SourceErrorType.parse,
        message: 'JS 规则缺少 script',
      );
    }
    try {
      await runtime.load(
        script,
        name: _id,
        bridge: _JsHttpBridge(this),
        baseUrl: rule.descriptor.baseUrl,
      );
    } on JsRuntimeError catch (error) {
      throw SourceException(
        sourceId: _id,
        type: SourceErrorType.parse,
        message: 'JS 规则加载失败：${error.message}',
      );
    }

    _capabilities.clear();
    for (final entry in jsFunctionCapabilities.entries) {
      if (await runtime.hasFunction(entry.key)) _capabilities.add(entry.value);
    }
    _ready = true;
  }

  void dispose() {
    _detailCache.clear();
    runtime.dispose();
  }

  // ---------------------------------------------------------------- 能力

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    // 榜单地址里的 `{page}` / `{offset}` 由宿主渲染并补全为绝对地址，
    // 与声明式规则的语义一致（JS 侧拿到的就是可直接请求的地址）。
    final template = feed.urlTemplate ?? rule.baseUrl;
    final rendered = renderTemplate(template, <String, String>{
      'page': '$page',
      'offset': '${(page - 1) * 20}',
    });
    final url = resolveUrl(rule.baseUrl, rendered) ?? rendered;
    final raw = await _invoke('discover', <Object?>[url, page]);
    return _toItems(raw);
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final raw = await _invoke('search', <Object?>[keyword, page]);
    return _toItems(raw);
  }

  @override
  Future<MediaItem> detail(MediaItem item) async =>
      (await _loadDetail(item)).item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async =>
      (await _loadDetail(item)).chapters;

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final url = chapter.url ?? '';
    final raw = await _invoke('content', <Object?>[
      url,
      <String, Object?>{
        'sourceId': chapter.sourceId,
        'remoteId': chapter.remoteId,
        'title': chapter.title,
        'url': chapter.url,
        'number': chapter.number,
        'volumeTitle': chapter.volumeTitle,
      },
    ]);
    return _toContent(raw, chapterUrl: url);
  }

  // ---------------------------------------------------------------- 内部

  /// 调用 JS 函数并把错误翻译成来源错误。
  Future<Object?> _invoke(String function, List<Object?> args) async {
    try {
      return await runtime.call(function, args);
    } on JsRuntimeError catch (error) {
      final hostError = error.hostError;
      if (hostError != null) {
        // 宿主网络错误的分类必须原样透传（例如 auth 不能被降级成 parse）。
        throw SourceException(
          sourceId: _id,
          type: hostError.type,
          message: hostError.message,
        );
      }
      if (error.message.startsWith('TRIOMI_NO_FUNCTION|')) {
        final name = error.message.split('|').last;
        throw SourceException(
          sourceId: _id,
          type: SourceErrorType.parse,
          message: '规则没有导出 $name 函数',
        );
      }
      throw SourceException(
        sourceId: _id,
        type: SourceErrorType.parse,
        message: 'JS 规则 $function 执行失败：${error.message}',
      );
    }
  }

  /// 详情与目录一次取回（JS 的 `detail()` 同时返回两者），并按地址缓存，
  /// 避免详情页先取详情、再取目录时打两次请求。
  Future<_JsDetail> _loadDetail(MediaItem item) async {
    final url = item.url ?? '';
    final cached = _detailCache[url];
    if (cached != null) return cached;

    final raw = await _invoke('detail', <Object?>[url, item.toJson()]);
    final map = raw is Map<Object?, Object?> ? raw : const <Object?, Object?>{};
    final rawItem = map['item'];
    final result = _JsDetail(
      item: rawItem is Map<Object?, Object?> ? _mergeItem(item, rawItem) : item,
      chapters: _toChapters(map['chapters'], url),
    );
    _detailCache[url] = result;
    return result;
  }

  List<MediaItem> _toItems(Object? raw) {
    if (raw is! List) return const <MediaItem>[];
    final items = <MediaItem>[];
    for (final node in raw) {
      if (node is! Map<Object?, Object?>) continue;
      final item = _toItem(node);
      if (item != null) items.add(item);
    }
    return items;
  }

  MediaItem? _toItem(Map<Object?, Object?> map) {
    final remoteId = map['remoteId']?.toString() ?? '';
    final title = map['title']?.toString() ?? map['name']?.toString() ?? '';
    if (remoteId.isEmpty || title.isEmpty) return null;
    return _buildItem(map, remoteId: remoteId, title: title);
  }

  /// 构造条目；地址一律按规则 baseUrl 补全——JS 侧返回相对地址与
  /// 声明式规则的行为保持一致（JS 侧的 `absolute` 只是可选的提前补全）。
  MediaItem _buildItem(
    Map<Object?, Object?> map, {
    required String remoteId,
    required String title,
  }) {
    return MediaItem(
      sourceId: _id,
      remoteId: remoteId,
      type: MediaType.tryParse(map['type']?.toString()) ?? descriptor.type,
      title: title,
      url: resolveUrl(rule.baseUrl, map['url']?.toString()),
      coverUrl: resolveUrl(rule.baseUrl, map['coverUrl']?.toString()),
      author: map['author']?.toString(),
      description: map['description']?.toString(),
      tags: _tags(map['tags']),
      rating: double.tryParse(map['rating']?.toString() ?? ''),
      status: map['status']?.toString(),
    );
  }

  /// 详情返回的条目可能只带局部字段（如只补了简介），缺的部分沿用列表页的值。
  MediaItem _mergeItem(MediaItem base, Map<Object?, Object?> raw) {
    final remoteId = raw['remoteId']?.toString();
    final title = raw['title']?.toString() ?? raw['name']?.toString();
    return MediaItem(
      sourceId: _id,
      remoteId: remoteId == null || remoteId.isEmpty ? base.remoteId : remoteId,
      type: MediaType.tryParse(raw['type']?.toString()) ?? base.type,
      title: title == null || title.isEmpty ? base.title : title,
      url: resolveUrl(rule.baseUrl, raw['url']?.toString()) ?? base.url,
      coverUrl:
          resolveUrl(rule.baseUrl, raw['coverUrl']?.toString()) ??
          base.coverUrl,
      author: raw['author']?.toString() ?? base.author,
      description: raw['description']?.toString() ?? base.description,
      tags: raw.containsKey('tags') ? _tags(raw['tags']) : base.tags,
      rating: double.tryParse(raw['rating']?.toString() ?? '') ?? base.rating,
      status: raw['status']?.toString() ?? base.status,
    );
  }

  List<Chapter> _toChapters(Object? raw, String baseUrl) {
    if (raw is! List) return const <Chapter>[];
    final chapters = <Chapter>[];
    var index = 0;
    for (final node in raw) {
      if (node is! Map<Object?, Object?>) continue;
      final remoteId =
          node['remoteId']?.toString() ?? node['url']?.toString() ?? '';
      if (remoteId.isEmpty) continue;
      final rawTitle =
          node['title']?.toString() ?? node['name']?.toString() ?? '';
      final title = rawTitle.isNotEmpty ? rawTitle : '第 ${index + 1} 话';
      chapters.add(
        Chapter(
          sourceId: _id,
          remoteId: remoteId,
          title: title,
          url:
              resolveUrl(baseUrl, node['url']?.toString()) ??
              node['url']?.toString(),
          number:
              double.tryParse(node['number']?.toString() ?? '') ??
              Chapter.parseNumber(title),
          sortIndex: index,
          volumeTitle: node['volumeTitle']?.toString(),
          releaseDate: DateTime.tryParse(node['releaseDate']?.toString() ?? ''),
          locked:
              node['locked'] == true || node['locked']?.toString() == 'true',
        ),
      );
      index++;
    }
    return chapters;
  }

  ChapterContent _toContent(Object? raw, {required String chapterUrl}) {
    if (raw is! Map<Object?, Object?>) return const ChapterContent();
    final playSources = <PlaySource>[];
    final rawPlay = raw['playSources'] ?? raw['play'];
    if (rawPlay is List) {
      for (final node in rawPlay) {
        if (node is! Map<Object?, Object?>) continue;
        final url = resolveUrl(chapterUrl, node['url']?.toString());
        if (url == null || url.isEmpty) continue;
        final name = node['name']?.toString();
        playSources.add(
          PlaySource(
            name: name == null || name.isEmpty ? '线路' : name,
            url: url,
          ),
        );
      }
    }
    return ChapterContent(
      images: _resolveList(raw['images'], chapterUrl),
      text: raw['text']?.toString(),
      html: raw['html']?.toString(),
      playSources: playSources,
      danmakuUrl: resolveUrl(
        chapterUrl,
        (raw['danmakuUrl'] ?? raw['danmaku'])?.toString(),
      ),
    );
  }

  List<String> _resolveList(Object? raw, String baseUrl) {
    if (raw is! List) return const <String>[];
    final values = <String>[];
    for (final node in raw) {
      final resolved = resolveUrl(baseUrl, node?.toString());
      if (resolved != null && resolved.isNotEmpty) values.add(resolved);
    }
    return values;
  }

  List<String> _tags(Object? raw) {
    if (raw is List) {
      return <String>[
        for (final tag in raw)
          if (tag != null && tag.toString().trim().isNotEmpty)
            tag.toString().trim(),
      ];
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return <String>[
        for (final tag in raw.split(RegExp(r'[,，/\s]+')))
          if (tag.trim().isNotEmpty) tag.trim(),
      ];
    }
    return const <String>[];
  }
}

class _JsDetail {
  const _JsDetail({required this.item, required this.chapters});

  final MediaItem item;
  final List<Chapter> chapters;
}

/// 宿主桥实现：请求走 [SourceHttpClient]，解析复用 [HtmlSelector]。
class _JsHttpBridge implements JsHostBridge {
  _JsHttpBridge(this._source);

  final JsSource _source;

  @override
  Future<JsFetchResponse> fetch(JsFetchRequest request) async {
    final response = await _source.http.send(
      SourceRequest(
        url: request.url,
        method: request.method,
        // 规则级请求头先铺底（如固定 Referer），单次请求的头覆盖它。
        headers: <String, String>{..._source.rule.headers, ...request.headers},
        body: request.body,
        bodyType: RequestBodyType.parse(request.bodyType),
      ),
      sourceId: _source._id,
    );
    return JsFetchResponse(
      status: response.statusCode,
      body: response.body,
      url: response.url,
    );
  }

  @override
  List<Map<String, String>> selectRows(
    String html,
    String selector,
    Map<Object?, Object?>? fields,
    String? baseUrl,
  ) {
    final document = html_parser.parse(html);
    final nodes = HtmlSelector.selectInDocument(document, selector);
    final specs = fields == null ? null : parseFields(fields);
    return <Map<String, String>>[
      for (final node in nodes) _row(node, specs, baseUrl),
    ];
  }

  @override
  String? selectValue(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) => HtmlSelector.extract(
    html,
    FieldSpec(selector: selector, attr: attr, absolute: true),
    baseUrl: baseUrl,
  );

  @override
  List<String> selectValues(
    String html,
    String selector,
    String attr,
    String? baseUrl,
  ) => HtmlSelector.extractAll(
    html,
    FieldSpec(selector: selector, attr: attr, absolute: true),
    baseUrl: baseUrl,
  );

  Map<String, String> _row(
    HtmlNode node,
    Map<String, FieldSpec>? specs,
    String? baseUrl,
  ) {
    if (specs == null || specs.isEmpty) {
      return <String, String>{'text': node.value('text')?.trim() ?? ''};
    }
    final row = <String, String>{};
    for (final entry in specs.entries) {
      final value = HtmlSelector.extractWithin(
        node,
        entry.value,
        baseUrl: baseUrl,
      );
      if (value != null && value.isNotEmpty) row[entry.key] = value;
    }
    return row;
  }
}
