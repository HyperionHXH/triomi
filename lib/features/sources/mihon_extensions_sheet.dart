import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/backup/apk_backup_files.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/mihon_installer.dart';
import '../../core/source/mihon_repository.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';

const mihonDefaultRepositoryUrl =
    'https://raw.githubusercontent.com/HyperionHXH/Mihon-Extensions/main/repo/index.json';
const _mihonRepositoriesKey = 'mihon.repositories';
const _mihonEnabledKey = 'mihon.enabledPackages';
const _mihonInstalledKey = 'mihon.installedPackages';
const _mihonHostStatusKey = 'mihon.hostStatus';

/// Mihon/Komikku 扩展管理。下载、启停状态与 Triomi 规则来源分开保存。
class MihonExtensionsSheet extends ConsumerStatefulWidget {
  const MihonExtensionsSheet({super.key});

  @override
  ConsumerState<MihonExtensionsSheet> createState() =>
      _MihonExtensionsSheetState();
}

enum _ExtensionSection { installed, browse, repositories }

class _MihonExtensionsSheetState extends ConsumerState<MihonExtensionsSheet> {
  MihonRepositoryIndex? _index;
  Object? _error;
  bool _loading = false;
  SourceFilters _filters = const SourceFilters(language: 'zh');
  _ExtensionSection _section = _ExtensionSection.installed;

  void _setFilters(SourceFilters value) {
    setState(() => _filters = value);
    unawaited(
      ref
          .read(preferencesProvider)
          .set('sources.filters.mihon', value.toJson()),
    );
  }

  final Set<String> _enabled = <String>{};
  final Map<String, String> _installed = <String, String>{};
  final Map<String, Map<String, Object?>> _hostStatus =
      <String, Map<String, Object?>>{};
  final Set<String> _downloading = <String>{};
  bool _toggling = false;
  List<String> _repositories = <String>[];
  String? _selectedRepository;
  ApkBackupFiles? _apkFiles;
  List<Map<String, Object?>> _pendingApks = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreferences());
  }

  Future<void> _loadPreferences() async {
    final preferences = ref.read(preferencesProvider);
    _filters = SourceFilters.fromJson(
      preferences.get<Object?>('sources.filters.mihon'),
      defaultLanguage: 'zh',
    ).copyWith(clearType: true);
    final rawRepositories = preferences.get<List<Object?>>(
      _mihonRepositoriesKey,
    );
    final repositories = <String>{
      mihonDefaultRepositoryUrl,
      for (final item in rawRepositories ?? const <Object?>[]) item.toString(),
    }.where((item) => item.trim().isNotEmpty).toList();
    final rawEnabled = preferences.get<List<Object?>>(_mihonEnabledKey);
    final rawInstalled = preferences.get<Map<dynamic, dynamic>>(
      _mihonInstalledKey,
    );
    final rawHostStatus = preferences.get<Map<dynamic, dynamic>>(
      _mihonHostStatusKey,
    );
    final apkFiles = ApkBackupFiles(
      root: Directory(
        '${await (await getApplicationSupportDirectory()).resolveSymbolicLinks()}/mihon-pending',
      ),
      preferences: preferences,
    );
    final pendingApks = apkFiles.pending.values.toList();
    if (!mounted) return;
    setState(() {
      _apkFiles = apkFiles;
      _pendingApks = pendingApks;
      _repositories = repositories;
      _selectedRepository = repositories.first;
      _enabled.addAll(
        rawEnabled?.map((item) => item.toString()) ?? const <String>[],
      );
      for (final entry
          in rawInstalled?.entries ?? const <MapEntry<dynamic, dynamic>>[]) {
        _installed['${entry.key}'] = '${entry.value}';
      }
      for (final entry
          in rawHostStatus?.entries ?? const <MapEntry<dynamic, dynamic>>[]) {
        final value = entry.value;
        if (value is Map) {
          _hostStatus['${entry.key}'] = <String, Object?>{
            for (final item in value.entries) '${item.key}': item.value,
          };
        }
      }
      if (_installed.isEmpty && _hostStatus.isEmpty && _pendingApks.isEmpty) {
        _section = _ExtensionSection.browse;
      }
    });
    if (_section == _ExtensionSection.browse) await _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || _repositories.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 先使用第一个仓库；后续仓库可单独刷新，避免同名扩展静默覆盖。
      final repository = _selectedRepository ?? _repositories.first;
      final index = await MihonRepositoryClient(
        ref.read(sourceHttpClientProvider),
      ).fetch(repository);
      if (!mounted) return;
      setState(() => _index = index);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addRepository() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加 Mihon 仓库'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/repo/index.json',
            labelText: '仓库索引 URL',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      if (value != null && mounted) _toast('仓库地址必须是 HTTPS');
      return;
    }
    if (!mounted || _repositories.contains(uri.toString())) return;
    final repositories = <String>[..._repositories, uri.toString()];
    await ref
        .read(preferencesProvider)
        .set(_mihonRepositoriesKey, repositories);
    if (!mounted) return;
    setState(() {
      _repositories = repositories;
      _selectedRepository = uri.toString();
      _index = null;
      _section = _ExtensionSection.browse;
    });
    await _refresh();
  }

  Future<void> _download(MihonExtension extension) async {
    if (_downloading.contains(extension.packageName)) return;
    if (mounted) {
      setState(() => _downloading.add(extension.packageName));
    }
    try {
      final probe =
          await MihonInstaller(
            http: ref.read(sourceHttpClientProvider),
            preferences: ref.read(preferencesProvider),
          ).install(
            extension,
            signerSha256: _index?.signingKey ?? '',
            confirmPublisher: (candidate) async {
              if (!mounted) return false;
              return await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('确认扩展发布者'),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${extension.name} 的 APK 签名已验证，但发布者与聚合仓库默认签名不同。确认发布者指纹后才能加载。',
                            ),
                            const SizedBox(height: 12),
                            Text('仓库：${_index?.sourceUrl ?? ''}'),
                            const SizedBox(height: 8),
                            const Text('扩展发布者 SHA-256'),
                            SelectableText(candidate.actualSigner),
                            const SizedBox(height: 8),
                            const Text('仓库默认签名'),
                            SelectableText(
                              candidate.repositorySigner.isEmpty
                                  ? '未提供'
                                  : candidate.repositorySigner,
                            ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('信任此发布者'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
            },
          );
      _installed[extension.packageName] = extension.versionName;
      _hostStatus[extension.packageName] = probe;
      // A previously enabled package may be reinstalled/updated. Keep the
      // persisted preference authoritative, but only after the new APK has
      // passed the host executable probe. First-time installs remain disabled.
      if (_enabled.contains(extension.packageName)) {
        final nativeOk = await platformChannel.setMihonEnabled(
          extension.packageName,
          true,
        );
        if (Platform.isAndroid && !nativeOk) {
          _enabled.remove(extension.packageName);
          await ref
              .read(preferencesProvider)
              .set(_mihonEnabledKey, _enabled.toList());
          if (mounted) _toast('${extension.name}：宿主未接受已保存的启用状态');
        }
      }
      if (mounted) {
        setState(() {});
        final ok = probe['ok'] == true;
        final detail = ok
            ? '已加载 ${probe['sourceCount'] ?? 0} 个来源'
            : (probe['factoryLoaded'] == true
                  ? '已发现工厂，但宿主未执行：${probe['hostError'] ?? '等待 Mihon source-api 运行时'}'
                  : '宿主未加载：${probe['hostError'] ?? probe['error'] ?? '未知原因'}');
        _toast('${extension.name}：$detail');
      }
    } catch (error) {
      if (mounted) _toast('下载失败：$error');
    } finally {
      if (mounted) {
        setState(() => _downloading.remove(extension.packageName));
      }
    }
  }

  Future<void> _toggle(String packageName, bool enabled) async {
    if (_toggling) return;
    final preferences = ref.read(preferencesProvider);
    setState(() => _toggling = true);
    try {
      final next = {..._enabled};
      if (enabled) {
        next.add(packageName);
      } else {
        next.remove(packageName);
      }
      await preferences.set(_mihonEnabledKey, next.toList());
      final nativeOk = await platformChannel.setMihonEnabled(
        packageName,
        enabled,
      );
      if (Platform.isAndroid && !nativeOk) {
        await preferences.set(_mihonEnabledKey, _enabled.toList());
        if (mounted) _toast('宿主没有接受启用状态变更');
        return;
      }
      _enabled
        ..clear()
        ..addAll(next);
    } catch (_) {
      await preferences.set(_mihonEnabledKey, _enabled.toList());
      if (mounted) _toast('启用状态保存失败，请重试');
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _activatePending(Map<String, Object?> row) async {
    final packageName = row['packageName'] as String;
    final files = _apkFiles;
    if (files == null || _downloading.contains(packageName)) return;
    setState(() => _downloading.add(packageName));
    try {
      final status =
          await MihonInstaller(
            http: ref.read(sourceHttpClientProvider),
            preferences: ref.read(preferencesProvider),
          ).activatePending(
            files,
            packageName,
            confirmPublisher: (candidate) async {
              if (!mounted) return false;
              return await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('确认恢复 APK 的实际发布者'),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '以下信息已从本机 APK 静态验证。备份中的信任不会迁移；确认后才会首次执行扩展代码。请仅接受你认识的发布者。',
                            ),
                            const SizedBox(height: 12),
                            const Text('实际包名'),
                            SelectableText(candidate.packageName),
                            const SizedBox(height: 8),
                            Text(
                              '实际版本：${candidate.versionName} (${candidate.versionCode})',
                            ),
                            const SizedBox(height: 8),
                            const Text('实际发布者 SHA-256'),
                            SelectableText(candidate.actualSigner),
                            const SizedBox(height: 8),
                            const Text('实际 APK SHA-256'),
                            SelectableText(candidate.apkHash),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: const Text('保持停用'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('确认发布者并加载'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
            },
          );
      if (!mounted) return;
      setState(() {
        _pendingApks = files.pending.values.toList();
        _installed[packageName] = row['versionName'] as String;
        _hostStatus[packageName] = status;
      });
      ref.invalidate(sourceRegistryProvider);
      _toast('扩展已验证并加载；新恢复的来源仍停用，请在来源管理中手动启用');
    } catch (error) {
      if (mounted) _toast('恢复 APK 未激活：$error');
    } finally {
      if (mounted) setState(() => _downloading.remove(packageName));
    }
  }

  Widget _pendingApkTile(Map<String, Object?> row) {
    final busy = _downloading.contains(row['packageName']);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.lock_outline),
      title: Text('${row['packageName']}'),
      subtitle: Text(
        '恢复 APK · v${row['versionName']} (${row['versionCode']}) · ${sourceContentLabel(sourceNsfwFlag(row['nsfw']))} · 停用待确认\n'
        '${Platform.isAndroid ? '未执行扩展代码；需确认实际发布者' : '当前平台不支持执行；仅保存可移植 APK 字节'}',
      ),
      trailing: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: Platform.isAndroid
                  ? () => unawaited(_activatePending(row))
                  : null,
              child: const Text('核验并加载'),
            ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _selectSection(_ExtensionSection value) {
    setState(() => _section = value);
    if (value == _ExtensionSection.browse && _index == null && !_loading) {
      unawaited(_refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    final query = _filters.query.trim().toLowerCase();
    final entries = index?.extensions
        .where((entry) => entry.name.toLowerCase().contains(query))
        .toList() ?? const <MihonExtension>[];
    final packages = <String>{..._installed.keys, ..._hostStatus.keys}.toList()
      ..sort();
    final installed = packages
        .where((package) => _packageName(package).toLowerCase().contains(query))
        .toList();
    final pending = _pendingApks
        .where((row) => '${row['name'] ?? ''}'.toLowerCase().contains(query))
        .toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.86,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '漫画扩展',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭扩展管理',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(Platform.isAndroid
                  ? 'Mihon / Komikku APK · 安装后需手动启用，并确认发布者。'
                  : '当前平台不执行 APK。漫画浏览中的内置 MangaDex 可直接在线使用；这里可管理 APK 文件与仓库。'),
              const SizedBox(height: 12),
              SegmentedButton<_ExtensionSection>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: _ExtensionSection.installed,
                    label: Text('已安装'),
                  ),
                  ButtonSegment(
                    value: _ExtensionSection.browse,
                    label: Text('浏览扩展'),
                  ),
                  ButtonSegment(
                    value: _ExtensionSection.repositories,
                    label: Text('仓库'),
                  ),
                ],
                selected: {_section},
                onSelectionChanged: (value) => _selectSection(value.single),
              ),
              const SizedBox(height: 12),
              if (_section == _ExtensionSection.repositories) ...[
                FilledButton.icon(
                  onPressed: _addRepository,
                  icon: const Icon(Icons.add_link),
                  label: const Text('添加扩展仓库'),
                ),
                const SizedBox(height: 8),
                const Text(
                  '使用 Mihon / Tachiyomi APK 仓库 index.json；不是 Kazumi 规则地址。选择仓库后浏览并安装扩展。',
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final repository in _repositories)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(
                            Uri.tryParse(repository)?.host ?? repository,
                          ),
                          subtitle: Text(repository),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _loading
                              ? null
                              : () {
                                  setState(() {
                                    _selectedRepository = repository;
                                    _section = _ExtensionSection.browse;
                                    _index = null;
                                  });
                                  unawaited(_refresh());
                                },
                        ),
                    ],
                  ),
                ),
              ] else ...[
                if (_section == _ExtensionSection.browse)
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () =>
                              _selectSection(_ExtensionSection.repositories),
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: Text(
                            Uri.tryParse(_selectedRepository ?? '')?.host ??
                                '选择仓库',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新仓库',
                        onPressed: _loading ? null : _refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                TextFormField(
                  initialValue: _filters.query,
                  decoration: const InputDecoration(
                    labelText: '搜索插件名称',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (query) => _setFilters(_filters.copyWith(query: query)),
                ),
                if (_section == _ExtensionSection.installed)
                  Expanded(
                    child: ListView(
                      children: [
                        if (pending.isNotEmpty)
                          const ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('恢复后待确认'),
                          ),
                        for (final row in pending) _pendingApkTile(row),
                        for (final package in installed)
                          _installedTile(package),
                        if (installed.isEmpty && pending.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              packages.isEmpty && _pendingApks.isEmpty
                                  ? '尚未安装扩展。到“浏览扩展”选择来源，或在“仓库”添加地址。'
                                  : '没有匹配的已安装扩展，请清除筛选。',
                            ),
                          ),
                      ],
                    ),
                  )
                else ...[
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null)
                    Text('仓库加载失败，已安装扩展不受影响。可重试或切换仓库。\n$_error'),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final entry in entries) _extensionTile(entry),
                        if (entries.isEmpty && !_loading && _error == null)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('没有匹配的扩展，请调整插件名称。'),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _packageName(String package) {
    final raw = _hostStatus[package]?['sources'];
    if (raw is List) {
      final names = raw
          .whereType<Map<Object?, Object?>>()
          .map((source) => '${source['name'] ?? ''}')
          .where((name) => name.isNotEmpty)
          .toSet();
      if (names.isNotEmpty) return names.join(' / ');
    }
    return package.split('.').last;
  }

  Widget _installedTile(String package) {
    final host = _hostStatus[package];
    final ready = host?['ok'] == true;
    final enabled = ready && _enabled.contains(package);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.extension_outlined),
      title: Text(_packageName(package)),
      subtitle: Text(
        'v${_installed[package] ?? host?['versionName'] ?? host?['versionCode'] ?? '未知'} · ${sourceContentLabel(sourceNsfwFlag(host?['nsfw']))}\n'
        '${ready ? (enabled ? '已启用' : '已安装 · 已停用') : '宿主未加载，当前不可用'}\n$package',
      ),
      trailing: Semantics(
        label: '启用扩展 ${_packageName(package)}',
        child: Switch(
          value: enabled,
          onChanged: ready && !_toggling
              ? (value) => _toggle(package, value)
              : null,
        ),
      ),
    );
  }

  Widget _extensionTile(MihonExtension extension) {
    final downloaded =
        _installed[extension.packageName] == extension.versionName;
    final downloading = _downloading.contains(extension.packageName);
    final host = _hostStatus[extension.packageName];
    final hostReady = host?['ok'] == true;
    final savedEnabled = _enabled.contains(extension.packageName);
    final enabled = hostReady && savedEnabled;
    final type = extension.mediaType?.label ?? '漫画';
    final status = downloading
        ? '正在下载 APK…'
        : !downloaded
        ? '尚未下载 APK'
        : hostReady
        ? (savedEnabled ? '宿主已执行，已启用' : '宿主已执行，可启用')
        : savedEnabled
        ? '已保存启用偏好，但宿主未执行，当前不可用'
        : '已下载，等待 Mihon 宿主执行，当前不可用';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.extension_outlined),
      title: Text(extension.name),
      subtitle: Text(
        '$type · v${extension.versionName} · ${sourceContentLabel(extension.declaredNsfw)}\n'
        '${extension.sources.map((source) => '${source.name} (${sourceLanguageLabel(sourceLanguage(source.language))})').join('、')}\n$status',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (downloading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (downloaded && hostReady)
            Tooltip(
              message: hostReady ? '宿主已加载，可启用' : '已下载但宿主未加载：请查看提示并修复兼容性',
              child: Icon(
                hostReady ? Icons.check_circle : Icons.download_done,
                size: 20,
              ),
            )
          else
            IconButton(
              tooltip: downloaded ? '已下载但宿主未加载：请查看提示并修复兼容性' : '下载 APK',
              onPressed: () => unawaited(_download(extension)),
              icon: const Icon(Icons.download_outlined),
            ),
          Semantics(
            label: '启用扩展 ${extension.name}',
            child: Switch(
              value: enabled,
              onChanged: hostReady && !_toggling
                  ? (value) => _toggle(extension.packageName, value)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
