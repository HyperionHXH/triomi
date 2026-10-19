import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart' as zip;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:triomi/features/settings/app_update_service.dart';

const _hash =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _otherHash =
    '2222222222222222222222222222222222222222222222222222222222222222';
String _url(String name, [int code = 156]) =>
    'https://github.com/HyperionHXH/triomi/releases/download/v0.1.0-test.$code/$name';
Map<String, Object?> _asset(
  String name, {
  int bytes = 3,
  String? digest = _hash,
  int code = 156,
}) => {
  'name': name,
  'state': 'uploaded',
  'size': bytes,
  'digest': digest == null ? null : 'sha256:$digest',
  'browser_download_url': _url(name, code),
};
Map<String, Object?> _release({
  int code = 156,
  List<Map<String, Object?>>? assets,
}) => {
  'tag_name': 'v0.1.0-test.$code',
  'name': 'Triomi test.$code',
  'draft': false,
  'prerelease': true,
  'published_at': '2026-10-17T06:33:25Z',
  'body': 'Real release notes',
  'assets': assets ?? [_asset('triomi-android.apk', code: code)],
};
AppUpdateRelease _parse(Map<String, Object?> raw) =>
    AppUpdateRelease.parse(utf8.encode(jsonEncode([raw]))).single;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('release build boundaries agree with Windows PE build field and reject unknown conventions', () {
    expect(appUpdateReleaseCode('v0.1.0-test.156'), 156);
    expect(appUpdateReleaseCode('0.1.0-test.65535'), 65535);
    for (final tag in [
      'v0.1.0-test.0',
      'v0.1.0-test.65536',
      'v0.1.0-test.-1',
      'v0.1.0-test.0156',
      'v0.1.0',
      'test.156',
      'v0.1.0-test.156-extra',
    ]) {
      expect(appUpdateReleaseCode(tag), null, reason: tag);
    }
  });
  test('prereleases are retained and ordered by actual build instead of lexical title or date', () {
    final releases = AppUpdateRelease.parse(
      utf8.encode(
        jsonEncode([
          _release(code: 99),
          _release(code: 156),
          _release(code: 155),
          {..._release(code: 157), 'draft': true},
          {..._release(), 'tag_name': 'unversioned'},
        ]),
      ),
    );
    expect(releases.map((release) => release.versionCode), [156, 155, 99]);
    expect(releases.first.prerelease, true);
    expect(releases.first.version, '0.1.0');
    expect(releases.first.notes, 'Real release notes');
    const installed = AppUpdateInfo(
      packageName: 'io.github.hyperionhxh.triomi',
      versionCode: 156,
      version: '0.1.0',
      sha256: _hash,
      platform: 'windows',
    );
    expect(releases.first.isNewerThan(installed), false);
    expect(_parse(_release(code: 157)).isNewerThan(installed), true);
  });
  test('asset selection rejects foreign repo, foreign tag, duplicate, missing size and bad digest', () {
    for (final asset in [
      {
        ..._asset('triomi-android.apk'),
        'browser_download_url': _url('triomi-android.apk')
            .replaceFirst('/triomi/', '/other/'),
      },
      {
        ..._asset('triomi-android.apk'),
        'browser_download_url': _url('triomi-android.apk', 155),
      },
      {
        ..._asset('triomi-android.apk'),
        'browser_download_url': '${_url('triomi-android.apk')}?token=secret',
      },
      {..._asset('triomi-android.apk'), 'size': appUpdateMaxBytes + 1},
      {..._asset('triomi-android.apk'), 'digest': 'sha256:1111'},
    ]) {
      expect(() => _parse(_release(assets: [asset])), throwsFormatException);
    }
    expect(
      () => _parse(
        _release(
          assets: [_asset('triomi-android.apk'), _asset('triomi-android.apk')],
        ),
      ),
      throwsFormatException,
    );
  });
  test('redirect trust is exact HTTPS GitHub CDN, without credentials or arbitrary ports', () {
    final original = Uri.parse(_url('triomi-android.apk'));
    expect(
      appUpdateTrustedRedirect(
        Uri.parse(
          'https://release-assets.githubusercontent.com/github-production-release-asset/1/a?sig=temporary',
        ),
        original,
      ),
      true,
    );
    for (final url in [
      'http://release-assets.githubusercontent.com/a',
      'https://release-assets.githubusercontent.com.evil.test/a',
      'https://evilgithubusercontent.com/a',
      'https://user:password@objects.githubusercontent.com/a',
      'https://objects.githubusercontent.com:8443/a',
      'https://objects.githubusercontent.com/a#fragment',
      'https://github.com/other/repo/file',
    ]) {
      expect(
        appUpdateTrustedRedirect(Uri.parse(url), original),
        false,
        reason: url,
      );
    }
  });
  test('checksum parser rejects duplicate filenames, traversal, truncated hashes and oversized metadata', () {
    expect(appUpdateChecksums(utf8.encode('$_hash  triomi-android.apk\n')), {
      'triomi-android.apk': _hash,
    });
    for (final text in [
      '$_hash  ../triomi.apk',
      '1234  triomi.apk',
      '$_hash  triomi.apk\n$_hash  triomi.apk',
    ]) {
      expect(
        () => appUpdateChecksums(utf8.encode(text)),
        throwsFormatException,
      );
    }
    expect(
      () => appUpdateChecksums(List.filled(65537, 32)),
      throwsFormatException,
    );
  });
  test('production list request uses releases endpoint, includes prerelease data and strips inherited credentials', () async {
    final adapter = _Adapter(
      (options, _) => ResponseBody.fromString(jsonEncode([_release()]), 200),
    );
    final dio = Dio(
      BaseOptions(
        headers: {'Authorization': 'private', 'Cookie': 'source-session'},
      ),
    )..httpClientAdapter = adapter;
    final service = AppUpdateService(dio: dio);
    try {
      final releases = await service.releases(AppUpdateCancellation());
      expect(releases.single.versionCode, 156);
      expect(adapter.requests.single.toString(), appUpdateReleasesApi);
    } finally {
      service.close();
    }
  });
  test('release list rejects redirects and bounds streamed JSON without leaking response diagnostics', () async {
    for (final redirect in [true, false]) {
      final adapter = _Adapter(
        (options, _) => redirect
            ? ResponseBody.fromString(
                'private-signed-cdn-token',
                302,
                headers: {
                  'location': [
                    'https://attacker.test/?token=private-signed-cdn-token',
                  ],
                },
              )
            : ResponseBody.fromBytes(List.filled(4 * 1024 * 1024 + 1, 32), 200),
      );
      final service = AppUpdateService(dio: Dio()..httpClientAdapter = adapter);
      try {
        await expectLater(
          service.releases(AppUpdateCancellation()),
          redirect
              ? throwsA(
                  isA<HttpException>().having(
                    (error) => error.message,
                    'safe error',
                    isNot(contains('private-signed-cdn-token')),
                  ),
                )
              : throwsFormatException,
        );
        expect(adapter.requests.length, 1);
      } finally {
        service.close();
      }
    }
  });
  test('official assets without legacy checksums still require valid GitHub SHA-256', () async {
    final adapter = _Adapter(
      (options, _) => throw StateError('no metadata request expected'),
    );
    final service = AppUpdateService(dio: Dio()..httpClientAdapter = adapter);
    try {
      expect(
        await service.releaseChecksums(
          _parse(_release()),
          AppUpdateCancellation(),
        ),
        {'triomi-android.apk': _hash},
      );
      expect(
        await service.releaseChecksums(
          _parse(
            _release(assets: [_asset('triomi-android.apk', digest: null)]),
          ),
          AppUpdateCancellation(),
        ),
        isEmpty,
      );
      expect(adapter.requests, isEmpty);
    } finally {
      service.close();
    }
  });
  for (final mode in [
    'trusted',
    'legacy-checksums',
    'foreign',
    'downgrade',
    'loop',
    'cancel',
    'mismatch',
    'truncated',
  ]) {
    test('real release metadata transport handles $mode before payload staging', () async {
      final token = AppUpdateCancellation();
      final sums = utf8.encode(
        '${mode == 'mismatch' ? _otherHash : _hash}  triomi-android.apk\n',
      );
      final release = _parse(
        _release(
          assets: [
            _asset(
              'triomi-android.apk',
              digest: mode == 'legacy-checksums' ? null : _hash,
            ),
            _asset(
              'SHA256SUMS.txt',
              bytes: sums.length,
              digest: mode == 'legacy-checksums'
                  ? null
                  : sha256.convert(sums).toString(),
            ),
          ],
        ),
      );
      final adapter = _Adapter((options, count) {
        if (mode == 'cancel' && count == 1) token.cancel();
        if (count == 1 || mode == 'loop') {
          final location = mode == 'foreign'
              ? 'https://attacker.test/SHA256SUMS.txt'
              : mode == 'downgrade'
              ? 'http://objects.githubusercontent.com/a'
              : 'https://release-assets.githubusercontent.com/a?sig=temporary-secret';
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [location],
            },
          );
        }
        return ResponseBody.fromBytes(
          mode == 'truncated' ? sums.sublist(1) : sums,
          200,
        );
      });
      final service = AppUpdateService(dio: Dio()..httpClientAdapter = adapter);
      try {
        if (mode == 'trusted' || mode == 'legacy-checksums') {
          expect(
            (await service.releaseChecksums(
              release,
              token,
            ))['triomi-android.apk'],
            _hash,
          );
          expect(adapter.requests.length, 2);
        } else {
          await expectLater(
            service.releaseChecksums(release, token),
            mode == 'cancel'
                ? throwsA(isA<AppUpdateCancelled>())
                : throwsFormatException,
          );
          if (mode == 'foreign' || mode == 'downgrade' || mode == 'cancel') {
            expect(adapter.requests.length, 1);
          }
          if (mode == 'loop') expect(adapter.requests.length, 5);
        }
      } finally {
        service.close();
      }
    });
  }
  test('cancel before release check performs no request', () async {
    final adapter = _Adapter(
      (options, _) => throw StateError('must not fetch'),
    );
    final service = AppUpdateService(dio: Dio()..httpClientAdapter = adapter);
    try {
      await expectLater(
        service.releases(AppUpdateCancellation()..cancel()),
        throwsA(isA<AppUpdateCancelled>()),
      );
      expect(adapter.requests, isEmpty);
    } finally {
      service.close();
    }
  });
  for (final mode in ['late-cancel', 'oversized', 'bad-digest']) {
    test('metadata stream $mode cannot publish release checksums', () async {
      final token = AppUpdateCancellation();
      final sums = utf8.encode('$_hash  triomi-android.apk\n');
      final release = _parse(
        _release(
          assets: [
            _asset('triomi-android.apk'),
            _asset(
              'SHA256SUMS.txt',
              bytes: sums.length,
              digest: mode == 'bad-digest'
                  ? _otherHash
                  : sha256.convert(sums).toString(),
            ),
          ],
        ),
      );
      Stream<Uint8List> stream() async* {
        yield Uint8List.fromList(
          mode == 'oversized' ? List.filled(65537, 32) : sums,
        );
        if (mode == 'late-cancel') token.cancel();
      }

      final service = AppUpdateService(
        dio: Dio()
          ..httpClientAdapter = _Adapter(
            (options, _) => ResponseBody(stream(), 200),
          ),
      );
      try {
        await expectLater(
          service.releaseChecksums(release, token),
          mode == 'late-cancel'
              ? throwsA(isA<AppUpdateCancelled>())
              : throwsFormatException,
        );
      } finally {
        service.close();
      }
    });
  }
  for (final scenario in [
    'valid',
    'pe-version-mismatch',
    'member-hash-mismatch',
    'late-cancel',
  ]) {
    test(
      'official Windows download $scenario consumes verified manifest, ZIP members and native version',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'triomi-github-update-',
        );
        const channel = MethodChannel('triomi/platform');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final executable = [1, 2, 3], dll = [4, 5, 6];
        final token = AppUpdateCancellation();
        final archive = zip.Archive()
          ..addFile(
            zip.ArchiveFile('triomi.exe', executable.length, executable),
          )
          ..addFile(zip.ArchiveFile('flutter_windows.dll', dll.length, dll));
        final bundle = zip.ZipEncoder().encode(archive);
        final zipHash = sha256.convert(bundle).toString();
        final manifest = utf8.encode(
          jsonEncode({
            'platform': 'windows',
            'packageName': 'io.github.hyperionhxh.triomi',
            'versionCode': 156,
            'version': '0.1.0',
            'sha256': zipHash,
            'files': {
              'triomi.exe': {
                'size': executable.length,
                'sha256': sha256.convert(executable).toString(),
              },
              'flutter_windows.dll': {
                'size': dll.length,
                'sha256': scenario == 'member-hash-mismatch'
                    ? _otherHash
                    : sha256.convert(dll).toString(),
              },
            },
          }),
        );
        final manifestHash = sha256.convert(manifest).toString();
        final sums = utf8.encode(
          '$zipHash  triomi-windows.zip\n$manifestHash  triomi-windows.update.json\n',
        );
        final payloads = {
          'triomi-windows.zip': bundle,
          'triomi-windows.update.json': manifest,
          'SHA256SUMS.txt': sums,
        };
        final release = _parse(
          _release(
            assets: payloads.entries
                .map(
                  (entry) => _asset(
                    entry.key,
                    bytes: entry.value.length,
                    digest: sha256.convert(entry.value).toString(),
                  ),
                )
                .toList(),
          ),
        );
        final adapter = _Adapter(
          (options, _) => ResponseBody.fromBytes(
            payloads[options.uri.pathSegments.last]!,
            200,
          ),
        );
        final service = AppUpdateService(
          dio: Dio()..httpClientAdapter = adapter,
          windowsUpdateRoot: Directory('${directory.path}/stage'),
        );
        final stages = <String>[];
        service.onProgress = (progress) {
          if (stages.isEmpty || stages.last != progress.phase) {
            stages.add(progress.phase);
          }
        };
        try {
          final current = File('${directory.path}/installed.exe');
          await current.writeAsBytes([7, 8, 9]);
          messenger.setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'inspectAppUpdateInfo') {
              // Metadata-only native boundary; actual ZIP bytes, all member hashes,
              // CRCs, manifest identity and actual staged EXE are consumed above it.
              expect(
                await File((call.arguments as Map)['path'] as String)
                    .readAsBytes(),
                executable,
              );
              if (scenario == 'late-cancel') token.cancel();
              return {
                'versionCode': scenario == 'pe-version-mismatch' ? 155 : 156,
                'version': '0.1.0',
              };
            }
            if (call.method == 'currentAppUpdateInfo') {
              return {
                'packageName': 'io.github.hyperionhxh.triomi',
                'platform': 'windows',
                'versionCode': 155,
                'version': '0.1.0',
                'path': current.path,
              };
            }
            throw StateError('No install or execution is expected');
          });
          if (scenario == 'valid') {
            final candidate = await service.downloadRelease(release, token);
            expect(candidate.decision, 'upgrade');
            expect(candidate.offered.versionCode, 156);
            expect(candidate.signatureVerified, false);
            expect(await File(candidate.path).readAsBytes(), bundle);
            expect(
              candidate.offered.artifactSha256,
              sha256.convert(executable).toString(),
            );
            expect(adapter.requests.length, 3);
            expect(
              stages,
              containsAllInOrder([
                'metadata',
                'download',
                'copy',
                'bundle',
                'manifest',
              ]),
            );
            await service.discard(candidate);
            expect(await File(candidate.path).exists(), false);
          } else {
            await expectLater(
              service.downloadRelease(release, token),
              scenario == 'late-cancel'
                  ? throwsA(isA<AppUpdateCancelled>())
                  : throwsFormatException,
            );
            expect(
              await Directory('${directory.path}/stage').list().isEmpty,
              true,
            );
          }
        } finally {
          messenger.setMockMethodCallHandler(channel, null);
          service.close();
          await directory.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
  for (final mode in ['valid', 'cancel-before', 'cancel-during', 'changed']) {
    test(
      'Windows Explorer handoff $mode verifies real spaced path before external action',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'triomi update handoff ',
        );
        final launches = <List<String>>[];
        final service = AppUpdateService(
          launchExplorer: (arguments) async {
            launches.add(arguments);
          },
        );
        final token = AppUpdateCancellation();
        try {
          final bytes = List<int>.filled(256 * 1024, 7);
          final file = File('${directory.path}/verified bundle.zip');
          await file.writeAsBytes(bytes);
          const current = AppUpdateInfo(
            packageName: 'io.github.hyperionhxh.triomi',
            versionCode: 155,
            version: '0.1.0',
            sha256: _hash,
            platform: 'windows',
          );
          final offered = AppUpdateInfo(
            packageName: current.packageName,
            versionCode: 156,
            version: current.version,
            sha256: sha256.convert(bytes).toString(),
            platform: 'windows',
          );
          final candidate = AppUpdateCandidate(
            current: current,
            offered: offered,
            path: file.path,
            bytes: bytes.length,
            source: 'official fixture',
            decision: 'upgrade',
            signatureVerified: false,
          );
          if (mode == 'cancel-before') token.cancel();
          if (mode == 'cancel-during') {
            service.onProgress = (_) => token.cancel();
          }
          if (mode == 'changed') await file.writeAsBytes([1, 2, 3]);
          if (mode == 'valid') {
            await service.revealWindowsBundle(candidate, token);
            expect(launches, [
              ['/select,', await file.resolveSymbolicLinks()],
            ]);
          } else {
            await expectLater(
              service.revealWindowsBundle(candidate, token),
              mode == 'changed'
                  ? throwsFormatException
                  : throwsA(isA<AppUpdateCancelled>()),
            );
            expect(launches, isEmpty);
          }
        } finally {
          service.close();
          await directory.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
  for (final allowed in [true, false]) {
    test('redirect $allowed aborts superseded adapter request before next fetch', () async {
      final sums = utf8.encode('$_hash  triomi-android.apk\n');
      final release = _parse(
        _release(
          assets: [
            _asset('triomi-android.apk'),
            _asset(
              'SHA256SUMS.txt',
              bytes: sums.length,
              digest: sha256.convert(sums).toString(),
            ),
          ],
        ),
      );
      var aborted = false;
      final adapter = _Adapter(
        (options, count) {
          if (count == 1) {
            return ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': [
                  allowed
                      ? 'https://release-assets.githubusercontent.com/checksums'
                      : 'https://attacker.test/checksums',
                ],
              },
            );
          }
          expect(aborted, true);
          return ResponseBody.fromBytes(sums, 200);
        },
        onFetch: (options, cancelFuture) {
          if (options.uri.host == 'github.com') {
            cancelFuture?.then((_) {
              aborted = true;
            });
          }
        },
      );
      final service = AppUpdateService(dio: Dio()..httpClientAdapter = adapter);
      try {
        if (allowed) {
          expect(
            (await service.releaseChecksums(
              release,
              AppUpdateCancellation(),
            ))['triomi-android.apk'],
            _hash,
          );
        } else {
          await expectLater(
            service.releaseChecksums(release, AppUpdateCancellation()),
            throwsFormatException,
          );
          expect(adapter.requests.length, 1);
        }
        expect(aborted, true);
      } finally {
        service.close();
      }
    });
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond, {this.onFetch});
  final ResponseBody Function(RequestOptions, int) respond;
  final requests = <Uri>[];
  final void Function(RequestOptions, Future<void>?)? onFetch;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    onFetch?.call(options, cancelFuture);
    expect(options.followRedirects, false);
    expect(
      options.headers.keys.any(
        (key) => [
          'authorization',
          'cookie',
          'proxy-authorization',
        ].contains(key.toLowerCase()),
      ),
      false,
    );
    return respond(options, requests.length);
  }

  @override
  void close({bool force = false}) {}
}
