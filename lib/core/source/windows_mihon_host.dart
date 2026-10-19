import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'suwayomi_client.dart';

/// App-owned desktop host, not a connection to a user's external Suwayomi.
/// The Windows job owns the JVM; credentials/port never enter portable records.
class WindowsMihonHost {
  WindowsMihonHost._();
  static final instance = WindowsMihonHost._();
  static const _channel = MethodChannel('triomi/platform');
  static const _serverHash =
      'af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd';
  late Directory _root;
  late Directory _payload;
  final _records = <String, Map<String, Object?>>{};
  Future<void>? _prepared, _runtime;
  Future<SuwayomiClient>? _started, _connecting;
  Future<void> _tail = Future.value(), _saving = Future.value();
  RandomAccessFile? _lock;
  String _proxy = '';

  Future<void> configureProxy(String value) => _mutate(() async {
    final uri = value.isEmpty ? null : Uri.tryParse(value);
    if (value.isNotEmpty &&
        (uri == null ||
            uri.scheme != 'http' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            !uri.hasPort ||
            uri.port < 1 ||
            uri.port > 65535 ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('桌面扩展代理必须是无账号、无路径的HTTP主机与端口');
    }
    if (_proxy == value) return;
    if (_started != null || _connecting != null) await _stopClient();
    _proxy = value;
  });

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _prepare() => _prepared ??= () async {
    _root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'mihon-desktop'),
    );
    await _root.create(recursive: true);
    _payload = Directory(
      p.join(p.dirname(Platform.resolvedExecutable), 'extension-runtime'),
    );
    final state = File(p.join(_root.path, 'state.json'));
    if (await state.exists()) {
      final raw = jsonDecode(await state.readAsString()) as Map;
      for (final entry in raw.entries) {
        _records['${entry.key}'] = Map<String, Object?>.from(
          entry.value as Map,
        );
      }
    }
  }();

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _prepareRuntime() => _runtime ??= () async {
    await _prepare();
    final provenanceFile = File(p.join(_payload.path, 'provenance.json'));
    if (!await provenanceFile.exists()) {
      throw StateError('缺少桌面扩展运行时，请完整解压或安装新版Windows包，不要只复制EXE');
    }
    final metadata = jsonDecode(await provenanceFile.readAsString()) as Map;
    final server = metadata['suwayomi'] as Map;
    if (server['sha256'] != _serverHash) throw StateError('桌面扩展运行时版本不匹配');
    final output = File(p.join(_root.path, 'runtime', 'suwayomi.jar'));
    if (await output.exists() && await _hash(output) == _serverHash) return;
    await output.parent.create(recursive: true);
    final temporary = File('${output.path}.part');
    final writer = await temporary.open(mode: FileMode.write);
    try {
      for (final raw in server['parts'] as List) {
        final part = Map<String, Object?>.from(raw as Map);
        final name = '${part['file']}';
        if (p.basename(name) != name ||
            !RegExp(r'^suwayomi\.jar\.part\d+$').hasMatch(name)) {
          throw const FormatException('桌面运行时分片路径无效');
        }
        final input = File(p.join(_payload.path, name));
        if (await input.length() != part['size'] ||
            await _hash(input) != part['sha256']) {
          throw StateError('桌面扩展运行时文件损坏，请重新下载完整Windows包');
        }
        await for (final bytes in input.openRead()) {
          await writer.writeFrom(bytes);
        }
      }
    } finally {
      await writer.close();
    }
    if (await _hash(temporary) != _serverHash) {
      await temporary.delete();
      throw StateError('桌面扩展运行时校验失败');
    }
    if (await output.exists()) await output.delete();
    await temporary.rename(output.path);
  }();

  String get _java => p.join(_payload.path, 'java', 'bin', 'java.exe');
  String get _server => p.join(_root.path, 'runtime', 'suwayomi.jar');

  Future<Map<String, Object?>> _inspect(
    String path,
    String package,
    int version, {
    String? jar,
  }) async {
    await _prepareRuntime();
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$')
            .hasMatch(package) ||
        version < 0) {
      throw const FormatException('扩展包身份无效');
    }
    final process = await Process.start(_java, [
      '-Xmx128m',
      '-cp',
      [
        p.join(_payload.path, 'triomi-apk-inspector.jar'),
        _server,
        p.join(_payload.path, 'apksig.jar'),
      ].join(';'),
      'triomi.desktop.ApkInspector',
      path,
      package,
      '$version',
      ?jar,
    ]);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.drain<void>();
    late int exitCode;
    try {
      final tracked = await _channel.invokeMethod<bool>(
        'desktopMihonTrackVerifier',
        {'pid': process.pid},
      );
      if (tracked != true) throw StateError('无法安全启动扩展静态核验进程');
      exitCode = await process.exitCode.timeout(const Duration(seconds: 45));
    } finally {
      process.kill();
      await process.exitCode;
      await _channel.invokeMethod<bool>('desktopMihonUntrackVerifier', {
        'pid': process.pid,
      });
      await stderr;
    }
    if (exitCode != 0) throw StateError('桌面扩展静态核验失败：APK签名、包名、版本或配套JAR不匹配');
    final value = Map<String, Object?>.from(
      jsonDecode((await stdout).trim()) as Map,
    );
    if (value['ok'] != true || value['signatureVerified'] != true) {
      throw StateError('APK密码学签名核验失败');
    }
    return value;
  }

  Future<Map<String, Object?>> inspectMetadata(
    String path,
    String package,
    int version,
  ) async {
    final value = await _inspect(path, package, version);
    final staged = await _stage(
      File(path),
      package,
      '${value['sha256']}',
      'apk',
    );
    return {...value, 'stagedPath': staged.path};
  }

  Future<File> _stage(
    File input,
    String package,
    String hash,
    String suffix,
  ) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('扩展指纹无效');
    }
    final output = File(
      p.join(_root.path, 'verified', package, '$hash.$suffix'),
    );
    await output.parent.create(recursive: true);
    if (!await output.exists() || await _hash(output) != hash) {
      final candidate = File('${output.path}.part');
      await input.copy(candidate.path);
      if (await _hash(candidate) != hash) {
        await candidate.delete();
        throw StateError('核验后扩展文件已改变');
      }
      if (await output.exists()) await output.delete();
      await candidate.rename(output.path);
    }
    return output;
  }

  Future<void> _save() {
    final result = Completer<void>();
    _saving = _saving.then((_) async {
      try {
        final state = File(p.join(_root.path, 'state.json'));
        final candidate = File('${state.path}.part');
        final snapshot = jsonEncode(_records);
        await candidate.writeAsString(snapshot, flush: true);
        await _channel.invokeMethod<bool>('desktopMihonReplaceFile', {
          'source': candidate.path,
          'destination': state.path,
        });
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<SuwayomiClient> _client() =>
      _connecting ??= _ensureClient().whenComplete(() => _connecting = null);

  Future<SuwayomiClient> _ensureClient() async {
    final existing = _started;
    if (existing != null) {
      final client = await existing;
      if (await _channel.invokeMethod<bool>('desktopMihonAlive') == true) {
        return client;
      }
      // Never replay a possibly completed mutation. Restart before the next
      // request only after the owned process handle confirms that it exited.
      if (identical(_started, existing)) {
        _started = null;
        client.dio.close(force: true);
        final previousLock = _lock;
        _lock = null;
        await previousLock?.close();
      }
    }
    return _started ??= _startClient();
  }

  Future<void> _stopClient() async {
    final connecting = _connecting;
    if (connecting != null) {
      try {
        await connecting;
      } catch (_) {
        // A failed startup already stopped its owned JVM.
      }
    }
    await _channel.invokeMethod<Object?>('desktopMihonStop');
    final started = _started;
    _started = null;
    if (started != null) {
      try {
        (await started).dio.close(force: true);
      } catch (_) {
        // Failed startup has no reusable transport.
      }
    }
    final previousLock = _lock;
    _lock = null;
    await previousLock?.close();
  }

  Future<SuwayomiClient> _startClient() async {
    await _prepareRuntime();
    _lock = await File(p.join(_root.path, 'runtime.lock'))
        .open(mode: FileMode.append);
    try {
      await _lock!.lock(FileLock.exclusive).timeout(const Duration(seconds: 2));
      // Only verified, app-owned original bytes may be reused after restart.
      for (final entry in _records.entries) {
        final record = entry.value;
        final apk = File('${record['stagedPath']}');
        final jar = record['desktopJarPath'] as String?;
        final checked = await _inspect(
          apk.path,
          entry.key,
          record['versionCode'] as int,
          jar: jar,
        );
        if (checked['sha256'] != record['sha256'] ||
            checked['signerSha256'] != record['signerSha256'] ||
            checked['jarSha256'] != record['desktopJarSha256']) {
          throw StateError('已安装桌面扩展文件已改变；保留原收藏，请重新核验扩展');
        }
      }
      // Sources are lazy-loaded upstream. Quarantine unrecorded/changed JARs
      // before starting Java, then reconcile its database before any source API.
      final extensions = Directory(p.join(_root.path, 'extensions'));
      if (await extensions.exists()) {
        final allowed = {
          for (final record in _records.values)
            record['runtimeFile']: record['runtimeFileSha256'],
        };
        await for (final file in extensions.list()) {
          if (file is! File || p.extension(file.path) != '.jar') continue;
          if (allowed[p.basename(file.path)] == await _hash(file)) continue;
          final quarantine = Directory(p.join(_root.path, 'quarantine'));
          await quarantine.create(recursive: true);
          await file.rename(
            p.join(
              quarantine.path,
              '${DateTime.now().microsecondsSinceEpoch}-${p.basename(file.path)}',
            ),
          );
        }
      }
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final secret = List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final settings = <String, Object>{
        'ip': '127.0.0.1',
        'port': port,
        'authMode': 'BASIC_AUTH',
        'authUsername': 'triomi',
        'authPassword': secret,
        'webUIEnabled': false,
        'initialOpenInBrowserEnabled': false,
        'systemTrayEnabled': false,
        'kcefEnabled': false,
        'globalUpdateInterval': 0.0,
        'backupInterval': 0,
        'extensionStores': <String>[],
        'webUIUpdateCheckInterval': 0.0,
        'maxLogFiles': 1,
      };
      await File(p.join(_root.path, 'server.conf')).writeAsString(
        settings.entries
            .map((entry) => 'server.${entry.key} = ${jsonEncode(entry.value)}')
            .join('\n'),
        flush: true,
      );
      final dio = Dio(
        BaseOptions(
          baseUrl: 'http://127.0.0.1:$port',
          followRedirects: false,
          connectTimeout: const Duration(seconds: 2),
          receiveTimeout: const Duration(seconds: 90),
          headers: {
            'Authorization':
                'Basic ${base64Encode(utf8.encode('triomi:$secret'))}',
          },
        ),
      );
      (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () =>
          HttpClient()..findProxy = (_) => 'DIRECT';
      await _channel.invokeMethod<Object?>('desktopMihonStart', {
        'root': _root.path,
        if (_proxy.isNotEmpty) ...{
          'proxyHost': Uri.parse(_proxy).host,
          'proxyPort': Uri.parse(_proxy).port,
        },
      });
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (true) {
        try {
          await dio.get<Object?>('/api/v1/settings/about');
          break;
        } on DioException catch (error) {
          if (error.response != null || DateTime.now().isAfter(deadline)) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      final client = SuwayomiClient(
        dio: dio,
        cache: Directory(p.join(_root.path, 'image-cache')),
      );
      await _reconcile(client);
      return client;
    } catch (_) {
      await _channel.invokeMethod<Object?>('desktopMihonStop');
      await _lock?.close();
      _lock = null;
      _started = null;
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> _installed(SuwayomiClient client) async {
    final response = await client.dio.get<Object?>('/api/v1/extension/list');
    return [
      for (final row in response.data as List)
        if (row is Map && row['installed'] == true)
          Map<String, Object?>.from(row),
    ];
  }

  Future<Map<String, Object?>> _runtimeIdentity(
    SuwayomiClient client,
    String package,
    Map<String, Object?> record,
  ) async {
    final installed = (await _installed(client))
        .firstWhere((row) => row['pkgName'] == package);
    if (installed['versionCode'] != record['versionCode']) {
      throw StateError('运行时安装版本与已核验扩展不同');
    }
    final name = '${installed['apkName']}'.replaceFirst(
      RegExp(r'\.apk$'),
      '.jar',
    );
    if (p.basename(name) != name) throw const FormatException('运行时文件名无效');
    final hash = await _hash(File(p.join(_root.path, 'extensions', name)));
    if (record['desktopJarSha256'] != null &&
        hash != record['desktopJarSha256']) {
      throw StateError('实际执行JAR与已确认指纹不同，拒绝加载');
    }
    return {'runtimeFile': name, 'runtimeFileSha256': hash};
  }

  Future<void> _installRecord(
    SuwayomiClient client,
    String package,
    Map<String, Object?> record,
  ) async {
    await client.install(
      File('${record['desktopJarPath'] ?? record['stagedPath']}'),
      nativeJar: record['desktopJarPath'] != null,
    );
    record.addAll(await _runtimeIdentity(client, package, record));
  }

  Future<void> _reconcile(SuwayomiClient client) async {
    final installed = await _installed(client);
    final valid = <String>{};
    for (final row in installed) {
      final package = '${row['pkgName']}';
      final record = _records[package];
      var matches = false;
      if (record != null) {
        try {
          final identity = await _runtimeIdentity(client, package, record);
          matches =
              identity['runtimeFile'] == record['runtimeFile'] &&
              identity['runtimeFileSha256'] == record['runtimeFileSha256'];
        } on FileSystemException {
          // Interrupted installation or quarantined, modified executable.
        } on StateError {
          // Runtime metadata does not match the last committed trust record.
        }
      }
      if (matches) {
        valid.add(package);
      } else {
        await client.uninstall(package);
      }
    }
    for (final entry in _records.entries) {
      if (!valid.contains(entry.key)) {
        await _installRecord(client, entry.key, entry.value);
      }
    }
    await _save();
  }

  Future<Map<String, Object?>> inspectExtension({
    required String path,
    required String package,
    required int version,
    required String signer,
    required String hash,
    String? jarPath,
    String? jarHash,
  }) => _mutate(() async {
    final metadata = await _inspect(path, package, version, jar: jarPath);
    if (metadata['sha256'] != hash ||
        metadata['signerSha256'] != signer ||
        metadata['jarSha256'] != jarHash) {
      throw StateError('待加载扩展与已确认指纹不同');
    }
    final old = _records[package];
    if (old != null &&
        (old['signerSha256'] != signer ||
            (old['versionCode'] as int) > version ||
            old['versionCode'] == version && old['sha256'] != hash)) {
      throw StateError('扩展更新身份与已信任版本不一致，保留原版本');
    }
    final apk = await _stage(File(path), package, hash, 'apk');
    final jar = jarPath == null
        ? null
        : await _stage(File(jarPath), package, jarHash!, 'jar');
    final client = await _client();
    if (old != null &&
        old['sha256'] == hash &&
        old['desktopJarSha256'] == jarHash) {
      return old;
    }
    try {
      if (old != null) await client.uninstall(package);
      final record = <String, Object?>{
        ...metadata,
        'stagedPath': apk.path,
        'desktopJarPath': jar?.path,
        'desktopJarSha256': jarHash,
      };
      await _installRecord(client, package, record);
      final sources = await client.extensionSources(package);
      if (sources.isEmpty) throw StateError('桌面兼容运行时未能加载此扩展的来源');
      record.addAll({
        'enabled': old?['enabled'] == true,
        'sources': sources,
        'sourceCount': sources.length,
        'executable': true,
        'factoryLoaded': true,
      });
      _records[package] = record;
      await _save();
      return record;
    } catch (error) {
      if (old == null) {
        _records.remove(package);
      } else {
        _records[package] = old;
      }
      try {
        // The upstream install coroutine can outlive its HTTP connection.
        // Terminate and await Java before recovery; never race a late commit.
        await _stopClient();
        await _client();
      } catch (_) {
        await _stopClient();
        throw StateError('扩展安装失败且回滚未完成，已停止运行时；重试将核验并恢复原版本。原因：$error');
      }
      rethrow;
    }
  });

  Future<bool> setEnabled(String package, bool enabled) => _mutate(() async {
    await _prepare();
    final record = _records[package];
    if (record == null) return false;
    // Startup reconciliation also publishes executable identities. Finish it
    // before changing enabled state, so rollback cannot race that snapshot.
    await _client();
    final previous = record['enabled'];
    record['enabled'] = enabled;
    try {
      await _save();
    } catch (_) {
      record['enabled'] = previous;
      rethrow;
    }
    return true;
  });

  Future<Map<String, Object?>> _active(
    String package,
    String source, {
    int? version,
    String? signer,
  }) async {
    await _tail;
    await _prepare();
    final record = _records[package];
    if (record == null ||
        record['enabled'] != true ||
        !(record['sources'] as List).any(
          (row) => row is Map && '${row['id']}' == source,
        ) ||
        version != null && record['versionCode'] != version ||
        signer != null && record['signerSha256'] != signer) {
      throw StateError('桌面扩展未启用、未受信任或版本已改变，请在扩展管理中核验');
    }
    return record;
  }

  Future<Map<String, Object?>> request({
    required String package,
    required String sourceId,
    required String operation,
    int? version,
    String? signer,
    int page = 1,
    String query = '',
    Map<String, Object?>? manga,
    Map<String, Object?>? chapter,
    Map<String, Object?>? pageData,
    List<Map<String, Object?>>? filters,
  }) async {
    await _active(package, sourceId, version: version, signer: signer);
    return (await _client()).request(
      sourceId: sourceId,
      operation: operation,
      page: page,
      query: query,
      manga: manga,
      chapter: chapter,
      pageData: pageData,
      filters: filters,
    );
  }

  Future<List<Map<String, Object?>>> preferences(
    String package,
    String source,
  ) async {
    await _active(package, source);
    return (await _client()).preferences(source);
  }

  Future<void> setPreference(
    String package,
    String source,
    int position,
    Object? value,
  ) async {
    await _active(package, source);
    await (await _client()).setPreference(source, position, value);
  }

  Future<List<int>> coverBytes(String value, String descriptorId) async {
    final parts = descriptorId.split(':');
    final uri = Uri.parse(value);
    if (parts.length != 3 ||
        parts[0] != 'mihon' ||
        uri.scheme != 'mihon-cover' ||
        uri.host != 'source' ||
        uri.queryParameters['source'] != parts[2]) {
      throw const FormatException('桌面扩展封面与来源不匹配');
    }
    await _active(parts[1], parts[2]);
    return (await _client()).coverBytes(uri);
  }
}
