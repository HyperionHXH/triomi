import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/source/http_client.dart';
import '../../core/source/rule_schema.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';

/// 来源与规则管理。
///
/// 三条导入路径：粘贴规则文本、从剪贴板、从 URL 拉取。
/// 导入失败必须显示具体原因（哪一项校验没过），不能只提示「导入失败」。
class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  bool _busy = false;

  Future<void> _importFromText(String text, {String? repoUrl}) async {
    setState(() => _busy = true);
    try {
      final descriptor = await ref
          .read(sourceRegistryProvider)
          .importFromText(text, repoUrl: repoUrl);
      await ref.read(sourcesProvider.notifier).refresh();
      if (!mounted) return;
      _toast('已导入「${descriptor.name}」');
    } on RuleFormatException catch (error) {
      if (!mounted) return;
      _toast('规则有问题：${error.message}');
    } catch (error) {
      if (!mounted) return;
      _toast('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromUrl(String url) async {
    setState(() => _busy = true);
    try {
      final response = await ref
          .read(sourceHttpClientProvider)
          .send(SourceRequest(url: url), sourceId: 'import');
      if (!mounted) return;
      await _importFromText(response.body, repoUrl: url);
    } catch (error) {
      if (!mounted) return;
      _toast('拉取规则失败：$error');
      setState(() => _busy = false);
    }
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _toast('剪贴板里没有文本');
      return;
    }
    await _importFromText(text, repoUrl: 'clipboard');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourcesProvider);

    return PageScaffold(
      title: '来源与规则',
      actions: <Widget>[
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        IconButton(
          tooltip: '从剪贴板导入规则',
          onPressed: _busy ? null : _importFromClipboard,
          icon: const Icon(Icons.content_paste),
        ),
        IconButton(
          tooltip: '导入规则',
          onPressed: _busy ? null : _showImportSheet,
          icon: const Icon(Icons.add),
        ),
      ],
      child: sources.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyStateView(
          icon: Icons.error_outline,
          title: '来源加载失败',
          message: '$error',
        ),
        data: (snapshot) {
          if (snapshot.entries.isEmpty && snapshot.failures.isEmpty) {
            return EmptyStateView(
              icon: Icons.extension_outlined,
              title: '还没有来源',
              message: '导入一份规则 JSON，或从规则仓库地址拉取，来源就会出现在这里。',
              action: FilledButton.icon(
                onPressed: _showImportSheet,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('导入规则'),
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: <Widget>[
              for (final entry in snapshot.entries)
                _SourceTile(
                  entry: entry,
                  onToggle: (value) => ref
                      .read(sourcesProvider.notifier)
                      .setEnabled(entry.descriptor.id, enabled: value),
                  onDelete: () => _confirmDelete(entry),
                  onAccount: entry.source is AccountProvider
                      ? () => _showAccountSheet(entry)
                      : null,
                ),
              for (final failure in snapshot.failures)
                _FailureTile(failure: failure),
            ],
          );
        },
      ),
    );
  }

  /// 账号管理：显示登录状态，支持登录 / 登出（凭据不落日志，只进安全存储）。
  Future<void> _showAccountSheet(SourceEntry entry) async {
    final provider = entry.source as AccountProvider;
    final accountController = TextEditingController();
    final passwordController = TextEditingController();
    var busy = false;
    String? message;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text('${entry.descriptor.name} · 账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    provider.isLoggedIn
                        ? Icons.verified_user_outlined
                        : Icons.person_off_outlined,
                    size: 18,
                    color: provider.isLoggedIn
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    provider.isLoggedIn ? '已登录' : '未登录',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  message!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: accountController,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: '用户名或邮箱',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: passwordController,
                enabled: !busy,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            if (provider.isLoggedIn)
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await provider.logout();
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          _toast('已退出登录');
                        } catch (error) {
                          setState(() {
                            message = '退出失败：$error';
                            busy = false;
                          });
                        }
                      },
                child: const Text('退出登录'),
              ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final account = accountController.text.trim();
                      final password = passwordController.text;
                      if (account.isEmpty || password.isEmpty) {
                        setState(() => message = '请填写账号与密码');
                        return;
                      }
                      setState(() {
                        busy = true;
                        message = null;
                      });
                      try {
                        await provider.login(account, password);
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        _toast('登录成功');
                      } catch (error) {
                        setState(() {
                          message = '$error';
                          busy = false;
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(SourceEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除来源'),
        content: Text('确定要移除「${entry.descriptor.name}」吗？书架里来自该源的内容将无法继续更新。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(sourcesProvider.notifier).remove(entry.descriptor.id);
    if (!mounted) return;
    _toast('已移除「${entry.descriptor.name}」');
  }

  Future<void> _showImportSheet() async {
    final controller = TextEditingController();
    final urlController = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.md,
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('导入规则', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '粘贴声明式规则（JSON）。规则只描述如何解析站点，应用不内置任何内容源。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: context.palette.mutedForeground),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              maxLines: 6,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: '{\n  "id": "my-manga",\n  "name": "我的漫画源",\n  "type": "manga",\n  ...\n}',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: <Widget>[
                TextButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    controller.text = data?.text ?? '';
                  },
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('粘贴'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () async {
                    final text = controller.text;
                    if (text.trim().isEmpty) return;
                    Navigator.of(sheetContext).pop();
                    await _importFromText(text);
                  },
                  child: const Text('导入'),
                ),
              ],
            ),
            const Divider(height: AppSpacing.xl),
            Text('从远程地址拉取', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      hintText: 'https://example.com/my-rule.json',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                FilledButton.tonal(
                  onPressed: () async {
                    final url = urlController.text.trim();
                    if (url.isEmpty) return;
                    Navigator.of(sheetContext).pop();
                    await _importFromUrl(url);
                  },
                  child: const Text('拉取'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    urlController.dispose();
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.entry,
    required this.onToggle,
    required this.onDelete,
    this.onAccount,
  });

  final SourceEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  /// 有账号能力的来源显示「账号」入口（登录 / 登出）。
  final VoidCallback? onAccount;

  @override
  Widget build(BuildContext context) {
    final descriptor = entry.descriptor;
    final theme = Theme.of(context);
    final palette = context.palette;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxs,
      ),
      leading: CircleAvatar(
        backgroundColor: palette.coverPlaceholder,
        child: Text(
          descriptor.type.label.characters.first,
          style: theme.textTheme.bodySmall,
        ),
      ),
      title: Text(descriptor.name),
      subtitle: Text(
        <String>[
          descriptor.type.label,
          descriptor.kind.label,
          if (descriptor.version != null) 'v${descriptor.version}',
          if (descriptor.requireLogin) '需登录',
          if (descriptor.capabilities.isNotEmpty)
            descriptor.capabilities.map((c) => c.label).join('·'),
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onAccount != null)
            IconButton(
              tooltip: '账号',
              onPressed: onAccount,
              icon: const Icon(Icons.person_outline, size: 20),
            ),
          Switch(value: entry.enabled, onChanged: onToggle),
          IconButton(
            tooltip: '移除',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

class _FailureTile extends StatelessWidget {
  const _FailureTile({required this.failure});

  final SourceFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxs,
      ),
      leading: Icon(Icons.error_outline, color: theme.colorScheme.error),
      title: Text(failure.name),
      subtitle: Text('规则无法加载：${failure.message}'),
      isThreeLine: true,
    );
  }
}
