import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/versioned_webdav_backup.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/source/http_client.dart';

void main() {
  test('oversized upload rejects before any remote request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 500;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final store = VersionedWebDavBackup(WebDavClient(http: http));
    final config = WebDavConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/dav/',
      username: 'local-fixture',
      password: 'local-fixture',
    );
    await expectLater(
      store.upload(
        config,
        Uint8List(VersionedWebDavBackup.maxBackupSize + 1),
        const RemoteBackupInfo(exists: false),
      ),
      throwsFormatException,
    );
    expect(requests, 0);
  });
  test('versioned WebDAV reuses chunks, preserves revisions and rejects stale head', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final files = <String, Uint8List>{}, tags = <String, String>{};
    var puts = 0;
    server.listen((request) async {
      final key = request.uri.path;
      if (request.method == 'MKCOL') {
        request.response.statusCode = 405;
      } else if (request.method == 'PROPFIND') {
        request.response.statusCode = files.containsKey(key) ? 207 : 404;
        if (files.containsKey(key)) {
          request.response.headers.set('ETag', tags[key]!);
          request.response.write(
            '<d:getcontentlength>${files[key]!.length}</d:getcontentlength>',
          );
        }
      } else if (request.method == 'PUT') {
        final conflict =
            request.headers.value('If-None-Match') == '*' &&
                files.containsKey(key) ||
            request.headers.value('If-Match') != null &&
                request.headers.value('If-Match') != tags[key];
        if (conflict) {
          request.response.statusCode = 412;
        } else {
          final body = BytesBuilder();
          await for (final chunk in request) {
            body.add(chunk);
          }
          files[key] = body.takeBytes();
          tags[key] = '"revision-${++puts}"';
          request.response.statusCode = 201;
        }
      } else if (request.method == 'GET') {
        request.response.statusCode = files.containsKey(key) ? 200 : 404;
        if (files.containsKey(key)) request.response.add(files[key]!);
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final client = WebDavClient(http: http),
        store = VersionedWebDavBackup(WebDavClient(http: http));
    final config = WebDavConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/dav/',
      username: 'local-fixture',
      password: 'local-fixture',
    );
    final original = Uint8List(VersionedWebDavBackup.chunkSize + 100)
      ..fillRange(0, VersionedWebDavBackup.chunkSize + 100, 3);
    await store.upload(config, original, await client.stat(store.head(config)));
    final firstHead = await client.stat(store.head(config));
    final firstObjects = files.keys
        .where((k) => k.contains('/objects/'))
        .toSet();
    final changed = Uint8List.fromList(original)..[original.length - 1] = 4;
    await store.upload(config, changed, firstHead);
    expect(await store.download(config), orderedEquals(changed));
    expect(
      files.keys.where((k) => k.contains('/objects/')).length,
      firstObjects.length + 1,
    );
    expect(files.keys.where((k) => k.contains('/revisions/')).length, 2);
    await expectLater(
      store.upload(config, original, firstHead),
      throwsA(isA<Object>()),
    );
    expect(await store.download(config), orderedEquals(changed));
    final head = jsonDecode(
      utf8.decode(files[Uri.parse(store.head(config).fileUrl).path]!),
    ) as Map;
    final hash = ((head['chunks'] as List).last as Map)['sha256'];
    files['/dav/triomi/objects/$hash.bin'] = Uint8List(100);
    await expectLater(store.download(config), throwsFormatException);
  });
}
