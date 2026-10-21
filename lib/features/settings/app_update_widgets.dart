import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import 'app_update_service.dart';

const _actionSize = Size(0, 48);

/// Presentation only: progress and cancellation remain owned by the page.
class AppUpdateTransferView extends StatelessWidget {
  const AppUpdateTransferView({
    super.key,
    required this.versionLabel,
    required this.operationLabel,
    required this.progress,
    required this.onCancel,
    this.cancelling = false,
  });

  final String versionLabel;
  final String operationLabel;
  final AppUpdateProgress? progress;
  final VoidCallback? onCancel;
  final bool cancelling;

  @override
  Widget build(BuildContext context) {
    final phase = progress?.phase;
    final copying = phase == 'copy' || phase == 'download';
    final total = progress?.total;
    final bytes = progress?.bytes ?? 0;
    final fraction = copying && total != null && total > 0
        ? (bytes / total).clamp(0.0, 1.0).toDouble()
        : null;
    final (title, icon, hint) = switch (phase) {
      'copy' => (
        '正在暂存更新文件',
        Icons.file_copy_outlined,
        '正在复制到本次更新的暂存位置，随后继续核验。',
      ),
      'download' => ('正在下载更新', Icons.downloading_outlined, '下载完毕后还需核验，不会自动安装。'),
      'metadata' => (
        '正在读取更新校验信息',
        Icons.manage_search_outlined,
        '正在读取发布清单与文件摘要，尚未开始下载更新文件。',
      ),
      'verify' => (
        '正在核验更新文件',
        Icons.fact_check_outlined,
        '文件已接收，正在检查完整性与实际应用信息。',
      ),
      'signature' => (
        '正在核验 APK 签名',
        Icons.fact_check_outlined,
        '正在核对安装包签名、包名与实际版本。',
      ),
      'bundle' => (
        '正在核验 Windows 更新包',
        Icons.inventory_2_outlined,
        '正在逐一核对 ZIP 成员与应用程序版本。',
      ),
      'manifest' => ('正在整理核验结果', Icons.fact_check_outlined, '正在保存完整性清单，尚未安装。'),
      'handoff' => (
        '正在重新核验更新文件',
        Icons.fact_check_outlined,
        '交接前再次检查更新文件，尚未完成安装。',
      ),
      'verified' => ('核验已完成', Icons.fact_check_outlined, '正在准备更新确认；仍需你选择下一步。'),
      _ => (
        '正在处理更新',
        Icons.hourglass_top_outlined,
        '$operationLabel。请稍候；不会自动安装更新。',
      ),
    };
    return _UpdateCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusHeading(
            icon: icon,
            title: cancelling ? '正在取消' : title,
            subtitle: versionLabel,
          ),
          const SizedBox(height: AppSpacing.lg),
          LinearProgressIndicator(
            value: cancelling ? null : fraction,
            semanticsLabel: cancelling ? '正在取消更新操作' : title,
            semanticsValue: fraction == null
                ? null
                : '${(fraction * 100).toStringAsFixed(1)}%',
          ),
          const SizedBox(height: AppSpacing.sm),
          if (copying)
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xxs,
              children: [
                if (fraction != null)
                  Text(
                    '${(fraction * 100).toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                Text(
                  total != null && total > 0
                      ? '${_mib(bytes)} / ${_mib(total)}'
                      : '${_mib(bytes)} · 总大小待确认',
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.sm),
          Text(cancelling ? '正在停止操作并清理本次暂存文件，请稍候。' : hint),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            key: const ValueKey('app-update-transfer-cancel'),
            style: OutlinedButton.styleFrom(minimumSize: _actionSize),
            onPressed: cancelling ? null : onCancel,
            icon: const Icon(Icons.close),
            label: Text(cancelling ? '正在取消' : '取消操作'),
          ),
        ],
      ),
    );
  }
}

class AppUpdateReadyView extends StatelessWidget {
  const AppUpdateReadyView({
    super.key,
    required this.candidate,
    required this.busy,
    this.onInstall,
    this.onRevealWindows,
    this.onDiscard,
  });

  final AppUpdateCandidate candidate;
  final bool busy;
  final VoidCallback? onInstall;
  final VoidCallback? onRevealWindows;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final android = _canInstallAndroid(candidate);
    final windows = _canRevealWindows(candidate);
    return _UpdateCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CandidateSummary(candidate: candidate),
          const SizedBox(height: AppSpacing.md),
          _CandidateDetails(candidate: candidate),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              if (android)
                FilledButton.icon(
                  key: const ValueKey('app-update-ready-install'),
                  style: FilledButton.styleFrom(minimumSize: _actionSize),
                  onPressed: busy ? null : onInstall,
                  icon: const Icon(Icons.install_mobile_outlined),
                  label: const Text('立即安装'),
                ),
              if (windows)
                FilledButton.icon(
                  key: const ValueKey('app-update-ready-reveal'),
                  style: FilledButton.styleFrom(minimumSize: _actionSize),
                  onPressed: busy ? null : onRevealWindows,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开文件位置'),
                ),
              TextButton(
                key: const ValueKey('app-update-ready-discard'),
                style: TextButton.styleFrom(minimumSize: _actionSize),
                onPressed: busy ? null : onDiscard,
                child: const Text('移除暂存文件'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AppUpdateHandoffView extends StatelessWidget {
  const AppUpdateHandoffView({
    super.key,
    required this.windows,
    required this.onRefreshCurrent,
  });

  final bool windows;
  final VoidCallback? onRefreshCurrent;

  @override
  Widget build(BuildContext context) => _UpdateCard(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusHeading(
          icon: windows ? Icons.folder_open_outlined : Icons.open_in_new,
          title: windows ? '已交给文件资源管理器' : '已交给系统安装器',
          subtitle: '尚未确认安装完成',
        ),
        const SizedBox(height: AppSpacing.md),
        if (windows) ...[
          const _InstallStep(number: '1', text: '在文件资源管理器中找到已选中的 ZIP。'),
          const _InstallStep(
            number: '2',
            text: '选择“全部解压缩”，解压到一个新文件夹，保留全部 DLL 和 data 文件。',
          ),
          const _InstallStep(
            number: '3',
            text: '关闭 Triomi，从新文件夹运行 triomi.exe，并将快捷方式指向新位置。',
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text('原有应用数据保留。Triomi 不会自动覆盖正在运行的程序。'),
        ] else
          const Text('请在系统安装器中确认是否安装。若取消安装，当前应用保持不变；返回后可重新读取实际版本。'),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: _actionSize),
          onPressed: onRefreshCurrent,
          icon: const Icon(Icons.refresh),
          label: const Text('重新读取当前版本'),
        ),
      ],
    ),
  );
}

/// Returns intent only. The caller must recheck and perform the actual handoff.
Future<bool?> showAppUpdateReadyDialog(
  BuildContext context, {
  required AppUpdateCandidate candidate,
  required bool windows,
  bool downloaded = false,
}) {
  final actionable = windows
      ? _canRevealWindows(candidate)
      : _canInstallAndroid(candidate);
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.all(AppSpacing.md),
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(
        actionable
            ? (downloaded ? '下载完成' : (windows ? '使用更新包' : '安装更新'))
            : '此文件不能用于更新',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CandidateSummary(candidate: candidate),
            const SizedBox(height: AppSpacing.md),
            if (actionable)
              Text(
                windows
                    ? '仅打开 ZIP 所在位置。请解压到新文件夹，关闭 Triomi 后运行新版本；不会自动替换或安装。'
                    : '将再次核验并打开系统安装器，最终是否安装由你确认。不会清除应用数据。',
              ),
            const SizedBox(height: AppSpacing.sm),
            _CandidateDetails(candidate: candidate),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('app-update-ready-later'),
          style: TextButton.styleFrom(minimumSize: _actionSize),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(actionable ? '稍后安装' : '关闭'),
        ),
        if (actionable)
          FilledButton(
            key: const ValueKey('app-update-ready-confirm'),
            style: FilledButton.styleFrom(minimumSize: _actionSize),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(windows ? '打开文件位置' : '立即安装'),
          ),
      ],
    ),
  );
}

Future<bool?> showStartupUpdateDialog(
  BuildContext context, {
  required AppUpdateRelease release,
  required bool windows,
}) => showDialog<bool>(
  context: context,
  builder: (context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.center,
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.system_update_alt_rounded,
                  size: 34,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '有新版本可用',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '${release.version}  ·  ${release.tag}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '已为 ${windows ? 'Windows' : 'Android'} 准备官方更新。你可以现在查看并下载，也可以稍后再决定；不会自动安装。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  release.notes.trim(),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('app-startup-update-later'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('稍后再说'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('app-startup-update-open'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Text('查看更新'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
);

Future<bool?> showAppUpdatePermissionDialog(BuildContext context) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        constraints: const BoxConstraints(maxWidth: 560),
        title: const Text('允许 Triomi 请求安装'),
        content: const Text(
          'Android 需要你在系统设置中允许 Triomi 安装应用。此授权仅针对 Triomi，不会直接开始安装。'
          '\n\n你可以选择不授权。若授权，请返回此页，再次确认更新文件并打开系统安装器。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('app-update-permission-cancel'),
            style: TextButton.styleFrom(minimumSize: _actionSize),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('暂不授权'),
          ),
          FilledButton(
            key: const ValueKey('app-update-permission-settings'),
            style: FilledButton.styleFrom(minimumSize: _actionSize),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('打开系统设置'),
          ),
        ],
      ),
    );

bool _canInstallAndroid(AppUpdateCandidate candidate) =>
    candidate.canInstall &&
    candidate.offered.platform == 'android' &&
    candidate.current.platform == 'android' &&
    candidate.signatureVerified;

bool _canRevealWindows(AppUpdateCandidate candidate) =>
    candidate.canInstall &&
    candidate.offered.platform == 'windows' &&
    candidate.current.platform == 'windows' &&
    candidate.manifestPath != null;

String _mib(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
String _version(AppUpdateInfo info) =>
    '${info.version}（构建 ${info.versionCode}）';

String _candidateExplanation(AppUpdateCandidate candidate) =>
    switch (candidate.decision) {
      'wrongPackage' => '此文件不属于当前应用或平台，不能用于更新 Triomi。',
      'wrongSigner' => '安装包签名未通过核验，或与当前 Triomi 的签名不同，不能安装。',
      'downgrade' => '此文件的版本比当前版本更旧，不能用于降级。',
      'alreadyInstalled' => '此版本及文件内容与当前应用一致，无需重复安装。',
      'sameVersionChanged' => '构建号相同，但文件内容不同，不能作为更新安装。',
      'upgrade' when _canInstallAndroid(candidate) =>
        'APK 签名、包名与版本核验已通过，等待你确认安装。',
      'upgrade' when _canRevealWindows(candidate) =>
        'ZIP、成员清单与程序版本已核验。Windows 包未签名，完整性校验不等同于发布者签名。',
      'upgrade' => '此文件尚不具备可用的安装或交接条件，不能继续更新。',
      _ => '无法确认此文件可用于更新，未开放安装。',
    };

class _CandidateSummary extends StatelessWidget {
  const _CandidateSummary({required this.candidate});
  final AppUpdateCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final valid = _canInstallAndroid(candidate) || _canRevealWindows(candidate);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusHeading(
          icon: valid ? Icons.check_circle_outline : Icons.info_outline,
          title: valid ? '更新文件已就绪' : '不能安装此文件',
          subtitle: _version(candidate.offered),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '当前  ${_version(candidate.current)}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          '更新至  ${_version(candidate.offered)}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(_candidateExplanation(candidate)),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xxs,
          children: [
            Text(
              candidate.offered.platform == 'windows'
                  ? 'Windows ZIP'
                  : candidate.offered.platform == 'android'
                  ? 'Android APK'
                  : '更新文件',
            ),
            Text(_mib(candidate.bytes)),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '来源：${candidate.source}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _CandidateDetails extends StatelessWidget {
  const _CandidateDetails({required this.candidate});
  final AppUpdateCandidate candidate;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
    title: const Text('文件与核验详情'),
    children: [
      _Detail(label: '文件位置', value: candidate.path),
      if (candidate.manifestPath != null)
        _Detail(label: '完整性清单', value: candidate.manifestPath!),
      _Detail(label: '文件大小', value: '${candidate.bytes} 字节'),
      _Detail(label: '来源', value: candidate.source),
      _Detail(label: '核验结果', value: _candidateExplanation(candidate)),
      _IdentityDetails(label: '当前应用', info: candidate.current),
      _IdentityDetails(label: '更新文件', info: candidate.offered),
      _Detail(
        label: '签名验证',
        value: candidate.offered.platform == 'windows'
            ? '未验证发布者签名；Windows 包未签名'
            : candidate.signatureVerified
            ? 'APK 签名已验证'
            : '未通过 APK 签名验证',
      ),
    ],
  );
}

class _IdentityDetails extends StatelessWidget {
  const _IdentityDetails({required this.label, required this.info});
  final String label;
  final AppUpdateInfo info;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Detail(label: '$label · 版本', value: _version(info)),
      _Detail(label: '$label · 包名 / 标识', value: info.packageName),
      _Detail(label: '$label · SHA-256', value: info.sha256),
      if (info.artifactSha256 != null)
        _Detail(label: '$label · EXE SHA-256', value: info.artifactSha256!),
      if (info.signerSha256 != null)
        _Detail(label: '$label · 签名证书 SHA-256', value: info.signerSha256!),
    ],
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: AppSpacing.xxs),
          SelectableText(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

class _StatusHeading extends StatelessWidget {
  const _StatusHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    ],
  );
}

class _InstallStep extends StatelessWidget {
  const _InstallStep({required this.number, required this.text});
  final String number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$number.', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: AppCard(
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}
