import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/backup_location.dart';
import '../../core/backup/backup_restore_preview.dart';
import '../../core/backup/scheduled_backup.dart';
import '../../core/db/database_provider.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import '../library/data/windows_content_updates.dart';
import '../schedule/data/background_update_check.dart';
import '../settings/settings_controller.dart';
import 'backup_location_settings.dart';
import 'backup_restore_dialog.dart';
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
  List<BackupDocument> _local = const [];

  /// Persisted request reconciled with Android jobs or Windows Task Scheduler.
  bool _backgroundCheck = false;
  bool _scheduledBackup = false;
  bool _includeSourceRules = true;
  bool _includeApkPackages = true;

  static const String backgroundCheckKey = backgroundCheckPreferenceKey;

  // Windows runs on the current user's interactive token, never while logged
  // out. The foreground provider checks against the same single database.

  @override
  void initState() {
    super.initState();
    _backgroundCheck =
        ref.read(preferencesProvider).get<bool>(backgroundCheckKey) ?? false;
    _scheduledBackup =
        ref.read(preferencesProvider).get<bool>(scheduledBackupKey) ?? false;
    final prefs = ref.read(preferencesProvider);
    _status =
        prefs.get<String>(windowsContentScheduleErrorKey) ??
        prefs.get<String>('content.updates.animeCompleted.error') ??
        prefs.get<String>('content.updates.lastError');
    unawaited(_refreshLocal());
  }

  Future<void> _refreshLocal() async {
    try {
      final store = BackupLocationStore(ref.read(preferencesProvider));
      final location = await store.current();
      final files = location == null
          ? <BackupDocument>[]
          : await store.list(location);
      if (mounted) setState(() => _local = files);
    } catch (error) {
      if (mounted) {
        setState(() {
          _local = const [];
          _status = '备份目录不可读取：$error';
        });
      }
    }
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
                  '包含收藏、进度、历史、正文、下载、封面和插件；需额外临时空间。'
                  '不含账号凭据和插件信任。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时备份规则定义'),
                  subtitle: const Text('包含 JSON/JS/Kazumi 原文，恢复后停用。代码可能含私人信息。'),
                  value: _includeSourceRules,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _includeSourceRules = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时备份APK包'),
                  subtitle: const Text('包含 APK 及签名身份，不含信任。恢复后需逐包确认才能加载。'),
                  value: _includeApkPackages,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _includeApkPackages = value),
                ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('导出完整备份'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _export(metadataOnly: true),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('仅导出元数据'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每日自动本地备份'),
                  subtitle: Text(
                    Platform.isWindows
                        ? '每日 03:00 或登录后执行，需当前用户登录且应用关闭。仅本地元数据，保留旧备份。'
                        : '约每日执行，低电量延后。仅本地元数据，保留旧备份；需有效的外部目录授权。',
                  ),
                  value: _scheduledBackup,
                  onChanged:
                      _busy || !(Platform.isAndroid || Platform.isWindows)
                      ? null
                      : _toggleScheduledBackup,
                ),
                const SizedBox(height: AppSpacing.xs),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('后台检查更新'),
                  subtitle: Text(
                    Platform.isWindows
                        ? windowsContentBehaviorDescription
                        : '仅 WiFi 下检查追番更新，需要通知权限。',
                  ),
                  value: _backgroundCheck,
                  onChanged: _busy ? null : _toggleBackgroundCheck,
                ),
                const SizedBox(height: AppSpacing.xs),
                BackupLocationSettings(
                  key: ValueKey(_busy),
                  onChanged: () => unawaited(_refreshLocal()),
                ),
                TextButton(
                  onPressed: _busy ? null : _refreshLocal,
                  child: const Text('刷新所选目录文件'),
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('恢复备份', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '预览后合并到本机，不含账号凭据。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickBackup,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('选择备份 ZIP 恢复'),
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
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${(file.size / 1024).toStringAsFixed(1)} KB',
                      ),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () => _openBackup(file.location),
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

  Future<void> _export({bool metadataOnly = false}) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final store = BackupLocationStore(ref.read(preferencesProvider));
      final destination = await store.current() ?? await store.choose();
      if (destination == null || !mounted) return;
      final includeSourceRules = !metadataOnly && _includeSourceRules;
      if (includeSourceRules) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认备份规则原文'),
            content: Text(
              '保存到：${destination.label}\n'
              '备份包含规则原始代码，可能隐藏私人信息或凭据；请核对后私下保管。显式凭据字段和凭据 URL 将拒绝导出。恢复后规则停用，已有规则保留。此选项仅用于本地手动备份。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认本地备份规则'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      final result = await ref
          .read(backupServiceProvider)
          .exportPortableBackup(
            location: destination,
            metadataOnly: metadataOnly,
            includeSourceRules: includeSourceRules,
            includeApkPackages: _includeApkPackages,
            writeToTree: platformChannel.writeFileToTree,
          );
      await _refreshLocal();
      if (!mounted) return;
      final location = '已保存到所选外部目录：${destination.label}';
      setState(() {
        _status =
            '已导出：${result.summary.libraryEntries} 条书架、'
            '${result.summary.historyEntries} 条历史、'
            '${result.summary.cachedChapters} 条目录缓存、'
            '${result.summary.covers} 张封面、${result.summary.downloadedMedia} 章完整媒体、${result.summary.partialDownloads} 章部分下载、'
            '${result.summary.sourceRules} 个规则定义、${result.summary.apkPackages} 个APK包\n'
            '$location\n${result.path}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleScheduledBackup(bool enabled) async {
    setState(() => _busy = true);
    final prefs = ref.read(preferencesProvider);
    try {
      if (enabled && Platform.isAndroid) {
        final store = BackupLocationStore(prefs);
        if (await store.current() == null && await store.choose() == null) {
          return;
        }
      }
      await prefs.set(scheduledBackupKey, enabled);
      await prefs.flush();
      if (!await scheduleLocalBackups(prefs)) {
        throw StateError('本地备份排程失败');
      }
      if (mounted) setState(() => _scheduledBackup = enabled);
    } catch (error) {
      if (mounted) {
        setState(() {
          _scheduledBackup = prefs.get<bool>(scheduledBackupKey) ?? false;
          _status = '排程失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleBackgroundCheck(bool value) async {
    final preferences = ref.read(preferencesProvider);
    setState(() => _busy = true);
    try {
      if (Platform.isWindows) {
        await preferences.set(backgroundCheckKey, value);
        await preferences.flush();
        final scheduled = await restoreBackgroundUpdateSchedule(preferences);
        if (!mounted) return;
        setState(() {
          _backgroundCheck = value;
          _status = scheduled
              ? (value
                    ? windowsContentBehaviorDescription
                    : '追番后台检查已关闭；漫画后台更新不受影响')
              : preferences.get<String>(windowsContentScheduleErrorKey);
        });
        return;
      }
      if (!Platform.isAndroid) {
        if (mounted) setState(() => _status = '当前平台不支持后台内容检查');
        return;
      }
      if (value && !await platformChannel.requestNotificationPermission()) {
        if (mounted) setState(() => _status = '没有通知权限，无法开启后台更新提醒');
        return;
      }
      if (!await platformChannel.scheduleBackgroundCheck(value)) {
        if (mounted) setState(() => _status = '后台检查排程失败，请稍后重试');
        return;
      }
      await preferences.set(backgroundCheckKey, value);
      if (mounted) {
        setState(() {
          _backgroundCheck = value;
          _status = value ? '已开启：约每 12 小时检查一次追番更新（仅 WiFi）' : '已关闭追番后台检查';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _backgroundCheck = preferences.get<bool>(backgroundCheckKey) ?? false;
          _status = '后台更新排程失败；请检查系统任务设置后重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBackup() async {
    BackupImportSource? source;
    try {
      source = await BackupImportSource.pick();
      if (source != null && mounted) await _import(source);
    } catch (error) {
      if (mounted) setState(() => _status = '读取备份失败：$error');
    } finally {
      await source?.dispose();
    }
  }

  Future<void> _openBackup(String location) async {
    BackupImportSource? source;
    try {
      source = await BackupImportSource.open(location);
      if (mounted) await _import(source);
    } catch (error) {
      if (mounted) setState(() => _status = '读取备份失败：$error');
    } finally {
      await source?.dispose();
    }
  }

  Future<void> _import(BackupImportSource source) async {
    setState(() {
      _busy = true;
      _status = '正在校验备份…';
    });
    try {
      final preview = await previewBackupRestoreFile(
        ref.read(databaseProvider),
        source.path,
        preferences: ref.read(preferencesProvider),
        apkFiles: await ref.read(backupServiceProvider).openApkFiles(),
      );
      if (!mounted) return;
      final options = await confirmBackupRestore(
        context,
        preview,
        target: source.original,
      );
      if (options == null || !mounted) return;
      final summary = await ref
          .read(backupServiceProvider)
          .importFromFile(
            source.path,
            options: options,
            expectedHash: preview.byteHash,
          );
      // 导入写的是数据库，书架/历史是内存里的 AsyncNotifier：不刷新就要
      // 重启才看得到。
      ref.invalidate(libraryByTypeProvider);
      ref.invalidate(appearanceProvider);
      ref.invalidate(libraryCategoriesForTypeProvider);
      ref.invalidate(historyProvider);
      ref.invalidate(sourcesProvider);
      if (!mounted) return;
      setState(() {
        _status =
            '导入完成：作品 ${summary.items}、书架 ${summary.libraryEntries}、'
            '历史 ${summary.historyEntries}、目录 ${summary.cachedChapters}、'
            '封面 ${summary.covers}、完整媒体 ${summary.downloadedMedia}、部分下载 ${summary.partialDownloads}（暂停）、'
            '规则 ${summary.sourceRules}（停用）、APK ${summary.apkPackages}（待确认）、设置 ${summary.settings}';
      });
      final remove = await confirmDeleteRestoredBackup(
        context,
        source.original,
      );
      if (remove == true) {
        try {
          await source.deleteOriginal(preview.byteHash);
          if (mounted) setState(() => _status = '${_status!}\n已删除原备份文件。');
        } catch (error) {
          if (mounted) {
            setState(() => _status = '${_status!}\n恢复已成功，但原备份未删除：$error');
          }
        }
      }
      await _refreshLocal();
    } catch (error) {
      if (mounted) setState(() => _status = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
