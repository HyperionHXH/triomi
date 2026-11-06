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
                '目标：$target\n新增或更新 ${preview.incomingWins} 条；保留本机 ${preview.localWins} 条；同时间冲突 ${preview.equalTimestampConflicts} 条保留本机。\n保留已有收藏与下载。完整媒体 ${preview.downloadedMedia} 章校验后可用；部分下载 ${preview.partialDownloads} 章暂停，继续时重新校验；缺失文件仅恢复暂停索引。封面仅补缺，不可用来源保持停用。',
              ),
              const SizedBox(height: 12),
              Text(
                '分类：新增 ${preview.incomingCategories} 项；保留本机 ${preview.keptCategories} 项。',
              ),
              Text(
                '分模块书架设置：补充 ${preview.incomingScopedLibrarySettings} 项；保留本机 ${preview.keptScopedLibrarySettings} 项。',
              ),
              const Divider(height: 24),
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
                    '仅对可信备份开启。静态校验后保存并停用，已有规则与信任保持不变；请到来源管理手动启用。',
                  ),
                  value: restoreSourceRules,
                  onChanged: preview.incomingSourceRules == 0
                      ? null
                      : (value) => setState(() => restoreSourceRules = value),
                ),
              ],
              if (preview.incomingApkPackages + preview.keptApkPackages >
                  0) ...[
                Text(
                  'APK 包：可新增暂存 ${preview.incomingApkPackages} 个；保留本机 ${preview.keptApkPackages} 个。',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('暂存APK包（不加载、不导入信任）'),
                  subtitle: const Text(
                    '重新核验包名、版本、签名与哈希；不支持验签的平台仅校验文件且不可执行。加载前需逐包确认；拒绝降级、换签名及同版本异内容。',
                  ),
                  value: restoreApkPackages,
                  onChanged: preview.incomingApkPackages == 0
                      ? null
                      : (value) => setState(() => restoreApkPackages = value),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('替换已有非敏感设置'),
                subtitle: const Text('关闭时保留本机设置，仅补充缺失键；各模块已有书架设置始终保留'),
                value: replaceSettings,
                onChanged: (value) => setState(() => replaceSettings = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('追踪身份冲突保留本机'),
                subtitle: const Text('关闭后，身份冲突将中止导入；仅影响本机'),
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

/// Only called after verified import and its database/settings commit succeed.
Future<bool?> confirmDeleteRestoredBackup(
  BuildContext context,
  String original,
) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('恢复成功，要删除原备份吗？'),
    content: SingleChildScrollView(
      child: Text(
        '建议保留备份。删除仅影响以下原始 ZIP，保留下载及其他文件。\n\n$original\n\n删除不可撤销；权限不足时将保留文件。',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('保留备份'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('删除这个原备份'),
      ),
    ],
  ),
);
