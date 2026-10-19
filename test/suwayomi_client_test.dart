import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/suwayomi_client.dart';
import 'package:triomi/features/library/data/library_repository.dart';
import 'package:triomi/features/library/data/manga_update_service.dart';
import 'package:triomi/features/manga/manga_filter_snapshot.dart';

import 'fixtures/test_database.dart';

void main() {
  late HttpServer server;
  late Directory directory;
  late Dio dio;
  late SuwayomiClient client;
  late Future<void> Function(HttpRequest) handle;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('triomi-desktop-source-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    client = SuwayomiClient(dio: dio, cache: directory);
    server.listen((request) async {
      try {
        await handle(request);
      } catch (_) {
        request.response.statusCode = 500;
      } finally {
        await request.response.close();
      }
    });
  });
  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  void json(HttpRequest request, Object value) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
  }

  test(
    'identical chapter URLs remain source-qualified through image consumption',
    () async {
      const sourceA = '9007199254740993', sourceB = '9007199254740995';
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final variables = body['variables'] as Map;
          if (variables.containsKey('source')) {
            json(request, {
              'data': {
                'mangas': {
                  'nodes': [
                    {'id': variables['source'] == sourceA ? 11 : 12},
                  ],
                },
              },
            });
            return;
          }
          json(request, {
            'data': {
              'chapters': {
                'nodes': [
                  {
                    'url': '/chapter/1',
                    'sourceOrder': 7,
                    'manga': {'id': 11, 'sourceId': sourceA, 'url': '/book'},
                  },
                  {
                    'url': '/chapter/1',
                    'sourceOrder': 8,
                    'manga': {'id': 12, 'sourceId': sourceB, 'url': '/book'},
                  },
                ],
              },
            },
          });
        } else if (request.uri.path.endsWith('/page/0')) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(
            request.uri.path.contains('/manga/11/') ? [1, 11, 7] : [2, 12, 8],
          );
        } else {
          json(request, {'pageCount': 1});
        }
      };
      for (final (source, bytes) in [
        (sourceA, [1, 11, 7]),
        (sourceB, [2, 12, 8]),
      ]) {
        final pages = await client.request(
          sourceId: source,
          operation: 'pages',
          manga: {'url': '/book'},
          chapter: {'url': '/chapter/1'},
        );
        final page = Map<String, Object?>.from(
          (pages['pages'] as List).single as Map,
        );
        final loaded = await client.request(
          sourceId: source,
          operation: 'imageFile',
          pageData: page,
        );
        expect(await File(loaded['filePath'] as String).readAsBytes(), bytes);
      }
    },
  );

  test(
    'a chapter from another source cannot be opened via a colliding URL',
    () async {
      var imageReads = 0;
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if ((body['variables'] as Map).containsKey('source')) {
            json(request, {
              'data': {
                'mangas': {
                  'nodes': [
                    {'id': 1},
                  ],
                },
              },
            });
            return;
          }
          json(request, {
            'data': {
              'chapters': {
                'nodes': [
                  {
                    'url': '/same',
                    'sourceOrder': 3,
                    'manga': {'id': 1, 'sourceId': '2', 'url': '/book'},
                  },
                ],
              },
            },
          });
        } else if (request.uri.path.endsWith('/chapters')) {
          json(request, <Object?>[]);
        } else {
          imageReads++;
          json(request, {'pageCount': 1});
        }
      };
      await expectLater(
        client.request(
          sourceId: '1',
          operation: 'pages',
          manga: {'url': '/book'},
          chapter: {'url': '/same'},
        ),
        throwsStateError,
      );
      expect(imageReads, 0);
    },
  );

  test(
    'restored bookmarks resolve exact URL, not the first same-title work',
    () async {
      final pages = <int>[];
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          json(request, {
            'data': {
              'mangas': {'nodes': <Object?>[]},
            },
          });
        } else if (request.uri.path.endsWith('/quick-search')) {
          final page = int.parse(request.uri.queryParameters['pageNum']!);
          pages.add(page);
          json(request, {
            'mangaList': [
              {
                'id': page == 1 ? 1 : 2,
                'sourceId': '123',
                'url': page == 1 ? '/impostor' : '/original',
                'title': 'Same title',
              },
            ],
            'hasNextPage': page == 1,
          });
        } else if (request.uri.path == '/api/v1/manga/2') {
          json(request, {
            'id': 2,
            'sourceId': '123',
            'url': '/original',
            'title': 'Original edition',
            'genre': ['History'],
          });
        } else {
          throw StateError('Wrong edition requested');
        }
      };
      final detail = await client.request(
        sourceId: '123',
        operation: 'detail',
        manga: {'url': '/original', 'title': 'Same title'},
      );
      expect((detail['manga'] as Map)['url'], '/original');
      expect((detail['manga'] as Map)['title'], 'Original edition');
      expect(pages, [1, 2]);
    },
  );

  test(
    'foreign catalogue works cannot leak into a source-qualified collection',
    () async {
      handle = (request) async => json(request, {
        'mangaList': [
          {'id': 1, 'sourceId': '456', 'url': '/book', 'title': 'Wrong source'},
        ],
        'hasNextPage': false,
      });
      await expectLater(
        client.request(sourceId: '123', operation: 'popular'),
        throwsFormatException,
      );
    },
  );

  test('nested source filter selections drive a stateless search', () async {
    handle = (request) async {
      final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final changes = data['filter'] as List;
      final group = changes
          .map((change) => jsonDecode('${(change as Map)['state']}') as Map)
          .singleWhere((change) => change['position'] == 1);
      final included = group['state'] == 'true';
      json(request, {
        'mangaList': included
            ? [
                {
                  'id': 7,
                  'sourceId': '123',
                  'url': '/chosen',
                  'title': 'Chosen genre',
                  'genre': <String>[],
                },
              ]
            : <Object?>[],
        'hasNextPage': false,
      });
    };
    final result = await client.request(
      sourceId: '123',
      operation: 'search',
      query: 'book',
      filters: [
        {
          'type': 'group',
          'name': 'Genres',
          'state': [
            {'type': 'check', 'name': 'A', 'state': false},
            {'type': 'check', 'name': 'B', 'state': true},
          ],
        },
      ],
    );
    expect((result['mangas'] as List).single, containsPair('url', '/chosen'));
  });

  test('same-source colliding chapters remain qualified by their owning collection', () async {
    handle = (request) async {
      if (request.uri.path == '/api/graphql') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final variables = body['variables'] as Map;
        if (variables.containsKey('source')) {
          json(request, {
            'data': {
              'mangas': {
                'nodes': [
                  {'id': variables['url'] == '/all' ? 1 : 2},
                ],
              },
            },
          });
        } else {
          json(request, {
            'data': {
              'chapters': {
                'nodes': [
                  for (final (id, url, order) in [
                    (1, '/all', 500),
                    (2, '/2026', 4),
                  ])
                    {
                      'url': '/1234/',
                      'sourceOrder': order,
                      'manga': {'id': id, 'sourceId': '123', 'url': url},
                    },
                ],
              },
            },
          });
        }
      } else if (request.uri.path.endsWith('/page/0')) {
        request.response.add(
          request.uri.path.contains('/manga/1/') ? [1] : [2],
        );
      } else {
        json(request, {'pageCount': 1});
      }
    };
    for (final (url, expected) in [('/all', 1), ('/2026', 2)]) {
      final pages = await client.request(
        sourceId: '123',
        operation: 'pages',
        manga: {'url': url, 'title': 'xkcd'},
        chapter: {'url': '/1234/'},
      );
      final page = Map<String, Object?>.from(
        (pages['pages'] as List).single as Map,
      );
      expect((page['manga'] as Map)['url'], url);
      expect((page['manga'] as Map).containsKey('id'), isFalse);
      final image = await client.request(
        sourceId: '123',
        operation: 'imageFile',
        pageData: page,
      );
      expect(await File(image['filePath'] as String).readAsBytes(), [expected]);
    }
  });

  test('restored xkcd content hydrates without detail and survives an empty replacement runtime', () async {
    var runtimeId = 41;
    var knownWork = false, knownChapters = false;
    final cataloguePages = <int>[];
    var directoryHydrations = 0, detailReads = 0;
    handle = (request) async {
      final path = request.uri.path;
      if (path == '/api/graphql') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final variables = body['variables'] as Map;
        if (variables.containsKey('source')) {
          json(request, {
            'data': {
              'mangas': {
                'nodes': [
                  if (knownWork) {'id': runtimeId},
                ],
              },
            },
          });
        } else {
          json(request, {
            'data': {
              'chapters': {
                'nodes': [
                  if (knownChapters)
                    {
                      'url': '/1234/',
                      'sourceOrder': 8,
                      'manga': {
                        'id': runtimeId,
                        'sourceId': '123',
                        'url': '/2026',
                      },
                    },
                ],
              },
            },
          });
        }
      } else if (path.endsWith('/quick-search')) {
        json(request, {'mangaList': <Object?>[], 'hasNextPage': false});
      } else if (path.contains('/popular/')) {
        final page = int.parse(request.uri.pathSegments.last);
        cataloguePages.add(page);
        if (page == 2) knownWork = true;
        json(request, {
          'mangaList': [
            {
              'id': page == 2 ? runtimeId : 1,
              'sourceId': '123',
              'url': page == 2 ? '/2026' : '/all',
              'title': 'xkcd',
            },
          ],
          'hasNextPage': page == 1,
        });
      } else if (path == '/api/v1/manga/$runtimeId/chapters') {
        expect(request.uri.queryParameters['onlineFetch'], 'true');
        knownChapters = true;
        directoryHydrations++;
        json(request, <Object?>[]);
      } else if (path == '/api/v1/manga/$runtimeId/chapter/8') {
        json(request, {'pageCount': 1});
      } else if (path == '/api/v1/manga/$runtimeId/chapter/8/page/0') {
        request.response.add([runtimeId, 8]);
      } else {
        detailReads++;
        throw StateError('Content must not require opening details');
      }
    };
    final pages = await client.request(
      sourceId: '123',
      operation: 'pages',
      manga: {'url': '/2026', 'title': 'xkcd'},
      chapter: {'url': '/1234/'},
    );
    final portablePage = Map<String, Object?>.from(
      jsonDecode(jsonEncode((pages['pages'] as List).single)) as Map,
    );
    runtimeId = 93;
    knownWork = knownChapters = false;
    client = SuwayomiClient(dio: dio, cache: directory);
    final image = await client.request(
      sourceId: '123',
      operation: 'imageFile',
      pageData: portablePage,
    );
    expect(await File(image['filePath'] as String).readAsBytes(), [93, 8]);
    expect(directoryHydrations, 2);
    expect(cataloguePages, [1, 2, 1, 2]);
    expect(detailReads, 0);
  });

  test(
    'restored detail uses exact catalogue URL when title search is unsupported',
    () async {
      final cataloguePages = <int>[];
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          json(request, {
            'data': {
              'mangas': {'nodes': <Object?>[]},
            },
          });
        } else if (request.uri.path.endsWith('/quick-search')) {
          json(request, {'mangaList': <Object?>[], 'hasNextPage': false});
        } else if (request.uri.path.contains('/popular/')) {
          final page = int.parse(request.uri.pathSegments.last);
          cataloguePages.add(page);
          json(request, {
            'mangaList': [
              {
                'id': page,
                'sourceId': '123',
                'url': page == 1 ? '/all' : '/2026',
                'title': 'xkcd',
              },
            ],
            'hasNextPage': page == 1,
          });
        } else if (request.uri.path == '/api/v1/manga/2') {
          json(request, {
            'id': 2,
            'sourceId': '123',
            'url': '/2026',
            'title': 'xkcd 2026',
          });
        } else {
          throw StateError('Unexpected API');
        }
      };
      final detail = await client.request(
        sourceId: '123',
        operation: 'detail',
        manga: {'url': '/2026', 'title': 'xkcd'},
      );
      expect((detail['manga'] as Map)['url'], '/2026');
      await expectLater(
        client.request(
          sourceId: '123',
          operation: 'detail',
          manga: {'url': '/missing', 'title': 'xkcd'},
        ),
        throwsStateError,
      );
      expect(cataloguePages, [1, 2, 1, 2]);
    },
  );

  test(
    'Android saved filter snapshots restore and drive a desktop search',
    () async {
      handle = (request) async {
        if (request.uri.path.endsWith('/filters')) {
          json(request, [
            {
              'type': 'Header',
              'filter': {'name': 'Options', 'state': 'ignored'},
            },
            {
              'type': 'Group',
              'filter': {
                'name': 'Genres',
                'state': [
                  {
                    'type': 'CheckBox',
                    'filter': {'name': 'Science', 'state': false},
                  },
                  {
                    'type': 'Select',
                    'filter': {
                      'name': 'Year',
                      'state': 0,
                      'values': [2025, 2026],
                    },
                  },
                ],
              },
            },
            {
              'type': 'Separator',
              'filter': {'name': '', 'state': 'ignored'},
            },
          ]);
        } else {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final changes = (body['filter'] as List).cast<Map<String, Object?>>();
          final selections = changes
              .map((row) => jsonDecode(row['state'] as String) as Map<String, Object?>)
              .toList();
          final matches =
              selections.any(
                (row) => row['position'] == 0 && row['state'] == 'true',
              ) &&
              selections.any(
                (row) => row['position'] == 1 && row['state'] == '1',
              );
          json(request, {
            'mangaList': [
              if (matches)
                {
                  'id': 1,
                  'sourceId': '123',
                  'url': '/chosen',
                  'title': 'Chosen',
                },
            ],
            'hasNextPage': false,
          });
        }
      };
      final fresh = await client.request(sourceId: '123', operation: 'filters');
      final saved = decodeMangaFilters(
        jsonEncode([
          {
            'index': 0,
            'name': 'Options',
            'type': 'header',
            'state': null,
            'values': null,
          },
          {
            'index': 1,
            'name': 'Genres',
            'type': 'group',
            'state': [
              {
                'index': 0,
                'name': 'Science',
                'type': 'check',
                'state': true,
                'values': null,
              },
              {
                'index': 1,
                'name': 'Year',
                'type': 'select',
                'state': 1,
                'values': ['2025', '2026'],
              },
            ],
            'values': null,
          },
          {
            'index': 2,
            'name': '',
            'type': 'separator',
            'state': null,
            'values': null,
          },
        ]),
      );
      final restored = restoreMangaFilters([
        for (final row in fresh['filters'] as List)
          Map<String, Object?>.from(row as Map),
      ], saved);
      final results = await client.request(
        sourceId: '123',
        operation: 'search',
        filters: restored,
      );
      expect(
        (results['mangas'] as List).single,
        containsPair('url', '/chosen'),
      );
    },
  );

  test(
    'refreshed cover changes both display URI and persistent thumbnail bytes',
    () async {
      var revision = 100, reads = 0;
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          json(request, {
            'data': {
              'mangas': {
                'nodes': [
                  {'id': 7},
                ],
              },
            },
          });
        } else if (request.uri.path.endsWith('/thumbnail')) {
          reads++;
          request.response.add([revision]);
        } else {
          json(request, {
            'id': 7,
            'sourceId': '123',
            'url': '/book',
            'title': 'Book',
            'thumbnailUrl': '/api/v1/manga/7/thumbnail',
            'thumbnailUrlLastFetched': revision,
          });
        }
      };
      Future<Uri> refresh() async {
        final result = await client.request(
          sourceId: '123',
          operation: 'detail',
          manga: {'url': '/book'},
        );
        return Uri.parse((result['manga'] as Map)['thumbnailUrl'] as String);
      }

      final original = await refresh();
      expect(await client.coverBytes(original), [100]);
      expect(await client.coverBytes(original), [100]);
      revision = 101;
      final updated = await refresh();
      expect(updated, isNot(original));
      expect(updated.queryParameters['url'], original.queryParameters['url']);
      expect(
        updated.queryParameters['source'],
        original.queryParameters['source'],
      );
      expect(await client.coverBytes(updated), [101]);
      client = SuwayomiClient(dio: dio, cache: directory);
      expect(await client.coverBytes(updated), [101]);
      expect(reads, 2);
    },
  );

  test(
    'completed runtime status remains skipped by the library update consumer',
    () async {
      handle = (request) async => json(request, {
        'mangaList': [
          {
            'id': 1,
            'sourceId': '123',
            'url': '/done',
            'title': 'Done',
            'status': 'COMPLETED',
          },
        ],
        'hasNextPage': false,
      });
      final result = await client.request(
        sourceId: '123',
        operation: 'popular',
      );
      final row = (result['mangas'] as List).single as Map;
      final db = openTestDatabase();
      final service = MangaUpdateService(
        db: db,
        snapshot: () async => SourceRegistrySnapshot(entries: [], failures: []),
        options: const MangaUpdateOptions(),
        constraintsAllow: () async => true,
      );
      try {
        await LibraryRepository(db).addToLibrary(
          MediaItem(
            sourceId: 'mihon:pkg:123',
            remoteId: row['url'] as String,
            type: MediaType.manga,
            title: row['title'] as String,
            status: '${row['status']}',
          ),
        );
        expect(row['status'], '2');
        await service.enqueue();
        expect(await db.select(db.mangaUpdates).get(), isEmpty);
      } finally {
        await service.dispose();
        await db.close();
      }
    },
  );
}
