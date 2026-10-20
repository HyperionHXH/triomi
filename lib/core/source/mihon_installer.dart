import 'dart:async';

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../backup/apk_backup_files.dart';
import '../platform/platform_channel.dart';
import '../storage/preferences.dart';
import 'http_client.dart';
import 'mihon_repository.dart';
import 'source_filters.dart';

class MihonPublisherCandidate {
  const MihonPublisherCandidate({
    required this.actualSigner,
    required this.repositorySigner,
    required this.apkHash,
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    this.desktopJarSha256,
    this.desktopJarUrl,
  });
  final String actualSigner;
  final String repositorySigner;
  final String apkHash;
  final String packageName;
  final int versionCode;
  final String versionName;
  final String? desktopJarSha256;
  final String? desktopJarUrl;
}

class MihonInstaller {
  const MihonInstaller({required this.http, required this.preferences});
  static Future<void>? _metadataTail;

  Future<T> _withMetadataLock<T>(Future<T> Function() action) async {
    final previous = _metadataTail;
    final release = Completer<void>();
    _metadataTail = release.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_metadataTail, release.future)) _metadataTail = null;
    }
  }

  final SourceHttpClient http;
  final Preferences preferences;

  Future<Map<String, Object?>> install(
    MihonExtension extension, {
    required String signerSha256,
    Future<bool> Function(MihonPublisherCandidate candidate)? confirmPublisher,
  }) => _withMetadataLock(
    () => _install(
      extension,
      signerSha256: signerSha256,
      confirmPublisher: confirmPublisher,
    ),
  );

  Future<Map<String, Object?>> _install(
    MihonExtension extension, {
    required String signerSha256,
    Future<bool> Function(MihonPublisherCandidate candidate)? confirmPublisher,
  }) async {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/mihon-extensions',
    );
    await directory.create(recursive: true);
    final candidateDirectory = await directory.createTemp('candidate-');
    final desktop = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    File? desktopJar;
    String? desktopJarHash;
    final candidate = File('${candidateDirectory.path}/extension.apk');
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          await _download(extension, candidate);
          break;
        } on DioException {
          if (attempt >= 2) rethrow;
          await Future<void>.delayed(Duration(seconds: attempt + 1));
        } on IOException {
          if (attempt >= 2) rethrow;
          await Future<void>.delayed(Duration(seconds: attempt + 1));
        }
      }
      if (desktop && extension.jarUrl != null) {
        desktopJar = File('${candidateDirectory.path}/extension.jar');
        await _downloadUrl(
          extension.jarUrl!,
          extension.packageName,
          desktopJar,
        );
        desktopJarHash = (await sha256.bind(desktopJar.openRead()).first)
            .toString();
        if (extension.jarSha256 != null &&
            desktopJarHash != extension.jarSha256) {
          throw StateError('桌面 JAR 内容指纹与仓库不一致');
        }
      }
      final metadata = await platformChannel.inspectMihonMetadata(
        apkPath: candidate.path,
        packageName: extension.packageName,
        versionCode: extension.versionCode,
      );
      if (metadata['ok'] != true || metadata['signatureVerified'] != true) {
        throw StateError('${metadata['error'] ?? 'APK 签名验证失败'}');
      }
      final actualSigner = '${metadata['signerSha256']}'.toLowerCase();
      final actualHash = '${metadata['sha256']}'.toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(actualSigner) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(actualHash)) {
        throw StateError('APK 发布者或内容指纹无效');
      }
      if (extension.apkSha256 != null &&
          extension.apkSha256!.toLowerCase() != actualHash) {
        throw StateError('APK 内容 SHA-256 与仓库不一致');
      }
      final old = preferences.get<Map<dynamic, dynamic>>(
        'mihon.hostStatus',
      )?[extension.packageName];
      final pinned = old is Map
          ? old['signerSha256']?.toString().toLowerCase()
          : null;
      if (pinned != null && actualSigner != pinned) {
        throw StateError('更新发布者签名与已信任版本不一致，保留旧版本');
      }
      ApkBackupFiles.checkUpdate({
        'signerSha256': actualSigner,
        'sha256': actualHash,
        'versionCode': extension.versionCode,
      }, old);
      if (extension.publisherSignerSha256 != null &&
          actualSigner != extension.publisherSignerSha256!.toLowerCase()) {
        throw StateError('APK 发布者签名与扩展声明不一致');
      }
      final declared =
          extension.publisherSignerSha256 ?? signerSha256.toLowerCase();
      final oldJarHash = old is Map ? old['desktopJarSha256'] : null;
      if (pinned == null && actualSigner != declared ||
          desktopJarHash != null && oldJarHash != desktopJarHash) {
        final accepted = await confirmPublisher?.call(
          MihonPublisherCandidate(
            actualSigner: actualSigner,
            repositorySigner: signerSha256,
            apkHash: actualHash,
            packageName: extension.packageName,
            versionCode: extension.versionCode,
            versionName: extension.versionName,
            desktopJarSha256: desktopJarHash,
            desktopJarUrl: extension.jarUrl,
          ),
        );
        if (accepted != true) throw StateError('尚未确认扩展发布者或独立的桌面 JAR 指纹');
      }
      final status = await platformChannel.inspectMihonExtension(
        apkPath: '${metadata['stagedPath']}',
        packageName: extension.packageName,
        versionCode: extension.versionCode,
        signerSha256: actualSigner,
        apkSha256: actualHash,
        desktopJarPath: desktopJar?.path,
        desktopJarSha256: desktopJarHash,
      );
      if (status['ok'] != true || status['executable'] != true) {
        throw StateError(
          '${status['hostError'] ?? status['error'] ?? 'APK 无法执行'}',
        );
      }
      // Carry declarations only after the APK identity/hash checks above.
      // This is display metadata, never permission to execute or enable.
      status['name'] = extension.name;
      status['lang'] =
          extension.sources.map((source) => source.language).toSet().length == 1
          ? extension.sources.first.language
          : '';
      status['nsfw'] =
          extension.declaredNsfw == true ||
              sourceNsfwFlag(metadata['nsfw']) == true
          ? true
          : sourceNsfwFlag(metadata['nsfw']) ?? extension.declaredNsfw;
      final hostSources = status['sources'];
      if (hostSources is List) {
        status['sources'] = [
          for (final raw in hostSources)
            if (raw is Map)
              <String, Object?>{
                for (final entry in raw.entries) '${entry.key}': entry.value,
                'nsfw': sourceNsfwFlag(metadata['nsfw']) == true
                    ? true
                    : extension.sources
                              .where((source) => source.id == '${raw['id']}')
                              .firstOrNull
                              ?.nsfw ??
                          sourceNsfwFlag(status['nsfw']),
              },
        ];
      }
      final installed = <String, Object?>{
        ...?preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages')
            ?.map((key, value) => MapEntry('$key', value)),
        extension.packageName: extension.versionName,
      };
      final hostStatus = <String, Object?>{
        ...?preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')
            ?.map((key, value) => MapEntry('$key', value)),
        extension.packageName: status,
      };
      await preferences.set('mihon.hostStatus', hostStatus);
      await preferences.set('mihon.installedPackages', installed);
      return status;
    } finally {
      await candidateDirectory.delete(recursive: true);
    }
  }

  /// Restored bytes are inert until the user accepts the actual verified identity.
  /// Backup metadata can never supply the acceptance or a publisher pin.
  Future<Map<String, Object?>> activatePending(
    ApkBackupFiles files,
    String packageName, {
    required Future<bool> Function(MihonPublisherCandidate candidate)
    confirmPublisher,
  }) => _withMetadataLock(() async {
    final metadata = await files.inspectPending(packageName);
    final accepted = await confirmPublisher(
      MihonPublisherCandidate(
        actualSigner: metadata['signerSha256'] as String,
        repositorySigner: '',
        apkHash: metadata['sha256'] as String,
        packageName: metadata['packageName'] as String,
        versionCode: metadata['versionCode'] as int,
        versionName: metadata['versionName'] as String,
      ),
    );
    if (!accepted) throw StateError('尚未确认恢复 APK 的发布者；文件保持停用');
    // Confirmation can take arbitrarily long; recheck catalogue and bytes.
    final current = await files.inspectPending(packageName);
    for (final key in const [
      'sha256',
      'signerSha256',
      'versionCode',
      'versionName',
      'packageName',
    ]) {
      if (metadata[key] != current[key]) throw StateError('确认期间 APK 已改变，请重新确认');
    }
    final status = await platformChannel.inspectMihonExtension(
      apkPath: current['stagedPath'] as String,
      packageName: packageName,
      versionCode: current['versionCode'] as int,
      signerSha256: current['signerSha256'] as String,
      apkSha256: current['sha256'] as String,
    );
    if (status['ok'] != true || status['executable'] != true) {
      throw StateError(
        '${status['hostError'] ?? status['error'] ?? 'APK 无法执行；保留待确认文件'}',
      );
    }
    final restoredNsfw = sourceNsfwFlag(files.pending[packageName]?['nsfw']);
    final manifestNsfw = sourceNsfwFlag(current['nsfw']);
    status['nsfw'] = restoredNsfw == true || manifestNsfw == true
        ? true
        : manifestNsfw ?? restoredNsfw;
    final installed = <String, Object?>{
      ...?preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages')
          ?.map((key, value) => MapEntry('$key', value)),
      packageName: current['versionName'],
    };
    final hostStatus = <String, Object?>{
      ...?preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')
          ?.map((key, value) => MapEntry('$key', value)),
      packageName: status,
    };
    await preferences.set('mihon.hostStatus', hostStatus);
    await preferences.set('mihon.installedPackages', installed);
    await preferences.flush();
    // Loading is explicitly confirmed, but never enables a newly restored source.
    await files.removeActivated(packageName, current['sha256'] as String);
    return status;
  });
  /// Removes executable trust/installation records only. Reading data and each
  /// source's own preferences live in separate stores and are never deleted.
  Future<void> uninstall(
    String packageName, {
    ApkBackupFiles? pendingFiles,
  }) => _withMetadataLock(() async {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$')
        .hasMatch(packageName)) {
      throw const FormatException('扩展包身份无效');
    }
    // Always ask the host: a failed install can leave staged native files
    // without any corresponding Dart metadata.
    if (!await platformChannel.uninstallMihon(packageName)) {
      throw StateError('宿主未完成卸载，已保留安装记录。请关闭正在使用的插件后重试；Windows 需完整的 extension-runtime 安装。');
    }
    final pending = pendingFiles?.pending[packageName];
    if (pending != null) {
      await pendingFiles!.removeActivated(packageName, pending['sha256'] as String);
    }
    final installed = <String, Object?>{
        ...?preferences.get<Map<dynamic, dynamic>>('mihon.installedPackages')
            ?.map((key, value) => MapEntry('$key', value)),
      }..remove(packageName);
      final statuses = <String, Object?>{
        ...?preferences.get<Map<dynamic, dynamic>>('mihon.hostStatus')
            ?.map((key, value) => MapEntry('$key', value)),
      }..remove(packageName);
      final enabled = <String>{
        for (final value
            in preferences.get<List<Object?>>('mihon.enabledPackages') ?? [])
          '$value',
      }..remove(packageName);
      const keys = [
        'mihon.enabledPackages',
        'mihon.hostStatus',
        'mihon.installedPackages',
      ];
      final before = preferences.exportAll();
      final previous = <String, Object?>{
        for (final key in keys)
          if (before.containsKey(key)) key: before[key],
      };
      final missing = keys.where((key) => !before.containsKey(key)).toSet();
      try {
        await preferences.set('mihon.enabledPackages', enabled.toList());
        await preferences.set('mihon.hostStatus', statuses);
        await preferences.set('mihon.installedPackages', installed);
        await preferences.flush();
      } catch (_) {
        await preferences.restoreSubset(previous, missing);
        await preferences.flush();
        rethrow;
      }
    });

  Future<void> _download(MihonExtension extension, File candidate) =>
      _downloadUrl(extension.apkUrl, extension.packageName, candidate);

  Future<void> _downloadUrl(String url, String package, File candidate) async {
    var stream = http is SecureRuleDownloadClient
        ? await (http as SecureRuleDownloadClient).downloadRuleBytes(
            url,
            sourceId: 'mihon:$package',
          )
        : await http.downloadBytes(url, sourceId: 'mihon:$package');
    const limit = 64 * 1024 * 1024;
    for (var recovery = 0; ; recovery++) {
      try {
        // Every delivery attempt starts at byte zero. A partial primary body
        // must never be concatenated with the complete API replacement.
        final output = await candidate.open(mode: FileMode.write);
        var length = 0;
        try {
          await for (final chunk in stream.stream) {
            length += chunk.length;
            if (length > limit) throw StateError('扩展文件超过 64 MiB');
            await output.writeFrom(chunk);
          }
        } finally {
          await output.close();
        }
        if (length == 0) throw StateError('扩展文件下载为空');
        return;
      } on DioException catch (error) {
        if (recovery != 0 || http is! SecureRuleDownloadClient) rethrow;
        stream = await (http as SecureRuleDownloadClient).downloadRuleBytes(
          url,
          sourceId: 'mihon:$package',
          afterStreamFailure: error,
        );
      }
    }
  }
}
