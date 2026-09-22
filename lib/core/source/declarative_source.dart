import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import '../models/chapter.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import 'http_client.dart';
import 'json_path.dart';
import 'rule_schema.dart';
import 'selector_engine.dart';
import 'source_api.dart';

/// 声明式规则的执行器：把 JSON 规则翻译成「发请求 → 解析 → 映射模型」。
///
/// 与 JS 扩展源相比，它不需要原生 JS 引擎，因此在 Web 上也可用，
/// 覆盖绝大多数结构规整的站点与开放接口。
class DeclarativeSource
    implements
        DiscoverProvider,
        SearchProvider,
        DetailProvider,
        ContentProvider {
  DeclarativeSource({required this.rule, required this.http});

  final SourceRule rule;
  final SourceHttpClient http;

  @override
  SourceDescriptor get descriptor => rule.descriptor;

  @override
  bool get isReady => true;

  @override
  List<DiscoverFeed> get feeds => rule.feeds;

  String get _sourceId => descriptor.id;

  // ---------------------------------------------------------------- 榜单

  @override
  Future<List<MediaItem>> discover(DiscoverFeed feed, {int page = 1}) async {
    final list = rule.discover;
    if (list == null) {
      throw _ruleMissing('discover', '规则没有定义榜单');
    }
    final request = _withUrl(list.request, feed.urlTemplate);
    final response = await _send(request, page: page);
    return _items(response, list);
  }

  // ---------------------------------------------------------------- 搜索

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    final list = rule.search;
    if (list == null) {
      throw _ruleMissing('search', '规则没有定义搜索');
    }
    final response = await _send(
      _withUrl(list.request, null),
      page: page,
      keyword: keyword,
    );
    return _items(response, list);
  }

  // ---------------------------------------------------------------- 详情

  @override
  Future<MediaItem> detail(MediaItem item) async {
    final detailRule = rule.detail;
    if (detailRule == null) {
      throw _ruleMissing('detail', '规则没有定义详情');
    }
    final request = _withUrl(
      detailRule.request ?? const RuleRequest(url: '{urlRaw}'),
      null,
    );
    final response = await _send(request, item: item);
    final fields = _extractFields(response, detailRule.fields);
    return _merge(item, fields, response.url);
  }

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    final chaptersRule = rule.detail?.chapters;
    if (chaptersRule == null) return const <Chapter>[];

    final request = _withUrl(
      chaptersRule.request ?? const RuleRequest(url: '{urlRaw}'),
      null,
    );
    final response = await _send(request, item: item);
    final rows = _rows(response, chaptersRule);

    final chapters = <Chapter>[];
    var index = 0;
    for (final row in rows) {
      final remoteId = row['remoteId'] ?? row['url'];
      if (remoteId == null || remoteId.isEmpty) continue;
      final rawTitle = row['title'] ?? row['name'];
      final title = rawTitle != null && rawTitle.isNotEmpty
          ? rawTitle
          : '第 ${index + 1} 话';
      chapters.add(
        Chapter(
          sourceId: _sourceId,
          remoteId: remoteId,
          title: title,
          url: resolveUrl(response.url, row['url']),
          number:
              double.tryParse(row['number'] ?? '') ??
              Chapter.parseNumber(title),
          sortIndex: index,
          volumeTitle: row['volumeTitle'],
          releaseDate: DateTime.tryParse(row['releaseDate'] ?? ''),
          locked: row['locked'] == 'true',
        ),
      );
      index++;
    }
    return chapters;
  }

  // ---------------------------------------------------------------- 正文

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    final contentRule = rule.content;
    if (contentRule == null) {
      throw _ruleMissing('content', '规则没有定义正文');
    }
    final chapterUrl = chapter.url;
    if (chapterUrl == null || chapterUrl.isEmpty) {
      throw SourceException(
        sourceId: _sourceId,
        type: SourceErrorType.parse,
        message: '章节缺少地址，无法取正文',
      );
    }

    final response = await _send(
      _withUrl(const RuleRequest(url: '{urlRaw}'), null),
      chapterUrl: chapterUrl,
    );

    // 图片：多个选择器按顺序尝试，第一个有结果的生效
    // （很多站点的懒加载地址在 data-src / data-original 上）。
    var images = const <String>[];
    for (final selector in contentRule.imageSelectors) {
      final spec = FieldSpec.parseInline(selector, defaultAttr: 'src');
      final found = HtmlSelector.extractAll(
        response.body,
        FieldSpec(
          selector: spec.selector,
          attr: spec.attr,
          regex: spec.regex,
          absolute: true,
        ),
        baseUrl: response.url,
      );
      if (found.isNotEmpty) {
        images = found;
        break;
      }
    }

    // 小说正文：取第一个命中节点的纯文本。
    String? text;
    final textSelector = contentRule.textSelector;
    if (textSelector != null && textSelector.isNotEmpty) {
      final node = HtmlSelector.selectFirst(response.body, textSelector);
      if (node != null) {
        final plain = htmlToPlainText(node.element.innerHtml);
        text = plain.isEmpty ? null : plain;
      }
    }

    // 番剧线路：同一元素上取线路名与地址。
    var playSources = const <PlaySource>[];
    final playRule = contentRule.playSources;
    if (playRule != null) {
      playSources = <PlaySource>[
        for (final row in _rows(response, playRule))
          if ((row['url'] ?? '').isNotEmpty)
            PlaySource(
              name: row['name']?.isNotEmpty == true ? row['name']! : '线路',
              url: resolveUrl(response.url, row['url'])!,
            ),
      ];
    }

    return ChapterContent(images: images, text: text, playSources: playSources);
  }

  // ---------------------------------------------------------------- 内部实现

  /// 组装请求：规则级 headers 先铺底，请求级 headers 覆盖。
  Future<SourceResponse> _send(
    RuleRequest request, {
    int page = 1,
    String? keyword,
    MediaItem? item,
    String? chapterUrl,
  }) {
    final rendered = request.render(
      baseUrl: rule.baseUrl,
      page: page,
      keyword: keyword,
      itemUrl: item?.url ?? chapterUrl,
      id: item?.remoteId,
    );
    return http.send(
      SourceRequest(
        url: rendered.url,
        method: rendered.method,
        headers: <String, String>{...rule.headers, ...rendered.headers},
        body: rendered.body,
        bodyType: rendered.bodyType,
      ),
      sourceId: _sourceId,
    );
  }

  /// 用给定地址覆盖请求模板里的地址（榜单各有各的地址）。
  RuleRequest _withUrl(RuleRequest? base, String? overrideUrl) => RuleRequest(
    url: overrideUrl != null && overrideUrl.isNotEmpty
        ? overrideUrl
        : (base?.url ?? ''),
    method: base?.method ?? 'GET',
    headers: base?.headers ?? const <String, String>{},
    body: base?.body,
    bodyType: base?.bodyType ?? RequestBodyType.none,
    pageSize: base?.pageSize ?? 20,
  );

  List<MediaItem> _items(SourceResponse response, RuleList list) {
    final items = <MediaItem>[];
    for (final row in _rows(response, list)) {
      final item = _toItem(row, response.url);
      if (item != null) items.add(item);
    }
    return items;
  }

  /// 列表解析：HTML 走选择器，JSON 走点路径。
  List<Map<String, String>> _rows(SourceResponse response, RuleList list) {
    if (rule.response == ResponseFormat.json) {
      final decoded = _decodeJson(response);
      return <Map<String, String>>[
        for (final node in jsonPickList(decoded, list.listSelector))
          if (node is Map) _rowFromJson(node, list.fields),
      ];
    }

    final document = html_parser.parse(response.body);
    final nodes = HtmlSelector.selectInDocument(document, list.listSelector);
    return <Map<String, String>>[
      for (final node in nodes) _rowFromHtml(node, list.fields, response.url),
    ];
  }

  Map<String, String> _rowFromHtml(
    HtmlNode node,
    Map<String, FieldSpec> fields,
    String baseUrl,
  ) {
    final row = <String, String>{};
    for (final entry in fields.entries) {
      final value = HtmlSelector.extractWithin(
        node,
        entry.value,
        baseUrl: baseUrl,
      );
      if (value != null && value.isNotEmpty) row[entry.key] = value;
    }
    return row;
  }

  Map<String, String> _rowFromJson(
    Map<Object?, Object?> node,
    Map<String, FieldSpec> fields,
  ) {
    final row = <String, String>{};
    for (final entry in fields.entries) {
      final raw = jsonPickString(node, entry.value.selector);
      final value = applyFieldSpec(entry.value, raw);
      if (value != null && value.isNotEmpty) row[entry.key] = value;
    }
    return row;
  }

  Map<String, String> _extractFields(
    SourceResponse response,
    Map<String, FieldSpec> fields,
  ) {
    if (rule.response == ResponseFormat.json) {
      final decoded = _decodeJson(response);
      if (decoded is Map) return _rowFromJson(decoded, fields);
      return const <String, String>{};
    }
    // 详情字段取自整篇文档，用 HtmlNode 包一层根节点。
    final document = html_parser.parse(response.body);
    final root = document.documentElement;
    if (root == null) return const <String, String>{};
    return _rowFromHtml(
      HtmlNode.fromElement(root, documentRoot: root),
      fields,
      response.url,
    );
  }

  Object? _decodeJson(SourceResponse response) {
    try {
      return jsonDecode(response.body);
    } catch (error) {
      throw SourceException(
        sourceId: _sourceId,
        type: SourceErrorType.parse,
        message: '响应不是合法 JSON：$error',
      );
    }
  }

  MediaItem? _toItem(Map<String, String> row, String baseUrl) {
    final remoteId = row['remoteId'];
    // title 允许用 name 兜底：不少接口的「中文名」字段会为空（如 Bangumi 的 name_cn）。
    final title = row['title'] ?? row['name'];
    if (remoteId == null || remoteId.isEmpty) return null;
    if (title == null || title.isEmpty) return null;

    return MediaItem(
      sourceId: _sourceId,
      remoteId: remoteId,
      type: descriptor.type,
      title: title,
      url: resolveUrl(baseUrl, row['url']),
      coverUrl: resolveUrl(baseUrl, row['coverUrl'] ?? row['cover']),
      author: row['author'],
      description: row['description'],
      tags: _splitTags(row['tags']),
      rating: double.tryParse(row['rating'] ?? ''),
      status: row['status'],
    );
  }

  MediaItem _merge(MediaItem item, Map<String, String> fields, String baseUrl) {
    if (fields.isEmpty) return item;
    final mergedTitle = fields['title'] ?? fields['name'];
    return MediaItem(
      sourceId: item.sourceId,
      remoteId: item.remoteId,
      type: item.type,
      title: mergedTitle?.isNotEmpty == true ? mergedTitle! : item.title,
      url: item.url ?? resolveUrl(baseUrl, fields['url']),
      coverUrl:
          resolveUrl(baseUrl, fields['coverUrl'] ?? fields['cover']) ??
          item.coverUrl,
      author: fields['author'] ?? item.author,
      description: fields['description'] ?? item.description,
      tags: fields.containsKey('tags') ? _splitTags(fields['tags']) : item.tags,
      rating: double.tryParse(fields['rating'] ?? '') ?? item.rating,
      status: fields['status'] ?? item.status,
    );
  }

  List<String> _splitTags(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    return <String>[
      for (final tag in raw.split(RegExp(r'[,，/\s]+')))
        if (tag.trim().isNotEmpty) tag.trim(),
    ];
  }

  SourceException _ruleMissing(String capability, String message) =>
      SourceException(
        sourceId: _sourceId,
        type: SourceErrorType.parse,
        message: message,
      );
}
