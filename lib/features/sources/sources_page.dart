import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database_provider.dart';
import '../../core/models/media_type.dart';
import '../../core/source/bangumi_route_policy.dart';
import '../../core/source/http_client.dart';
import '../../core/source/js/js_source.dart';
import '../../core/source/kazumi_repository.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/mangadex_preferences.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/rule_schema.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../downloads/data/download_repository.dart';
import '../manga/manga_extension_details_page.dart';
import '../manga/manga_extensions_page.dart';
import '../manga/windows_mihon_settings_page.dart';
import 'catalog_sheet.dart';
import 'kazumi_repositories_sheet.dart';
import 'source_filter_controls.dart';

/// 来源与规则管理。
///
/// 三条导入路径：粘贴规则文本、从剪贴板、从 URL 拉取。
/// 导入失败必须显示具体原因（哪一项校验没过），不能只提示「导入失败」。
class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key, this.initialType, this.initialQuery});

  final MediaType? initialType;
  final String? initialQuery;

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  bool _busy = false;
  late SourceFilters _filters;
  late MediaType _type;
  bool _updating = false;
  final _updates = <String, KazumiUpdateResult>{};

  @override
  void initState() {
    super.initState();
    final preferences = ref.read(preferencesProvider);
    final legacy = SourceFilters.fromJson(
      preferences.get<Object?>('sources.filters.installed'),
    );
    _type =
        widget.initialType ??
        MediaType.tryParse(preferences.get<String>('sources.selectedType')) ??
        legacy.type ??
        MediaType.anime;
    _filters = SourceFilters.fromJson(
      preferences.get<Object?>('sources.filters.installed.${_type.name}') ??
          preferences.get<Object?>('sources.filters.installed'),
    ).copyWith(clearType: true, query: widget.initialQuery);
    if (_type == MediaType.anime) unawaited(_refreshAnimeUpdates());
  }

  void _setFilters(SourceFilters value) {
    setState(() => _filters = value);
    ref
        .read(preferencesProvider)
        .set('sources.filters.installed.${_type.name}', value.toJson());
  }

  void _selectType(MediaType value) {
    if (_type == value) return;
    if (widget.initialType != null && widget.initialType != value) return;
    final preferences = ref.read(preferencesProvider);
    setState(() {
      _type = value;
      _filters = SourceFilters.fromJson(
        preferences.get<Object?>('sources.filters.installed.${value.name}') ??
            preferences.get<Object?>('sources.filters.installed'),
      ).copyWith(clearType: true);
    });
    preferences.set('sources.selectedType', value.name);
    if (value == MediaType.anime) unawaited(_refreshAnimeUpdates());
  }

  Future<void> _refreshAnimeUpdates({bool update = false, String? id}) async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await ref.read(sourcesProvider.future);
      final saved = ref
          .read(preferencesProvider)
          .get<Map<dynamic, dynamic>>('kazumi.repositories');
      final repositories = saved == null
          ? {KazumiRepository.defaultRepository: true}
          : {
              for (final entry in saved.entries)
                '${entry.key}': entry.value == true,
            };
      final results =
          await KazumiRepository(
            ref.read(sourceRegistryProvider),
            allowPublicFallback: ref.read(bangumiMirrorEnabledProvider),
          ).refreshInstalled(
            repositories: repositories,
            update: update,
            sourceIds: id == null ? null : {id},
          );
      if (update) await ref.read(sourcesProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        for (final result in results) {
          _updates[result.id] = result;
        }
      });
      if (update) {
        final failed = results.where((result) => result.failed).toList();
        final changed = results.where((result) => result.updated).length;
        if (failed.isEmpty) {
          _toast(results.isEmpty ? '没有已安装的 Kazumi 插件' : '已更新 $changed 个；其余已核验');
        } else {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('更新完成 · 成功 $changed · 未更新 ${failed.length}'),
              content: SingleChildScrollView(
                child: Text(
                  [
                    '每个失败插件的原规则和启停状态均保留。',
                    for (final result in failed)
                      '${result.name}\n${result.message}',
                  ].join('\n\n'),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) _toast('检查插件更新失败：$error');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _importFromText(String text, {String? repoUrl}) async {
    setState(() => _busy = true);
    try {
      final descriptor = await ref
          .read(sourceRegistryProvider)
          .importFromText(text, repoUrl: repoUrl);
      await ref.read(sourcesProvider.notifier).refresh();
      if (!mounted) return;
      _selectType(descriptor.type);
      _toast(
        widget.initialType != null && descriptor.type != widget.initialType
            ? '已导入「${descriptor.name}」；请在${descriptor.type.label}设置中管理'
            : '已导入「${descriptor.name}」',
      );
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

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourcesProvider);
    return PageScaffold(
      title: _type == MediaType.anime
          ? '番剧插件'
          : widget.initialType == null
          ? '来源管理'
          : '${_type.label}来源',
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
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.initialType == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SegmentedButton<MediaType>(
                showSelectedIcon: false,
                segments: [
                  for (final type in MediaType.values)
                    ButtonSegment(value: type, label: Text(type.label)),
                ],
                selected: {_type},
                onSelectionChanged: (value) => _selectType(value.single),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _showAddSources,
                  icon: const Icon(Icons.add),
                  label: Text(
                    _type == MediaType.anime ? '添加插件来源' : '添加${_type.label}来源',
                  ),
                ),
                if (_type == MediaType.anime)
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: _updating
                            ? null
                            : () => _refreshAnimeUpdates(update: true),
                        icon: _updating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.update),
                        label: const Text('全部更新'),
                      ),
                      TextButton(
                        onPressed: _updating ? null : _refreshAnimeUpdates,
                        child: const Text('检查更新'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Expanded(
            child: sources.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyStateView(
                icon: Icons.error_outline,
                title: '来源加载失败',
                message: '$error',
              ),
              data: (snapshot) {
                final scopedEntries = snapshot.entries
                    .where(
                      (entry) =>
                          entry.descriptor.type == _type &&
                          (developmentSourcesEnabled ||
                              !developmentSourceIds.contains(
                                entry.descriptor.id,
                              )),
                    )
                    .toList();
                final scopedFailures = snapshot.failures
                    .where(
                      (failure) =>
                          failure.type == _type &&
                          (developmentSourcesEnabled ||
                              !developmentSourceIds.contains(failure.id)),
                    )
                    .toList();

                final visible = scopedEntries
                    .where(
                      (entry) =>
                          _type == MediaType.anime ||
                          _filters.matches(
                            languages: [entry.descriptor.lang],
                            nsfw: entry.descriptor.nsfw,
                            mediaType: entry.descriptor.type,
                            searchText: [
                              entry.descriptor.id,
                              entry.descriptor.name,
                            ],
                          ),
                    )
                    .toList();
                final failures = scopedFailures
                    .where(
                      (failure) =>
                          _type == MediaType.anime ||
                          _filters.matches(
                            languages: [failure.lang],
                            nsfw: failure.nsfw,
                            mediaType: failure.type,
                            searchText: [failure.id, failure.name],
                          ),
                    )
                    .toList();
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  children: <Widget>[
                    if (_type != MediaType.anime)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                        ),
                        child: SourceFilterControls(
                          filters: _filters,
                          types: const [],
                          languages: [
                            ...scopedEntries.map(
                              (entry) => entry.descriptor.lang,
                            ),
                            ...scopedFailures.map((failure) => failure.lang),
                          ],
                          onChanged: _setFilters,
                          visibleCount: visible.length + failures.length,
                          totalCount:
                              scopedEntries.length + scopedFailures.length,
                        ),
                      ),
                    if (_type != MediaType.anime &&
                        visible.isEmpty &&
                        failures.isEmpty)
                      Center(
                        child: TextButton(
                          onPressed: () => _setFilters(const SourceFilters()),
                          child: const Text('没有匹配的来源 · 清除筛选'),
                        ),
                      ),
                    if (scopedEntries.isEmpty && scopedFailures.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('尚无${_type.label}来源，请添加仓库或规则。'),
                      ),
                    for (final entry in visible)
                      _SourceTile(
                        entry: entry,
                        updateStatus: _updates[entry.descriptor.id]?.message,
                        updating: _updating,
                        onUpdate: entry.source is KazumiSource
                            ? () => _refreshAnimeUpdates(
                                update: true,
                                id: entry.descriptor.id,
                              )
                            : null,
                        onToggle: (value) => ref
                            .read(sourcesProvider.notifier)
                            .setEnabled(entry.descriptor.id, enabled: value),
                        onDelete: () => _confirmDelete(entry),
                        onAccount: entry.source is AccountProvider
                            ? () => _showAccountSheet(entry)
                            : null,
                        onWebSession:
                            entry.enabled &&
                                !(entry.source is MihonSource &&
                                    !kIsWeb &&
                                    defaultTargetPlatform ==
                                        TargetPlatform.windows)
                            ? switch (entry.source) {
                                final MihonSource source =>
                                  () => _openMihonSession(source),
                                final KazumiSource source =>
                                  () => _openRuleSession(source),
                                _ => null,
                              }
                            : null,
                        onSettings: entry.source is MihonSource && entry.enabled
                            ? () async {
                                final source = entry.source as MihonSource;
                                try {
                                  final opened = await openMihonPreferences(
                                    context,
                                    source,
                                  );
                                  if (!opened && mounted) {
                                    _toast('当前平台不支持 APK 来源设置');
                                  }
                                } catch (error) {
                                  if (mounted) _toast('来源设置不可用：$error');
                                }
                              }
                            : entry.enabled &&
                                  entry.source is JsSource &&
                                  supportsMangaDexDataSaver(
                                    entry.descriptor.id,
                                    entry.descriptor.version,
                                  )
                            ? _showMangaDexSettings
                            : null,
                      ),
                    for (final failure in failures)
                      _FailureTile(failure: failure),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddSources() async {
    if (_type == MediaType.anime) {
      var import = false;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => KazumiRepositoriesSheet(
          onImport: () {
            import = true;
            Navigator.pop(context);
          },
        ),
      );
      if (!mounted) return;
      if (import) await _showImportSheet();
      await ref.read(sourcesProvider.notifier).refresh();
      if (mounted) await _refreshAnimeUpdates();
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '添加${_type.label}来源',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (_type == MediaType.manga)
                ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('漫画扩展与仓库'),
                  subtitle: const Text('Mihon / Komikku'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, 'mihon'),
                ),
              if (_type == MediaType.novel)
                const ListTile(
                  leading: Icon(Icons.manage_accounts_outlined),
                  title: Text('内置小说站点'),
                  subtitle: Text('轻之国度、轻书架 · 管理账号'),
                ),
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: Text('${_type.label}规则目录'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, 'catalog'),
              ),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('手动导入规则'),
                subtitle: const Text('JSON 规则文本或地址，非 APK 仓库'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, 'import'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'mihon':
        await _showMihonExtensions();
      case 'catalog':
        await _showCatalog();
      case 'import':
        await _showImportSheet();
    }
  }

  Future<void> _showMangaDexSettings() async {
    final preferences = ref.read(preferencesProvider);
    var dataSaver = preferences.get<bool>(mangaDexDataSaverKey) ?? false;
    var saving = false;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SwitchListTile(
            title: const Text('MangaDex 低流量图片'),
            subtitle: const Text('在线章节优先使用节流图片，无可用版本时使用原图；缓存与下载不变。'),
            value: dataSaver,
            onChanged: saving
                ? null
                : (value) async {
                    setSheetState(() => saving = true);
                    try {
                      await preferences.set(mangaDexDataSaverKey, value);
                      if (context.mounted) {
                        setSheetState(() => dataSaver = value);
                      }
                    } catch (error) {
                      if (mounted) _toast('图片偏好保存失败：$error');
                    } finally {
                      if (context.mounted) {
                        setSheetState(() => saving = false);
                      }
                    }
                  },
          ),
        ),
      ),
    );
  }

  Future<void> _showCatalog() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CatalogSheet(type: _type),
    );
    if (mounted) await ref.read(sourcesProvider.notifier).refresh();
  }

  Future<void> _openMihonSession(MihonSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await source.openWebSession();
      if (mounted && saved) _toast('站点会话已保存');
    } catch (error) {
      if (mounted) _toast('打开来源网站失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRuleSession(KazumiSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await source.openWebSession();
      if (mounted && saved) _toast('站点会话已保存；请重试来源，不代表验证通过');
    } catch (_) {
      if (mounted) _toast('当前平台无法打开规则站点验证');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showMihonExtensions() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MangaExtensionsPage(initialQuery: widget.initialQuery),
      ),
    );
    if (mounted) {
      // Mihon enabled state lives in Preferences, which is captured while
      // constructing SourceRegistry. Recreate it before refreshing entries.
      ref.invalidate(sourceRegistryProvider);
      await ref.read(sourcesProvider.notifier).refresh();
    }
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
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.lg,
          ),
          title: Text('${entry.descriptor.name} · 账号'),
          content: Column(
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
                        // F1：登出清理。缓存正文可能含付费解锁内容，
                        // 必须清；离线文件由用户选择。
                        final deleteFiles = await showDialog<bool>(
                          context: dialogContext,
                          builder: (confirmContext) => AlertDialog(
                            title: const Text('退出登录'),
                            content: const Text(
                              '退出会清除本站的登录凭据、章节缓存的正文与离线索引。\n是否同时删除已下载的离线文件？',
                            ),
                            actions: <Widget>[
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(confirmContext).pop(false),
                                child: const Text('保留文件'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(confirmContext).pop(true),
                                child: const Text('一并删除'),
                              ),
                            ],
                          ),
                        );
                        // 用户取消了清理对话框：不登出。
                        if (deleteFiles == null) return;
                        setState(() => busy = true);
                        try {
                          await provider.logout();
                          await purgeSourceOfflineData(
                            ref.read(databaseProvider),
                            provider.descriptor.id,
                            deleteFiles: deleteFiles,
                          );
                          ref.invalidate(sourcesProvider);
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          _toast('已退出登录并清理本地数据');
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
                        ref.invalidate(sourcesProvider);
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '导入${_type.label}规则',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '仅支持 JSON 规则；APK 请到漫画扩展安装。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: context.palette.mutedForeground),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                maxLines: 6,
                minLines: 4,
                decoration: InputDecoration(
                  hintText:
                      '{"id": "my-source", "name": "我的来源", "type": "${_type.name}", ...}',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
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
    this.onWebSession,
    this.onSettings,
    this.onUpdate,
    this.updateStatus,
    this.updating = false,
  });

  final SourceEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  /// 有账号能力的来源显示「账号」入口（登录 / 登出）。
  final VoidCallback? onAccount;
  final VoidCallback? onWebSession;
  final VoidCallback? onSettings;
  final VoidCallback? onUpdate;
  final String? updateStatus;
  final bool updating;

  @override
  Widget build(BuildContext context) {
    final descriptor = entry.descriptor;
    final theme = Theme.of(context);
    final palette = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: palette.coverPlaceholder,
                    child: Text(
                      descriptor.type.label.characters.first,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          descriptor.name,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          <String>[
                            entry.enabled ? '已启用' : '已停用',
                            descriptor.kind.label,
                            if (descriptor.type != MediaType.anime) ...[
                              sourceLanguageLabel(
                                sourceLanguage(descriptor.lang),
                              ),
                              sourceContentLabel(descriptor.nsfw),
                            ],
                            if (descriptor.version != null)
                              'v${descriptor.version}',
                            if (entry.source case final AccountProvider account)
                              account.isLoggedIn ? '已登录' : '未登录',
                            if (descriptor.requireLogin) '需站点权限',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: palette.mutedForeground,
                          ),
                        ),
                        if (descriptor.baseUrl case final website?)
                          SelectableText(
                            website,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        if (updateStatus case final status?)
                          Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xxs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('启用', style: theme.textTheme.bodySmall),
                      Semantics(
                        label: '启用来源 ${descriptor.name}',
                        child: Switch(
                          value: entry.enabled,
                          onChanged: onToggle,
                        ),
                      ),
                    ],
                  ),
                  if (onUpdate != null)
                    TextButton.icon(
                      onPressed: updating ? null : onUpdate,
                      icon: const Icon(Icons.update, size: 20),
                      label: const Text('检查并更新'),
                    ),
                  if (onAccount != null)
                    TextButton.icon(
                      onPressed: onAccount,
                      icon: const Icon(Icons.person_outline, size: 20),
                      label: const Text('站点账号'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '${descriptor.name}更多操作',
                    onSelected: (value) {
                      switch (value) {
                        case 'session':
                          onWebSession?.call();
                        case 'settings':
                          onSettings?.call();
                        case 'remove':
                          onDelete();
                      }
                    },
                    itemBuilder: (_) => [
                      if (onSettings != null)
                        const PopupMenuItem(
                          value: 'settings',
                          child: Text('来源设置'),
                        ),
                      if (onWebSession != null)
                        const PopupMenuItem(
                          value: 'session',
                          child: Text('打开站点与验证'),
                        ),
                      const PopupMenuItem(value: 'remove', child: Text('移除来源')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(indent: AppSpacing.lg, endIndent: AppSpacing.lg),
      ],
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
      onTap: failure.id.startsWith('mihon:')
          ? () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => MangaExtensionDetailsPage(
                  packageName: failure.id.split(':')[1],
                  diagnostic: failure.message,
                ),
              ),
            )
          : null,
      title: Text(failure.name),
      subtitle: Text(
        '${sourceLanguageLabel(sourceLanguage(failure.lang))} · ${sourceContentLabel(failure.nsfw)}\n来源无法加载：${failure.message}',
      ),
      isThreeLine: true,
    );
  }
}
