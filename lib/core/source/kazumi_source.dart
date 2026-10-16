import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/media_item.dart';
import '../models/media_type.dart';
import '../models/source_descriptor.dart';
import '../models/source_exception.dart';
import '../platform/platform_channel.dart';
import 'http_client.dart';
import 'kazumi_api.dart';
import 'rule_schema.dart';
import 'selector_engine.dart';
import 'source_api.dart';
import 'windows_source_session.dart';

/// Kazumi XPath and API-mode protocol. Rules never execute scripts.
class KazumiRule {
  KazumiRule._(this.raw, this.descriptor, this.searchApi, this.chapterApi);
  final Map<String, dynamic> raw;
  final SourceDescriptor descriptor;
  final KazumiApiRule? searchApi, chapterApi;

  static bool recognizes(String text) {
    try {
      final raw = jsonDecode(text);
      return raw is Map &&
          (raw.containsKey('searchList') || raw['searchMode'] == 'api') &&
          raw.containsKey('baseURL');
    } on FormatException {
      return false;
    }
  }

  static KazumiRule parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const RuleFormatException('Kazumi 规则不是有效 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const RuleFormatException('Kazumi 规则必须是对象');
    }
    String requiredText(String key) {
      final value = (decoded as Map<String, dynamic>)[key];
      if (value is! String || value.trim().isEmpty) {
        throw RuleFormatException('Kazumi 规则缺少 $key');
      }
      return value.trim();
    }

    if (decoded['deprecated'] == true) {
      throw const RuleFormatException('上游已弃用此规则，不能安装');
    }
    final api = int.tryParse('${decoded['api'] ?? '1'}');
    if (api == null ||
        api < 1 ||
        api > 8 ||
        (decoded['type'] ?? 'anime') != 'anime') {
      throw const RuleFormatException('当前支持 Kazumi api 1–8 的番剧规则');
    }
    final searchMode = decoded['searchMode'] ?? 'xpath';
    final chapterMode = decoded['chapterMode'] ?? 'xpath';
    if (!['xpath', 'api'].contains(searchMode) ||
        !['xpath', 'api'].contains(chapterMode)) {
      throw const RuleFormatException('规则模式仅支持 xpath/api');
    }
    final searchApi = searchMode == 'api'
        ? KazumiApiRule(decoded['searchApiConfig'], search: true)
        : null;
    final chapterApi = chapterMode == 'api'
        ? KazumiApiRule(decoded['chapterApiConfig'], search: false)
        : null;
    final antiCrawler = decoded['antiCrawlerConfig'];
    if (antiCrawler is Map && antiCrawler['enabled'] == true) {
      final detectType = int.tryParse(
        '${antiCrawler['captchaDetectType'] ?? 1}',
      );
      if (![1, 2, 3].contains(detectType)) {
        throw const RuleFormatException('验证码检测类型必须为 XPath/文本/正则');
      }
      final value = '${antiCrawler['captchaDetectValue'] ?? ''}';
      try {
        if (value.isNotEmpty && detectType == 1) {
          HtmlSelector.selectAll('<html></html>', value);
        }
        if (value.isNotEmpty && detectType == 3) RegExp(value);
      } catch (_) {
        throw const RuleFormatException('验证码检测表达式无效');
      }
      // captchaScript/auto-click flags are retained, never executed.
    }
    final name = requiredText('name');
    final version = requiredText('version');
    if (!RegExp(r'^\d+(?:\.\d+){0,3}$').hasMatch(version)) {
      throw const RuleFormatException('Kazumi 规则版本必须是数字版本');
    }
    for (final key in ['baseURL', if (searchApi == null) 'searchURL']) {
      final uri = Uri.tryParse(requiredText(key));
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw RuleFormatException('$key 必须是 HTTPS 地址');
      }
    }
    if (searchApi == null && !requiredText('searchURL').contains('@keyword')) {
      throw const RuleFormatException('searchURL 缺少 @keyword');
    }
    for (final key in [
      if (searchApi == null) ...['searchList', 'searchName', 'searchResult'],
      if (chapterApi == null) ...['chapterRoads', 'chapterResult'],
    ]) {
      final value = requiredText(key);
      if (!value.startsWith('//') && !value.startsWith('.//')) {
        throw RuleFormatException('$key 必须是 XPath 选择器');
      }
      try {
        HtmlSelector.selectAll('<html><body></body></html>', value);
      } catch (_) {
        throw RuleFormatException('$key 的 XPath 无效');
      }
    }
    final id =
        'kazumi:${sha256.convert(utf8.encode(name.toLowerCase())).toString().substring(0, 24)}';
    return KazumiRule._(
      decoded,
      SourceDescriptor(
        id: id,
        name: name,
        type: MediaType.anime,
        kind: SourceKind.plugin,
        baseUrl: requiredText('baseURL'),
        version: version,
        capabilities: const {
          SourceCapability.search,
          SourceCapability.detail,
          SourceCapability.content,
        },
      ),
      searchApi,
      chapterApi,
    );
  }

  String get text => jsonEncode(raw);
}

class KazumiSource implements SearchProvider, DetailProvider, ContentProvider {
  KazumiSource({required this.rule, required this.http});
  final KazumiRule rule;
  final SourceHttpClient http;
  @override
  SourceDescriptor get descriptor => rule.descriptor;
  @override
  bool get isReady => true;

  Map<String, String> get _headers => {
    'User-Agent': '${rule.raw['userAgent'] ?? ''}'.trim().isEmpty
        ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36'
        : '${rule.raw['userAgent']}',
    'Referer': '${rule.raw['referer'] ?? ''}'.isEmpty
        ? descriptor.baseUrl!
        : '${rule.raw['referer']}',
  };

  SourceException _error(
    String message, {
    SourceErrorType type = SourceErrorType.parse,
  }) => SourceException(sourceId: descriptor.id, type: type, message: message);

  String _url(String value, {String? base}) {
    final uri = Uri.tryParse(
      resolveUrl(base ?? descriptor.baseUrl!, value) ?? '',
    );
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw _error('来源返回了无效或非 HTTPS 地址');
    }
    return uri.toString();
  }

  Future<String> _fetch(String url, {bool post = false}) async {
    final uri = Uri.parse(_url(url));
    return _fetchRequest(
      SourceRequest(
        url: post ? uri.replace(query: null).toString() : uri.toString(),
        method: post ? 'POST' : 'GET',
        headers: _headers,
        body: post ? uri.query : null,
        bodyType: post ? RequestBodyType.form : RequestBodyType.none,
      ),
    );
  }

  Future<String> _fetchRequest(SourceRequest request) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var uri = Uri.parse(_url(request.url));
    var method = request.method;
    var body = request.body;
    var bodyType = request.bodyType;
    final headers = Map<String, String>.of(request.headers);
    for (var hop = 0; hop <= 5; hop++) {
      if (_browserCookies) {
        final cookies = _windows
            ? await WindowsSourceSession.cookies(descriptor.id, uri.toString())
            : await platformChannel.ruleCookieHeader(uri.toString());
        headers.removeWhere((key, _) => key.toLowerCase() == 'cookie');
        if (cookies != null && cookies.isNotEmpty) headers['Cookie'] = cookies;
      }
      final response = await http
          .send(
            SourceRequest(
              url: uri.toString(),
              method: method,
              headers: headers,
              body: body,
              bodyType: bodyType,
              followRedirects: false,
              checkStatus: false,
            ),
            sourceId: descriptor.id,
          )
          .timeout(deadline.difference(DateTime.now()));
      if (_browserCookies) {
        final header = response.headers['set-cookie'];
        if (header != null) {
          final cookies = header.split(RegExp(r',(?=\s*[^=;,\s]+=[^;,]*)'));
          if (_windows) {
            await WindowsSourceSession.storeCookies(descriptor.id, uri.toString(), cookies);
          } else {
            await platformChannel.storeRuleCookies(uri.toString(), cookies);
          }
        }
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final target = response.headers['location'];
        if (target == null || hop == 5) throw _error('站点重定向无效或次数过多');
        final next = Uri.parse(_url(uri.resolve(target).toString()));
        if (next.origin != uri.origin) {
          headers.removeWhere(
            (key, _) => ['authorization', 'cookie'].contains(key.toLowerCase()),
          );
        }
        if (response.statusCode == 303 ||
            ([301, 302].contains(response.statusCode) && method == 'POST')) {
          method = 'GET';
          body = null;
          bodyType = RequestBodyType.none;
        }
        uri = next;
        continue;
      }
      if (_challenge(response.body)) {
        throw KazumiVerificationRequired(descriptor.id, uri.toString());
      }
      if (!response.isSuccess) {
        throw _error(
          '站点请求失败（HTTP ${response.statusCode}）',
          type: switch (response.statusCode) {
            401 || 403 => SourceErrorType.auth,
            429 => SourceErrorType.rateLimited,
            404 => SourceErrorType.notFound,
            _ => SourceErrorType.network,
          },
        );
      }
      return response.body;
    }
    throw _error('站点重定向次数过多');
  }

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _browserCookies => _android || _windows;
  bool _challenge(String body) {
    final config = rule.raw['antiCrawlerConfig'];
    if (config is! Map || config['enabled'] != true) return false;
    final value = '${config['captchaDetectValue'] ?? ''}';
    if (value.isNotEmpty) {
      return switch (int.tryParse('${config['captchaDetectType'] ?? 1}')) {
        2 => body.contains(value),
        3 => RegExp(value).hasMatch(body),
        _ => HtmlSelector.selectAll(body, value).isNotEmpty,
      };
    }
    for (final field in ['captchaImage', 'captchaButton']) {
      final selector = '${config[field] ?? ''}';
      if (selector.isNotEmpty &&
          HtmlSelector.selectAll(body, selector).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  Future<bool> openWebSession({String? url}) {
    final target = _url(url ?? descriptor.baseUrl!);
    if (_windows) {
      return WindowsSourceSession.open(
        sourceId: descriptor.id, url: target,
        userAgent: _headers['User-Agent']!,
      );
    }
    return platformChannel.openRuleSession(target, _headers['User-Agent']!);
  }

  // Kazumi queries // against the current subtree, unlike Triomi field rules.
  String _relative(String value) => value.startsWith('//') ? '.$value' : value;

  @override
  Future<List<MediaItem>> search(String keyword, {int page = 1}) async {
    if (page > 1 || keyword.trim().isEmpty) return [];
    if (rule.searchApi case final api?) {
      try {
        final text = await _fetchRequest(
          api.request({'keyword': keyword}, _headers),
        );
        final seen = <String>{};
        return [
          for (final row in api.searchRows(text))
            if (seen.add(row.remoteId))
              MediaItem(
                sourceId: descriptor.id,
                remoteId: row.remoteId,
                type: MediaType.anime,
                title: row.title,
              ),
        ];
      } on RuleFormatException catch (error) {
        throw _error('$error');
      } on FormatException {
        throw _error('API 搜索响应不是有效 JSON');
      }
    }
    final html = await _fetch(
      '${rule.raw['searchURL']}'.replaceAll(
        '@keyword',
        Uri.encodeQueryComponent(keyword),
      ),
      post: rule.raw['usePost'] == true,
    );
    final items = <MediaItem>[];
    final seen = <String>{};
    for (final row in HtmlSelector.selectAll(
      html,
      '${rule.raw['searchList']}',
    )) {
      final title = HtmlSelector.extractWithin(
        row,
        FieldSpec(selector: _relative('${rule.raw['searchName']}')),
      );
      final href = HtmlSelector.extractWithin(
        row,
        FieldSpec(
          selector: _relative('${rule.raw['searchResult']}'),
          attr: 'href',
        ),
      );
      if (title == null || title.isEmpty || href == null || href.isEmpty) {
        continue;
      }
      final url = _url(href);
      if (!seen.add(url)) continue;
      items.add(
        MediaItem(
          sourceId: descriptor.id,
          remoteId: url,
          type: MediaType.anime,
          title: title,
          url: url,
        ),
      );
    }
    return items;
  }

  @override
  Future<MediaItem> detail(MediaItem item) async => item;

  @override
  Future<List<Chapter>> chapters(MediaItem item) async {
    if (item.sourceId != descriptor.id) throw _error('作品来源不一致');
    if (rule.chapterApi case final api?) {
      try {
        final text = await _fetchRequest(
          api.request({'source': item.remoteId}, _headers),
        );
        final result = api.chapters(text, item, descriptor.baseUrl!);
        if (result.isEmpty) throw _error('API 响应未找到剧集');
        return result;
      } on RuleFormatException catch (error) {
        throw _error('$error');
      } on FormatException {
        throw _error('API 剧集响应不是有效 JSON');
      }
    }
    final html = await _fetch(item.url ?? item.remoteId);
    final result = <Chapter>[];
    final roads = HtmlSelector.selectAll(html, '${rule.raw['chapterRoads']}');
    for (var road = 0; road < roads.length; road++) {
      final seen = <String>{};
      final episodes = HtmlSelector.selectWithin(
        roads[road],
        _relative('${rule.raw['chapterResult']}'),
      );
      for (var index = 0; index < episodes.length; index++) {
        final href = episodes[index].value('href');
        if (href == null || href.isEmpty) continue;
        final url = _url(href, base: item.url);
        if (!seen.add(url)) continue;
        final title = episodes[index].value('text')?.trim() ?? '';
        result.add(
          Chapter(
            sourceId: descriptor.id,
            remoteId:
                '${item.remoteId}#road=$road&url=${Uri.encodeComponent(url)}',
            title: title.isEmpty ? '第 ${index + 1} 集' : title,
            url: url,
            number: Chapter.parseNumber(title) ?? (index + 1).toDouble(),
            volumeTitle: '播放列表 ${road + 1}',
            sortIndex: result.length,
          ),
        );
      }
    }
    if (result.isEmpty) throw _error('未找到剧集，请检查规则或尝试其他来源');
    return result;
  }

  @override
  Future<ChapterContent> content(Chapter chapter) async {
    if (chapter.sourceId != descriptor.id || chapter.locked) {
      throw _error('章节来源不一致或不可播放');
    }
    final url = _url(chapter.url ?? '');
    final direct = RegExp(
      r'\.(mp4|m3u8)(?:\?|$)',
      caseSensitive: false,
    ).hasMatch(url);
    return ChapterContent(
      playSources: [
        PlaySource(
          name: chapter.volumeTitle ?? descriptor.name,
          url: url,
          webPage: !direct,
          headers: _headers,
        ),
      ],
    );
  }
}

class KazumiVerificationRequired extends SourceException {
  const KazumiVerificationRequired(String sourceId, this.url)
    : super(
        sourceId: sourceId,
        type: SourceErrorType.permission,
        message: '网站要求人工验证；请打开可见站点完成验证后重试',
      );
  final String url;
}
