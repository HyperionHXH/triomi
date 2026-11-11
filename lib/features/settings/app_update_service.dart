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

import '../../core/source/system_proxy_adapter.dart';
import '../../core/storage/preferences.dart';
import 'windows_update_storage.dart';

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
  final _streamCancellations = <void Function()>{};
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    for (final cancelStream in _streamCancellations.toList()) {
      cancelStream();
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
    this.windowsRevision = 0,
    this.iosRevision = 0,
  });
  final String packageName, version, sha256, platform;
  final String? signerSha256;
  final String? artifactSha256;
  final int versionCode;
  final int windowsRevision;
  final int iosRevision;
  factory AppUpdateInfo.fromMap(Map<Object?, Object?> map) => AppUpdateInfo(
    packageName: map['packageName'] as String,
    versionCode: map['versionCode'] as int,
    version: map['version'] as String,
    sha256: map['sha256'] as String,
    signerSha256: map['signerSha256'] as String?,
    platform: map['platform'] as String,
    artifactSha256: map['artifactSha256'] as String?,
    windowsRevision: map['windowsRevision'] is int
        ? map['windowsRevision'] as int
        : 0,
    iosRevision: map['iosRevision'] is int ? map['iosRevision'] as int : 0,
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
  final currentVersion = _AppUpdateVersion.parse(current.version);
  final offeredVersion = _AppUpdateVersion.parse(offered.version);
  if (currentVersion == null || offeredVersion == null) {
    throw const FormatException('应用版本必须是受支持的语义版本');
  }
  if (offeredVersion.compareVersion(currentVersion) < 0) return 'downgrade';
  if (offered.versionCode < current.versionCode) return 'downgrade';
  if (current.platform == 'ios' &&
      offered.versionCode == current.versionCode &&
      offeredVersion.compareVersion(currentVersion) == 0) {
    if (offered.iosRevision < current.iosRevision) return 'downgrade';
    if (offered.iosRevision > current.iosRevision) return 'upgrade';
    return 'alreadyInstalled';
  }
  if (current.platform == 'windows' &&
      offered.versionCode == current.versionCode &&
      offeredVersion.compareVersion(currentVersion) == 0) {
    if (offered.windowsRevision < current.windowsRevision) return 'downgrade';
    if (offered.windowsRevision > current.windowsRevision) return 'upgrade';
  }
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

/// Bytes in explicit updater-owned roots; protected bytes are never clearable.
class AppUpdateStorageInfo {
  const AppUpdateStorageInfo({
    this.incomingBytes = 0,
    this.installBytes = 0,
    this.legacyBytes = 0,
    this.reclaimableBytes = 0,
    this.protectedBytes = 0,
    this.removedBytes = 0,
    this.skippedFiles = 0,
  });
  factory AppUpdateStorageInfo.fromMap(Map<Object?, Object?> map) =>
      AppUpdateStorageInfo(
        incomingBytes: map['incomingBytes'] as int,
        installBytes: map['installBytes'] as int,
        legacyBytes: map['legacyBytes'] as int,
        reclaimableBytes: map['reclaimableBytes'] as int,
        protectedBytes: map['protectedBytes'] as int,
        removedBytes: map['removedBytes'] as int,
        skippedFiles: map['skippedFiles'] as int,
      );
  final int incomingBytes, installBytes, legacyBytes;
  final int reclaimableBytes, protectedBytes, removedBytes, skippedFiles;
  int get totalBytes => incomingBytes + installBytes + legacyBytes;
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

/// Stable tags advertise a semantic version, never an invented package build.
/// Historical test tags additionally advertise the exact Android/Windows build.
final _releaseTagPattern = RegExp(
  r'^v?(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})(?:-test\.([1-9]\d{0,4}))?$',
);

class _AppUpdateVersion {
  const _AppUpdateVersion(this.major, this.minor, this.patch, this.build);
  final int major, minor, patch;
  final int? build;
  String get version => '$major.$minor.$patch';
  String get identity => '$version${build == null ? '' : '-test.$build'}';

  static _AppUpdateVersion? parse(String value) {
    final match = _releaseTagPattern.firstMatch(value);
    if (match == null || match.end != value.length) return null;
    final major = int.parse(match[1]!);
    final minor = int.parse(match[2]!);
    final patch = int.parse(match[3]!);
    final build = match[4] == null ? null : int.parse(match[4]!);
    // Windows PE version components and historical builds are unsigned WORDs.
    if (major > 65535 ||
        minor > 65535 ||
        patch > 65535 ||
        (build != null && build > 65535)) {
      return null;
    }
    return _AppUpdateVersion(major, minor, patch, build);
  }

  int compareVersion(_AppUpdateVersion other) {
    final majorOrder = major.compareTo(other.major);
    if (majorOrder != 0) return majorOrder;
    final minorOrder = minor.compareTo(other.minor);
    return minorOrder != 0 ? minorOrder : patch.compareTo(other.patch);
  }

  int compareTo(_AppUpdateVersion other) {
    final versionOrder = compareVersion(other);
    if (versionOrder != 0) return versionOrder;
    if (build == null) return other.build == null ? 0 : 1;
    if (other.build == null) return -1;
    return build!.compareTo(other.build!);
  }
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
    required this._version,
    required this.notes,
    required this.prerelease,
    required this.publishedAt,
    required this.assets,
    this.windowsRevision,
    this.windowsBuild,
    this.iosRevision,
    this.iosBuild,
    this.iosOnly = false,
  });
  final String tag, name, notes, publishedAt;
  final _AppUpdateVersion _version;
  String get version => _version.version;
  int? get advertisedBuild => iosBuild ?? _version.build;
  String get identity =>
      '${_version.identity}${windowsRevision == null ? '' : '-windows.$windowsRevision'}'
      '${iosRevision == null ? '' : '-ios.${iosBuild ?? 0}-r$iosRevision'}';
  final int? windowsRevision, windowsBuild;
  final int? iosRevision, iosBuild;
  final bool iosOnly;
  String get versionLabel =>
      '$version${advertisedBuild == null ? '' : ' · 构建 $advertisedBuild'}'
      '${windowsRevision == null ? '' : ' · Windows 修订 $windowsRevision'}'
      '${iosRevision == null ? '' : ' · iOS 修订 $iosRevision'}';
  AppUpdateRelease withWindowsManifest(int revision, int build) =>
      AppUpdateRelease._(
        tag: tag,
        name: name,
        version: _version,
        notes: notes,
        prerelease: prerelease,
        publishedAt: publishedAt,
        assets: assets,
        windowsRevision: revision,
        windowsBuild: build,
      );
  final bool prerelease;
  final Map<String, AppUpdateReleaseAsset> assets;
  AppUpdateRelease withIosManifest(int revision, int build) =>
      AppUpdateRelease._(
        tag: tag,
        name: name,
        version: _version,
        notes: notes,
        prerelease: prerelease,
        publishedAt: publishedAt,
        assets: assets,
        iosRevision: revision,
        iosBuild: build,
        iosOnly: iosOnly,
      );
  int compareTo(AppUpdateRelease other) {
    final order = _version.compareTo(other._version);
    if (order != 0) return order;
    final buildOrder = (iosBuild ?? 0).compareTo(other.iosBuild ?? 0);
    return buildOrder != 0
        ? buildOrder
        : (iosRevision ?? 0).compareTo(other.iosRevision ?? 0);
  }

  int? compareVersionTo(AppUpdateInfo installed) {
    final current = _AppUpdateVersion.parse(installed.version);
    return current == null ? null : _version.compareVersion(current);
  }

  bool isNewerThan(AppUpdateInfo installed) {
    if (iosOnly && installed.platform != 'ios') return false;
    final current = _AppUpdateVersion.parse(installed.version);
    if (current == null) return false;
    final order = _version.compareVersion(current);
    if (order < 0) return false;
    if (installed.platform == 'ios') {
      if (iosBuild == null || iosRevision == null) return false;
      return iosBuild! > installed.versionCode ||
          (order == 0 &&
              iosBuild == installed.versionCode &&
              iosRevision! > installed.iosRevision);
    }
    if (installed.platform == 'windows' && order == 0 && windowsBuild != null) {
      return windowsBuild! > installed.versionCode ||
          (windowsBuild == installed.versionCode &&
              (windowsRevision ?? 0) > installed.windowsRevision);
    }
    final build = advertisedBuild;
    if (build != null && build <= installed.versionCode) return false;
    return order > 0 ||
        (build != null && build > installed.versionCode) ||
        (build == null && current.build != null);
  }

  bool matchesPackage(String packageVersion, Object? packageBuild) =>
      packageVersion == version &&
      packageBuild is int &&
      packageBuild > 0 &&
      packageBuild <= 65535 &&
      (advertisedBuild == null || packageBuild == advertisedBuild);

  static List<AppUpdateRelease> parse(List<int> bytes) {
    if (bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('GitHub 版本列表超过 4 MiB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! List || raw.length > 30) {
      throw const FormatException('GitHub 版本列表格式无效');
    }
    final releases = <AppUpdateRelease>[];
    final identities = <String>{};
    final codes = <int>{};
    for (final item in raw) {
      if (item is! Map ||
          item['draft'] != false ||
          item['tag_name'] is! String) {
        continue;
      }
      final tag = item['tag_name'] as String;
      final iosTag = RegExp(
        r'^v?(\d+\.\d+\.\d+)-ios\.([1-9]\d{0,4})(?:-r([1-9]\d{0,4}))?$',
      ).firstMatch(tag);
      final version = _AppUpdateVersion.parse(iosTag?[1] ?? tag);
      if (version == null ||
          (iosTag != null &&
              (int.parse(iosTag[2]!) > 65535 ||
                  int.parse(iosTag[3] ?? '0') > 65535))) {
        continue;
      }
      if (!identities.add(iosTag == null ? version.identity : tag) ||
          (version.build != null && !codes.add(version.build!))) {
        throw const FormatException('发布版本的身份或构建号重复');
      }
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
          'Triomi-iOS-Unsigned.ipa',
          'triomi-ios.update.json',
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
          version: version,
          notes: notes,
          prerelease: version.build != null || item['prerelease'] == true,
          publishedAt: item['published_at'] is String
              ? item['published_at'] as String
              : '',
          assets: Map.unmodifiable(assets),
          iosOnly: iosTag != null,
          iosRevision: iosTag == null ? null : int.parse(iosTag[3] ?? '0'),
          iosBuild: iosTag == null ? null : int.parse(iosTag[2]!),
        ),
      );
    }
    releases.sort((a, b) => b.compareTo(a));
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
    'ios' => 'Triomi-iOS-Unsigned.ipa',
    _ => null,
  };
  if (asset == null) return null;
  AppUpdateRelease? best;
  for (final release in releases) {
    if (!release.isNewerThan(installed) ||
        !release.assets.containsKey(asset) ||
        !release.assets.containsKey('SHA256SUMS.txt') ||
        (installed.platform == 'ios' &&
            !release.assets.containsKey('triomi-ios.update.json')) ||
        (installed.platform == 'windows' &&
            !release.assets.containsKey('triomi-windows.update.json'))) {
      continue;
    }
    if (best == null || release.compareTo(best) > 0) best = release;
  }
  return best;
}

/// The preference is checked before even creating a client. Manual checks on
/// AppUpdatePage deliberately do not pass through this startup-only gate.
Future<({AppUpdateInfo current, AppUpdateRelease release})?>
checkStartupAppUpdate(
  Preferences preferences, {
  AppUpdateService Function()? createService,
}) async {
  if (!preferences.automaticAppUpdateCheckEnabled) return null;
  final service = (createService ?? AppUpdateService.new)();
  final cancellation = AppUpdateCancellation();
  final disabled = Completer<void>();
  final subscription = preferences
      .watch(Preferences.automaticAppUpdateCheckKey)
      .listen((value) {
        if (value == false) {
          cancellation.cancel();
          if (!disabled.isCompleted) disabled.complete();
        }
      });
  try {
    final current = await Future.any<AppUpdateInfo?>([
      service.current(),
      disabled.future.then<AppUpdateInfo?>((_) => null),
    ]);
    if (current == null ||
        cancellation.cancelled ||
        !preferences.automaticAppUpdateCheckEnabled) {
      return null;
    }
    final releases = await Future.any<Object?>([
      service.releases(cancellation),
      disabled.future.then<Object?>((_) => null),
    ]);
    if (!preferences.automaticAppUpdateCheckEnabled ||
        cancellation.cancelled ||
        releases == null) {
      return null;
    }
    cancellation.check();
    final releasesForPlatform = await service.resolvePlatformRevisions(
      current,
      releases as List<AppUpdateRelease>,
      cancellation,
    );
    final release = newestAppUpdateRelease(current, releasesForPlatform);
    if (!preferences.automaticAppUpdateCheckEnabled) return null;
    return release == null ? null : (current: current, release: release);
  } on AppUpdateCancelled {
    if (!cancellation.cancelled) rethrow;
    return null;
  } finally {
    try {
      await subscription.cancel();
    } finally {
      service.close();
    }
  }
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
  cancellation.check();
  final parent = destination.parent;
  final type = await FileSystemEntity.type(
    destination.path,
    followLinks: false,
  );
  if (await FileSystemEntity.type(parent.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      p.normalize(await parent.resolveSymbolicLinks()) !=
          p.normalize(parent.absolute.path) ||
      (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file)) {
    throw const FileSystemException('更新暂存只允许无路径别名的普通文件');
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
      if (expectedBytes != null && size > expectedBytes) {
        throw const FormatException('更新文件超过发布声明大小');
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
    try {
      if (!closed) await output.close();
    } finally {
      if (await FileSystemEntity.type(destination.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await destination.delete();
      }
    }
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
    if (dio == null && Platform.isWindows) {
      _dio.httpClientAdapter = SystemProxyHttpClientAdapter(
        createClient: HttpClient.new,
      );
    }
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
  void Function()? onForegroundCancelled;
  void Function({required bool installed, required bool released})?
  onInstallerFinished;
  bool _progressAttached = false;
  static AppUpdateService? _progressOwner;

  void attachProgress() {
    if (!Platform.isAndroid) return;
    _progressAttached = true;
    _progressOwner = this;
    _native.setMethodCallHandler((call) async {
      if (call.method == 'downloadForegroundCancelled') {
        onForegroundCancelled?.call();
      }
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
      if (call.method == 'installerFinished' && call.arguments is Map) {
        final raw = call.arguments as Map;
        onInstallerFinished?.call(
          installed: raw['installed'] == true,
          released: raw['released'] == true,
        );
      }
    });
  }

  void close() {
    if (_progressAttached && identical(_progressOwner, this)) {
      _progressAttached = false;
      _progressOwner = null;
      _native.setMethodCallHandler(null);
    }
    _dio.close(force: true);
  }

  Future<void> beginDownloadForeground() async {
    if (Platform.isIOS) {
      await const MethodChannel('triomi/platform').invokeMethod<bool>(
        'downloadWake',
        {'owner': 'app-update', 'active': true},
      );
      return;
    }
    if (Platform.isWindows) {
      await const MethodChannel('triomi/platform')
          .invokeMethod<bool>('beginAppUpdate');
      return;
    }
    if (!Platform.isAndroid) return;
    // Same user-visible notification permission policy as the content queue.
    await const MethodChannel('triomi/platform')
        .invokeMethod<bool>('requestNotificationPermission');
    final started = await _native.invokeMethod<bool>('beginDownloadForeground');
    if (started != true) {
      throw PlatformException(
        code: 'foreground_unavailable',
        message: '无法启动更新下载前台服务，请回到应用前台重试。',
      );
    }
  }

  Future<void> updateDownloadForeground(AppUpdateProgress progress) async {
    if (Platform.isWindows) {
      await const MethodChannel('triomi/platform')
          .invokeMethod<bool>('updateAppUpdate', {
            'progress': progress.total == null || progress.total! <= 0
                ? 0.0
                : (progress.bytes / progress.total!).clamp(0.0, 1.0),
          });
      return;
    }
    if (!Platform.isAndroid) return;
    await _native.invokeMethod<bool>('updateDownloadForeground', {
      'phase': progress.phase,
      'bytes': progress.bytes,
      'total': progress.total,
    });
  }

  Future<void> endDownloadForeground() async {
    if (Platform.isIOS) {
      await const MethodChannel('triomi/platform').invokeMethod<bool>(
        'downloadWake',
        {'owner': 'app-update', 'active': false},
      );
      return;
    }
    if (Platform.isWindows) {
      await const MethodChannel('triomi/platform')
          .invokeMethod<bool>('endAppUpdate');
      return;
    }
    if (Platform.isAndroid) {
      await _native.invokeMethod<void>('endDownloadForeground');
    }
  }

  Future<void> cancel(AppUpdateCancellation token) async {
    token.cancel();
    if (Platform.isAndroid) await _native.invokeMethod<Object?>('cancel');
  }

  Future<AppUpdateInfo> current() async {
    if (Platform.isAndroid || Platform.isIOS) {
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

  /// Pure inspection: this method never removes staging files.
  Future<AppUpdateStorageInfo> storageInfo() async {
    if (Platform.isWindows) {
      return AppUpdateStorageInfo.fromMap(
        await WindowsUpdateStorage(rootOverride: windowsUpdateRoot).inspect(),
      );
    }
    if (!Platform.isAndroid) return const AppUpdateStorageInfo();
    return AppUpdateStorageInfo.fromMap(
      (await _native.invokeMethod<Map<Object?, Object?>>('storageInfo'))!,
    );
  }

  /// Run after startup's first frame. Reaps installed/abandoned owned stages.
  /// Explicit clear additionally requests all safely reclaimable stages only.
  Future<AppUpdateStorageInfo> maintainStorage({bool clear = false}) async {
    if (Platform.isWindows) {
      return AppUpdateStorageInfo.fromMap(
        await WindowsUpdateStorage(rootOverride: windowsUpdateRoot)
            .inspect(clear: clear, maintain: true),
      );
    }
    if (!Platform.isAndroid) return const AppUpdateStorageInfo();
    return AppUpdateStorageInfo.fromMap(
      (await _native.invokeMethod<Map<Object?, Object?>>('maintainStorage', {
        'clear': clear,
      }))!,
    );
  }

  Future<AppUpdateCandidate?> pendingCandidate() async {
    if (Platform.isWindows) {
      final storage = WindowsUpdateStorage(rootOverride: windowsUpdateRoot);
      final stages = await storage.stages();
      stages.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      for (final stage in stages) {
        if (await storage.protected(stage)) continue;
        final metadata = await storage.metadata(stage);
        if (metadata == null) continue;
        final token = AppUpdateCancellation();
        WindowsUpdateStorage.active.add(p.normalize(stage.absolute.path));
        try {
          final manifest = await _regular(
            p.join(stage.path, 'verified-manifest.json'),
          );
          if (await manifest.length() > 1024 * 1024) continue;
          final raw = jsonDecode(await manifest.readAsString());
          final zip = await _regular(p.join(stage.path, 'verified-bundle.zip'));
          final hash = (await sha256.bind(zip.openRead()).first).toString();
          if (raw is! Map ||
              raw['platform'] != 'windows' ||
              raw['packageName'] != 'io.github.hyperionhxh.triomi' ||
              raw['sha256'] != hash ||
              metadata['sha256'] != hash ||
              raw['files'] is! Map) {
            continue;
          }
          final candidate = await _inspectWindowsStage(stage, raw, hash, token);
          if (candidate.canInstall) return candidate;
          if (candidate.decision == 'alreadyInstalled' ||
              candidate.decision == 'downgrade') {
            await storage.save(stage, {...metadata, 'completed': true});
          }
        } catch (_) {
          // A damaged stage is never offered as an installable update.
        } finally {
          WindowsUpdateStorage.active.remove(p.normalize(stage.absolute.path));
        }
      }
      return null;
    }
    if (!Platform.isAndroid) return null;
    final raw = await _native.invokeMethod<Map<Object?, Object?>>(
      'pendingCandidate',
    );
    return raw == null || raw.isEmpty ? null : _candidate(raw);
  }

  Future<AppUpdateCandidate?> pickApk(AppUpdateCancellation token) async {
    token.check();
    final raw = await _native.invokeMethod<Map<Object?, Object?>>('pickApk');
    if (raw == null) {
      token.check();
      return null;
    }
    late final AppUpdateCandidate candidate;
    try {
      candidate = _candidate(raw);
    } catch (_) {
      await _native.invokeMethod<Object?>('discard', {
        'path': raw['path'] as String,
      });
      rethrow;
    }
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

  Future<List<AppUpdateRelease>> resolvePlatformRevisions(
    AppUpdateInfo current,
    List<AppUpdateRelease> releases,
    AppUpdateCancellation token,
  ) async {
    if (current.platform != 'ios') {
      return resolveWindowsRevisions(
        current,
        releases.where((release) => !release.iosOnly).toList(),
        token,
      );
    }
    final result = <AppUpdateRelease>[];
    for (final release in releases) {
      token.check();
      if (!release.iosOnly ||
          !release.assets.containsKey('Triomi-iOS-Unsigned.ipa') ||
          !release.assets.containsKey('triomi-ios.update.json') ||
          !release.assets.containsKey('SHA256SUMS.txt')) {
        continue;
      }
      final manifest = await _iosManifest(release, token);
      result.add(
        release.withIosManifest(
          manifest['iosRevision'] as int,
          manifest['versionCode'] as int,
        ),
      );
    }
    result.sort((a, b) => b.compareTo(a));
    return result;
  }

  Future<AppUpdateCandidate> _downloadIos(
    AppUpdateRelease release,
    AppUpdateReleaseAsset asset,
    String hash,
    AppUpdateCancellation token,
  ) async {
    final manifest = await _iosManifest(release, token);
    if (manifest['sha256'] != hash) {
      throw const FormatException('iOS 发布在检查期间发生变化，请重新检查');
    }
    token.check();
    final path = (await _native.invokeMethod<String>('beginIosStage'))!;
    final file = File(path);
    final marker = File(p.join(file.parent.path, 'cancel'));
    token._marker = marker;
    var retained = false;
    try {
      token.check();
      final body = await _request(asset.url, token, officialAsset: true);
      await stageAppUpdateBytes(
        body.stream,
        file,
        cancellation: token,
        expectedHash: hash,
        expectedBytes: asset.bytes,
        onProgress: onProgress,
        phase: 'download',
      );
      token.check();
      onProgress?.call(const AppUpdateProgress('ipa', 0));
      final markerPath = marker.path;
      final plist = await Isolate.run(
        () => inspectIosUpdateZip(path, markerPath),
      );
      token.check();
      final raw = (await _native.invokeMethod<Map<Object?, Object?>>(
        'inspectIos',
        {'path': path, 'sha256': hash, 'manifest': manifest, 'plist': plist},
      ))!;
      token.check();
      final offered = AppUpdateInfo.fromMap(raw);
      final installed = await current();
      token.check();
      final decision = appUpdateDecision(
        installed,
        offered,
        signatureVerified: false,
      );
      if (decision != 'upgrade') {
        throw const FormatException('此 iOS 版本、构建或修订已安装或更旧，不能更新');
      }
      final candidate = AppUpdateCandidate(
        current: installed,
        offered: offered,
        path: path,
        bytes: asset.bytes,
        source: '官方 GitHub $appUpdateRepository · ${release.tag}',
        decision: decision,
        signatureVerified: false,
      );
      retained = true;
      onProgress?.call(AppUpdateProgress('verified', asset.bytes, asset.bytes));
      return candidate;
    } finally {
      token._marker = null;
      if (!retained) {
        await _native.invokeMethod<bool>('discardIos', {'path': path});
      }
    }
  }

  Future<Map<String, dynamic>> _iosManifest(
    AppUpdateRelease release,
    AppUpdateCancellation token,
  ) async {
    if (!release.iosOnly) throw const FormatException('仅接受官方独立 iOS 发布');
    final asset = release.assets['triomi-ios.update.json'];
    final ipa = release.assets['Triomi-iOS-Unsigned.ipa'];
    if (asset == null ||
        ipa == null ||
        !release.assets.containsKey('SHA256SUMS.txt')) {
      throw const FormatException('iOS 发布缺少 IPA、修订清单或 SHA256SUMS');
    }
    final checksums = await releaseChecksums(release, token);
    final bytes = await _readBounded(asset.url, token, 64 * 1024, asset: asset);
    final raw = jsonDecode(utf8.decode(bytes));
    if (checksums[asset.name] != sha256.convert(bytes).toString() ||
        raw is! Map<String, dynamic> ||
        raw['platform'] != 'ios' ||
        raw['packageName'] != 'io.github.hyperionhxh.triomi' ||
        raw['version'] is! String ||
        !release.matchesPackage(raw['version'] as String, raw['versionCode']) ||
        raw['iosRevision'] is! int ||
        (raw['iosRevision'] as int) < 0 ||
        (raw['iosRevision'] as int) > 65535 ||
        (release.iosOnly && raw['iosRevision'] != release.iosRevision) ||
        raw['sha256'] is! String ||
        !_hashPattern.hasMatch(raw['sha256'] as String) ||
        raw['sha256'] != checksums[ipa.name]) {
      throw const FormatException('iOS 修订清单与官方发布或 SHA-256 不符');
    }
    return raw;
  }

  /// Fetch only the small, digest-verified desktop manifest for same-version
  /// servicing releases. Startup never downloads the ZIP or executes a file.
  Future<List<AppUpdateRelease>> resolveWindowsRevisions(
    AppUpdateInfo current,
    List<AppUpdateRelease> releases,
    AppUpdateCancellation token,
  ) async {
    if (current.platform != 'windows') return releases;
    final resolved = <AppUpdateRelease>[];
    for (final release in releases) {
      token.check();
      if (release.compareVersionTo(current) == 0 &&
          release.assets.containsKey('triomi-windows.update.json') &&
          release.assets.containsKey('triomi-windows.zip')) {
        final checksums = await releaseChecksums(release, token);
        final asset = release.assets['triomi-windows.update.json']!;
        final bytes = await _readBounded(
          asset.url,
          token,
          1024 * 1024,
          asset: asset,
        );
        final raw = jsonDecode(utf8.decode(bytes));
        if (checksums[asset.name] != sha256.convert(bytes).toString() ||
            raw is! Map ||
            raw['platform'] != 'windows' ||
            raw['packageName'] != current.packageName ||
            raw['version'] is! String ||
            !release.matchesPackage(
              raw['version'] as String,
              raw['versionCode'],
            ) ||
            raw['sha256'] != checksums['triomi-windows.zip']) {
          throw const FormatException('Windows 修订清单与公开发布不符');
        }
        final revision = raw['windowsRevision'] ?? 0;
        if (revision is! int || revision < 0 || revision > 65535) {
          throw const FormatException('Windows 修订号无效');
        }
        resolved.add(
          release.withWindowsManifest(revision, raw['versionCode'] as int),
        );
      } else {
        resolved.add(release);
      }
    }
    return resolved;
  }

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
    final platform = (await current()).platform;
    final android = platform == 'android';
    if (!{'android', 'windows', 'ios'}.contains(platform)) {
      throw UnsupportedError('当前平台没有受支持的应用更新流程');
    }
    final asset =
        release.assets[platform == 'ios'
            ? 'Triomi-iOS-Unsigned.ipa'
            : android
            ? 'triomi-android.apk'
            : 'triomi-windows.zip'];
    if (asset == null) throw const FormatException('此版本没有当前平台的完整更新包');
    onProgress?.call(const AppUpdateProgress('metadata', 0));
    final checksums = await releaseChecksums(release, token);
    String expected(AppUpdateReleaseAsset value) {
      final hash = checksums[value.name];
      if (hash == null) throw const FormatException('发布资产缺少可信传输的完整 SHA-256');
      return hash;
    }

    final hash = expected(asset);
    if (platform == 'ios') return _downloadIos(release, asset, hash, token);
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
        raw['version'] is! String ||
        !release.matchesPackage(raw['version'] as String, raw['versionCode']) ||
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
    onProgress?.call(AppUpdateProgress('download', 0, asset.bytes));
    final body = await _request(asset.url, token, officialAsset: true);
    final length = int.tryParse(
      body.headers['content-length']?.firstOrNull ?? '',
    );
    if (length != null && length != asset.bytes) {
      await body.stream.listen(null, onError: (Object _) {}).cancel();
      throw const FormatException('更新文件长度与发布资产不符');
    }
    final candidate = await stageAndroidApk(
      body.stream,
      token,
      expectedHash: hash,
      expectedBytes: asset.bytes,
      source: '官方 GitHub $appUpdateRepository · ${release.tag}',
    );
    if (!release.matchesPackage(
      candidate.offered.version,
      candidate.offered.versionCode,
    )) {
      await discard(candidate);
      throw const FormatException('APK 实际版本与发布版本不符');
    }
    return candidate;
  }

  /// Native-owned lease covers the whole download, copy and verification chain.
  Future<AppUpdateCandidate> stageAndroidApk(
    Stream<List<int>> bytes,
    AppUpdateCancellation token, {
    required String expectedHash,
    required int expectedBytes,
    required String source,
  }) async {
    final input = StreamIterator<List<int>>(bytes);
    Future<void>? streamCancellation;
    Future<void> closeStream() => streamCancellation ??= input.cancel();
    void cancelStream() {
      // The awaited cleanup below still reports cancellation failures.
      closeStream().ignore();
    }

    File? incoming;
    late Future<bool> nextChunk;
    Stream<List<int>> chunks() async* {
      while (await nextChunk) {
        yield input.current;
        nextChunk = input.moveNext();
      }
    }

    AppUpdateCandidate? candidate;
    try {
      // StreamIterator subscribes only on moveNext. Take ownership before any
      // cancellation, allocation or copy setup can fail, without awaiting data.
      nextChunk = input.moveNext();
      // An early source error remains on nextChunk for chunks() to rethrow.
      nextChunk.ignore();
      token._streamCancellations.add(cancelStream);
      token.check();
      final lease = (await _native.invokeMethod<Map<Object?, Object?>>(
        'beginIncoming',
      ))!;
      incoming = File(lease['path'] as String);
      await stageAppUpdateBytes(
        chunks(),
        incoming,
        cancellation: token,
        expectedHash: expectedHash,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        phase: 'download',
      );
      token.check();
      onProgress?.call(const AppUpdateProgress('verify', 0));
      final raw = (await _native.invokeMethod<Map<Object?, Object?>>(
        'inspect',
        {'path': incoming.path, 'sha256': expectedHash, 'source': source},
      ))!;
      try {
        candidate = _candidate(raw);
      } catch (_) {
        await _native.invokeMethod<Object?>('discard', {
          'path': raw['path'] as String,
        });
        rethrow;
      }
      token.check();
      onProgress?.call(
        AppUpdateProgress('verified', candidate.bytes, candidate.bytes),
      );
      return candidate;
    } catch (_) {
      final rejected = candidate;
      candidate = null;
      if (rejected != null) await discard(rejected);
      rethrow;
    } finally {
      token._streamCancellations.remove(cancelStream);
      try {
        await closeStream();
      } finally {
        if (incoming != null) {
          final result = await _native.invokeMethod<Map<Object?, Object?>>(
            'finishIncoming',
            {'path': incoming.path},
          );
          if (result?['removed'] != true) {
            if (candidate != null) await discard(candidate);
            throw const FileSystemException('无法清理本次下载暂存');
          }
        }
      }
    }
  }

  Future<bool> canInstall() async =>
      await _native.invokeMethod<bool>('canInstall') == true;
  Future<void> openUnknownSources() async {
    await _native.invokeMethod<Object?>('openUnknownSources');
  }

  Future<void> launchInstaller(AppUpdateCandidate candidate) async {
    if (candidate.offered.platform == 'ios') {
      if (!candidate.canInstall || (await current()).platform != 'ios') {
        throw StateError('只能交接已核验的新版本 iOS IPA');
      }
      await _native.invokeMethod<Object?>('handoffIos', {
        'path': candidate.path,
        'sha256': candidate.offered.sha256,
        'consent': true,
      });
      return;
    }
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

  /// Release page ownership without deleting bytes still leased to the installer.
  Future<void> abandon(AppUpdateCandidate candidate) async {
    if (Platform.isAndroid && candidate.offered.platform == 'android') {
      await _native.invokeMethod<Object?>('discard', {
        'path': candidate.path,
        'relinquish': true,
      });
    } else {
      await discard(candidate);
    }
  }

  Future<void> discard(AppUpdateCandidate candidate) async {
    if (candidate.offered.platform == 'ios') {
      if (await _native.invokeMethod<bool>('discardIos', {
            'path': candidate.path,
          }) !=
          true) {
        throw const FileSystemException('iOS 更新文件正在交接或无法清理');
      }
    } else if (candidate.offered.platform == 'android') {
      if ((await _native.invokeMethod<Map<Object?, Object?>>('discard', {
            'path': candidate.path,
          }))?['removed'] !=
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
      if (await WindowsUpdateStorage(rootOverride: windowsUpdateRoot)
          .protected(directory)) {
        throw StateError('更新程序仍在使用该暂存，不能移除');
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
    WindowsUpdateStorage.active.add(p.normalize(directory.absolute.path));
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
      final candidate = await _inspectWindowsStage(directory, raw, hash, token);
      await WindowsUpdateStorage(rootOverride: windowsUpdateRoot)
          .save(directory, {
            'version': candidate.offered.version,
            'versionCode': candidate.offered.versionCode,
            'windowsRevision': candidate.offered.windowsRevision,
            'sha256': candidate.offered.sha256,
          });
      return candidate;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      WindowsUpdateStorage.active.remove(p.normalize(directory.absolute.path));
      token._marker = null;
    }
  }

  Future<AppUpdateCandidate> _inspectWindowsStage(
    Directory directory,
    Map<Object?, Object?> raw,
    String hash,
    AppUpdateCancellation token,
  ) async {
    final staged = File(p.join(directory.path, 'verified-bundle.zip'));
    final marker = File(p.join(directory.path, 'cancel'));
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
    final revision = raw['windowsRevision'] ?? 0;
    if (revision is! int ||
        revision < 0 ||
        revision > 65535 ||
        (executableInfo['windowsRevision'] ?? 0) != revision) {
      throw const FormatException('桌面修订号与实际程序不符');
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
      windowsRevision: raw['windowsRevision'] is int
          ? raw['windowsRevision'] as int
          : 0,
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
      decision: appUpdateDecision(installed, offered, signatureVerified: false),
      signatureVerified: false,
      manifestPath: savedManifest.path,
    );
  }

  /// The helper validates again, waits for this process, rolls back failed
  /// writes and restarts Triomi. The page owns the explicit user confirmation.
  Future<void> installWindowsBundle(
    AppUpdateCandidate candidate,
    AppUpdateCancellation token,
  ) async {
    if (!Platform.isWindows ||
        candidate.offered.platform != 'windows' ||
        candidate.manifestPath == null ||
        !candidate.canInstall) {
      throw StateError('此更新包不能安装到当前 Windows 应用');
    }
    final storage = WindowsUpdateStorage(rootOverride: windowsUpdateRoot);
    final stage = (await storage.stages())
        .where(
          (entry) => p.equals(
            p.join(entry.path, 'verified-bundle.zip'),
            candidate.path,
          ),
        )
        .firstOrNull;
    if (stage == null || await storage.protected(stage)) {
      throw StateError('更新暂存不存在或正在使用');
    }
    WindowsUpdateStorage.active.add(p.normalize(stage.absolute.path));
    final marker = File(p.join(stage.path, 'cancel'));
    token._marker = marker;
    Directory? payload;
    var handedOff = false;
    try {
      final manifest = await _regular(candidate.manifestPath!);
      if (await manifest.length() > 1024 * 1024) {
        throw const FormatException('更新清单过大');
      }
      final raw = jsonDecode(await manifest.readAsString());
      final zip = await _regular(candidate.path);
      final hash = (await sha256.bind(zip.openRead()).first).toString();
      if (raw is! Map ||
          raw['sha256'] != hash ||
          hash != candidate.offered.sha256) {
        throw const FormatException('更新包或清单已改变');
      }
      final checked = await _inspectWindowsStage(stage, raw, hash, token);
      if (!checked.canInstall) throw StateError('当前程序已更新或不能接受该修订');
      payload = await stage.createTemp('payload-');
      final payloadPath = payload.path,
          zipPath = zip.path,
          markerPath = marker.path;
      final files = (raw['files'] as Map).cast<Object?, Object?>();
      onProgress?.call(const AppUpdateProgress('install', 0));
      final inspected = await Isolate.run(
        () => verifyWindowsUpdateZip(
          zipPath,
          files,
          markerPath,
          destinationPath: payloadPath,
        ),
      );
      await File(inspected).delete();
      token.check();
      final accepted = await const MethodChannel('triomi/platform')
          .invokeMethod<bool>('installWindowsUpdate', {
            'payloadPath': payloadPath,
            'files': files,
            'consent': true,
          });
      if (accepted != true) throw StateError('Windows 未接受更新交接，现有应用未改动');
      handedOff = true;
    } finally {
      token._marker = null;
      WindowsUpdateStorage.active.remove(p.normalize(stage.absolute.path));
      if (!handedOff && payload != null && await payload.exists()) {
        await payload.delete(recursive: true);
      }
    }
  }
}

Future<File> _regular(String path) async {
  final absolute = p.absolute(path);
  for (var part = absolute; ; part = p.dirname(part)) {
    if (await FileSystemEntity.type(part, followLinks: false) ==
        FileSystemEntityType.link) {
      // iOS exposes its system /var -> /private/var alias even after
      // Foundation URL canonicalization. Permit only that exact prefix and
      // unchanged suffix; user-created or updater-child links still fail.
      if (Platform.isIOS &&
          part == '/var' &&
          absolute.startsWith('/var/') &&
          await Directory('/var').resolveSymbolicLinks() == '/private/var' &&
          await File(absolute).resolveSymbolicLinks() == '/private$absolute') {
        continue;
      }
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

/// Inspects only the bounded root plist; no IPA content is extracted to disk.
/// The payload SHA-256 is checked before this inspection. Native then parses
/// binary/XML plist and compares it with the manifest and installed bundle.
Future<Uint8List> inspectIosUpdateZip(String path, String markerPath) async {
  void check() {
    if (File(markerPath).existsSync()) throw const AppUpdateCancelled();
  }

  void checkExtra(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset < bytes.length) {
      if (offset + 4 > bytes.length) {
        throw const FormatException('IPA ZIP 扩展字段被截断');
      }
      final id = data.getUint16(offset, Endian.little);
      final size = data.getUint16(offset + 2, Endian.little);
      // No ZIP64 size/offset override or alternate Unicode member pathname.
      if (id == 0x0001 || id == 0x7075 || offset + 4 + size > bytes.length) {
        throw const FormatException('IPA ZIP64 或替代路径扩展不受支持');
      }
      offset += 4 + size;
    }
  }

  check();
  final file = await _regular(path);
  final length = await file.length();
  if (length < 22 || length > appUpdateMaxBytes) {
    throw const FormatException('IPA 大小无效');
  }
  final handle = await file.open();
  Future<Uint8List> readAt(int offset, int count) async {
    check();
    if (offset < 0 || count < 0 || offset + count > length) {
      throw const FormatException('IPA ZIP 字段超出文件范围');
    }
    await handle.setPosition(offset);
    final bytes = Uint8List(count);
    var position = 0;
    while (position < count) {
      final read = await handle.readInto(bytes, position, count);
      check();
      if (read == 0) throw const FormatException('IPA ZIP 被截断');
      position += read;
    }
    return bytes;
  }

  try {
    final start = length > 65557 ? length - 65557 : 0;
    final tail = await readAt(start, length - start);
    final endData = ByteData.sublistView(tail);
    var end = -1;
    for (var i = 0; i + 22 <= tail.length; i++) {
      if (endData.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + endData.getUint16(i + 20, Endian.little) == tail.length) {
        if (end != -1) throw const FormatException('IPA ZIP 存在多个结束目录');
        end = i;
      }
    }
    if (end < 0) throw const FormatException('IPA ZIP 缺少有效结束目录');
    for (var i = end + 22; i + 4 <= tail.length; i++) {
      final signature = endData.getUint32(i, Endian.little);
      if (signature == 0x06054b50 ||
          signature == 0x06064b50 ||
          signature == 0x07064b50) {
        throw const FormatException('IPA ZIP 注释中存在替代目录或 ZIP64 元数据');
      }
    }
    final declaredEntries = endData.getUint16(end + 10, Endian.little);
    final directorySize = endData.getUint32(end + 12, Endian.little);
    final directoryOffset = endData.getUint32(end + 16, Endian.little);
    final directoryEnd = start + end;
    if (endData.getUint16(end + 4, Endian.little) != 0 ||
        endData.getUint16(end + 6, Endian.little) != 0 ||
        endData.getUint16(end + 8, Endian.little) != declaredEntries ||
        declaredEntries > 10000 ||
        directorySize > 8 * 1024 * 1024 ||
        directoryOffset + directorySize != directoryEnd ||
        (end >= 20 &&
            endData.getUint32(end - 20, Endian.little) == 0x07064b50)) {
      throw const FormatException('IPA ZIP 目录无效、分卷、ZIP64 或超限');
    }
    // Never ask an archive reader to rediscover EOCD or apply ZIP64 overrides.
    // Parse only the validated directory range, enforcing the actual entry cap
    // before reading each header, independently of EOCD's claimed count.
    final names = <String>{}, apps = <String>{}, executables = <String>{};
    ({int offset, int compressedSize, int size, int method, int crc})? plist;
    var cursor = directoryOffset, actualEntries = 0, total = 0;
    while (cursor < directoryEnd) {
      check();
      if (actualEntries >= 10000) {
        throw const FormatException('IPA ZIP 实际成员超过 10000 限制');
      }
      if (cursor + 46 > directoryEnd) {
        throw const FormatException('IPA ZIP 中央目录被截断');
      }
      final central = ByteData.sublistView(await readAt(cursor, 46));
      if (central.getUint32(0, Endian.little) != 0x02014b50 ||
          central.getUint16(6, Endian.little) > 20 ||
          central.getUint16(34, Endian.little) != 0) {
        throw const FormatException('IPA ZIP 中央目录签名、ZIP64 或分卷成员无效');
      }
      final flags = central.getUint16(8, Endian.little);
      final method = central.getUint16(10, Endian.little);
      final crc = central.getUint32(16, Endian.little);
      final compressedSize = central.getUint32(20, Endian.little);
      final size = central.getUint32(24, Endian.little);
      final nameSize = central.getUint16(28, Endian.little);
      final extraSize = central.getUint16(30, Endian.little);
      final commentSize = central.getUint16(32, Endian.little);
      final mode = (central.getUint32(38, Endian.little) >> 16) & 0xf000;
      final localOffset = central.getUint32(42, Endian.little);
      final next = cursor + 46 + nameSize + extraSize + commentSize;
      if (next > directoryEnd ||
          nameSize == 0 ||
          localOffset + 30 > directoryOffset ||
          compressedSize == 0xffffffff ||
          size == 0xffffffff ||
          (flags & 1) != 0 ||
          ![0, 8].contains(method)) {
        throw const FormatException('IPA ZIP 成员范围、加密或压缩方式无效');
      }
      final rawName = await readAt(cursor + 46, nameSize);
      final name = (flags & 0x800) != 0
          ? utf8.decode(rawName)
          : latin1.decode(rawName);
      checkExtra(await readAt(cursor + 46 + nameSize, extraSize));
      if (!names.add(name.toLowerCase()) ||
          name.startsWith('/') ||
          name.contains('\\') ||
          name.contains(':') ||
          name.contains('//') ||
          RegExp(r'[\x00-\x1f]').hasMatch(name) ||
          name.split('/').any((part) => part == '.' || part == '..') ||
          (mode != 0 && mode != 0x8000 && mode != 0x4000)) {
        throw const FormatException('IPA 存在重复、路径别名、符号链接或非法成员');
      }
      total += size;
      if (total > 2 * 1024 * 1024 * 1024) {
        throw const FormatException('IPA 展开声明超过限制');
      }
      final local = ByteData.sublistView(await readAt(localOffset, 30));
      final localNameSize = local.getUint16(26, Endian.little);
      final localExtraSize = local.getUint16(28, Endian.little);
      final dataOffset = localOffset + 30 + localNameSize + localExtraSize;
      if (local.getUint32(0, Endian.little) != 0x04034b50 ||
          local.getUint16(4, Endian.little) > 20 ||
          local.getUint16(6, Endian.little) != flags ||
          local.getUint16(8, Endian.little) != method ||
          localNameSize != nameSize ||
          dataOffset + compressedSize > directoryOffset ||
          local.getUint32(18, Endian.little) == 0xffffffff ||
          local.getUint32(22, Endian.little) == 0xffffffff ||
          ((flags & 8) == 0 &&
              (local.getUint32(14, Endian.little) != crc ||
                  local.getUint32(18, Endian.little) != compressedSize ||
                  local.getUint32(22, Endian.little) != size))) {
        throw const FormatException('IPA ZIP 本地成员与中央目录不一致');
      }
      final localName = await readAt(localOffset + 30, localNameSize);
      for (var i = 0; i < rawName.length; i++) {
        if (localName[i] != rawName[i]) {
          throw const FormatException('IPA ZIP 本地路径与中央目录不一致');
        }
      }
      checkExtra(
        await readAt(localOffset + 30 + localNameSize, localExtraSize),
      );
      final parts = name.split('/');
      if (parts.length >= 3 &&
          parts[0] == 'Payload' &&
          parts[1].endsWith('.app')) {
        apps.add(parts[1]);
        if (parts.length == 3 && parts[2] == 'Info.plist') {
          plist = (
            offset: dataOffset,
            compressedSize: compressedSize,
            size: size,
            method: method,
            crc: crc,
          );
        }
        if (parts.length == 3 && parts[2] == 'Runner' && size > 0) {
          executables.add(parts[1]);
        }
      }
      actualEntries++;
      cursor = next;
    }
    if (actualEntries != declaredEntries) {
      throw const FormatException('IPA ZIP 实际成员数与目录声明不符');
    }
    if (apps.length != 1 ||
        plist == null ||
        plist.size < 1 ||
        plist.size > 1024 * 1024 ||
        !executables.contains(apps.single)) {
      throw const FormatException('IPA 必须包含唯一完整 Runner.app 与有限 Info.plist');
    }
    final member = plist;
    final compressed = file.openRead(
      member.offset,
      member.offset + member.compressedSize,
    );
    final decoded = member.method == 8
        ? ZLibDecoder(raw: true).bind(compressed)
        : compressed;
    final result = BytesBuilder(copy: false);
    var crc = 0;
    await for (final chunk in decoded) {
      check();
      if (result.length + chunk.length > member.size ||
          result.length + chunk.length > 1024 * 1024) {
        throw const FormatException('IPA Info.plist 实际展开超过限制');
      }
      crc = getCrc32(chunk, crc);
      result.add(chunk);
    }
    if (result.length != member.size || crc != member.crc) {
      throw const FormatException('IPA Info.plist 长度或 CRC 不符');
    }
    check();
    return result.takeBytes();
  } finally {
    await handle.close();
  }
}

/// Bounded member verification. Optional extraction is only into a fresh,
/// caller-owned directory and uses the same validated member names and hashes.
Future<String> verifyWindowsUpdateZip(
  String zipPath,
  Map<Object?, Object?> files,
  String markerPath, {
  String? destinationPath,
}) async {
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
  final destination = destinationPath == null
      ? null
      : Directory(destinationPath);
  if (destination != null &&
      (await FileSystemEntity.type(destination.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(
            await destination.resolveSymbolicLinks(),
            destination.absolute.path,
          ) ||
          await destination.list().isEmpty == false)) {
    throw const FormatException('更新展开目录必须是新的普通空目录');
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
          RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(name) ||
          name
              .split('/')
              .any(
                (part) =>
                    part.isNotEmpty &&
                    RegExp(
                      r'^(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)',
                      caseSensitive: false,
                    ).hasMatch(part),
              ) ||
          name.contains('//') ||
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
      if (destination != null) {
        final target = File(p.joinAll([destination.path, ...name.split('/')]));
        await target.parent.create(recursive: true);
        await file.rename(target.path);
      } else {
        await file.delete();
      }
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
