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
  final CancelToken network = CancelToken();
  bool _cancelled = false;
  File? _marker;
  bool get cancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    network.cancel();
    try { _marker?.writeAsStringSync('cancel'); } on FileSystemException { /* The operation may have just finished cleanup. */ }
  }
  void check() { if (_cancelled) throw const AppUpdateCancelled(); }
}

class AppUpdateProgress {
  const AppUpdateProgress(this.phase, this.bytes, [this.total]);
  final String phase;
  final int bytes;
  final int? total;
}

class AppUpdateInfo {
  const AppUpdateInfo({required this.packageName, required this.versionCode,
    required this.version, required this.sha256, this.signerSha256, required this.platform, this.artifactSha256});
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
String appUpdateDecision(AppUpdateInfo current, AppUpdateInfo offered, {required bool signatureVerified}) {
  if (!_hashPattern.hasMatch(current.sha256) || !_hashPattern.hasMatch(offered.sha256)) {
    throw const FormatException('SHA-256 必须是完整 64 位小写散列');
  }
  if (offered.artifactSha256 != null && !_hashPattern.hasMatch(offered.artifactSha256!)) {
    throw const FormatException('EXE SHA-256 必须是完整散列');
  }
  if (current.platform != offered.platform || current.packageName != offered.packageName) return 'wrongPackage';
  if (current.platform == 'android' && (!signatureVerified ||
      current.signerSha256 == null || !_hashPattern.hasMatch(current.signerSha256!) ||
      current.signerSha256 != offered.signerSha256)) {
    return 'wrongSigner';
  }
  if (offered.versionCode < current.versionCode) return 'downgrade';
  if (offered.versionCode == current.versionCode) {
    return (offered.artifactSha256 ?? offered.sha256) == current.sha256 ? 'alreadyInstalled' : 'sameVersionChanged';
  }
  return 'upgrade';
}

class AppUpdateCandidate {
  const AppUpdateCandidate({required this.current, required this.offered, required this.path,
    required this.bytes, required this.source, required this.decision,
    required this.signatureVerified, this.manifestPath});
  final AppUpdateInfo current, offered;
  final String path, source, decision;
  final String? manifestPath;
  final int bytes;
  final bool signatureVerified;
  bool get canInstall => decision == 'upgrade';
}

class AppUpdateManifest {
  const AppUpdateManifest({required this.versionCode, required this.version, required this.url, required this.sha256});
  final int versionCode;
  final String version, sha256;
  final Uri url;
  static Uri https(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const FormatException('只接受无用户名/密码及片段的 HTTPS 地址');
    }
    return uri;
  }
  factory AppUpdateManifest.parse(List<int> bytes) {
    if (bytes.length > 64 * 1024) throw const FormatException('更新清单超过 64 KiB');
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map || raw['versionCode'] is! int || (raw['versionCode'] as int) < 1 ||
        raw['version'] is! String || (raw['version'] as String).isEmpty ||
        (raw['version'] as String).length > 256 || raw['url'] is! String ||
        raw['sha256'] is! String || !_hashPattern.hasMatch(raw['sha256'] as String)) {
      throw const FormatException('清单需要有效 versionCode、version、HTTPS url 和完整 sha256');
    }
    return AppUpdateManifest(versionCode: raw['versionCode'] as int,
      version: raw['version'] as String, url: https(raw['url'] as String), sha256: raw['sha256'] as String);
  }
}

/// Private bounded copy: cancellation and length/hash mismatches remove the partial file.
Future<String> stageAppUpdateBytes(Stream<List<int>> input, File destination, {
  required AppUpdateCancellation cancellation, String? expectedHash, int? expectedBytes,
  void Function(AppUpdateProgress)? onProgress,
}) async {
  if (expectedHash != null && !_hashPattern.hasMatch(expectedHash)) throw const FormatException('无效的完整 SHA-256');
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
      if (size > appUpdateMaxBytes) throw const FormatException('更新文件超过 512 MiB');
      output.add(bytes);
      await output.flush();
      hash.add(bytes);
      onProgress?.call(AppUpdateProgress('copy', size, expectedBytes));
    }
    await output.flush();
    await output.close();
    closed = true;
    hash.close();
    cancellation.check();
    if (size == 0 || (expectedBytes != null && size != expectedBytes)) throw const FormatException('更新文件为空或被截断');
    if (expectedHash != null && digest.value.toString() != expectedHash) throw const FormatException('更新文件 SHA-256 不符');
    return digest.value.toString();
  } catch (_) {
    if (!closed) await output.close();
    if (await destination.exists()) await destination.delete();
    cancellation.check();
    rethrow;
  }
}

class AppUpdateService {
  AppUpdateService({Dio? dio, this.windowsUpdateRoot}) : _dio = dio ?? Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 40),
    followRedirects: false, maxRedirects: 0));
  static const _native = MethodChannel('triomi/app-update');
  final Dio _dio;
  /// Explicit owned root for desktop staging (production defaults to support).
  final Directory? windowsUpdateRoot;
  void Function(AppUpdateProgress)? onProgress;

  void attachProgress() {
    if (!Platform.isAndroid) return;
    _native.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is Map) {
        final raw = call.arguments as Map;
        onProgress?.call(AppUpdateProgress(raw['phase'] as String, raw['bytes'] as int, raw['total'] as int?));
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
      return AppUpdateInfo.fromMap((await _native.invokeMethod<Map<Object?, Object?>>('current'))!);
    }
    if (!Platform.isWindows) throw UnsupportedError('当前平台没有受支持的应用更新流程');
    final map = (await const MethodChannel('triomi/platform').invokeMethod<Map<Object?, Object?>>('currentAppUpdateInfo'))!;
    final file = await _regular(map['path'] as String);
    return AppUpdateInfo.fromMap({...map, 'sha256': (await sha256.bind(file.openRead()).first).toString()});
  }
  Future<AppUpdateCandidate?> pickApk(AppUpdateCancellation token) async {
    token.check();
    final raw = await _native.invokeMethod<Map<Object?, Object?>>('pickApk');
    if (raw == null) { token.check(); return null; }
    final candidate = _candidate(raw);
    if (token.cancelled) { await discard(candidate); token.check(); }
    return candidate;
  }
  AppUpdateCandidate _candidate(Map<Object?, Object?> raw) {
    final installed = AppUpdateInfo.fromMap((raw['current'] as Map).cast<Object?, Object?>());
    final offered = AppUpdateInfo.fromMap({...raw, 'platform': 'android'});
    final verified = raw['signatureVerified'] == true;
    final decision = appUpdateDecision(installed, offered, signatureVerified: verified);
    if (decision != raw['decision']) throw const FormatException('原生与页面的升级策略结果不一致');
    return AppUpdateCandidate(current: installed, offered: offered, path: raw['path'] as String,
      bytes: raw['bytes'] as int, source: raw['source'] as String, decision: decision, signatureVerified: verified);
  }

  Future<AppUpdateManifest> checkManifest(String endpoint, AppUpdateCancellation token) async {
    final uri = AppUpdateManifest.https(endpoint);
    final response = await _request(uri, token);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      token.check();
      if (bytes.length + chunk.length > 64 * 1024) throw const FormatException('更新清单超过 64 KiB');
      bytes.addAll(chunk);
    }
    token.check();
    return AppUpdateManifest.parse(bytes);
  }
  Future<ResponseBody> _request(Uri uri, AppUpdateCancellation token) async {
    token.check();
    try {
      final response = await _dio.getUri<ResponseBody>(uri,
        options: Options(responseType: ResponseType.stream, followRedirects: false,
          validateStatus: (status) => status == 200, headers: const {'Accept-Encoding': 'identity'}),
        cancelToken: token.network);
      return response.data!;
    } on DioException {
      token.check();
      // Do not expose request URL query, tokens or headers in errors/logs.
      throw const HttpException('HTTPS 请求失败、超时或被重定向；未接受重定向和不安全连接');
    }
  }
  Future<AppUpdateCandidate> downloadApk(AppUpdateManifest manifest, String endpoint, AppUpdateCancellation token) async {
    if (!Platform.isAndroid) throw UnsupportedError('网络 APK 仅支持 Android；Windows 请选择独立桌面 ZIP');
    final directory = await _native.invokeMethod<String>('stagingDirectory');
    final root = await Directory(directory!).resolveSymbolicLinks();
    final incoming = File(p.join(root, 'download-${DateTime.now().microsecondsSinceEpoch}.apk'));
    try {
      final body = await _request(manifest.url, token);
      final length = int.tryParse(body.headers['content-length']?.firstOrNull ?? '');
      if (length != null && (length < 1 || length > appUpdateMaxBytes)) throw const FormatException('更新文件长度超限');
      await stageAppUpdateBytes(body.stream, incoming, cancellation: token, expectedHash: manifest.sha256,
        expectedBytes: length, onProgress: onProgress);
      token.check();
      final raw = (await _native.invokeMethod<Map<Object?, Object?>>('inspect', {
        'path': incoming.path, 'sha256': manifest.sha256,
        'source': '用户手动指定 HTTPS 清单 ${_source(endpoint)}；APK ${_source(manifest.url.toString())}',
      }))!;
      final candidate = _candidate(raw);
      if (candidate.offered.versionCode != manifest.versionCode || candidate.offered.version != manifest.version) {
        await discard(candidate);
        throw const FormatException('APK 实际版本与手动清单不符');
      }
      if (token.cancelled) await discard(candidate);
      token.check();
      onProgress?.call(AppUpdateProgress('verified', candidate.bytes, candidate.bytes));
      return candidate;
    } finally { if (await incoming.exists()) await incoming.delete(); }
  }
  Future<bool> canInstall() async => await _native.invokeMethod<bool>('canInstall') == true;
  Future<void> openUnknownSources() async { await _native.invokeMethod<Object?>('openUnknownSources'); }
  Future<void> launchInstaller(AppUpdateCandidate candidate) async {
    if (!candidate.canInstall || !candidate.signatureVerified || candidate.offered.platform != 'android') {
      throw StateError('只能把已核验的新版本 Android APK 交给系统安装器');
    }
    await _native.invokeMethod<Object?>('launchInstaller', {'path': candidate.path,
      'sha256': candidate.offered.sha256, 'consent': true});
  }
  Future<void> discard(AppUpdateCandidate candidate) async {
    if (candidate.offered.platform == 'android') {
      if (await _native.invokeMethod<bool>('discard', {'path': candidate.path}) != true) {
        throw const FileSystemException('无法清理本次更新暂存');
      }
    } else {
      final directory = Directory(p.dirname(candidate.path));
      final root = windowsUpdateRoot ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'app-update'));
      if (!RegExp(r'^bundle-[A-Za-z0-9_-]+$').hasMatch(p.basename(directory.path)) ||
          await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory ||
          p.dirname(await directory.resolveSymbolicLinks()) != await root.resolveSymbolicLinks()) {
        throw const FormatException('暂存清理只允许应用专用目录');
      }
      await directory.delete(recursive: true);
    }
  }

  /// Unsigned desktop transport integrity, not Android signature trust. The user
  /// supplies a trusted manifest and explicitly acknowledges that distinction.
  Future<AppUpdateCandidate> stageWindowsBundle(String zipPath, String manifestPath, AppUpdateCancellation token) async {
    if (!Platform.isWindows) throw UnsupportedError('桌面 ZIP 流程仅支持 Windows');
    token.check();
    final zip = await _regular(zipPath);
    token.check();
    final manifestFile = await _regular(manifestPath);
    token.check();
    if (await manifestFile.length() > 1024 * 1024) throw const FormatException('桌面清单超过 1 MiB');
    token.check();
    final raw = jsonDecode(await manifestFile.readAsString());
    token.check();
    if (raw is! Map || raw['platform'] != 'windows' || raw['packageName'] != 'io.github.hyperionhxh.triomi' ||
        raw['versionCode'] is! int || (raw['versionCode'] as int) < 1 || raw['version'] is! String ||
        (raw['version'] as String).isEmpty || (raw['version'] as String).length > 256 ||
        raw['sha256'] is! String || !_hashPattern.hasMatch(raw['sha256'] as String) || raw['files'] is! Map) {
      throw const FormatException('桌面清单需要 platform:windows、正确 packageName、versionCode、version、ZIP sha256 及 files');
    }
    final root = windowsUpdateRoot ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'app-update'));
    token.check();
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory ||
        p.dirname(await root.resolveSymbolicLinks()) != await root.parent.resolveSymbolicLinks()) {
      throw const FormatException('更新目录不允许符号链接或路径别名');
    }
    token.check();
    final directory = await Directory(await root.resolveSymbolicLinks()).createTemp('bundle-');
    final staged = File(p.join(directory.path, 'verified-bundle.zip'));
    final marker = File(p.join(directory.path, 'cancel'));
    token._marker = marker;
    try {
      token.check();
      final hash = await stageAppUpdateBytes(zip.openRead(), staged, cancellation: token,
        expectedHash: raw['sha256'] as String, expectedBytes: await zip.length(), onProgress: onProgress);
      token.check();
      onProgress?.call(const AppUpdateProgress('bundle', 0));
      final stagedPath = staged.path, markerPath = marker.path;
      final memberHashes = raw['files'] as Map;
      token.check();
      final executablePath = await Isolate.run(() => verifyWindowsUpdateZip(stagedPath, memberHashes, markerPath));
      token.check();
      final executableInfo = (await const MethodChannel('triomi/platform').invokeMethod<Map<Object?, Object?>>(
        'inspectAppUpdateInfo', {'path': executablePath}))!;
      token.check();
      final executableHash = (await sha256.bind(File(executablePath).openRead()).first).toString();
      token.check();
      await File(executablePath).delete();
      token.check();
      if (executableInfo['versionCode'] != raw['versionCode'] || executableInfo['version'] != raw['version']) {
        throw const FormatException('桌面 EXE 实际版本与清单不符');
      }
      token.check();
      final installed = await current();
      token.check();
      final offered = AppUpdateInfo(packageName: raw['packageName'] as String,
        versionCode: raw['versionCode'] as int, version: raw['version'] as String, sha256: hash,
        artifactSha256: executableHash, platform: 'windows');
      final savedManifest = File(p.join(directory.path, 'verified-manifest.json'));
      await savedManifest.writeAsString(jsonEncode(raw), flush: true);
      onProgress?.call(const AppUpdateProgress('manifest', 0));
      token.check();
      final bytes = await staged.length();
      token.check();
      return AppUpdateCandidate(current: installed, offered: offered, path: staged.path,
        bytes: bytes, source: '用户指定桌面 ZIP 与外部完整性清单（未经发布者签名）',
        decision: appUpdateDecision(installed, offered, signatureVerified: false),
        signatureVerified: false, manifestPath: savedManifest.path);
    } catch (_) { await directory.delete(recursive: true); rethrow; }
    finally { token._marker = null; }
  }
}

String _source(String url) {
  final uri = Uri.parse(url);
  // Only origins are shown; private endpoint paths/query are never copied to diagnostics.
  return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
}

Future<File> _regular(String path) async {
  final absolute = p.absolute(path);
  for (var part = absolute;; part = p.dirname(part)) {
    if (await FileSystemEntity.type(part, followLinks: false) == FileSystemEntityType.link) {
      throw const FormatException('更新输入不允许符号链接');
    }
    if (p.dirname(part) == part) break;
  }
  if (await FileSystemEntity.type(absolute, followLinks: false) != FileSystemEntityType.file) {
    throw const FormatException('必须选择现存普通文件');
  }
  return File(await File(absolute).resolveSymbolicLinks());
}

/// Static desktop ZIP byte verification; used by the real staging flow before
/// querying PE resources. No member names become filesystem paths.
Future<String> verifyWindowsUpdateZip(String zipPath, Map<Object?, Object?> files, String markerPath) async {
  void checkCancelled() { if (File(markerPath).existsSync()) throw const AppUpdateCancelled(); }
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
          i + 22 + data.getUint16(i + 20, Endian.little) == bytes.length) { offset = i; break; }
    }
    if (offset < 0 || data.getUint16(offset + 4, Endian.little) != 0 ||
        data.getUint16(offset + 6, Endian.little) != 0 ||
        data.getUint16(offset + 10, Endian.little) > 10000 ||
        data.getUint16(offset + 10, Endian.little) != data.getUint16(offset + 8, Endian.little) ||
        data.getUint32(offset + 12, Endian.little) > 8 * 1024 * 1024 ||
        data.getUint32(offset + 16, Endian.little) + data.getUint32(offset + 12, Endian.little) != start + offset) {
      throw const FormatException('桌面 ZIP 目录无效、分卷、ZIP64 或超限');
    }
  } finally { await handle.close(); }
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
    if (directory.fileHeaders.length > 10000 || files.length > 10000 ||
        directory.fileHeaders.length != directory.totalCentralDirectoryEntries) {
      throw const FormatException('桌面 ZIP 成员过多或目录不一致');
    }
    for (final header in directory.fileHeaders) {
      checkCancelled();
      final name = header.filename;
      final mode = (header.externalFileAttributes >> 16) & 0xf000;
      if (header.file == null || header.file!.filename != name || !names.add(name) || !folded.add(name.toLowerCase()) ||
          name.contains('\\') || name.startsWith('/') || name.contains(':') ||
          name.split('/').any((part) => part == '..' || part == '.' || part.endsWith('.') || part.endsWith(' ')) ||
          (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
          (header.generalPurposeBitFlag & 1) != 0 || ![0, 8].contains(header.compressionMethod) ||
          header.file!.flags != header.generalPurposeBitFlag) {
        throw const FormatException('桌面 ZIP 存在重复、路径别名、加密或非法文件');
      }
      if (name.endsWith('/')) continue;
      actual.add(name);
      total += header.uncompressedSize;
      if (header.uncompressedSize < 0 || header.uncompressedSize > 128 * 1024 * 1024 ||
          total > 1024 * 1024 * 1024) {
        throw const FormatException('桌面 ZIP 展开内容超限');
      }
      final metadata = files[name];
      if (metadata is! Map || metadata['size'] != header.uncompressedSize ||
          metadata['sha256'] is! String || !_hashPattern.hasMatch(metadata['sha256'] as String)) {
        throw const FormatException('桌面文件清单缺失或无效');
      }
      final compressed = header.file!.getStream(decompress: false);
      Stream<List<int>> chunks() async* {
        while (!compressed.isEOS) {
          checkCancelled();
          yield compressed.readBytes(compressed.length < 65536 ? compressed.length : 65536).toUint8List();
          await Future<void>.delayed(Duration.zero);
        }
      }
      final decoded = header.compressionMethod == 8 ? ZLibDecoder(raw: true).bind(chunks()) : chunks();
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
          if (size > header.uncompressedSize || size > 128 * 1024 * 1024 || actualTotal > 1024 * 1024 * 1024) {
            throw const FormatException('桌面 ZIP 实际解压输出超过声明或限制');
          }
          crc = getCrc32(chunk, crc);
          hash.add(chunk);
          output.add(chunk);
          await output.flush();
        }
      } finally { hash.close(); await output.close(); }
      checkCancelled();
      if (size != metadata['size'] || crc != header.crc32 || digest.value.toString() != metadata['sha256']) {
        throw const FormatException('桌面 ZIP 文件被截断或 CRC/SHA-256 不符');
      }
      if (name == 'triomi.exe') {
        await file.copy(executable.path);
        checkCancelled();
      }
      await file.delete();
    }
    if (actual.length != files.length || !actual.contains('triomi.exe') || !actual.contains('flutter_windows.dll') ||
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
