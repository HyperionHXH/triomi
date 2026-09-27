import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/backup_service.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/sync_providers.dart';

/// 备份 / 恢复：导出为 zip（书架 + 进度 + 历史 + 目录 + 设置 + 封面），
/// 导入按「更新时间较新者胜」合并，不覆盖本机更新的进度。
class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;
  String? _status;
  List<File> _local = const <File>[];

  /// 用户授权的导出目录（T7-4）；为空时走应用私有目录。
  String? _exportDirectory;

  /// 后台更新检查（T7-7）：仅设置位，真实排程见 TODO。
  bool _backgroundCheck = false;

  static const String backgroundCheckKey = 'updates.backgroundCheck';

  // TODO(T7-7): 后台更新的真实排程方案——
  // 方案 A：workmanager 插件（后台隔离回调 + Android WorkManager/iOS BGTask），
  //   代价：新增插件与初始化侵入。
  // 方案 B：MethodChannel + Android JobScheduler（Worker），仅 Android 原生实现，
  //   通过 triomi/platform 通道 scheduleBackgroundCheck(bool) 注册周期任务，
  //   由原生侧触发一次 dart 入口（需 headless engine）。
  // 排程内容：调用各追踪/放送表的轻量查询 → 本地通知（需通知权限申请流程）。
  // 规格默认关闭，以上方案在开启设置时由引导流程申请权限后启用。

  @override
  void initState() {
    super.initState();
    _exportDirectory = ref
        .read(preferencesProvider)
        .get<String>(BackupService.exportDirectoryKey);
    _backgroundCheck =
        ref.read(preferencesProvider).get<bool>(backgroundCheckKey) ?? false;
    unawaited(_refreshLocal());
  }

  Future<void> _refreshLocal() async {
    final files = await BackupService.localBackups();
    if (!mounted) return;
    setState(() => _local = files);
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '备份与恢复',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('导出备份', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '打包书架、阅读进度、历史、目录缓存与设置，并带上封面图。'
                  '凭据类设置（密码 / token）不会写入备份。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _export(includeCovers: true),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('导出完整备份（含封面）'),
                ),
                const SizedBox(height: AppSpacing.xs),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _export(includeCovers: false),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('导出精简备份（不含封面）'),
                ),
                const SizedBox(height: AppSpacing.xs),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _export(
                          includeCovers: false,
                          includeOfflineContent: false,
                        ),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('导出精简备份（不含封面与离线内容）'),
                ),
                const SizedBox(height: AppSpacing.xs),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('后台检查更新'),
                  subtitle: const Text(
                    '联网检查追番与来源更新并通知；默认关闭。'
                    '开启后需要通知权限。当前版本仅保存偏好，'
                    '实际排程在后续版本提供。',
                  ),
                  value: _backgroundCheck,
                  onChanged: (value) async {
                    await ref
                        .read(preferencesProvider)
                        .set(backgroundCheckKey, value);
                    setState(() => _backgroundCheck = value);
                  },
                ),
                const SizedBox(height: AppSpacing.xs),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(
                    _exportDirectory == null ? '导出到应用私有目录' : '导出到授权目录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: _exportDirectory == null
                      ? const Text('选择后备份包会写入该目录')
                      : Text(
                          _exportDirectory!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: _exportDirectory == null
                      ? const TextButton(onPressed: null, child: Text(''))
                      : null,
                  onTap: _busy ? null : _pickExportDirectory,
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('本地备份文件', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                if (_local.isEmpty)
                  Text('还没有本地备份', style: Theme.of(context).textTheme.bodySmall)
                else
                  for (final file in _local.take(5))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(
                        file.uri.pathSegments.last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${(file.lengthSync() / 1024).toStringAsFixed(1)} KB',
                      ),
                      trailing: TextButton(
                        onPressed: _busy ? null : () => _import(file.path),
                        child: const Text('导入'),
                      ),
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

  Future<void> _export({
    required bool includeCovers,
    bool includeOfflineContent = true,
  }) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final directory = _exportDirectory;
      final result = await ref
          .read(backupServiceProvider)
          .exportToFile(
            includeCovers: includeCovers,
            includeOfflineContent: includeOfflineContent,
            directoryUri: directory,
            writeToTree: (uri, fileName, bytes) async {
              await platformChannel.writeToTree(
                uri,
                fileName,
                Uint8List.fromList(bytes),
              );
            },
          );
      await _refreshLocal();
      if (!mounted) return;
      final note = directory != null && result.path.startsWith(directory)
          ? ''
          : '\n（授权目录写入失败，已回退应用私有目录）';
      setState(() {
        _status =
            '已导出：${result.summary.libraryEntries} 条书架、'
            '${result.summary.historyEntries} 条历史、'
            '${result.summary.cachedChapters} 条目录缓存、'
            '${result.summary.covers} 张封面\n${result.path}$note';
      });
      await _refreshLocal();
      if (!mounted) return;
      setState(() {
        _status =
            '已导出：${result.summary.libraryEntries} 条书架、'
            '${result.summary.historyEntries} 条历史、'
            '${result.summary.cachedChapters} 条目录缓存、'
            '${result.summary.covers} 张封面\n${result.path}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选择导出目录（SAF），持久化到设置；再次选择后可在系统选择器里改选。
  Future<void> _pickExportDirectory() async {
    final uri = await platformChannel.pickDirectory();
    if (!mounted) return;
    final preferences = ref.read(preferencesProvider);
    if (uri == null) return;
    await preferences.set(BackupService.exportDirectoryKey, uri);
    setState(() => _exportDirectory = uri);
  }

  Future<void> _import(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('导入会把备份内容与本机数据合并（更新时间较新者胜），不会删除本机已有的书架条目。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final summary = await ref
          .read(backupServiceProvider)
          .importFromFile(path);
      if (!mounted) return;
      setState(() {
        _status =
            '导入完成：作品 ${summary.items}、书架 ${summary.libraryEntries}、'
            '历史 ${summary.historyEntries}、目录 ${summary.cachedChapters}、'
            '设置 ${summary.settings}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
