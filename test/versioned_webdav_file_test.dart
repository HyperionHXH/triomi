import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/core/backup/versioned_webdav_backup.dart';
import 'package:triomi/core/backup/webdav_client.dart';
import 'package:triomi/core/models/source_exception.dart';
import 'package:triomi/core/source/http_client.dart';

void main() {
  test(
    'real Dio loopback streams a 257MiB file and reuses two objects',
    () async {
      final fixture = await _LoopbackDav.open();
      addTearDown(fixture.close);
      final http = DioSourceHttpClient();
      addTearDown(http.close);
      final store = VersionedWebDavBackup(WebDavClient(http: http));
      final config = fixture.config;
      final source = await _patternFile(fixture.root, 257);
      final sourceHash = await _hash(source);

      await store.uploadFile(
        config,
        source.path,
        const RemoteBackupInfo(exists: false),
      );
      final destination = File('${fixture.root.path}/roundtrip.zip');
      final result = await store.downloadToFile(config, destination);

      expect(result?.bytes, await source.length());
      expect(result?.sha256, sourceHash);
      expect(await _hash(destination), sourceHash);
      expect(fixture.objectPaths.length, 2);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('stale CAS keeps previous head and immutable revisions', () async {
    final fixture = await _LoopbackDav.open();
    addTearDown(fixture.close);
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final client = WebDavClient(http: http);
    final store = VersionedWebDavBackup(client);
    final config = fixture.config;
    final first = await _smallFile(fixture.root, 'first.zip', <int>[1, 2, 3]);
    final second = await _smallFile(fixture.root, 'second.zip', <int>[4, 5, 6]);

    await store.uploadFile(
      config,
      first.path,
      await client.stat(store.head(config)),
    );
    final firstHead = await client.stat(store.head(config));
    final firstRevision = fixture.revisionPaths.single;
    final firstRevisionBytes = fixture.bytesAt(firstRevision);
    await store.uploadFile(config, second.path, firstHead);
    final secondHeadBytes = fixture.bytesAt(
      Uri.parse(store.head(config).fileUrl).path,
    );

    final stale = await _smallFile(fixture.root, 'stale.zip', <int>[7, 8, 9]);
    await expectLater(
      store.uploadFile(config, stale.path, firstHead),
      throwsA(isA<SourceException>()),
    );
    expect(
      fixture.bytesAt(Uri.parse(store.head(config).fileUrl).path),
      secondHeadBytes,
    );
    expect(fixture.bytesAt(firstRevision), firstRevisionBytes);
  });

  test('corrupt, missing, oversized, and malformed remote data never publishes a destination', () async {
    final fixture = await _LoopbackDav.open();
    addTearDown(fixture.close);
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final client = WebDavClient(http: http);
    final store = VersionedWebDavBackup(client);
    final config = fixture.config;
    final source = await _smallFile(
      fixture.root,
      'valid.zip',
      List<int>.generate(32, (i) => i),
    );
    await store.uploadFile(
      config,
      source.path,
      await client.stat(store.head(config)),
    );
    final headPath = Uri.parse(store.head(config).fileUrl).path;
    final manifest = jsonDecode(utf8.decode(fixture.bytesAt(headPath))) as Map;
    final hash =
        ((manifest['chunks'] as List).single as Map)['sha256'] as String;
    final objectPath =
        '${Uri.parse(config.directoryUrl).path}/objects/$hash.bin';
    final originalObject = fixture.bytesAt(objectPath);

    fixture.setBytes(objectPath, List<int>.filled(originalObject.length, 0));
    final corrupt = File('${fixture.root.path}/corrupt.zip');
    await expectLater(
      store.downloadToFile(config, corrupt),
      throwsFormatException,
    );
    expect(await corrupt.exists(), isFalse);

    fixture.setBytes(objectPath, originalObject);
    fixture.delete(objectPath);
    final missing = File('${fixture.root.path}/missing.zip');
    await expectLater(
      store.downloadToFile(config, missing),
      throwsFormatException,
    );
    expect(await missing.exists(), isFalse);

    fixture.setBytes(
      objectPath,
      List<int>.filled(VersionedWebDavBackup.chunkSize + 1, 9),
    );
    final oversized = File('${fixture.root.path}/oversized.zip');
    await expectLater(
      store.downloadToFile(config, oversized),
      throwsFormatException,
    );
    expect(await oversized.exists(), isFalse);

    fixture.setBytes(objectPath, originalObject);
    fixture.setBytes(
      headPath,
      utf8.encode(
        jsonEncode({
          'version': 1,
          'size': 1,
          'sha256': 'bad',
          'chunks': const <Object?>[],
        }),
      ),
    );
    final malformed = File('${fixture.root.path}/malformed.zip');
    await expectLater(
      store.downloadToFile(config, malformed),
      throwsFormatException,
    );
    expect(await malformed.exists(), isFalse);

    fixture.setBytes(headPath, fixture.manifestFor(source));
    final existing = File('${fixture.root.path}/existing.zip');
    await existing.writeAsString('keep-local-bytes');
    await expectLater(store.downloadToFile(config, existing), throwsStateError);
    expect(await existing.readAsString(), 'keep-local-bytes');
  });

  test('16GiB sparse file is rejected before any remote request', () async {
    final fixture = await _LoopbackDav.open();
    addTearDown(fixture.close);
    final http = DioSourceHttpClient();
    addTearDown(http.close);
    final store = VersionedWebDavBackup(WebDavClient(http: http));
    final sparse = File('${fixture.root.path}/too-large.zip');
    final output = await sparse.open(mode: FileMode.writeOnly);
    if (Platform.isWindows) {
      final result = await Process.run('fsutil', ['sparse', 'setflag', sparse.path]);
      if (result.exitCode != 0) {
        await output.close();
        throw StateError('Cannot create sparse boundary fixture: ${result.stderr}');
      }
    }
    await output.setPosition(VersionedWebDavBackup.maxFileSize);
    await output.writeByte(1);
    await output.close();

    await expectLater(
      store.uploadFile(
        fixture.config,
        sparse.path,
        const RemoteBackupInfo(exists: false),
      ),
      throwsFormatException,
    );
    expect(fixture.requests, 0);
  });
}

Future<File> _patternFile(Directory root, int chunks) async {
  final file = File('${root.path}/large.zip');
  final output = file.openWrite();
  final a = List<int>.filled(VersionedWebDavBackup.chunkSize, 0x11);
  final b = List<int>.filled(VersionedWebDavBackup.chunkSize, 0x22);
  for (var index = 0; index < chunks; index++) {
    output.add(index.isEven ? a : b);
  }
  await output.close();
  return file;
}

Future<File> _smallFile(Directory root, String name, List<int> bytes) async {
  final file = File('${root.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class _LoopbackDav {
  _LoopbackDav(this.server, this.root, this.files, this.tags);
  final HttpServer server;
  final Directory root;
  final Map<String, File> files;
  final Map<String, String> tags;
  int requests = 0;
  int _etag = 0;

  static Future<_LoopbackDav> open() async {
    final root = await Directory.systemTemp.createTemp('triomi-dav-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _LoopbackDav(
      server,
      root,
      <String, File>{},
      <String, String>{},
    );
    server.listen(fixture._handle);
    return fixture;
  }

  WebDavConfig get config => WebDavConfig(
    baseUrl: 'http://127.0.0.1:${server.port}/dav/',
    username: 'loopback-user',
    password: 'loopback-password',
  );

  Iterable<String> get objectPaths =>
      files.keys.where((path) => path.contains('/objects/'));
  Iterable<String> get revisionPaths =>
      files.keys.where((path) => path.contains('/revisions/'));

  List<int> bytesAt(String path) => files[path]!.readAsBytesSync();

  void setBytes(String path, List<int> bytes) {
    final file = files[path] ??= File('${root.path}/remote-${files.length}');
    file.writeAsBytesSync(bytes, flush: true);
  }

  void delete(String path) {
    files.remove(path)?.deleteSync();
    tags.remove(path);
  }

  List<int> manifestFor(File source) {
    final hash = sha256.convert(source.readAsBytesSync()).toString();
    final chunkHash = sha256.convert(source.readAsBytesSync()).toString();
    return utf8.encode(
      jsonEncode({
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'size': source.lengthSync(),
        'sha256': hash,
        'chunks': [
          {'sha256': chunkHash, 'size': source.lengthSync()},
        ],
      }),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    requests++;
    final path = request.uri.path;
    final existing = files[path];
    if (request.method == 'MKCOL') {
      request.response.statusCode = 405;
    } else if (request.method == 'PROPFIND') {
      if (existing == null) {
        request.response.statusCode = 404;
      } else {
        request.response.statusCode = 207;
        request.response.headers.set('ETag', tags[path]!);
        request.response.write(
          '<d:getcontentlength>${existing.lengthSync()}</d:getcontentlength>',
        );
      }
    } else if (request.method == 'GET') {
      if (existing == null) {
        request.response.statusCode = 404;
      } else {
        request.response.statusCode = 200;
        request.response.headers.contentLength = existing.lengthSync();
        try {
          await request.response.addStream(existing.openRead());
          await request.response.close();
        } on HttpException {
          // A bounded consumer deliberately disconnects oversized responses.
        } on SocketException {
          // The client has already rejected the response and closed its stream.
        }
        return;
      }
    } else if (request.method == 'PUT') {
      final conflict =
          request.headers.value('If-None-Match') == '*' && existing != null ||
          request.headers.value('If-Match') != null &&
              request.headers.value('If-Match') != tags[path];
      if (conflict) {
        request.response.statusCode = 412;
      } else {
        final file = File('${root.path}/remote-${files.length}-$_etag');
        final output = file.openWrite();
        try {
          await output.addStream(request);
          await output.flush();
        } finally {
          await output.close();
        }
        files[path] = file;
        tags[path] = '"etag-${++_etag}"';
        request.response.statusCode = 201;
      }
    } else {
      request.response.statusCode = 500;
    }
    await request.response.close();
  }

  Future<void> close() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}
