import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'http_client.dart';

/// Translates Suwayomi's private local API into the existing Mihon host values.
/// Database IDs never become a Triomi work/chapter identity: plugin URLs do.
class SuwayomiClient {
  SuwayomiClient({required this.dio, required this.cache});
  final Dio dio;
  final Directory cache;

  Future<Object?> _call(String path, {Object? data, String? method}) async {
    final response = await dio.request<Object?>(
      path,
      data: data,
      options: Options(method: method ?? (data == null ? 'GET' : 'POST')),
      cancelToken: SourceRequestCancellation.current?.token,
    );
    if (response.statusCode == 204 || response.data == '') return null;
    return response.data;
  }

  static Map<String, Object?> _map(Object? value) {
    if (value is! Map) throw const FormatException('桌面扩展返回了无效对象');
    return Map<String, Object?>.from(value);
  }

  Future<Map<String, Object?>> _graphql(
    String query,
    Map<String, Object?> variables,
  ) async {
    final result = _map(
      await _call(
        '/api/graphql',
        data: {'query': query, 'variables': variables},
      ),
    );
    if (result['errors'] case final List<Object?> errors
        when errors.isNotEmpty) {
      throw const FormatException('桌面扩展资料查询失败');
    }
    return _map(result['data']);
  }

  Future<List<Map<String, Object?>>> extensionSources(String package) async {
    final rows = await _call('/api/v1/source/list') as List;
    return [
      for (final raw in rows)
        if (_map(raw) case final row
            when Uri.tryParse('${row['iconUrl']}')?.pathSegments.lastOrNull ==
                package)
          {
            'id': '${row['id']}',
            'name': row['name'],
            'lang': row['lang'],
            'supportsLatest': row['supportsLatest'] == true,
            'configurable': row['isConfigurable'] == true,
            'nsfw': row['isNsfw'] == true,
          },
    ];
  }

  Future<void> install(File file, {required bool nativeJar}) async {
    try {
      await _call(
        '/api/v1/extension/install',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(
            file.path,
            filename: file.uri.pathSegments.last,
          ),
        }),
      );
    } on DioException catch (error) {
      // This endpoint converts/loads local bytes, not a source website request.
      // Upstream returns only "Server Error" for verifier failures, so do not
      // present its local HTTP 500 as evidence that the website is broken.
      if (error.type != DioExceptionType.badResponse ||
          error.response?.statusCode != 500) {
        rethrow;
      }
      throw UnsupportedError(
        nativeJar
            ? 'Windows 扩展原生 JAR 加载失败；请检查其与当前桌面运行时的兼容性。'
                  '这是本地安装阶段失败，不是来源网站的 HTTP 500。'
            : 'Windows 扩展 APK 转换或加载失败；Android 可用不代表转换后的 JVM 字节码兼容。'
                  '这是本地安装阶段失败，不是来源网站的 HTTP 500。'
                  '若仓库提供原生 JAR，请重新安装并单独确认其来源与指纹；不会自动改用其他仓库或关闭 Java 验证。',
      );
    }
  }

  Future<void> uninstall(String package) async {
    await _call('/api/v1/extension/uninstall/${Uri.encodeComponent(package)}');
  }

  Future<List<Map<String, Object?>>> preferences(String sourceId) async => [
    for (final row
        in await _call('/api/v1/source/$sourceId/preferences') as List)
      _map(row),
  ];

  Future<void> setPreference(
    String sourceId,
    int position,
    Object? value,
  ) async {
    await _call(
      '/api/v1/source/$sourceId/preferences',
      data: {
        'position': position,
        'value': value is String ? value : jsonEncode(value),
      },
    );
  }

  Future<Map<String, Object?>> request({
    required String sourceId,
    required String operation,
    int page = 1,
    String query = '',
    Map<String, Object?>? manga,
    Map<String, Object?>? chapter,
    Map<String, Object?>? pageData,
    List<Map<String, Object?>>? filters,
  }) async {
    if (!RegExp(r'^-?\d+$').hasMatch(sourceId)) {
      throw const FormatException('无效的桌面扩展来源身份');
    }
    switch (operation) {
      case 'popular':
      case 'latest':
      case 'search':
        if (page < 1) throw const FormatException('无效的来源页码');
        final raw = operation == 'search'
            ? await _call(
                '/api/v1/source/$sourceId/quick-search?pageNum=$page',
                data: {
                  'searchTerm': query,
                  'filter': filters == null ? null : _filterChanges(filters),
                },
              )
            : await _call('/api/v1/source/$sourceId/$operation/$page');
        final data = _map(raw);
        return {
          'ok': true,
          'mangas': [
            for (final row in data['mangaList'] as List)
              _manga(_map(row), sourceId),
          ],
          'hasNextPage': data['hasNextPage'] == true,
        };
      case 'filters':
        final rows =
            await _call('/api/v1/source/$sourceId/filters?reset=true') as List;
        return {
          'ok': true,
          'filters': [
            for (var i = 0; i < rows.length; i++) _filter(_map(rows[i]), i),
          ],
        };
      case 'detail':
      case 'chapters':
        final id = await _mangaId(sourceId, manga!);
        if (operation == 'detail') {
          final value = _map(await _call('/api/v1/manga/$id?onlineFetch=true'));
          return {'ok': true, 'manga': _manga(value, sourceId)};
        }
        final rows =
            await _call('/api/v1/manga/$id/chapters?onlineFetch=true') as List;
        return {
          'ok': true,
          'chapters': [
            for (final raw in rows)
              if (_map(raw) case final row)
                {
                  'url': row['url'],
                  'name': row['name'],
                  'chapterNumber': row['chapterNumber'],
                  'dateUpload': row['uploadDate'],
                },
          ],
        };
      case 'pages':
        final owner = _portableManga(manga);
        final row = await _chapter(sourceId, '${chapter!['url']}', owner);
        final mangaId = _map(row['manga'])['id'];
        final index = row['sourceOrder'];
        final info = _map(await _call('/api/v1/manga/$mangaId/chapter/$index'));
        final count = info['pageCount'] as int;
        if (count < 1 || count > 5000) {
          throw const FormatException('来源未返回有效漫画页');
        }
        return {
          'ok': true,
          'pages': [
            for (var page = 0; page < count; page++)
              {'chapterUrl': chapter['url'], 'index': page, 'manga': owner},
          ],
        };
      case 'imageFile':
        final index = pageData?['index'];
        if (index is! int || index < 0 || index >= 5000) {
          throw const FormatException('无效的漫画图片页码');
        }
        final owner = _portableManga(
          pageData!['manga'] is Map ? _map(pageData['manga']) : null,
        );
        final row = await _chapter(
          sourceId,
          '${pageData['chapterUrl']}',
          owner,
        );
        final id = _map(row['manga'])['id'];
        final order = row['sourceOrder'];
        return _imageFile(
          '/api/v1/manga/$id/chapter/$order/page/$index',
          '$sourceId:${owner['url']}:${pageData['chapterUrl']}:$index',
        );
      case 'browserInfo':
        if (manga != null) {
          final id = await _mangaId(sourceId, manga);
          final row = _map(await _call('/api/v1/manga/$id?onlineFetch=true'));
          return {'ok': true, 'url': row['realUrl']};
        }
        final row = _map(await _call('/api/v1/source/$sourceId'));
        return {'ok': true, 'url': row['baseUrl']};
      case 'relatedInfo':
        // Suwayomi's public API has no native related-manga operation.
        return {'ok': true, 'supported': false};
      default:
        throw UnsupportedError('桌面扩展不支持此操作：$operation');
    }
  }

  static Map<String, Object?> _manga(
    Map<String, Object?> row,
    String sourceId,
  ) {
    if ('${row['sourceId']}' != sourceId) {
      throw const FormatException('桌面扩展返回了其他来源的作品');
    }
    return {
      ...row,
      'status': _status(row['status']),
      'thumbnailUrl': row['thumbnailUrl'] == null
          ? null
          : Uri(
              scheme: 'mihon-cover',
              host: 'source',
              queryParameters: {
                'source': sourceId,
                'url': '${row['url']}',
                'title': '${row['title']}',
                'revision': '${row['thumbnailUrlLastFetched'] ?? 0}',
              },
            ).toString(),
      'genre': (row['genre'] as List? ?? const []).join(', '),
    };
  }

  static String _status(Object? value) => switch ('$value'.toUpperCase()) {
    'UNKNOWN' => '0',
    'ONGOING' => '1',
    'COMPLETED' => '2',
    'LICENSED' => '3',
    'PUBLISHING_FINISHED' => '4',
    'CANCELLED' => '5',
    'ON_HIATUS' => '6',
    _ => value?.toString().toLowerCase() ?? '0',
  };

  // Only portable source metadata crosses the host/image bridge. Runtime
  // database IDs are always resolved afresh, including after backup restoration.
  static Map<String, Object?> _portableManga(Map<String, Object?>? manga) {
    if (manga == null || '${manga['url'] ?? ''}'.isEmpty) {
      throw const FormatException('漫画正文缺少所属作品的来源URL');
    }
    return {
      'url': manga['url'],
      'title': manga['title'],
      'thumbnailUrl': manga['thumbnailUrl'],
      'author': manga['author'],
      'description': manga['description'],
      'genre': manga['genre'],
    };
  }

  Future<int> _mangaId(String sourceId, Map<String, Object?> manga) async {
    final url = '${manga['url'] ?? ''}';
    if (url.isEmpty) throw const FormatException('作品没有来源URL');
    Future<int?> lookup() async {
      final data = await _graphql(
        r'''query($source: LongString!, $url: String!) {
        mangas(condition: {sourceId: $source, url: $url}, first: 2) { nodes { id } }
      }''',
        {'source': sourceId, 'url': url},
      );
      final rows = _map(data['mangas'])['nodes'] as List;
      if (rows.length > 1) throw const FormatException('来源作品身份冲突');
      return rows.isEmpty ? null : _map(rows.single)['id'] as int;
    }

    final existing = await lookup();
    if (existing != null) return existing;
    // The upstream API cannot insert an arbitrary plugin URL. Search first,
    // then walk the catalogue for sources (such as xkcd) without title search.
    // Both paths accept only the original source-qualified URL.
    final title = '${manga['title'] ?? ''}';
    if (title.isNotEmpty) {
      for (var page = 1; ; page++) {
        final result = _map(
          await _call(
            '/api/v1/source/$sourceId/quick-search?pageNum=$page',
            data: {'searchTerm': title, 'filter': null},
          ),
        );
        for (final raw in result['mangaList'] as List) {
          final row = _map(raw);
          if ('${row['sourceId']}' == sourceId && row['url'] == url) {
            return row['id'] as int;
          }
        }
        if (result['hasNextPage'] != true) break;
      }
    }
    for (var page = 1; ; page++) {
      final result = _map(
        await _call('/api/v1/source/$sourceId/popular/$page'),
      );
      for (final raw in result['mangaList'] as List) {
        final row = _map(raw);
        if ('${row['sourceId']}' == sourceId && row['url'] == url) {
          return row['id'] as int;
        }
      }
      if (result['hasNextPage'] != true) break;
    }
    throw StateError('此作品的原URL不在来源搜索或热门目录中，无法在桌面恢复');
  }

  Future<Map<String, Object?>> _chapter(
    String sourceId,
    String url,
    Map<String, Object?> manga,
  ) async {
    final id = await _mangaId(sourceId, manga);
    Future<List<Map<String, Object?>>> lookup() async {
      final data = await _graphql(
        r'''query($url: String!, $mangaId: Int!) {
        chapters(condition: {url: $url, mangaId: $mangaId}) {
          nodes { url sourceOrder manga { id sourceId url } }
        }
      }''',
        {'url': url, 'mangaId': id},
      );
      return [
        for (final raw in _map(data['chapters'])['nodes'] as List)
          if (_map(raw) case final row
              when row['url'] == url &&
                  _map(row['manga'])['id'] == id &&
                  '${_map(row['manga'])['sourceId']}' == sourceId &&
                  _map(row['manga'])['url'] == manga['url'])
            row,
      ];
    }

    var rows = await lookup();
    if (rows.isEmpty) {
      // Restored downloads can request content without opening details first.
      await _call('/api/v1/manga/$id/chapters?onlineFetch=true');
      rows = await lookup();
    }
    if (rows.length != 1) {
      throw StateError('原章节在所属作品中不存在或身份不唯一，请刷新原作品目录');
    }
    return rows.single;
  }

  Future<List<int>> coverBytes(Uri uri) async {
    final source = uri.queryParameters['source'] ?? '';
    final id = await _mangaId(source, {
      'url': uri.queryParameters['url'],
      'title': uri.queryParameters['title'],
    });
    final file = await _imageFile(
      '/api/v1/manga/$id/thumbnail',
      '$source:${uri.queryParameters['url']}:cover:${uri.queryParameters['revision'] ?? 0}',
    );
    return File(file['filePath'] as String).readAsBytes();
  }

  final _images = <String, Future<Map<String, Object?>>>{};
  Future<Map<String, Object?>> _imageFile(String path, String identity) async {
    final key = sha256.convert(utf8.encode(identity)).toString();
    return _images.putIfAbsent(key, () async {
      try {
        await cache.create(recursive: true);
        final file = File('${cache.path}/$key');
        if (!await file.exists()) {
          final part = File('${file.path}.part');
          final token = CancelToken();
          try {
            final response = await dio.download(
              path,
              part.path,
              cancelToken: token,
              onReceiveProgress: (received, total) {
                if (received > 64 * 1024 * 1024 || total > 64 * 1024 * 1024) {
                  token.cancel('漫画图片超过64MiB');
                }
              },
            );
            if ((await part.length()) == 0) {
              throw const FormatException('来源图片为空');
            }
            await part.rename(file.path);
            return {
              'ok': true,
              'filePath': file.path,
              'mime': response.headers.value('content-type') ?? 'image/jpeg',
            };
          } finally {
            if (await part.exists()) await part.delete();
          }
        }
        return {'ok': true, 'filePath': file.path};
      } finally {
        unawaited(_images.remove(key));
      }
    });
  }

  static Map<String, Object?> _filter(Map<String, Object?> raw, int index) {
    final row = _map(raw['filter']);
    final type = switch (raw['type']) {
      'Header' => 'header',
      'Separator' => 'separator',
      'Select' => 'select',
      'Text' => 'text',
      'CheckBox' => 'check',
      'TriState' => 'tri',
      'Group' => 'group',
      'Sort' => 'sort',
      _ => throw const FormatException('未知的来源筛选类型'),
    };
    return {
      'index': index,
      'type': type,
      'name': row['name'] ?? '',
      'values': switch (type) {
        'select' => [
          for (final value in row['values'] as List) value.toString(),
        ],
        'sort' => row['values'],
        _ => null,
      },
      'state': switch (type) {
        'group' => [
          for (var i = 0; i < (row['state'] as List).length; i++)
            _filter(_map((row['state'] as List)[i]), i),
        ],
        'header' || 'separator' => null,
        _ => row['state'],
      },
    };
  }

  static List<Map<String, Object?>> _filterChanges(
    List<Map<String, Object?>> rows,
  ) {
    String state(Map<String, Object?> row) => switch (row['type']) {
      'check' => row['state'] == true ? 'true' : 'false',
      'sort' => jsonEncode(row['state']),
      'select' || 'tri' => '${row['state'] as int}',
      'text' => '${row['state'] ?? ''}',
      _ => throw const FormatException('来源筛选类型不能提交'),
    };
    return [
      for (var i = 0; i < rows.length; i++)
        if (rows[i]['type'] == 'group')
          for (var j = 0; j < (rows[i]['state'] as List).length; j++)
            {
              'position': i,
              'state': jsonEncode({
                'position': j,
                'state': state(_map((rows[i]['state'] as List)[j])),
              }),
            }
        else if (rows[i]['type'] != 'header' && rows[i]['type'] != 'separator')
          {'position': i, 'state': state(rows[i])},
    ];
  }
}
