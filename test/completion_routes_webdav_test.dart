import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/source/http_client.dart';
import 'package:triomi/features/completion_routes/completion_routes_repository.dart';
import 'package:triomi/features/completion_routes/completion_routes_webdav.dart';

import 'fixtures/fake_preferences.dart';
import 'fixtures/portable_rule_test_support.dart';

void main() {
  sourceRuleTest('route-only DAV sync converges and refuses a concurrent remote write', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = DioSourceHttpClient();
    addTearDown(() async {
      transport.close();
      await server.close(force: true);
    });
    final config = WebDavConfig(
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: 'fixture',
      password: 'fixture',
    );
    String? document;
    var revision = 0;
    var writes = 0;
    final requests = <(String, String)>[];
    server.listen((request) async {
      final response = request.response;
      requests.add((request.method, request.uri.path));
      final etag = '"$revision"';
      if (request.method == 'MKCOL') {
        response.statusCode = 405;
      } else if (request.method == 'PROPFIND' || request.method == 'GET') {
        if (document == null) {
          response.statusCode = 404;
        } else if (request.method == 'GET' && request.headers.value('if-match') != etag) {
          response.statusCode = 412;
        } else {
          response.headers.set('etag', etag);
          response.statusCode = request.method == 'GET' ? 200 : 207;
          if (request.method == 'GET') response.write(document);
        }
      } else if (request.method == 'PUT') {
        final body = await utf8.decoder.bind(request).join();
        final matches = document == null
            ? request.headers.value('if-none-match') == '*'
            : request.headers.value('if-match') == etag;
        response.statusCode = matches ? 201 : 412;
        if (matches) {
          document = body;
          revision++;
          writes++;
        }
      }
      await response.close();
    });
    var now = DateTime.utc(2026, 1, 1);
    final local = CompletionRoutesRepository(memoryPreferences(), clock: () => now);
    final second = CompletionRoutesRepository(memoryPreferences(), clock: () => now);
    final client = WebDavClient(http: transport);
    final syncA = CompletionRoutesWebDav(local, client, () => config);
    final syncB = CompletionRoutesWebDav(second, client, () => config);
    final route = await local.createRoute('首条路线');
    expect(await syncA.sync((_) async => false), isNull);
    expect(document, isNull);
    expect(await syncA.sync((_) async => true), 1);
    expect(await syncB.sync((_) async => true), 1);
    expect(second.read().routes.single.id, route.id);
    expect(writes, 1, reason: 'read-only convergence must not rewrite the document');

    now = now.add(const Duration(minutes: 1));
    await local.deleteRoute(route.id);
    await syncA.sync((_) async => true);
    await syncB.sync((preview) async {
      expect(preview.merged.routes, isEmpty);
      return true;
    });
    expect(second.read().routes, isEmpty);
    expect(second.read().tombstones.single.id, route.id);

    final other = await second.createRoute('待上传');
    final existing = document;
    await expectLater(syncB.sync((_) async {
      revision++;
      return true;
    }), throwsA(anything));
    expect(second.read().routes.single.id, other.id);
    expect(document, existing);
    expect(writes, 2);
    expect(requests.where((entry) => entry.$1 != 'MKCOL').map((entry) => entry.$2).toSet(),
        {'/triomi/completion-routes.v1.json'});
  });
}
