import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/webdav_client.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
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

  bool _initialized = false;
  bool _busy = false;
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
    _initialized = true;
    if (config.isConfigured) unawaited(_checkRemote());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  WebDavConfig get _config => WebDavConfig(
    baseUrl: _urlController.text.trim(),
    username: _userController.text.trim(),
    password: _passwordController.text,
    remotePath: _pathController.text.trim().isEmpty
        ? 'triomi'
        : _pathController.text.trim(),
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
                  enabled: _initialized,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://dav.example.com/dav/',
                  ),
                ),
                TextField(
                  controller: _userController,
                  enabled: _initialized,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextField(
                  controller: _passwordController,
                  enabled: _initialized,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码 / 应用密码'),
                ),
                TextField(
                  controller: _pathController,
                  enabled: _initialized,
                  decoration: const InputDecoration(
                    labelText: '远端目录',
                    hintText: 'triomi',
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
    if (!_config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在检测远端…';
    });
    try {
      final info = await ref.read(webDavClientProvider).stat(_config);
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
    if (!_config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在打包并上传…';
    });
    try {
      final backup = await ref
          .read(backupServiceProvider)
          .exportToBytes(includeCovers: true);
      await ref.read(webDavClientProvider).upload(_config, backup.bytes);
      await ref.read(webDavConfigProvider.notifier).update(_config);
      if (!mounted) return;
      setState(() {
        _status =
            '上传完成：${(backup.bytes.length / 1024).toStringAsFixed(1)} KB'
            '（书架 ${backup.summary.libraryEntries} 条）';
      });
      await _checkRemote();
    } catch (error) {
      if (mounted) setState(() => _status = '上传失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    if (!_config.isConfigured) {
      setState(() => _status = '请先填写服务器地址与用户名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在拉取远端备份…';
    });
    try {
      final bytes = await ref.read(webDavClientProvider).download(_config);
      if (bytes == null) {
        if (mounted) setState(() => _status = '远端没有备份文件，先在一台设备上上传');
        return;
      }
      final summary = await ref
          .read(backupServiceProvider)
          .importFromBytes(
            bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          );
      // 合并写的是数据库，书架/历史是内存里的 AsyncNotifier：不刷新就要
      // 重启才看得到（双设备验证时实测到）。
      ref.invalidate(libraryProvider);
      ref.invalidate(historyProvider);
      if (!mounted) return;
      setState(() {
        _status =
            '合并完成：作品 ${summary.items}、书架 ${summary.libraryEntries}、'
            '历史 ${summary.historyEntries}、目录 ${summary.cachedChapters}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '拉取失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
