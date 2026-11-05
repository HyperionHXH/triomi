import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
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

  /// 后台更新检查（T7-7）：设置位 + Android 原生周期任务（JobScheduler）。
  bool _backgroundCheck = false;
  bool _scheduledBackup = false;
  bool _includeSourceRules = true;
  bool _includeApkPackages = !Platform.isIOS;

  static const String backgroundCheckKey = backgroundCheckPreferenceKey;

  // T7-7 实现：不引入 workmanager 插件，走 MethodChannel + Android JobScheduler。
  // 排程（12 小时 / 仅 WiFi）由原生侧注册周期任务；任务触发时拉起 headless
  // FlutterEngine 执行 Dart 入口 `backgroundUpdateCheck`（见
  // features/schedule/data/background_update_check.dart）：读本地追番 → 拉
  // Bangumi 今日放送 → 有命中才发本地通知（无命中不打扰）。默认关闭，
  // 开启前申请通知权限（Android 13+），被拒则保持关闭。

  @override
  void initState() {
    super.initState();
    _backgroundCheck =
        ref.read(preferencesProvider).get<bool>(backgroundCheckKey) ?? false;
    _scheduledBackup =
        ref.read(preferencesProvider).get<bool>(scheduledBackupKey) ?? false;
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
                  '默认完整备份：书架、进度、历史、小说正文缓存、漫画/动画完整及已校验的部分下载、封面和插件。'
                  '需要额外临时磁盘空间。账号密码、token 和插件信任不会写入备份。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时备份规则定义'),
                  subtitle: const Text(
                    '完整备份默认包含JSON/JS/Kazumi原文；恢复后停用。规则代码可能含私人信息，导出前需确认。',
                  ),
                  value: _includeSourceRules,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _includeSourceRules = value),
                ),
                if (!Platform.isIOS)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同时备份APK包'),
                    subtitle: const Text(
                      '完整备份默认包含已安装或待确认的APK及签名身份；不备份发布者信任。恢复只暂存，加载前逐包确认。',
                    ),
                    value: _includeApkPackages,
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _includeApkPackages = value),
                  ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('导出完整备份（下载、正文、插件）'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _export(metadataOnly: true),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text('仅导出元数据（不含下载、正文、封面、插件）'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每日自动本地备份'),
                  subtitle: Text(
                    Platform.isIOS
                        ? 'iOS 不保证每日定时执行；请手动导出到“文件”App，或在前台执行 WebDAV 同步。'
                        : Platform.isWindows
                        ? 'Windows 每日 03:00 或登录后执行（仅当前用户登录且应用关闭时）；只备份元数据，不含封面、正文、媒体、规则、APK 或凭据，不联网、不上传，旧备份保留。'
                        : 'Android 约每日执行，电量不足延后；仅元数据，不联网、不上传。必须先授权外部目录；权限失效会失败，不会回退私有目录。旧备份保留。',
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
                    Platform.isIOS
                        ? 'iOS 不提供 Android 周期任务；请在前台检查更新。fetch 声明不保证系统执行。'
                        : '联网检查追番更新并通知；默认关闭，开启后需要通知权限，仅在 WiFi 下检查。',
                  ),
                  value: _backgroundCheck,
                  onChanged: _busy || Platform.isIOS
                      ? null
                      : _toggleBackgroundCheck,
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
                  '选择已有备份，先预览内容，再确认合并到本机；不会自动恢复账号凭据。',
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
              '规则将原样携带代码，恢复后保持停用，已有规则不覆盖。不读取账号安全存储；显式凭据字段和凭据URL会拒绝导出，但无法证明任意代码中没有隐藏凭据。请自行核对并私下保管，不要分享含私人信息的备份。此选择不用于WebDAV或每日自动备份。',
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
            includeApkPackages: !Platform.isIOS && _includeApkPackages,
            writeToTree: platformChannel.writeFileToTree,
          );
      await _refreshLocal();
      if (!mounted) return;
      final location = '已保存到所选目录：${destination.label}';
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
            '规则 ${summary.sourceRules}（停用）、不兼容规则 ${summary.unsupportedSourceRules}（未恢复代码，请从目录安装）、APK ${summary.apkPackages}（待确认）、设置 ${summary.settings}';
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
