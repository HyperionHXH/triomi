import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/backup/backup_restore_preview.dart';
import '../../core/backup/versioned_webdav_backup.dart';
import '../../core/backup/webdav_client.dart';
import '../../core/db/database_provider.dart';
import '../../core/source/source_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import 'backup_restore_dialog.dart';
import 'data/sync_providers.dart';

/// WebDAV 同步：上传本机备份、拉取远端备份并合并（多设备零服务器方案）。
class WebDavSyncPage extends ConsumerStatefulWidget {
  const WebDavSyncPage({super.key});

  @override
  ConsumerState<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends ConsumerState<WebDavSyncPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _fileController = TextEditingController();

  bool _initialized = false;
  bool _busy = false;
  bool _includeDownloadedMedia = false;
  String? _status;
  RemoteBackupInfo? _remote;

  @override
  void initState() {
    super.initState();
    final config = ref.read(webDavConfigProvider);
    _urlController.text = config.baseUrl;
    _userController.text = config.username;
    _passwordController.text = config.password;
    _pathController.text = config.remotePath;
    _fileController.text = config.fileName;
    _initialized = true;
    if (config.isConfigured) unawaited(_checkRemote());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _pathController.dispose();
    _fileController.dispose();
    super.dispose();
  }

  WebDavConfig get _config => WebDavConfig(
    baseUrl: _urlController.text.trim(),
    username: _userController.text.trim(),
    password: _passwordController.text,
    remotePath: _pathController.text.trim().isEmpty
        ? 'triomi'
        : _pathController.text.trim(),
    fileName: _fileController.text.trim(),
  );

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(webDavConfigProvider);
    return PageScaffold(
      title: 'WebDAV 同步',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('服务器', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '支持任意标准 WebDAV（坚果云、Nextcloud、群晖等）。'
                  '密码只保存在本机设置里，不写日志、不随备份导出。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _urlController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://dav.example.com/dav/',
                  ),
                ),
                TextField(
                  controller: _userController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextField(
                  controller: _passwordController,
                  enabled: _initialized && !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码 / 应用密码'),
                ),
                TextField(
                  controller: _pathController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(
                    labelText: '远端目录',
                    hintText: 'triomi',
                  ),
                ),
                TextField(
                  controller: _fileController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(
                    labelText: '备份文件名',
                    hintText: 'backup.zip',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    FilledButton(
                      onPressed: _busy ? null : _saveAndCheck,
                      child: const Text('保存并检测'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      config.isConfigured ? '已配置' : '未配置',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          _card(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeDownloadedMedia,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _includeDownloadedMedia = value),
              title: const Text('包含已完成/部分下载媒体'),
              subtitle: const Text(
                '默认仅备份元数据和封面；启用后云端仍不包含来源代码或 APK。',
              ),
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('同步', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _remote == null
                      ? '尚未检测远端状态'
                      : _remote!.exists
                      ? '远端已有备份：'
                            '${((_remote!.sizeBytes ?? 0) / 1024).toStringAsFixed(1)} KB'
                            '${_remote!.modifiedAt == null ? '' : ' · ${_formatTime(_remote!.modifiedAt!)}'}'
                      : '远端还没有备份文件',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _busy ? null : _upload,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: const Text('上传本机备份'),
                ),
                const SizedBox(height: AppSpacing.xs),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _download,
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('拉取远端备份并合并'),
                ),
              ],
            ),
          ),
          if (_status != null)
            _card(
              child: Row(
                children: <Widget>[
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      _status!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.md,
      AppSpacing.lg,
      0,
    ),
    child: AppCard(child: child),
  );

  /// 远端时间按本机时区显示（服务端回的是 GMT 时间）。
  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _saveAndCheck() async {
    await ref.read(webDavConfigProvider.notifier).update(_config);
    await _checkRemote();
  }

  Future<void> _checkRemote() async {
    final config = _config;
    if (!config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在检测远端…';
    });
    try {
      final client = ref.read(webDavClientProvider);
      final info = await client.stat(
        VersionedWebDavBackup(client).head(config),
      );
      if (!mounted) return;
      setState(() {
        _remote = info;
        _status = info.exists ? '远端备份可用' : '远端还没有备份文件（首次上传会自动创建目录）';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '检测失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    final config = _config;
    if (!config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在读取远端状态…';
    });
    String? ownedPath;
    try {
      final client = ref.read(webDavClientProvider);
      final store = VersionedWebDavBackup(client);
      final expected = await client.stat(store.head(config));
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(expected.exists ? '确认覆盖远端备份' : '确认首次上传远端备份'),
          content: Text(
            '目标：${store.head(config).fileUrl}\n'
            '范围：元数据、设置、封面${_includeDownloadedMedia ? '、已完成/部分下载媒体' : ''}。\n'
            '不包含来源代码、APK 或发布者信任。上传会创建不可变内容块和版本清单；远端变化会拒绝覆盖。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消（不上传）'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认上传'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
      setState(() => _status = '正在打包并上传（磁盘流式）…');
      final backup = await ref.read(backupServiceProvider).exportToFile(
        includeCovers: true,
        includeDownloadedMedia: _includeDownloadedMedia,
        includeSourceRules: false,
        includeApkPackages: false,
      );
      ownedPath = backup.path;
      await store.uploadFile(config, backup.path, expected);
      await ref.read(webDavConfigProvider.notifier).update(config);
      if (!mounted) return;
      setState(() {
        _status =
            '上传完成：${(backup.summary.downloadedMedia)} 个媒体，'
            '书架 ${backup.summary.libraryEntries} 条';
      });
      await _checkRemote();
    } catch (error) {
      if (mounted) setState(() => _status = '上传失败：$error');
    } finally {
      if (ownedPath != null) {
        try {
          final file = File(ownedPath);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Keep a completed export if the platform temporarily denies cleanup.
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final config = _config;
    if (!config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在拉取远端备份（磁盘流式校验）…';
    });
    Directory? operation;
    BackupArtifactLease? guard;
    try {
      guard = await BackupArtifactGuard.acquireOperation();
      final client = ref.read(webDavClientProvider);
      operation = await Directory.systemTemp.createTemp('triomi-media-input-');
      final destination = File('${operation.path}${Platform.pathSeparator}backup.zip');
      final store = VersionedWebDavBackup(client);
      final downloaded = await store.downloadToFile(config, destination);
      if (downloaded == null) {
        final legacy = await client.downloadToFile(
          config,
          destination,
          maxBytes: VersionedWebDavBackup.maxFileSize,
        );
        if (legacy == null) {
          if (mounted) setState(() => _status = '远端没有备份文件，先在一台设备上上传');
          return;
        }
      }
      final preview = await previewBackupRestoreFile(
        ref.read(databaseProvider),
        destination.path,
        apkFiles: await ref.read(backupServiceProvider).openApkFiles(),
      );
      if (!mounted) return;
      final options = await confirmBackupRestore(
        context,
        preview,
        target: config.fileUrl,
      );
      if (options == null || !mounted) return;
      final summary = await ref.read(backupServiceProvider).importFromFile(
        destination.path,
        options: options,
        expectedHash: preview.byteHash,
      );
      ref.invalidate(libraryProvider);
      ref.invalidate(historyProvider);
      ref.invalidate(sourcesProvider);
      if (!mounted) return;
      setState(() {
        _status =
            '合并完成：作品 ${summary.items}、书架 ${summary.libraryEntries}、'
            '历史 ${summary.historyEntries}、目录 ${summary.cachedChapters}、'
            '规则 ${summary.sourceRules}（停用）';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '拉取失败：$error');
    } finally {
      try {
        await operation?.delete(recursive: true);
      } on FileSystemException {
        // A failed cleanup must not replace the transfer/import result.
      }
      if (mounted) setState(() => _busy = false);
      try {
        await guard?.release();
      } catch (_) {
        // Preserve the transfer/import result if lease release is delayed.
      }
  }
}
}
