import 'dart:convert';

import '../models/chapter.dart';
import '../models/media_item.dart';
import 'http_client.dart';
import 'rule_schema.dart';

/// Kazumi API-mode request templates and restricted JSONPath response mapping.
/// No script, filter expression, recursive descent, or dynamic code execution.
class KazumiApiRule {
  KazumiApiRule(Object? value, {required this.search}) {
    if (value is! Map<String, dynamic>) {
      throw const RuleFormatException('API 模式缺少配置对象');
    }
    raw = value;
    final request = raw['request'];
    if (request is! Map<String, dynamic>) {
      throw const RuleFormatException('API 模式缺少 request');
    }
    requestConfig = request;
    final method = '${request['method'] ?? 'GET'}'.toUpperCase();
    if (method != 'GET' && method != 'POST') {
      throw const RuleFormatException('API 请求仅支持 GET/POST');
    }
    _https('${request['url'] ?? ''}');
    final bodyType = '${request['bodyType'] ?? 'none'}';
    if (!const ['none', 'json', 'form'].contains(bodyType)) {
      throw const RuleFormatException('API bodyType 仅支持 none/json/form');
    }
    _map(request['headers']);
    _map(request['query']);
    if (bodyType == 'form' && request['body'] is! Map) {
      throw const RuleFormatException('API form body 必须是对象');
    }
    if (search) {
      _path('listPath', r'$.data[*]');
      _path('namePath', r'$.name');
      _path('sourcePath', r'$.url');
      final template = '${raw['sourceTemplate'] ?? ''}'.trim();
      if (template.isNotEmpty) {
        if (!template.contains('@source')) {
          throw const RuleFormatException('API 详情页模板必须引用 @source');
        }
        _https(template.replaceAll('@source', 'source'));
      }
    } else {
      final format = '${raw['format'] ?? 'nested'}';
      if (!const ['nested', 'delimited'].contains(format)) {
        throw const RuleFormatException('API 剧集格式仅支持 nested/delimited');
      }
      if (format == 'delimited') {
        _path('roadNamesPath', '');
        _path('roadEpisodesPath', '');
        for (final entry in _separators.entries) {
          if ('${raw[entry.key] ?? entry.value}'.isEmpty) {
            throw const RuleFormatException('API 剧集分隔符不能为空');
          }
        }
      } else {
        _path('roadsPath', r'$.data.roads[*]', optional: true);
        _path('roadNamePath', r'$.name', optional: true);
        _path('episodesPath', r'$.episodes[*]');
        _path('episodeNamePath', r'$.name');
        _path('episodeUrlPath', r'$.url', optional: true);
        if (!_paths.containsKey('episodeUrlPath') &&
            raw['episodePage'] == null) {
          throw const RuleFormatException('API 剧集缺少 URL 路径或播放页模板');
        }
      }
      for (final entry in _map(raw['variables']).entries) {
        _paths['var:${entry.key}'] = _ApiPath('${entry.value}');
      }
      if (raw['episodePage'] != null) {
        final page = _map(raw['episodePage']);
        if ('${page['url'] ?? ''}'.trim().isEmpty) {
          throw const RuleFormatException('API 播放页模板不能为空');
        }
        _https('${page['url']}');
        _map(page['query']);
      }
    }
  }

  final bool search;
  late final Map<String, dynamic> raw, requestConfig;
  final _paths = <String, _ApiPath>{};
  static const _separators = {
    'roadSeparator': r'$$$',
    'episodeSeparator': '#',
    'fieldSeparator': r'$',
  };
  static final _variable = RegExp(
    r'(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)',
  );

  void _path(String key, String fallback, {bool optional = false}) {
    final text = '${raw[key] ?? fallback}'.trim();
    if (optional && text.isEmpty) return;
    _paths[key] = _ApiPath(text);
  }

  SourceRequest request(
    Map<String, Object?> variables,
    Map<String, String> headers,
  ) {
    final config = requestConfig;
    final url = _url(config, variables);
    final renderedHeaders = _map(
      config['headers'],
    ).map((key, value) => MapEntry(key, '${_renderValue(value, variables)}'));
    final method = '${config['method'] ?? 'GET'}'.toUpperCase();
    final bodyType = RequestBodyType.parse('${config['bodyType'] ?? 'none'}');
    String? body;
    if (method == 'POST' && bodyType != RequestBodyType.none) {
      final value = _renderValue(config['body'], variables);
      body = bodyType == RequestBodyType.json
          ? jsonEncode(value)
          : _map(value).entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent('${e.value}')}',
                )
                .join('&');
    }
    return SourceRequest(
      url: url,
      method: method,
      headers: {...headers, ...renderedHeaders},
      body: body,
      bodyType: bodyType,
    );
  }

  List<({String title, String remoteId})> searchRows(String text) {
    final document = jsonDecode(text);
    final template = '${raw['sourceTemplate'] ?? ''}'.trim();
    final result = <({String title, String remoteId})>[];
    for (final node in _paths['listPath']!.read(document)) {
      final title = _text(_first('namePath', node));
      final source = _text(_first('sourcePath', node));
      if (title.isEmpty || source.isEmpty) continue;
      result.add((
        title: title,
        // API 9 permits a prefix immediately before @source, such as /GV@source.
        remoteId: template.isEmpty
            ? source
            : _https(
                template.replaceAll('@source', Uri.encodeComponent(source)),
              ),
      ));
    }
    return result;
  }

  List<Chapter> chapters(String text, MediaItem item, String baseUrl) {
    final document = jsonDecode(text);
    final variables = <String, Object?>{'source': item.remoteId};
    for (final entry in _map(raw['variables']).entries) {
      final value = _first('var:${entry.key}', document);
      if (value == null) throw RuleFormatException('API 响应缺少变量 ${entry.key}');
      variables[entry.key] = value;
    }
    final result = <Chapter>[];
    void add(String title, String url, String roadName, int road, int episode) {
      final finalUrl = raw['episodePage'] == null
          ? _https(Uri.parse(baseUrl).resolve(url).toString())
          : _url(_map(raw['episodePage']), {
              ...variables,
              'episodeUrl': url,
              'roadIndex': road,
              'roadNumber': road + 1,
              'episodeIndex': episode,
              'episodeNumber': episode + 1,
            });
      result.add(
        Chapter(
          sourceId: item.sourceId,
          remoteId:
              '${item.remoteId}#road=$road&url=${Uri.encodeComponent(finalUrl)}',
          title: title.isEmpty ? '第 ${episode + 1} 集' : title,
          url: finalUrl,
          number: Chapter.parseNumber(title) ?? (episode + 1).toDouble(),
          volumeTitle: roadName.isEmpty ? '播放列表 ${road + 1}' : roadName,
          sortIndex: result.length,
        ),
      );
    }

    if (raw['format'] == 'delimited') {
      String separator(String key) => '${raw[key] ?? _separators[key]}';
      final names = _text(_first('roadNamesPath', document))
          .split(separator('roadSeparator'));
      final roads = _text(_first('roadEpisodesPath', document))
          .split(separator('roadSeparator'));
      for (var road = 0; road < roads.length; road++) {
        final episodes = roads[road].split(separator('episodeSeparator'));
        for (var episode = 0; episode < episodes.length; episode++) {
          final entry = episodes[episode];
          final field = separator('fieldSeparator');
          final at = entry.indexOf(field);
          if (at < 0) continue;
          final url = entry.substring(at + field.length).trim();
          if (url.isEmpty && raw['episodePage'] == null) continue;
          add(
            entry.substring(0, at).trim(),
            url,
            road < names.length ? names[road] : '',
            road,
            episode,
          );
        }
      }
    } else {
      final roads = _paths['roadsPath']?.read(document) ?? [document];
      for (var road = 0; road < roads.length; road++) {
        final node = roads[road];
        final name = _text(_first('roadNamePath', node));
        final episodes = _paths['episodesPath']!.read(node);
        for (var episode = 0; episode < episodes.length; episode++) {
          final url = _text(_first('episodeUrlPath', episodes[episode]));
          if (url.isEmpty && raw['episodePage'] == null) continue;
          add(
            _text(_first('episodeNamePath', episodes[episode])),
            url,
            name,
            road,
            episode,
          );
        }
      }
    }
    return result;
  }

  Object? _first(String key, Object? node) =>
      _paths[key]?.read(node).firstOrNull;
  static String _text(Object? value) => value == null ? '' : '$value'.trim();
  static Map<String, dynamic> _map(Object? value) {
    if (value == null) return const {};
    if (value is! Map<String, dynamic>) {
      throw const RuleFormatException('API 字段必须是对象');
    }
    return value;
  }

  static String _https(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const RuleFormatException('API 请求和播放页必须使用无凭据的 HTTPS 地址');
    }
    return uri.toString();
  }

  static String _url(
    Map<String, dynamic> config,
    Map<String, Object?> variables,
  ) {
    final uri = Uri.parse(
      _https(_render('${config['url'] ?? ''}', variables, encode: true)),
    );
    final query = _map(
      config['query'],
    ).map((key, value) => MapEntry(key, '${_renderValue(value, variables)}'));
    return query.isEmpty
        ? uri.toString()
        : uri
              .replace(queryParameters: {...uri.queryParameters, ...query})
              .toString();
  }

  static String _render(
    String text,
    Map<String, Object?> variables, {
    bool encode = false,
  }) => text.replaceAllMapped(_variable, (match) {
    final name = match[1]!;
    if (!variables.containsKey(name)) {
      throw RuleFormatException('API 模板缺少变量 @$name');
    }
    final value = '${variables[name] ?? ''}';
    return encode ? Uri.encodeComponent(value) : value;
  });
  static Object? _renderValue(Object? value, Map<String, Object?> variables) {
    if (value is String) {
      final exact = _variable.firstMatch(value);
      if (exact != null && exact.start == 0 && exact.end == value.length) {
        final name = exact[1]!;
        if (!variables.containsKey(name)) {
          throw RuleFormatException('API 模板缺少变量 @$name');
        }
        return variables[name];
      }
      return _render(value, variables);
    }
    if (value is List) {
      return value.map((v) => _renderValue(v, variables)).toList();
    }
    if (value is Map<String, dynamic>) {
      return value.map((k, v) => MapEntry(k, _renderValue(v, variables)));
    }
    return value;
  }
}

class _ApiPath {
  _ApiPath(String expression) {
    if (!expression.startsWith(r'$')) {
      throw const RuleFormatException(r'JSONPath 必须以 $ 开头');
    }
    var at = 1;
    while (at < expression.length) {
      if (expression[at] == '.') {
        final match = _key.matchAsPrefix(expression, at + 1);
        if (match == null) throw const RuleFormatException('不支持此 JSONPath 点路径');
        _tokens.add(match[0]!);
        at = match.end;
      } else if (expression[at] == '[') {
        final match = _bracket.matchAsPrefix(expression, at);
        if (match == null) {
          throw const RuleFormatException('JSONPath 仅支持键、数组下标和通配符');
        }
        final content = match[1]!.trim();
        if (content == '*') {
          _tokens.add(_wildcard);
        } else if (content.startsWith('"')) {
          _tokens.add(jsonDecode(content) as String);
        } else if (content.startsWith("'")) {
          _tokens.add(
            content
                .substring(1, content.length - 1)
                .replaceAll(r"\'", "'")
                .replaceAll(r'\\', r'\'),
          );
        } else {
          _tokens.add(int.parse(content));
        }
        at = match.end;
      } else {
        throw const RuleFormatException('JSONPath 不支持递归、表达式或过滤脚本');
      }
    }
  }
  final _tokens = <Object>[];
  static const _wildcard = #wildcard;
  static final _key = RegExp(r'[A-Za-z0-9_$-]+');
  static final _bracket = RegExp(
    r'''\[\s*(\d+|\*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')\s*\]''',
  );
  List<Object?> read(Object? root) {
    var nodes = <Object?>[root];
    for (final token in _tokens) {
      final next = <Object?>[];
      for (final node in nodes) {
        if (token == _wildcard) {
          if (node is List) next.addAll(node);
          if (node is Map) next.addAll(node.values);
        } else if (token is int) {
          if (node is List && token < node.length) next.add(node[token]);
        } else if (node is Map && node.containsKey(token)) {
          next.add(node[token]);
        }
      }
      nodes = next;
    }
    return nodes;
  }
}
