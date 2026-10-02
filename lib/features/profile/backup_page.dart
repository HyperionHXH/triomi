import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/backup_service.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
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

  /// 后台更新检查（T7-7）：设置位 + Android 原生周期任务（JobScheduler）。
  bool _backgroundCheck = false;

  static const String backgroundCheckKey = 'updates.backgroundCheck';

  // T7-7 实现：不引入 workmanager 插件，走 MethodChannel + Android JobScheduler。
  // 排程（12 小时 / 仅 WiFi）由原生侧注册周期任务；任务触发时拉起 headless
  // FlutterEngine 执行 Dart 入口 `backgroundUpdateCheck`（见
  // features/schedule/data/background_update_check.dart）：读本地追番 → 拉
  // Bangumi 今日放送 → 有命中才发本地通知（无命中不打扰）。默认关闭，
  // 开启前申请通知权限（Android 13+），被拒则保持关闭。

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
                    '联网检查追番更新并通知；默认关闭，开启后需要通知权限，'
                    '仅在 WiFi 下检查。',
                  ),
                  value: _backgroundCheck,
                  onChanged: _busy ? null : _toggleBackgroundCheck,
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
              // D49：返回系统真实 document URI；null/空 → 服务层回退。
              return await platformChannel.writeToTree(
                    uri,
                    fileName,
                    Uint8List.fromList(bytes),
                  ) ??
                  '';
            },
          );
      await _refreshLocal();
      if (!mounted) return;
      // D50：显式区分保存位置；回退是导出成功，不得报成导出失败。
      final location = result.summary.savedToSaf
          ? '已保存到授权目录'
          : (directory == null
                ? '未选择授权目录，已保存到应用私有目录'
                : '授权目录写入失败，已保存到应用私有目录');
      setState(() {
        _status =
            '已导出：${result.summary.libraryEntries} 条书架、'
            '${result.summary.historyEntries} 条历史、'
            '${result.summary.cachedChapters} 条目录缓存、'
            '${result.summary.covers} 张封面\n'
            '$location\n${result.path}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 后台更新提醒开关：开启前先要通知权限，Android 上登记 JobScheduler
  /// 周期任务；被拒或排程失败时保持关闭并说明原因。
  Future<void> _toggleBackgroundCheck(bool value) async {
    final preferences = ref.read(preferencesProvider);
    if (!value) {
      await preferences.set(backgroundCheckKey, false);
      await platformChannel.scheduleBackgroundCheck(false);
      if (!mounted) return;
      setState(() => _backgroundCheck = false);
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      // 排程是 Android 专属能力；其它平台只保存偏好。
      await preferences.set(backgroundCheckKey, true);
      if (!mounted) return;
      setState(() {
        _backgroundCheck = true;
        _status = '当前平台仅保存偏好，后台排程为 Android 专属';
      });
      return;
    }

    final granted = await platformChannel.requestNotificationPermission();
    if (!granted) {
      if (!mounted) return;
      setState(() => _status = '没有通知权限，无法开启后台更新提醒');
      return;
    }
    final scheduled = await platformChannel.scheduleBackgroundCheck(true);
    if (!scheduled) {
      if (!mounted) return;
      setState(() => _status = '后台检查排程失败，请稍后重试');
      return;
    }
    await preferences.set(backgroundCheckKey, true);
    if (!mounted) return;
    setState(() {
      _backgroundCheck = true;
      _status = '已开启：约每 12 小时检查一次追番更新（仅 WiFi）';
    });
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
      // 导入写的是数据库，书架/历史是内存里的 AsyncNotifier：不刷新就要
      // 重启才看得到。
      ref.invalidate(libraryProvider);
      ref.invalidate(historyProvider);
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
