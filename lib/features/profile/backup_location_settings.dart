import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup/backup_location.dart';
import '../../core/storage/preferences.dart';

/// The same external-backup policy is used by onboarding and backup settings.
class BackupLocationSettings extends ConsumerStatefulWidget {
  const BackupLocationSettings({super.key, this.onChanged});
  final VoidCallback? onChanged;
  @override
  ConsumerState<BackupLocationSettings> createState() =>
      _BackupLocationSettingsState();
}

class _BackupLocationSettingsState
    extends ConsumerState<BackupLocationSettings> {
  BackupLocation? _location;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final location = await BackupLocationStore(ref.read(preferencesProvider))
          .current();
      if (mounted) setState(() => _location = location);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _choose() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final location = await BackupLocationStore(ref.read(preferencesProvider))
          .choose();
      if (location != null && mounted) {
        setState(() => _location = location);
        widget.onChanged?.call();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '无法授权备份目录：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_outlined),
        title: const Text('备份保存目录'),
        subtitle: SelectableText(
          _location == null
              ? '尚未授权：首次导出前请选择应用私有目录以外的文件夹'
              : _location!.isAppPrivate
              ? '应用私有目录（卸载会删除）：${_location!.label}'
              : _location!.label,
        ),
        trailing: TextButton(
          onPressed: _busy ? null : _choose,
          child: const Text('选择目录'),
        ),
      ),
      const Text(
        '请选择 iCloud Drive 或其他应用私有目录以外的文件夹。外部备份不会由应用在卸载时主动删除，重新安装后需重新授权；应用私有目录会随卸载删除。系统或云端提供程序可撤销权限或删除文件，请另存副本。下载与缓存默认仍在应用数据目录。',
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
