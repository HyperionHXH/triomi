import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:triomi/core/models/media_item.dart';
import 'package:triomi/core/models/media_type.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/core/source/source_registry.dart';
import 'package:triomi/core/source/suwayomi_client.dart';
import 'package:triomi/core/source/windows_mihon_host.dart';
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
  final detachedSockets = <Socket>{};

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('triomi-desktop-source-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}'));
    client = SuwayomiClient(dio: dio, cache: directory);
    server.listen((request) async {
      try {
        await handle(request);
      } catch (_) {
        // A cancelled real HTTP consumer may already have closed the socket.
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
  });
  tearDown(() async {
    dio.close(force: true);
    for (final socket in detachedSockets) {
      socket.destroy();
    }
    detachedSockets.clear();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  void json(HttpRequest request, Object value) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
  }

  final cancelled = throwsA(
    isA<DioException>().having(
      (error) => error.type,
      'cancellation type',
      DioExceptionType.cancel,
    ),
  );

  Future<void> streamUntilDisconnected(
    HttpRequest request,
    Completer<void> started,
    Completer<void> disconnected,
  ) async {
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.chunkedTransferEncoding = true;
    // HttpServer pauses its parser while a response is open, so response.done
    // need not observe peer FIN until the response is closed. Observe the real
    // socket instead, still serving a valid HTTP chunked response to production
    // Dio. This does not treat a cancellation token as proof of disconnect.
    final socket = await request.response.detachSocket();
    detachedSockets.add(socket);
    var closed = false;
    void finish() {
      closed = true;
      if (!disconnected.isCompleted) disconnected.complete();
    }

    final incoming = socket.listen(
      (_) {},
      onDone: finish,
      onError: (Object error) => finish(),
      cancelOnError: true,
    );
    final chunk = List<int>.filled(4096, 7);
    try {
      while (!closed) {
        socket.add(ascii.encode('${chunk.length.toRadixString(16)}\r\n'));
        socket.add(chunk);
        socket.add(const [13, 10]);
        await socket.flush();
        if (!started.isCompleted) started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } catch (_) {
      finish();
    } finally {
      detachedSockets.remove(socket);
      socket.destroy();
      await incoming.cancel();
    }
  }

  Future<bool> resolveImageIdentity(HttpRequest request) async {
    if (request.uri.path != '/api/graphql') return false;
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final variables = body['variables'] as Map;
    json(request, {
      'data': variables.containsKey('source')
          ? {
              'mangas': {
                'nodes': [
                  {'id': 11},
                ],
              },
            }
          : {
              'chapters': {
                'nodes': [
                  {
                    'url': '/chapter',
                    'sourceOrder': 2,
                    'manga': {'id': 11, 'sourceId': '1', 'url': '/book'},
                  },
                ],
              },
            },
    });
    return true;
  }

  Future<Map<String, Object?>> imageRequest(String id, {int index = 0}) =>
      client.request(
        requestId: id,
        sourceId: '1',
        operation: 'imageFile',
        pageData: {
          'index': index,
          'chapterUrl': '/chapter',
          'manga': {'url': '/book'},
        },
      );

  test(
    'parent cancellation cascades without retaining operation IDs',
    () async {
      final registry = SuwayomiRequestRegistry();
      final parent = SourceRequestCancellation();
      final startup = Completer<int>();
      final pending = parent.run(
        () => registry.run(
          'owned',
          () => SuwayomiRequestRegistry.wait(startup.future),
        ),
      );
      final result = expectLater(pending, cancelled);
      await expectLater(registry.run('owned', () async => 0), throwsStateError);
      expect(registry.activeCount, 1);
      parent.cancel();
      await result;
      expect(registry.activeCount, 0);
      startup.complete(42);
      expect(await registry.run('owned', () async => 7), 7);
    },
  );

  test(
    'cancelled startup waits leave shared work alive and release IDs',
    () async {
      final registry = SuwayomiRequestRegistry();
      final startup = Completer<int>();
      final first = registry.run(
        'first',
        () => SuwayomiRequestRegistry.wait(startup.future),
      );
      final result = expectLater(first, cancelled);
      final second = registry.run(
        'second',
        () => SuwayomiRequestRegistry.wait(startup.future),
      );
      expect(registry.activeCount, 2);
      await registry.cancel('first');
      await result;
      expect(registry.activeCount, 1);
      expect(startup.isCompleted, isFalse);
      startup.complete(42);
      expect(await second, 42);
      expect(registry.activeCount, 0);
    },
  );

  test(
    'only actual HTTP response metadata crosses the desktop request map',
    () async {
      handle = (request) async {
        request.response.statusCode = 429;
        request.response.headers.set(
          'Retry-After',
          'Wed, 05 Nov 2031 08:00:00 GMT',
        );
        request.response.write('rate limited');
      };
      final limited = await client.request(
        requestId: 'limited',
        sourceId: '1',
        operation: 'popular',
      );
      expect(limited['ok'], isFalse);
      expect(limited['statusCode'], 429);
      expect(limited['retryAfter'], 'Wed, 05 Nov 2031 08:00:00 GMT');
      expect(client.activeRequestCount, 0);
      handle = (request) async {
        request.response.statusCode = 500;
        request.response.write('wrapped website HTTP 429 Retry-After: 120');
      };
      final wrapped = await client.request(sourceId: '1', operation: 'latest');
      expect(wrapped['statusCode'], 500);
      expect(wrapped.containsKey('retryAfter'), isFalse);
    },
  );

  test(
    'cancelling a slow operation disconnects only its real HTTP request',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      final independentStarted = Completer<void>();
      final releaseIndependent = Completer<void>();
      handle = (request) async {
        if (request.uri.path.endsWith('/popular/1')) {
          await streamUntilDisconnected(request, started, disconnected);
        } else if (request.uri.path.endsWith('/latest/1')) {
          independentStarted.complete();
          await releaseIndependent.future;
          json(request, {'mangaList': <Object?>[], 'hasNextPage': false});
        } else {
          json(request, {
            'data': {
              'source': {'filters': <Object?>[]},
            },
          });
        }
      };
      final parent = SourceRequestCancellation();
      final slow = parent.run(
        () => client.request(
          requestId: 'slow',
          sourceId: '1',
          operation: 'popular',
        ),
      );
      final slowResult = expectLater(slow, cancelled);
      await started.future;
      final independent = parent.run(
        () => client.request(
          requestId: 'independent',
          sourceId: '1',
          operation: 'latest',
        ),
      );
      await independentStarted.future;
      expect(client.activeRequestCount, 2);
      await client.cancelRequest('slow');
      await slowResult;
      expect(client.activeRequestCount, 1);
      expect(parent.cancelled, isFalse);
      await client.cancelRequest('slow');
      releaseIndependent.complete();
      expect((await independent)['ok'], isTrue);
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(client.activeRequestCount, 0);
      // Completed/cancelled IDs are removed, not permanent cancellation tombstones.
      expect(
        (await client.request(
          requestId: 'slow',
          sourceId: '1',
          operation: 'filters',
        ))['ok'],
        isTrue,
      );
      expect(client.activeRequestCount, 0);
    },
  );

  test(
    'cancellation stops restoration paging before catalogue or detail fallback',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      final paths = <String>[];
      handle = (request) async {
        paths.add(request.uri.toString());
        if (request.uri.path == '/api/graphql') {
          await request.drain<void>();
          json(request, {
            'data': {
              'mangas': {'nodes': <Object?>[]},
            },
          });
        } else if (request.uri.queryParameters['pageNum'] == '1') {
          await request.drain<void>();
          json(request, {'mangaList': <Object?>[], 'hasNextPage': true});
        } else {
          await request.drain<void>();
          await streamUntilDisconnected(request, started, disconnected);
        }
      };
      final pending = client.request(
        requestId: 'paging',
        sourceId: '1',
        operation: 'detail',
        manga: {'url': '/missing', 'title': 'Original title'},
      );
      final result = expectLater(pending, cancelled);
      await started.future;
      await client.cancelRequest('paging');
      await result;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(paths, [
        '/api/graphql',
        '/api/v1/source/1/quick-search?pageNum=1',
        '/api/v1/source/1/quick-search?pageNum=2',
      ]);
      expect(client.activeRequestCount, 0);
    },
  );

  test(
    'cancelling a chapter lookup never starts its image HTTP request',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      var images = 0;
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if ((body['variables'] as Map).containsKey('source')) {
            json(request, {
              'data': {
                'mangas': {
                  'nodes': [
                    {'id': 11},
                  ],
                },
              },
            });
          } else {
            await streamUntilDisconnected(request, started, disconnected);
          }
        } else {
          images++;
        }
      };
      final pending = imageRequest('lookup');
      final result = expectLater(pending, cancelled);
      await started.future;
      await client.cancelRequest('lookup');
      await result;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(images, 0);
      expect(client.activeRequestCount, 0);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'cancelled image downloads quiesce and never publish a late cache file',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      handle = (request) async {
        if (await resolveImageIdentity(request)) return;
        await streamUntilDisconnected(request, started, disconnected);
      };
      final image = imageRequest('image');
      final result = expectLater(image, cancelled);
      await started.future;
      await client.cancelRequest('image');
      await result;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(await directory.list().toList(), isEmpty);
      expect(client.activeRequestCount, 0);
      expect(client.activeImageTransferCount, 0);
      expect(client.activeImageSubscriberCount, 0);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'a shared image stays alive until its final subscriber cancels',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      final secondResolved = Completer<void>();
      var chapterLookups = 0;
      var downloads = 0;
      handle = (request) async {
        if (request.uri.path == '/api/graphql') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if ((body['variables'] as Map).containsKey('mangaId')) {
            chapterLookups++;
            if (chapterLookups == 2) secondResolved.complete();
          }
          json(request, {
            'data': (body['variables'] as Map).containsKey('source')
                ? {
                    'mangas': {
                      'nodes': [
                        {'id': 11},
                      ],
                    },
                  }
                : {
                    'chapters': {
                      'nodes': [
                        {
                          'url': '/chapter',
                          'sourceOrder': 2,
                          'manga': {'id': 11, 'sourceId': '1', 'url': '/book'},
                        },
                      ],
                    },
                  },
          });
          return;
        }
        downloads++;
        await streamUntilDisconnected(request, started, disconnected);
      };
      final first = imageRequest('first');
      final firstResult = expectLater(first, cancelled);
      await started.future;
      final second = imageRequest('second');
      final secondResult = expectLater(second, cancelled);
      await secondResolved.future;
      await Future.doWhile(() async {
        if (client.activeImageSubscriberCount == 2) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 3));
      await client.cancelRequest('first');
      await firstResult;
      expect(disconnected.isCompleted, isFalse);
      expect(client.activeRequestCount, 1);
      expect(downloads, 1);
      await client.cancelRequest('second');
      await secondResult;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(client.activeRequestCount, 0);
      expect(client.activeImageTransferCount, 0);
      expect(client.activeImageSubscriberCount, 0);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'cancelling one shared-image reader lets the other finish and cache',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var downloads = 0;
      handle = (request) async {
        if (await resolveImageIdentity(request)) return;
        downloads++;
        request.response.headers.contentType = ContentType.binary;
        request.response.add([1, 2]);
        await request.response.flush();
        started.complete();
        await release.future;
        request.response.add([3, 4]);
      };
      final first = imageRequest('first');
      final result = expectLater(first, cancelled);
      await started.future;
      final second = imageRequest('second');
      await Future.doWhile(() async {
        if (client.activeImageSubscriberCount == 2) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 3));
      await client.cancelRequest('first');
      await result;
      release.complete();
      final file = File((await second)['filePath'] as String);
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
      final resumed = await imageRequest('first');
      expect(resumed['filePath'], file.path);
      expect(downloads, 1);
      expect(client.activeRequestCount, 0);
      expect(client.activeImageTransferCount, 0);
      expect(client.activeImageSubscriberCount, 0);
      final entries = await directory.list().toList();
      expect(entries, hasLength(1));
      expect(p.equals(entries.single.path, file.path), isTrue);
    },
  );

  test(
    'installation presence checks never recreate missing runtime state',
    () async {
      final root = Directory('${directory.path}/missing-runtime');
      final issue = await WindowsMihonHost.installationIssue(
        'org.example.plugin',
        root: root,
      );
      expect(issue?.requiresReinstall, isTrue);
      expect(await root.exists(), isFalse);
    },
  );

  test('desktop installation probes real filter endpoints without assuming site health', () async {
    final paths = <String>[];
    handle = (request) async {
      paths.add(request.uri.toString());
      json(request, {
        'data': {
          'source': {'filters': <Object?>[]},
        },
      });
    };
    final result = await WindowsMihonHost.probeSourceFilters(client, [
      {'id': '123', 'name': 'Example', 'lang': 'en'},
    ]);
    expect(result['filterProbe'], 'passed');
    expect(paths, ['/api/graphql']);
  });

  test('dynamic filters requiring login remain unknown instead of rejecting a loaded plugin', () async {
    handle = (request) async {
      expect(request.uri.path, '/api/graphql');
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      if ((body['variables'] as Map)['source'] == '123') {
        json(request, {
          'data': {
            'source': {'filters': <Object?>[]},
          },
        });
      } else {
        // The pinned runtime uses this same response for auth/site and JVM errors.
        request.response.statusCode = 500;
        request.response.write('Server Error');
      }
    };
    final result = await WindowsMihonHost.probeSourceFilters(client, [
      {'id': '123', 'name': 'Ready', 'lang': 'en'},
      {'id': '456', 'name': 'Needs login', 'lang': 'en'},
    ]);
    expect(result['filterProbe'], 'unknown');
    expect(result['filterProbeSources'], [
      {'sourceId': '123', 'status': 'passed'},
      {'sourceId': '456', 'status': 'unknown'},
    ]);
  });

  test(
    'dynamic filters cannot block installation beyond the probe budget',
    () async {
      final release = Completer<void>();
      handle = (request) async {
        await release.future;
        json(request, {
          'data': {
            'source': {'filters': <Object?>[]},
          },
        });
      };
      try {
        final result = await WindowsMihonHost.probeSourceFilters(client, [
          {'id': '123', 'name': 'Dynamic', 'lang': 'en'},
        ], budget: const Duration(milliseconds: 30));
        expect(result['filterProbe'], 'unknown');
      } finally {
        release.complete();
      }
    },
  );

  test(
    'malformed source factories fail before any filter request can execute',
    () async {
      var requests = 0;
      handle = (request) async {
        requests++;
        json(request, []);
      };
      await expectLater(
        WindowsMihonHost.probeSourceFilters(client, [
          {'id': '123', 'name': 'One', 'lang': 'en'},
          {'id': '123', 'name': 'Duplicate', 'lang': 'en'},
        ]),
        throwsStateError,
      );
      expect(requests, 0);
    },
  );

  test('installation presence checks require both verified originals and runtime JAR', () async {
    const package = 'org.example.plugin';
    final apk = File('${directory.path}/original.apk');
    final jar = File('${directory.path}/original.jar');
    final runtime = File('${directory.path}/extensions/runtime.jar');
    await runtime.parent.create();
    for (final file in [apk, jar, runtime]) {
      await file.writeAsBytes([1]);
    }
    final state = File('${directory.path}/state.json');
    await state.writeAsString(
      jsonEncode({
        package: {
          'stagedPath': apk.path,
          'desktopJarPath': jar.path,
          'runtimeFile': 'runtime.jar',
        },
      }),
    );
    final originalState = await state.readAsBytes();
    expect(
      await WindowsMihonHost.installationIssue(package, root: directory),
      isNull,
    );
    await jar.delete();
    expect(
      (await WindowsMihonHost.installationIssue(
        package,
        root: directory,
      ))?.requiresReinstall,
      isTrue,
    );
    expect(await state.readAsBytes(), originalState);
    expect(await apk.exists(), isTrue);
    expect(await runtime.exists(), isTrue);
  });

  test(
    'non-missing filesystem errors do not claim the installation was removed',
    () async {
      final state = Directory('${directory.path}/state.json');
      await state.create();
      final issue = await WindowsMihonHost.installationIssue(
        'org.example.plugin',
        root: directory,
      );
      expect(issue, isNotNull);
      expect(issue?.requiresReinstall, isFalse);
      expect(await state.exists(), isTrue);
    },
  );

  test(
    'APK conversion failures identify the local compatibility stage',
    () async {
      var installs = 0;
      handle = (request) async {
        installs++;
        await request.drain<void>();
        request.response.statusCode = 500;
        request.response.write('Server Error');
      };
      final apk = File('${directory.path}/extension.apk');
      await apk.writeAsBytes([1, 2, 3]);
      await expectLater(
        client.install(apk, nativeJar: false),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'compatibility stage',
            allOf(contains('APK 转换或加载失败'), contains('不是来源网站的 HTTP 500')),
          ),
        ),
      );
      expect(installs, 1);
    },
  );

  test(
    'native JAR loading failures do not claim an APK conversion failure',
    () async {
      handle = (request) async {
        await request.drain<void>();
        request.response.statusCode = 500;
        request.response.write('Server Error');
      };
      final jar = File('${directory.path}/extension.jar');
      await jar.writeAsBytes([1, 2, 3]);
      await expectLater(
        client.install(jar, nativeJar: true),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'compatibility stage',
            allOf(contains('原生 JAR 加载失败'), isNot(contains('APK 转换或加载失败'))),
          ),
        ),
      );
    },
  );

  test('host authentication failures retain their transport status', () async {
    handle = (request) async {
      await request.drain<void>();
      request.response.statusCode = 401;
      request.response.write('Unauthorized');
    };
    final apk = File('${directory.path}/extension.apk');
    await apk.writeAsBytes([1, 2, 3]);
    await expectLater(
      client.install(apk, nativeJar: false),
      throwsA(
        isA<DioException>().having(
          (error) => error.response?.statusCode,
          'host authentication status',
          401,
        ),
      ),
    );
  });

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
      expect(request.uri.path, '/api/graphql');
      final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final input = (data['variables'] as Map)['input'] as Map;
      expect(input['source'], '123');
      expect(input['page'], 1);
      expect(input['query'], 'book');
      final changes = input['filters'] as List;
      final group = changes
          .cast<Map<String, Object?>>()
          .map((change) => change['groupChange'] as Map)
          .singleWhere((change) => change['position'] == 1);
      final included = group['checkBoxState'] == true;
      json(request, {
        'data': {
          'fetchSourceManga': {
            'mangas': included
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
          },
        },
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
    'normalized GraphQL filters preserve labels and every typed state',
    () async {
      handle = (request) async {
        expect(request.uri.path, '/api/graphql');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['variables'], {'source': '514187608699312366'});
        expect(body['query'], contains('selectState: default'));
        json(request, {
          'data': {
            'source': {
              'filters': [
                {
                  '__typename': 'SelectFilter',
                  'name': 'Category',
                  'values': ['', 'Ao-yem', 'Cosplay'],
                  'selectState': 2,
                },
                {
                  '__typename': 'GroupFilter',
                  'name': 'Options',
                  'filters': [
                    {
                      '__typename': 'TextFilter',
                      'name': 'Tag',
                      'textState': 'test',
                    },
                    {
                      '__typename': 'CheckBoxFilter',
                      'name': 'Active',
                      'checkState': true,
                    },
                    {
                      '__typename': 'TriStateFilter',
                      'name': 'Ignored',
                      'triState': 'IGNORE',
                    },
                    {
                      '__typename': 'TriStateFilter',
                      'name': 'Included',
                      'triState': 'INCLUDE',
                    },
                    {
                      '__typename': 'TriStateFilter',
                      'name': 'Excluded',
                      'triState': 'EXCLUDE',
                    },
                  ],
                },
                {
                  '__typename': 'SortFilter',
                  'name': 'Order',
                  'values': ['Title', 'Date'],
                  'sortState': {'index': 1, 'ascending': false},
                },
                {
                  '__typename': 'SortFilter',
                  'name': 'Unset',
                  'values': ['Default'],
                  'sortState': null,
                },
              ],
            },
          },
        });
      };
      final result = await client.request(
        sourceId: '514187608699312366',
        operation: 'filters',
      );
      final filters = (result['filters'] as List).cast<Map<String, Object?>>();
      expect(filters[0], {
        'index': 0,
        'type': 'select',
        'name': 'Category',
        'values': ['', 'Ao-yem', 'Cosplay'],
        'state': 2,
      });
      final grouped = (filters[1]['state'] as List)
          .cast<Map<String, Object?>>();
      expect(grouped.map((row) => row['state']), ['test', true, 0, 1, 2]);
      expect(grouped.map((row) => row['index']), [0, 1, 2, 3, 4]);
      expect(filters[2]['state'], {'index': 1, 'ascending': false});
      expect(filters[3]['state'], isNull);
    },
  );

  test(
    'GraphQL partial errors never publish a successful filter snapshot',
    () async {
      handle = (request) async {
        json(request, {
          'data': {
            'source': {'filters': <Object?>[]},
          },
          'errors': [
            {'message': 'login required'},
          ],
        });
      };
      await expectLater(
        client.request(sourceId: '1', operation: 'filters'),
        throwsFormatException,
      );
    },
  );

  test(
    'cancelling normalized filters closes only the owned GraphQL socket',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      handle = (request) async {
        expect(request.uri.path, '/api/graphql');
        await request.drain<void>();
        await streamUntilDisconnected(request, started, disconnected);
      };
      final pending = client.request(
        requestId: 'filters',
        sourceId: '1',
        operation: 'filters',
      );
      final result = expectLater(pending, cancelled);
      await started.future;
      await client.cancelRequest('filters');
      await result;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(client.activeRequestCount, 0);
    },
  );

  test(
    'grouped informational filters keep source positions when searching',
    () async {
      handle = (request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (!(body['variables'] as Map).containsKey('input')) {
          json(request, {
            'data': {
              'source': {
                'filters': [
                  {
                    '__typename': 'SelectFilter',
                    'name': 'Search Mode',
                    'values': ['Pools', 'Tags'],
                    'selectState': 0,
                  },
                  {
                    '__typename': 'GroupFilter',
                    'name': 'Pool Search Options',
                    'filters': [
                      {
                        '__typename': 'HeaderFilter',
                        'name': '(Pools Search Mode only)',
                      },
                      {
                        '__typename': 'SelectFilter',
                        'name': 'Category',
                        'values': ['Any', 'Series'],
                        'selectState': 1,
                      },
                      {'__typename': 'SeparatorFilter', 'name': ''},
                      {
                        '__typename': 'CheckBoxFilter',
                        'name': 'Active',
                        'checkState': true,
                      },
                      {'__typename': 'HeaderFilter', 'name': 'End'},
                    ],
                  },
                ],
              },
            },
          });
        } else {
          expect(request.uri.path, '/api/graphql');
          final input = (body['variables'] as Map)['input'] as Map;
          final changes = (input['filters'] as List)
              .cast<Map<String, Object?>>();
          expect(changes.map((row) => row['position']), [0, 1, 1]);
          expect(changes.first['selectState'], 0);
          expect(changes.skip(1).map((row) => row['groupChange']), [
            {'position': 1, 'selectState': 1},
            {'position': 3, 'checkBoxState': true},
          ]);
          json(request, {
            'data': {
              'fetchSourceManga': {'mangas': <Object?>[], 'hasNextPage': false},
            },
          });
        }
      };
      final fresh = await client.request(sourceId: '1', operation: 'filters');
      final result = await client.request(
        sourceId: '1',
        operation: 'search',
        filters: (fresh['filters'] as List).cast<Map<String, Object?>>(),
      );
      expect(result['ok'], isTrue);
    },
  );

  test(
    'nested groups and grouped sort submit recursive typed changes',
    () async {
      handle = (request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final input = (body['variables'] as Map)['input'] as Map;
        expect(input['page'], 2);
        expect(input['filters'], [
          {
            'position': 0,
            'groupChange': {
              'position': 1,
              'groupChange': {'position': 0, 'triState': 'EXCLUDE'},
            },
          },
          {
            'position': 0,
            'groupChange': {
              'position': 2,
              'sortState': {'index': 1, 'ascending': false},
            },
          },
        ]);
        json(request, {
          'data': {
            'fetchSourceManga': {'mangas': <Object?>[], 'hasNextPage': true},
          },
        });
      };
      final result = await client.request(
        sourceId: '1',
        operation: 'search',
        page: 2,
        filters: [
          {
            'type': 'group',
            'state': [
              {'type': 'header'},
              {
                'type': 'group',
                'state': [
                  {'type': 'tri', 'state': 2},
                ],
              },
              {
                'type': 'sort',
                'state': {'index': 1, 'ascending': false},
              },
            ],
          },
        ],
      );
      expect(result['hasNextPage'], isTrue);
    },
  );

  test('explicit null sort preserves root and nested plugin state', () async {
    final filters = <Map<String, Object?>>[
      {
        'type': 'sort',
        'name': 'MangaDex order',
        'values': ['Title', 'Relevance'],
        'state': null,
      },
      {
        'type': 'group',
        'state': [
          {'type': 'header', 'state': null},
          {
            'type': 'group',
            'state': [
              {'type': 'sort', 'state': null},
              {'type': 'check', 'state': true},
            ],
          },
          {
            'type': 'sort',
            'state': {'index': 1, 'ascending': false},
          },
        ],
      },
    ];
    late Map<String, Object?> body;
    late String path;
    handle = (request) async {
      path = request.uri.path;
      body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, Object?>;
      json(request, {
        'data': {
          'fetchSourceManga': {'mangas': <Object?>[], 'hasNextPage': false},
        },
      });
    };
    final result = await client.request(
      sourceId: '1',
      operation: 'search',
      query: 'test',
      filters: filters,
    );
    expect(result['ok'], isTrue);
    expect(path, '/api/graphql');
    expect(body['query'], contains(r'triomiFilters: $triomiFilters'));
    final variables = body['variables'] as Map;
    final input = variables['input'] as Map;
    expect(input['source'], '1');
    expect(input['query'], 'test');
    expect(input['filters'], isNull);
    expect(jsonDecode(variables['triomiFilters'] as String), filters);
  });

  test(
    'GraphQL search preserves source identity and cancellation ownership',
    () async {
      final started = Completer<void>();
      final disconnected = Completer<void>();
      handle = (request) async {
        expect(request.uri.path, '/api/graphql');
        await request.drain<void>();
        await streamUntilDisconnected(request, started, disconnected);
      };
      final pending = client.request(
        requestId: 'search',
        sourceId: '123',
        operation: 'search',
      );
      final cancelledResult = expectLater(pending, cancelled);
      await started.future;
      await client.cancelRequest('search');
      await cancelledResult;
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(client.activeRequestCount, 0);
      handle = (request) async {
        json(request, {
          'data': {
            'fetchSourceManga': {
              'mangas': [
                {
                  'id': 9,
                  'sourceId': '456',
                  'url': '/foreign',
                  'title': 'Foreign',
                },
              ],
              'hasNextPage': false,
            },
          },
        });
      };
      await expectLater(
        client.request(sourceId: '123', operation: 'search'),
        throwsFormatException,
      );
    },
  );

  test(
    'Android saved filter snapshots restore and drive a desktop search',
    () async {
      handle = (request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (!(body['variables'] as Map).containsKey('input')) {
          expect((body['variables'] as Map)['source'], '123');
          json(request, {
            'data': {
              'source': {
                'filters': [
                  {'__typename': 'HeaderFilter', 'name': 'Options'},
                  {
                    '__typename': 'GroupFilter',
                    'name': 'Genres',
                    'filters': [
                      {
                        '__typename': 'CheckBoxFilter',
                        'name': 'Science',
                        'checkState': false,
                      },
                      {
                        '__typename': 'SelectFilter',
                        'name': 'Year',
                        'selectState': 0,
                        'values': ['2025', '2026'],
                      },
                    ],
                  },
                  {'__typename': 'SeparatorFilter', 'name': ''},
                ],
              },
            },
          });
        } else {
          final input = (body['variables'] as Map)['input'] as Map;
          final changes = (input['filters'] as List)
              .cast<Map<String, Object?>>();
          final selections = changes
              .map(
                (row) => Map<String, Object?>.from(row['groupChange'] as Map),
              )
              .toList();
          final matches =
              selections.any(
                (row) => row['position'] == 0 && row['checkBoxState'] == true,
              ) &&
              selections.any(
                (row) => row['position'] == 1 && row['selectState'] == 1,
              );
          json(request, {
            'data': {
              'fetchSourceManga': {
                'mangas': [
                  if (matches)
                    {
                      'id': 1,
                      'sourceId': '123',
                      'url': '/chosen',
                      'title': 'Chosen',
                    },
                ],
                'hasNextPage': false,
              },
            },
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
