import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/app_update_service.dart';

const _tag = 'v0.15.3';
const _base = 'https://github.com/HyperionHXH/triomi/releases/download/$_tag/';
const _zipHash =
    '1111111111111111111111111111111111111111111111111111111111111111';

class _Transport implements HttpClientAdapter {
  _Transport({required this.manifest, this.corruptManifest = false});
  final Map<String, Object?> manifest;
  final bool corruptManifest;
  final requests = <String>[];
  List<int> get bytes => utf8.encode(jsonEncode(manifest));
  String get digest => sha256.convert(bytes).toString();

  Map<String, Object?> asset(String name, List<int> data) => {
    'name': name,
    'state': 'uploaded',
    'size': data.length,
    'digest': 'sha256:${sha256.convert(data)}',
    'browser_download_url': '$_base$name',
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    if (options.uri.toString() == appUpdateReleasesApi) {
      return ResponseBody.fromString(
        jsonEncode([
          {
            'tag_name': _tag,
            'draft': false,
            'prerelease': false,
            'name': 'Triomi',
            'body': '',
            'published_at': '2026-11-08T00:00:00Z',
            'assets': [
              asset('triomi-windows.update.json', bytes),
              {
                'name': 'triomi-windows.zip',
                'state': 'uploaded',
                'size': 100,
                'digest': 'sha256:$_zipHash',
                'browser_download_url': '${_base}triomi-windows.zip',
              },
              asset(
                'SHA256SUMS.txt',
                utf8.encode(
                  '$digest  triomi-windows.update.json\n$_zipHash  triomi-windows.zip\n',
                ),
              ),
            ],
          },
        ]),
        200,
      );
    }
    if (options.uri.path.endsWith('/SHA256SUMS.txt')) {
      return ResponseBody.fromString(
        '$digest  triomi-windows.update.json\n$_zipHash  triomi-windows.zip\n',
        200,
      );
    }
    if (options.uri.path.endsWith('/triomi-windows.update.json')) {
      return ResponseBody.fromBytes(corruptManifest ? [1, 2, 3] : bytes, 200);
    }
    throw StateError('Startup must not download an executable ZIP');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const installed = AppUpdateInfo(
    packageName: 'io.github.hyperionhxh.triomi',
    version: '0.15.3',
    versionCode: 188,
    sha256: _zipHash,
    platform: 'windows',
  );
  Map<String, Object?> manifest(int revision) => {
    'platform': 'windows',
    'packageName': installed.packageName,
    'version': installed.version,
    'versionCode': installed.versionCode,
    'windowsRevision': revision,
    'sha256': _zipHash,
    'files': {},
  };
  for (final revision in [0, 1]) {
    test(
      'startup considers servicing revision $revision without downloading ZIP',
      () async {
        final transport = _Transport(manifest: manifest(revision));
        final service = AppUpdateService(
          dio: Dio()..httpClientAdapter = transport,
        );
        try {
          final token = AppUpdateCancellation();
          final releases = await service.resolveWindowsRevisions(
            installed,
            await service.releases(token),
            token,
          );
          final offered = newestAppUpdateRelease(installed, releases);
          expect(offered?.windowsRevision, revision == 0 ? isNull : 1);
          expect(
            transport.requests.any(
              (url) => url.endsWith('/triomi-windows.zip'),
            ),
            isFalse,
          );
          if (offered != null) {
            expect(offered.version, installed.version);
            expect(offered.windowsBuild, installed.versionCode);
            expect(offered.identity, isNot(releases.single.tag));
          }
        } finally {
          service.close();
        }
      },
    );
  }
  test('corrupt servicing manifest never produces an update offer', () async {
    final transport = _Transport(manifest: manifest(1), corruptManifest: true);
    final service = AppUpdateService(dio: Dio()..httpClientAdapter = transport);
    try {
      final token = AppUpdateCancellation();
      final releases = await service.releases(token);
      await expectLater(
        service.resolveWindowsRevisions(installed, releases, token),
        throwsFormatException,
      );
    } finally {
      service.close();
    }
  });
  test(
    'Android release lookup does not request Windows-only servicing metadata',
    () async {
      final transport = _Transport(manifest: manifest(1));
      final service = AppUpdateService(
        dio: Dio()..httpClientAdapter = transport,
      );
      try {
        final token = AppUpdateCancellation();
        final releases = await service.releases(token);
        const android = AppUpdateInfo(
          packageName: 'io.github.hyperionhxh.triomi',
          version: '0.15.3',
          versionCode: 188,
          sha256: _zipHash,
          platform: 'android',
        );
        final resolved = await service.resolveWindowsRevisions(
          android,
          releases,
          token,
        );
        expect(newestAppUpdateRelease(android, resolved), isNull);
        expect(transport.requests, [appUpdateReleasesApi]);
      } finally {
        service.close();
      }
    },
  );
}
