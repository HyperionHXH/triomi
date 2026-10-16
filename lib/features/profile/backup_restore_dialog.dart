import 'package:flutter/material.dart';

import '../../core/backup/backup_restore_preview.dart';
import '../../core/backup/backup_service.dart';

Future<BackupRestoreOptions?> confirmBackupRestore(
  BuildContext context,
  BackupRestorePreview preview, {
  required String target,
}) {
  var replaceSettings = false;
  var keepLocalTracking = true;
  var restoreSourceRules = false;
  var restoreApkPackages = false;
  return showDialog<BackupRestoreOptions>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('恢复冲突预览'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '目标：$target\n备份较新/新增 ${preview.incomingWins} 条；保留本机 ${preview.localWins} 条；同时间戳冲突 ${preview.equalTimestampConflicts} 条保留本机。\n不会删除本机已有书架或下载。完整媒体 ${preview.downloadedMedia} 章校验后可离线使用；部分下载 ${preview.partialDownloads} 章保持暂停，需要明确继续并重新校验新来源；没有文件的下载只恢复暂停索引。封面仅补缺失本机缓存；不可用来源保持停用。',
              ),
              if (preview.incomingSourceRules + preview.keptSourceRules >
                  0) ...[
                Text(
                  '规则定义：可新增/补全 ${preview.incomingSourceRules} 个；'
                  '已有规则或内置身份保留 ${preview.keptSourceRules} 个。',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('恢复规则定义（保持停用）'),
                  subtitle: const Text(
                    '默认不恢复代码；仅可信备份才开启。JSON/JS/Kazumi静态校验后入库，已有规则与原生内置身份不覆盖；不导入发布者信任，之后需在来源管理中手动启用。',
                  ),
                  value: restoreSourceRules,
                  onChanged: preview.incomingSourceRules == 0
                      ? null
                      : (value) => setState(() => restoreSourceRules = value),
                ),
              ],
              if (preview.incomingApkPackages + preview.keptApkPackages > 0) ...[
                Text('APK 包：可新增暂存 ${preview.incomingApkPackages} 个；保留本机 ${preview.keptApkPackages} 个。'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('暂存APK包（不加载、不导入信任）'),
                  subtitle: const Text('默认关闭；支持签名验证的平台重新验证实际包名、版本、签名和文件哈希，其他平台仅校验字节且不可执行。需到来源管理逐包确认身份后才可加载；降级、换签名和同版本异内容拒绝。'),
                  value: restoreApkPackages,
                  onChanged: preview.incomingApkPackages == 0 ? null : (value) => setState(() => restoreApkPackages = value),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('替换已有非敏感设置'),
                subtitle: const Text('关闭时保留本机设置，仅补充缺失键'),
                value: replaceSettings,
                onChanged: (value) => setState(() => replaceSettings = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('追踪身份冲突保留本机'),
                subtitle: const Text('关闭时冲突会拒绝整次导入；不会同步远端'),
                value: keepLocalTracking,
                onChanged: (value) => setState(() => keepLocalTracking = value),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              BackupRestoreOptions(
                replaceSettings: replaceSettings,
                keepLocalTracking: keepLocalTracking,
                restoreSourceRules: restoreSourceRules,
                restoreApkPackages: restoreApkPackages,
              ),
            ),
            child: const Text('确认合并当前备份'),
          ),
        ],
      ),
    ),
  );
}
