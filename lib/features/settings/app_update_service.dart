import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' hide ZLibDecoder, ZLibEncoder;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const appUpdateProductionSigner =
    '9b474750e4c2af300eb5a0207bfb9e477030f22bb390a7da7a40d3854edec077';
const appUpdateMaxBytes = 512 * 1024 * 1024;
final _hashPattern = RegExp(r'^[a-f0-9]{64}$');

class AppUpdateCancelled implements Exception {
  const AppUpdateCancelled();
  @override
  String toString() => '更新操作已取消；未启动安装器';
}

class AppUpdateCancellation {
  bool _cancelled = false;
  File? _marker;
  final _requests = <CancelToken>{};
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    try {
      _marker?.writeAsStringSync('cancel');
    } on FileSystemException {
      /* The operation may have just finished cleanup. */
    }
  }

  void check() {
    if (_cancelled) throw const AppUpdateCancelled();
  }
}

class AppUpdateProgress {
  const AppUpdateProgress(this.phase, this.bytes, [this.total]);
  final String phase;
  final int bytes;
  final int? total;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.packageName,
    required this.versionCode,
    required this.version,
    required this.sha256,
    this.signerSha256,
    required this.platform,
    this.artifactSha256,
  });
  final String packageName, version, sha256, platform;
  final String? signerSha256;
  final String? artifactSha256;
  final int versionCode;
  factory AppUpdateInfo.fromMap(Map<Object?, Object?> map) => AppUpdateInfo(
    packageName: map['packageName'] as String,
    versionCode: map['versionCode'] as int,
    version: map['version'] as String,
    sha256: map['sha256'] as String,
    signerSha256: map['signerSha256'] as String?,
    platform: map['platform'] as String,
    artifactSha256: map['artifactSha256'] as String?,
  );
}

/// The same no-bypass policy used again by Android immediately before handoff.
String appUpdateDecision(
  AppUpdateInfo current,
  AppUpdateInfo offered, {
  required bool signatureVerified,
}) {
  if (!_hashPattern.hasMatch(current.sha256) ||
      !_hashPattern.hasMatch(offered.sha256)) {
    throw const FormatException('SHA-256 必须是完整 64 位小写散列');
  }
  if (offered.artifactSha256 != null &&
      !_hashPattern.hasMatch(offered.artifactSha256!)) {
    throw const FormatException('EXE SHA-256 必须是完整散列');
  }
  if (current.platform != offered.platform ||
      current.packageName != offered.packageName) {
    return 'wrongPackage';
  }
  if (current.platform == 'android' &&
      (!signatureVerified ||
          current.signerSha256 == null ||
          !_hashPattern.hasMatch(current.signerSha256!) ||
          current.signerSha256 != offered.signerSha256)) {
    return 'wrongSigner';
  }
  if (offered.versionCode < current.versionCode) return 'downgrade';
  if (offered.versionCode == current.versionCode) {
    return (offered.artifactSha256 ?? offered.sha256) == current.sha256
        ? 'alreadyInstalled'
        : 'sameVersionChanged';
  }
  return 'upgrade';
}

class AppUpdateCandidate {
  const AppUpdateCandidate({
    required this.current,
    required this.offered,
    required this.path,
    required this.bytes,
    required this.source,
    required this.decision,
    required this.signatureVerified,
    this.manifestPath,
  });
  final AppUpdateInfo current, offered;
  final String path, source, decision;
  final String? manifestPath;
  final int bytes;
  final bool signatureVerified;
  bool get canInstall => decision == 'upgrade';
}

Uri _updateHttps(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('只接受无用户名/密码及片段的 HTTPS 地址');
  }
  return uri;
}

const appUpdateRepository = 'HyperionHXH/triomi';
const appUpdateReleasesApi =
    'https://api.github.com/repos/$appUpdateRepository/releases?per_page=30';

/// Release tags carry the same build number as Android and the Windows PE.
/// Unknown tag conventions are deliberately not guessed from release titles.
int? appUpdateReleaseCode(String tag) {
  final match = RegExp(r'^v?(\d+\.\d+\.\d+)-test\.([1-9]\d*)$').firstMatch(tag);
  final code = match == null ? null : int.tryParse(match[2]!);
  return code != null && code <= 65535 ? code : null;
}

class AppUpdateReleaseAsset {
  const AppUpdateReleaseAsset._(this.name, this.url, this.bytes, this.digest);
  final String name;
  final Uri url;
  final int bytes;
  final String? digest;
}

class AppUpdateRelease {
  const AppUpdateRelease._({
    required this.tag,
    required this.name,
    required this.version,
    required this.versionCode,
    required this.notes,
    required this.prerelease,
    required this.publishedAt,
    required this.assets,
  });
  final String tag, name, version, notes, publishedAt;
  final int versionCode;
  final bool prerelease;
  final Map<String, AppUpdateReleaseAsset> assets;
  bool isNewerThan(AppUpdateInfo installed) =>
      versionCode > installed.versionCode;

  static List<AppUpdateRelease> parse(List<int> bytes) {
    if (bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('GitHub 版本列表超过 4 MiB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! List || raw.length > 30) {
      throw const FormatException('GitHub 版本列表格式无效');
    }
    final releases = <AppUpdateRelease>[];
    final codes = <int>{};
    for (final item in raw) {
      if (item is! Map ||
          item['draft'] != false ||
          item['tag_name'] is! String) {
        continue;
      }
      final tag = item['tag_name'] as String;
      final code = appUpdateReleaseCode(tag);
      if (code == null) continue;
      if (!codes.add(code)) throw const FormatException('发布版本的构建号重复');
      final assets = <String, AppUpdateReleaseAsset>{};
      if (item['assets'] is! List || (item['assets'] as List).length > 30) {
        throw const FormatException('GitHub 发布资产格式无效');
      }
      for (final entry in item['assets'] as List) {
        if (entry is! Map || entry['name'] is! String) continue;
        final name = entry['name'] as String;
        if (!const {
          'triomi-android.apk',
          'triomi-windows.zip',
          'triomi-windows.msi',
          'triomi-windows.update.json',
          'SHA256SUMS.txt',
        }.contains(name)) {
          continue;
        }
        if (entry['state'] != 'uploaded' ||
            entry['size'] is! int ||
            (entry['size'] as int) < 1 ||
            (entry['size'] as int) > appUpdateMaxBytes ||
            entry['browser_download_url'] is! String ||
            assets.containsKey(name)) {
          throw const FormatException('GitHub 发布资产不完整或重复');
        }
        final url = _updateHttps(entry['browser_download_url'] as String);
        if (url.host != 'github.com' ||
            url.port != 443 ||
            url.hasQuery ||
            url.path != '/$appUpdateRepository/releases/download/$tag/$name') {
          throw const FormatException('发布资产不属于官方仓库及当前版本');
        }
        final digest = entry['digest'];
        if (digest != null &&
            (digest is! String ||
                !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest))) {
          throw const FormatException('GitHub 资产摘要无效');
        }
        assets[name] = AppUpdateReleaseAsset._(
          name,
          url,
          entry['size'] as int,
          digest == null ? null : (digest as String).substring(7),
        );
      }
      final notes = item['body'] is String ? item['body'] as String : '';
      final name = item['name'] is String ? item['name'] as String : tag;
      if (notes.length > 128 * 1024 || name.length > 1024) {
        throw const FormatException('发布说明过长');
      }
      releases.add(
        AppUpdateRelease._(
          tag: tag,
          name: name,
          version: tag.replaceFirst(RegExp(r'^v'), '').split('-test.').first,
          versionCode: code,
          notes: notes,
          prerelease: item['prerelease'] == true,
          publishedAt: item['published_at'] is String
              ? item['published_at'] as String
              : '',
          assets: Map.unmodifiable(assets),
        ),
      );
    }
    releases.sort((a, b) => b.versionCode.compareTo(a.versionCode));
    return releases;
  }
}

/// Finds the newest installable release for this platform without downloading
/// or installing anything during the startup check.
AppUpdateRelease? newestAppUpdateRelease(
  AppUpdateInfo installed,
  List<AppUpdateRelease> releases,
) {
  final asset = switch (installed.platform) {
    'android' => 'triomi-android.apk',
    'windows' => 'triomi-windows.zip',
    _ => null,
  };
  if (asset == null) return null;
  AppUpdateRelease? best;
  for (final release in releases) {
    if (!release.isNewerThan(installed) ||
        !release.assets.containsKey(asset) ||
        !release.assets.containsKey('SHA256SUMS.txt') ||
        (installed.platform == 'windows' &&
            !release.assets.containsKey('triomi-windows.update.json'))) {
      continue;
    }
    if (best == null || release.versionCode > best.versionCode) best = release;
  }
  return best;
}

/// Only GitHub's official asset CDN is trusted across redirects. No wildcard
/// suffixes, arbitrary ports, credentials, fragments or HTTPS downgrades.
bool appUpdateTrustedRedirect(Uri uri, Uri original) =>
    uri.scheme == 'https' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment &&
    (const {
          'release-assets.githubusercontent.com',
          'objects.githubusercontent.com',
          'github-releases.githubusercontent.com',
        }.contains(uri.host) ||
        (uri.host == 'github.com' &&
            uri.path == original.path &&
            !uri.hasQuery));

Map<String, String> appUpdateChecksums(List<int> bytes) {
  if (bytes.length > 64 * 1024) throw const FormatException('校验文件超过 64 KiB');
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
    if (line.trim().isEmpty) continue;
    final match = RegExp(r'^([a-f0-9]{64}) [ *]([^/\\\r\n]+)$')
        .firstMatch(line);
    if (match == null || result.containsKey(match[2])) {
      throw const FormatException('SHA256SUMS 格式无效或名称重复');
    }
    result[match[2]!] = match[1]!;
  }
  return result;
}

/// Private bounded copy: cancellation and length/hash mismatches remove the partial file.
Future<String> stageAppUpdateBytes(
  Stream<List<int>> input,
  File destination, {
  required AppUpdateCancellation cancellation,
  String? expectedHash,
  int? expectedBytes,
  void Function(AppUpdateProgress)? onProgress,
  String phase = 'copy',
}) async {
  if (expectedHash != null && !_hashPattern.hasMatch(expectedHash)) {
    throw const FormatException('无效的完整 SHA-256');
  }
  final output = destination.openWrite();
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  var size = 0;
  var closed = false;
  try {
    cancellation.check();
    await for (final bytes in input) {
      cancellation.check();
      size += bytes.length;
      if (size > appUpdateMaxBytes) {
        throw const FormatException('更新文件超过 512 MiB');
      }
      output.add(bytes);
      await output.flush();
      hash.add(bytes);
      onProgress?.call(AppUpdateProgress(phase, size, expectedBytes));
    }
    await output.flush();
    await output.close();
    closed = true;
    hash.close();
    cancellation.check();
    if (size == 0 || (expectedBytes != null && size != expectedBytes)) {
      throw const FormatException('更新文件为空或被截断');
    }
    if (expectedHash != null && digest.value.toString() != expectedHash) {
      throw const FormatException('更新文件 SHA-256 不符');
    }
    return digest.value.toString();
  } catch (_) {
    if (!closed) await output.close();
    if (await destination.exists()) await destination.delete();
    cancellation.check();
    rethrow;
  }
}

class AppUpdateService {
  AppUpdateService({
    Dio? dio,
    this.windowsUpdateRoot,
    Future<void> Function(List<String>)? launchExplorer,
  }) : _launchExplorer = launchExplorer ?? _startExplorer,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 40),
               followRedirects: false,
               maxRedirects: 0,
             ),
           ) {
    // This client is updater-owned. Never inherit a source login/cookie jar.
    _dio.options.headers.clear();
    _dio.interceptors.clear();
    _dio.options.queryParameters.clear();
    _dio.options.extra.clear();
    _dio.options.connectTimeout = const Duration(seconds: 20);
    _dio.options.receiveTimeout = const Duration(seconds: 40);
  }
  static const _native = MethodChannel('triomi/app-update');
  final Dio _dio;
  final Future<void> Function(List<String>) _launchExplorer;
  static Future<void> _startExplorer(List<String> arguments) async {
    await Process.start('explorer.exe', arguments);
  }

  /// Explicit owned root for desktop staging (production defaults to support).
  final Directory? windowsUpdateRoot;
  void Function(AppUpdateProgress)? onProgress;

  void attachProgress() {
    if (!Platform.isAndroid) return;
    _native.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is Map) {
        final raw = call.arguments as Map;
        onProgress?.call(
          AppUpdateProgress(
            raw['phase'] as String,
            raw['bytes'] as int,
            raw['total'] as int?,
          ),
        );
      }
    });
  }

  void close() {
    if (Platform.isAndroid) _native.setMethodCallHandler(null);
    _dio.close(force: true);
  }

  Future<void> cancel(AppUpdateCancellation token) async {
    token.cancel();
    if (Platform.isAndroid) await _native.invokeMethod<Object?>('cancel');
  }

  Future<AppUpdateInfo> current() async {
    if (Platform.isAndroid) {
      return AppUpdateInfo.fromMap(
        (await _native.invokeMethod<Map<Object?, Object?>>('current'))!,
      );
    }
    if (!Platform.isWindows) throw UnsupportedError('当前平台没有受支持的应用更新流程');
    final map = (await const MethodChannel('triomi/platform')
        .invokeMethod<Map<Object?, Object?>>('currentAppUpdateInfo'))!;
    final file = await _regular(map['path'] as String);
    return AppUpdateInfo.fromMap({
      ...map,
      'sha256': (await sha256.bind(file.openRead()).first).toString(),
    });
  }

  Future<AppUpdateCandidate?> pickApk(AppUpdateCancellation token) async {
    token.check();
    final raw = await _native.invokeMethod<Map<Object?, Object?>>('pickApk');
    if (raw == null) {
      token.check();
      return null;
    }
    final candidate = _candidate(raw);
    if (token.cancelled) {
      await discard(candidate);
      token.check();
    }
    return candidate;
  }

  AppUpdateCandidate _candidate(Map<Object?, Object?> raw) {
    final installed = AppUpdateInfo.fromMap(
      (raw['current'] as Map).cast<Object?, Object?>(),
    );
    final offered = AppUpdateInfo.fromMap({...raw, 'platform': 'android'});
    final verified = raw['signatureVerified'] == true;
    final decision = appUpdateDecision(
      installed,
      offered,
      signatureVerified: verified,
    );
    if (decision != raw['decision']) {
      throw const FormatException('原生与页面的升级策略结果不一致');
    }
    return AppUpdateCandidate(
      current: installed,
      offered: offered,
      path: raw['path'] as String,
      bytes: raw['bytes'] as int,
      source: raw['source'] as String,
      decision: decision,
      signatureVerified: verified,
    );
  }

  Future<List<AppUpdateRelease>> releases(AppUpdateCancellation token) async =>
      AppUpdateRelease.parse(
        await _readBounded(
          Uri.parse(appUpdateReleasesApi),
          token,
          4 * 1024 * 1024,
        ),
      );

  Future<List<int>> _readBounded(
    Uri uri,
    AppUpdateCancellation token,
    int limit, {
    AppUpdateReleaseAsset? asset,
  }) async {
    final body = await _request(uri, token, officialAsset: asset != null);
    final bytes = <int>[];
    try {
      await for (final chunk in body.stream) {
        token.check();
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('更新元数据超过大小限制');
        }
        bytes.addAll(chunk);
      }
    } on DioException {
      token.check();
      throw const HttpException('更新元数据传输失败；请重试');
    }
    token.check();
    if (asset != null &&
        (bytes.length != asset.bytes ||
            (asset.digest != null &&
                sha256.convert(bytes).toString() != asset.digest))) {
      throw const FormatException('发布元数据大小或 GitHub SHA-256 不符');
    }
    return bytes;
  }

  /// Resolves integrity before any payload is staged or handed to a platform.
  Future<Map<String, String>> releaseChecksums(
    AppUpdateRelease release,
    AppUpdateCancellation token,
  ) async {
    final sums = release.assets['SHA256SUMS.txt'];
    final checksums = sums == null
        ? <String, String>{}
        : appUpdateChecksums(
            await _readBounded(sums.url, token, 64 * 1024, asset: sums),
          );
    final result = <String, String>{};
    for (final asset in release.assets.values) {
      final checksum = checksums[asset.name];
      if (checksum != null &&
          asset.digest != null &&
          checksum != asset.digest) {
        throw const FormatException('SHA256SUMS 与 GitHub 资产摘要不一致');
      }
      final hash = checksum ?? asset.digest;
      if (hash != null) result[asset.name] = hash;
    }
    token.check();
    return result;
  }

  Future<AppUpdateCandidate> downloadRelease(
    AppUpdateRelease release,
    AppUpdateCancellation token,
  ) async {
    final android = Platform.isAndroid;
    if (!android && !Platform.isWindows) {
      throw UnsupportedError('仅支持 Android 和 Windows 更新');
    }
    final asset =
        release.assets[android ? 'triomi-android.apk' : 'triomi-windows.zip'];
    if (asset == null) throw const FormatException('此版本没有当前平台的完整更新包');
    onProgress?.call(const AppUpdateProgress('metadata', 0));
    final checksums = await releaseChecksums(release, token);
    String expected(AppUpdateReleaseAsset value) {
      final hash = checksums[value.name];
      if (hash == null) throw const FormatException('发布资产缺少可信传输的完整 SHA-256');
      return hash;
    }

    final hash = expected(asset);
    if (android) {
      return _downloadApk(release, asset, hash, token);
    }
    final manifestAsset = release.assets['triomi-windows.update.json'];
    if (manifestAsset == null) {
      throw const FormatException('此版本缺少 Windows 完整成员清单');
    }
    final manifestBytes = await _readBounded(
      manifestAsset.url,
      token,
      1024 * 1024,
      asset: manifestAsset,
    );
    if (sha256.convert(manifestBytes).toString() != expected(manifestAsset)) {
      throw const FormatException('Windows 清单 SHA-256 不符');
    }
    final raw = jsonDecode(utf8.decode(manifestBytes));
    if (raw is! Map ||
        raw['versionCode'] != release.versionCode ||
        raw['version'] != release.version ||
        raw['sha256'] != hash) {
      throw const FormatException('Windows 清单与 GitHub 版本或 ZIP 摘要不符');
    }
    final temporary = await Directory.systemTemp.createTemp('triomi-release-');
    try {
      final zip = File(p.join(temporary.path, 'release.zip'));
      final manifest = File(p.join(temporary.path, 'release.json'));
      await manifest.writeAsBytes(manifestBytes, flush: true);
      onProgress?.call(AppUpdateProgress('download', 0, asset.bytes));
      final body = await _request(asset.url, token, officialAsset: true);
      await stageAppUpdateBytes(
        body.stream,
        zip,
        cancellation: token,
        expectedHash: hash,
        expectedBytes: asset.bytes,
        onProgress: onProgress,
        phase: 'download',
      );
      final candidate = await stageWindowsBundle(
        zip.path,
        manifest.path,
        token,
      );
      return AppUpdateCandidate(
        current: candidate.current,
        offered: candidate.offered,
        path: candidate.path,
        bytes: candidate.bytes,
        source: '官方 GitHub $appUpdateRepository · ${release.tag}（Windows 未签名）',
        decision: candidate.decision,
        signatureVerified: candidate.signatureVerified,
        manifestPath: candidate.manifestPath,
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> revealWindowsBundle(
    AppUpdateCandidate candidate,
    AppUpdateCancellation token,
  ) async {
    token.check();
    if (!Platform.isWindows ||
        candidate.offered.platform != 'windows' ||
        !candidate.canInstall) {
      throw StateError('只能打开已核验的新版本 Windows 更新包');
    }
    final file = await _regular(candidate.path);
    token.check();
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var bytes = 0;
    try {
      await for (final chunk in file.openRead()) {
        token.check();
        bytes += chunk.length;
        if (bytes > appUpdateMaxBytes) {
          throw const FormatException('暂存 ZIP 大小超限');
        }
        hash.add(chunk);
        onProgress?.call(AppUpdateProgress('handoff', bytes, candidate.bytes));
      }
    } finally {
      hash.close();
    }
    token.check();
    if (bytes != candidate.bytes ||
        digest.value.toString() != candidate.offered.sha256) {
      throw const FormatException('暂存 ZIP 已改变，请重新下载并核验');
    }
    token.check();
    await _launchExplorer(['/select,', file.path]);
  }

  Future<ResponseBody> _request(
    Uri uri,
    AppUpdateCancellation token, {
    bool officialAsset = false,
  }) async {
    final original = uri;
    for (var redirects = 0; ; redirects++) {
      token.check();
      if (officialAsset && !appUpdateTrustedRedirect(uri, original)) {
        throw const FormatException('更新下载重定向离开 GitHub 官方资产主机');
      }
      final requestToken = CancelToken();
      token._requests.add(requestToken);
      void abortRequest() {
        token._requests.remove(requestToken);
        requestToken.cancel();
      }

      try {
        final response = await _dio.getUri<ResponseBody>(
          uri,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (status) =>
                status == 200 ||
                (officialAsset && [301, 302, 303, 307, 308].contains(status)),
            headers: const {
              'Accept-Encoding': 'identity',
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Triomi-App-Updater',
            },
          ),
          cancelToken: requestToken,
        );
        if (token.cancelled) {
          abortRequest();
          await response.data!.stream
              .listen(null, onError: (Object _) {})
              .cancel();
          token.check();
        }
        if (response.statusCode == 200) {
          final body = response.data!;
          Stream<Uint8List> chunks() async* {
            try {
              yield* body.stream;
            } finally {
              abortRequest();
            }
          }

          return ResponseBody(chunks(), body.statusCode, headers: body.headers);
        }
        // Dio's stream cancellation alone does not abort its underlying socket.
        // Abort this hop before validating/following the next location.
        abortRequest();
        await response.data!.stream
            .listen(null, onError: (Object _) {})
            .cancel();
        final location = response.headers.value('location');
        if (redirects >= 4 || location == null) {
          throw const FormatException('GitHub 下载重定向过多或缺少目标');
        }
        final next = uri.resolve(location);
        if (!appUpdateTrustedRedirect(next, original)) {
          throw const FormatException('拒绝不安全的 GitHub 下载重定向');
        }
        uri = next;
      } on DioException {
        abortRequest();
        token.check();
        // Never expose signed CDN queries, source credentials or headers.
        throw const HttpException('更新 HTTPS 请求失败、超时或被拒绝；请稍后重试（GitHub 可能限流）');
      }
    }
  }

  Future<AppUpdateCandidate> _downloadApk(
    AppUpdateRelease release,
    AppUpdateReleaseAsset asset,
    String hash,
    AppUpdateCancellation token,
  ) async {
    if (!Platform.isAndroid) throw UnsupportedError('网络 APK 仅支持 Android');
    final directory = await _native.invokeMethod<String>('stagingDirectory');
    final root = await Directory(directory!).resolveSymbolicLinks();
    final incoming = File(
      p.join(root, 'download-${DateTime.now().microsecondsSinceEpoch}.apk'),
    );
    try {
      onProgress?.call(AppUpdateProgress('download', 0, asset.bytes));
      final body = await _request(asset.url, token, officialAsset: true);
      final length = int.tryParse(
        body.headers['content-length']?.firstOrNull ?? '',
      );
      if (length != null && length != asset.bytes) {
        throw const FormatException('更新文件长度与发布资产不符');
      }
      await stageAppUpdateBytes(
        body.stream,
        incoming,
        cancellation: token,
        expectedHash: hash,
        expectedBytes: asset.bytes,
        onProgress: onProgress,
        phase: 'download',
      );
      token.check();
      onProgress?.call(const AppUpdateProgress('verify', 0));
      final raw = (await _native.invokeMethod<Map<Object?, Object?>>(
        'inspect',
        {
          'path': incoming.path,
          'sha256': hash,
          'source': '官方 GitHub $appUpdateRepository · ${release.tag}',
        },
      ))!;
      final candidate = _candidate(raw);
      if (candidate.offered.versionCode != release.versionCode ||
          candidate.offered.version != release.version) {
        await discard(candidate);
        throw const FormatException('APK 实际版本与发布版本不符');
      }
      if (token.cancelled) await discard(candidate);
      token.check();
      onProgress?.call(
        AppUpdateProgress('verified', candidate.bytes, candidate.bytes),
      );
      return candidate;
    } finally {
      if (await incoming.exists()) await incoming.delete();
    }
  }

  Future<bool> canInstall() async =>
      await _native.invokeMethod<bool>('canInstall') == true;
  Future<void> openUnknownSources() async {
    await _native.invokeMethod<Object?>('openUnknownSources');
  }

  Future<void> launchInstaller(AppUpdateCandidate candidate) async {
    if (!candidate.canInstall ||
        !candidate.signatureVerified ||
        candidate.offered.platform != 'android') {
      throw StateError('只能把已核验的新版本 Android APK 交给系统安装器');
    }
    await _native.invokeMethod<Object?>('launchInstaller', {
      'path': candidate.path,
      'sha256': candidate.offered.sha256,
      'consent': true,
    });
  }

  Future<void> discard(AppUpdateCandidate candidate) async {
    if (candidate.offered.platform == 'android') {
      if (await _native.invokeMethod<bool>('discard', {
            'path': candidate.path,
          }) !=
          true) {
        throw const FileSystemException('无法清理本次更新暂存');
      }
    } else {
      final directory = Directory(p.dirname(candidate.path));
      final root =
          windowsUpdateRoot ??
          Directory(
            p.join((await getApplicationSupportDirectory()).path, 'app-update'),
          );
      if (!RegExp(r'^bundle-[A-Za-z0-9_-]+$')
              .hasMatch(p.basename(directory.path)) ||
          await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          p.dirname(await directory.resolveSymbolicLinks()) !=
              await root.resolveSymbolicLinks()) {
        throw const FormatException('暂存清理只允许应用专用目录');
      }
      await directory.delete(recursive: true);
    }
  }

  /// Unsigned desktop transport integrity, not Android signature trust. The user
  /// supplies a trusted manifest and explicitly acknowledges that distinction.
  Future<AppUpdateCandidate> stageWindowsBundle(
    String zipPath,
    String manifestPath,
    AppUpdateCancellation token,
  ) async {
    if (!Platform.isWindows) throw UnsupportedError('桌面 ZIP 流程仅支持 Windows');
    token.check();
    final zip = await _regular(zipPath);
    token.check();
    final manifestFile = await _regular(manifestPath);
    token.check();
    if (await manifestFile.length() > 1024 * 1024) {
      throw const FormatException('桌面清单超过 1 MiB');
    }
    token.check();
    final raw = jsonDecode(await manifestFile.readAsString());
    token.check();
    if (raw is! Map ||
        raw['platform'] != 'windows' ||
        raw['packageName'] != 'io.github.hyperionhxh.triomi' ||
        raw['versionCode'] is! int ||
        (raw['versionCode'] as int) < 1 ||
        raw['version'] is! String ||
        (raw['version'] as String).isEmpty ||
        (raw['version'] as String).length > 256 ||
        raw['sha256'] is! String ||
        !_hashPattern.hasMatch(raw['sha256'] as String) ||
        raw['files'] is! Map) {
      throw const FormatException(
        '桌面清单需要 platform:windows、正确 packageName、versionCode、version、ZIP sha256 及 files',
      );
    }
    final root =
        windowsUpdateRoot ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'app-update'),
        );
    token.check();
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        p.dirname(await root.resolveSymbolicLinks()) !=
            await root.parent.resolveSymbolicLinks()) {
      throw const FormatException('更新目录不允许符号链接或路径别名');
    }
    token.check();
    final directory = await Directory(await root.resolveSymbolicLinks())
        .createTemp('bundle-');
    final staged = File(p.join(directory.path, 'verified-bundle.zip'));
    final marker = File(p.join(directory.path, 'cancel'));
    token._marker = marker;
    try {
      token.check();
      final hash = await stageAppUpdateBytes(
        zip.openRead(),
        staged,
        cancellation: token,
        expectedHash: raw['sha256'] as String,
        expectedBytes: await zip.length(),
        onProgress: onProgress,
      );
      token.check();
      onProgress?.call(const AppUpdateProgress('bundle', 0));
      final stagedPath = staged.path, markerPath = marker.path;
      final memberHashes = raw['files'] as Map;
      token.check();
      final executablePath = await Isolate.run(
        () => verifyWindowsUpdateZip(stagedPath, memberHashes, markerPath),
      );
      token.check();
      final executableInfo = (await const MethodChannel('triomi/platform')
          .invokeMethod<Map<Object?, Object?>>('inspectAppUpdateInfo', {
            'path': executablePath,
          }))!;
      token.check();
      final executableHash =
          (await sha256.bind(File(executablePath).openRead()).first).toString();
      token.check();
      await File(executablePath).delete();
      token.check();
      if (executableInfo['versionCode'] != raw['versionCode'] ||
          executableInfo['version'] != raw['version']) {
        throw const FormatException('桌面 EXE 实际版本与清单不符');
      }
      token.check();
      final installed = await current();
      token.check();
      final offered = AppUpdateInfo(
        packageName: raw['packageName'] as String,
        versionCode: raw['versionCode'] as int,
        version: raw['version'] as String,
        sha256: hash,
        artifactSha256: executableHash,
        platform: 'windows',
      );
      final savedManifest = File(
        p.join(directory.path, 'verified-manifest.json'),
      );
      await savedManifest.writeAsString(jsonEncode(raw), flush: true);
      onProgress?.call(const AppUpdateProgress('manifest', 0));
      token.check();
      final bytes = await staged.length();
      token.check();
      return AppUpdateCandidate(
        current: installed,
        offered: offered,
        path: staged.path,
        bytes: bytes,
        source: '用户指定桌面 ZIP 与外部完整性清单（未经发布者签名）',
        decision: appUpdateDecision(
          installed,
          offered,
          signatureVerified: false,
        ),
        signatureVerified: false,
        manifestPath: savedManifest.path,
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      token._marker = null;
    }
  }
}

Future<File> _regular(String path) async {
  final absolute = p.absolute(path);
  for (var part = absolute; ; part = p.dirname(part)) {
    if (await FileSystemEntity.type(part, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('更新输入不允许符号链接');
    }
    if (p.dirname(part) == part) break;
  }
  if (await FileSystemEntity.type(absolute, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('必须选择现存普通文件');
  }
  return File(await File(absolute).resolveSymbolicLinks());
}

/// Static desktop ZIP byte verification; used by the real staging flow before
/// querying PE resources. No member names become filesystem paths.
Future<String> verifyWindowsUpdateZip(
  String zipPath,
  Map<Object?, Object?> files,
  String markerPath,
) async {
  void checkCancelled() {
    if (File(markerPath).existsSync()) throw const AppUpdateCancelled();
  }

  checkCancelled();
  final handle = await File(zipPath).open();
  try {
    final length = await handle.length();
    checkCancelled();
    final start = length > 65557 ? length - 65557 : 0;
    await handle.setPosition(start);
    final bytes = await handle.read(length - start);
    checkCancelled();
    final data = ByteData.sublistView(bytes);
    var offset = -1;
    for (var i = bytes.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + data.getUint16(i + 20, Endian.little) == bytes.length) {
        offset = i;
        break;
      }
    }
    if (offset < 0 ||
        data.getUint16(offset + 4, Endian.little) != 0 ||
        data.getUint16(offset + 6, Endian.little) != 0 ||
        data.getUint16(offset + 10, Endian.little) > 10000 ||
        data.getUint16(offset + 10, Endian.little) !=
            data.getUint16(offset + 8, Endian.little) ||
        data.getUint32(offset + 12, Endian.little) > 8 * 1024 * 1024 ||
        data.getUint32(offset + 16, Endian.little) +
                data.getUint32(offset + 12, Endian.little) !=
            start + offset) {
      throw const FormatException('桌面 ZIP 目录无效、分卷、ZIP64 或超限');
    }
  } finally {
    await handle.close();
  }
  checkCancelled();
  final input = InputFileStream(zipPath);
  final temporary = await Directory(p.dirname(zipPath)).createTemp('verify-');
  final executable = File(p.join(p.dirname(zipPath), 'candidate.pe'));
  var complete = false;
  try {
    checkCancelled();
    final directory = ZipDirectory()..read(input);
    final names = <String>{}, folded = <String>{}, actual = <String>{};
    var total = 0, actualTotal = 0;
    if (directory.fileHeaders.length > 10000 ||
        files.length > 10000 ||
        directory.fileHeaders.length !=
            directory.totalCentralDirectoryEntries) {
      throw const FormatException('桌面 ZIP 成员过多或目录不一致');
    }
    for (final header in directory.fileHeaders) {
      checkCancelled();
      final name = header.filename;
      final mode = (header.externalFileAttributes >> 16) & 0xf000;
      if (header.file == null ||
          header.file!.filename != name ||
          !names.add(name) ||
          !folded.add(name.toLowerCase()) ||
          name.contains('\\') ||
          name.startsWith('/') ||
          name.contains(':') ||
          name
              .split('/')
              .any(
                (part) =>
                    part == '..' ||
                    part == '.' ||
                    part.endsWith('.') ||
                    part.endsWith(' '),
              ) ||
          (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          ![0, 8].contains(header.compressionMethod) ||
          header.file!.flags != header.generalPurposeBitFlag) {
        throw const FormatException('桌面 ZIP 存在重复、路径别名、加密或非法文件');
      }
      if (name.endsWith('/')) continue;
      actual.add(name);
      total += header.uncompressedSize;
      if (header.uncompressedSize < 0 ||
          header.uncompressedSize > 128 * 1024 * 1024 ||
          total > 1024 * 1024 * 1024) {
        throw const FormatException('桌面 ZIP 展开内容超限');
      }
      final metadata = files[name];
      if (metadata is! Map ||
          metadata['size'] != header.uncompressedSize ||
          metadata['sha256'] is! String ||
          !_hashPattern.hasMatch(metadata['sha256'] as String)) {
        throw const FormatException('桌面文件清单缺失或无效');
      }
      final compressed = header.file!.getStream(decompress: false);
      Stream<List<int>> chunks() async* {
        while (!compressed.isEOS) {
          checkCancelled();
          yield compressed
              .readBytes(compressed.length < 65536 ? compressed.length : 65536)
              .toUint8List();
          await Future<void>.delayed(Duration.zero);
        }
      }

      final decoded = header.compressionMethod == 8
          ? ZLibDecoder(raw: true).bind(chunks())
          : chunks();
      final file = File(p.join(temporary.path, '${names.length}.entry'));
      final output = file.openWrite();
      var size = 0, crc = 0;
      final digest = _DigestSink();
      final hash = sha256.startChunkedConversion(digest);
      try {
        await for (final chunk in decoded) {
          checkCancelled();
          size += chunk.length;
          actualTotal += chunk.length;
          if (size > header.uncompressedSize ||
              size > 128 * 1024 * 1024 ||
              actualTotal > 1024 * 1024 * 1024) {
            throw const FormatException('桌面 ZIP 实际解压输出超过声明或限制');
          }
          crc = getCrc32(chunk, crc);
          hash.add(chunk);
          output.add(chunk);
          await output.flush();
        }
      } finally {
        hash.close();
        await output.close();
      }
      checkCancelled();
      if (size != metadata['size'] ||
          crc != header.crc32 ||
          digest.value.toString() != metadata['sha256']) {
        throw const FormatException('桌面 ZIP 文件被截断或 CRC/SHA-256 不符');
      }
      if (name == 'triomi.exe') {
        await file.copy(executable.path);
        checkCancelled();
      }
      await file.delete();
    }
    if (actual.length != files.length ||
        !actual.contains('triomi.exe') ||
        !actual.contains('flutter_windows.dll') ||
        !actual.containsAll(files.keys.cast<String>())) {
      throw const FormatException('桌面 ZIP 不是完整的 Triomi 文件包或清单不匹配');
    }
    checkCancelled();
    complete = true;
    return executable.path;
  } finally {
    await input.close();
    await temporary.delete(recursive: true);
    if (!complete && await executable.exists()) await executable.delete();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
