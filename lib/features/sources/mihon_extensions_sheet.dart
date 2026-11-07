import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/backup/apk_backup_files.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/mihon_installer.dart';
import '../../core/source/mihon_repository.dart';
import '../../core/source/source_filters.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/windows_mihon_host.dart';
import '../../core/storage/preferences.dart';
import '../manga/manga_extension_details_page.dart';
import '../manga/mihon_extension_icon.dart';
import 'source_filter_controls.dart';

const _mihonRepositoriesKey = 'mihon.repositories';
const _mihonEnabledKey = 'mihon.enabledPackages';
const _mihonInstalledKey = 'mihon.installedPackages';
const _mihonHostStatusKey = 'mihon.hostStatus';
const _unknownProbeAction = '请先手动启用，再打开来源设置并重试';

/// Mihon/Komikku 扩展管理。下载、启停状态与 Triomi 规则来源分开保存。
class MihonExtensionsSheet extends ConsumerStatefulWidget {
  const MihonExtensionsSheet({
    super.key,
    this.initialQuery,
    this.browse = false,
    this.onRules,
  }) : _sharedErrors = null,
       _sharedFailures = null,
       _searchPage = false,
       _initialIndex = null,
       _initialRepository = null;

  const MihonExtensionsSheet._add({
    required Map<String, String> errors,
    required Map<String, MihonExtension> failures,
  }) : initialQuery = null,
       browse = true,
       onRules = null,
       _searchPage = false,
       _initialIndex = null,
       _initialRepository = null,
       _sharedErrors = errors,
       _sharedFailures = failures;

  const MihonExtensionsSheet._search({
    required this.browse,
    required this.initialQuery,
    required Map<String, String> errors,
    required Map<String, MihonExtension> failures,
    required MihonRepositoryIndex? index,
    required String? repository,
  }) : onRules = null,
       _searchPage = true,
       _initialIndex = index,
       _initialRepository = repository,
       _sharedErrors = errors,
       _sharedFailures = failures;

  final Map<String, String>? _sharedErrors;
  final Map<String, MihonExtension>? _sharedFailures;
  final bool _searchPage;
  final MihonRepositoryIndex? _initialIndex;
  final String? _initialRepository;

  final String? initialQuery;
  final bool browse;
  final Future<void> Function()? onRules;
  @override
  ConsumerState<MihonExtensionsSheet> createState() =>
      _MihonExtensionsSheetState();
}

enum _ExtensionSection { installed, browse, repositories }

class _MihonExtensionsSheetState extends ConsumerState<MihonExtensionsSheet> {
  MihonRepositoryIndex? _index;
  Object? _error;
  late final _installErrors = widget._sharedErrors ?? <String, String>{};
  final _installationIssues = <String, WindowsMihonInstallationIssue>{};
  int _installationGeneration = 0;
  bool _checkingInstallations =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool _loading = false;
  SourceFilters _filters = const SourceFilters(language: 'zh');
  _ExtensionSection _section = _ExtensionSection.installed;
  final _searchController = TextEditingController();
  bool _savingRepositories = false;
  int _repositoryGeneration = 0;

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
  final Set<String> _removing = <String>{};
  late final _failedExtensions =
      widget._sharedFailures ?? <String, MihonExtension>{};
  List<String> _repositories = <String>[];
  String? _selectedRepository;
  ApkBackupFiles? _apkFiles;
  List<Map<String, Object?>> _pendingApks = [];

  @override
  void initState() {
    super.initState();
    if (widget.browse ||
        (!widget._searchPage &&
            widget.initialQuery?.trim().isNotEmpty == true)) {
      _section = _ExtensionSection.browse;
    }
    _index = widget._initialIndex;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      unawaited(_loadPreferences(applyInitialQuery: true));
    }
  }

  @override
  void dispose() {
    _repositoryGeneration++;
    _installationGeneration++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reloadManagement() async {
    if (!mounted) return;
    _index = null;
    _enabled.clear();
    _installed.clear();
    _hostStatus.clear();
    await _loadPreferences();
  }

  Future<void> _loadPreferences({bool applyInitialQuery = false}) async {
    final repositoryGeneration = _repositoryGeneration;
    final preferences = ref.read(preferencesProvider);
    _filters = SourceFilters.fromJson(
      preferences.get<Object?>('sources.filters.mihon'),
      defaultLanguage: 'zh',
    ).copyWith(clearType: true);
    final initialQuery = applyInitialQuery ? widget.initialQuery?.trim() : null;
    _filters = _filters.copyWith(query: initialQuery ?? '');
    _searchController.text = _filters.query;
    final rawRepositories = preferences.get<List<Object?>>(
      _mihonRepositoriesKey,
    );
    final repositories = <String>{
      for (final item in rawRepositories ?? const <Object?>[])
        item.toString().trim(),
    }.where((item) => item.isNotEmpty).toList();
    final rawEnabled = preferences.get<List<Object?>>(_mihonEnabledKey);
    final rawInstalled = preferences.get<Map<dynamic, dynamic>>(
      _mihonInstalledKey,
    );
    final rawHostStatus = preferences.get<Map<dynamic, dynamic>>(
      _mihonHostStatusKey,
    );
    final support = await getApplicationSupportDirectory();
    final apkFiles = ApkBackupFiles(
      root: Directory('${await support.resolveSymbolicLinks()}/mihon-pending'),
      preferences: preferences,
    );
    final pendingApks = apkFiles.pending.values.toList();
    if (!mounted) return;
    setState(() {
      _apkFiles = apkFiles;
      _pendingApks = pendingApks;
      if (repositoryGeneration == _repositoryGeneration) {
        _repositories = repositories;
        _selectedRepository = repositories.contains(widget._initialRepository)
            ? widget._initialRepository
            : repositories.firstOrNull;
        if (applyInitialQuery &&
            _selectedRepository == widget._initialRepository) {
          _index = widget._initialIndex;
        }
      }
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
      if (widget.browse ||
          (!widget._searchPage &&
              widget.initialQuery?.trim().isNotEmpty == true)) {
        _section = _ExtensionSection.browse;
      }
    });
    unawaited(_refreshInstallationIssues(support));
    final initialIndex = _index;
    if (initialIndex != null && repositoryGeneration == _repositoryGeneration) {
      await _restoreInstalledIcons(initialIndex, repositoryGeneration);
    }
    if (_section == _ExtensionSection.browse && _index == null) {
      await _refresh();
    }
  }

  Future<void> _refreshInstallationIssues(Directory support) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final generation = ++_installationGeneration;
    final issues = <String, WindowsMihonInstallationIssue>{};
    for (final package in {..._installed.keys, ..._hostStatus.keys}) {
      final issue = await WindowsMihonHost.installationIssue(
        package,
        root: Directory('${support.path}/mihon-desktop'),
      );
      if (issue != null) issues[package] = issue;
    }
    if (!mounted) return;
    if (generation != _installationGeneration) {
      unawaited(_refreshInstallationIssues(support));
      return;
    }
    setState(() {
      _checkingInstallations = false;
      _installationIssues
        ..clear()
        ..addAll(issues);
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final generation = ++_repositoryGeneration;
    final repository = _selectedRepository;
    setState(() {
      _index = null;
      _loading = repository != null;
      _error = null;
    });
    if (repository == null) return;
    try {
      final index = await MihonRepositoryClient(
        ref.read(sourceHttpClientProvider),
      ).fetch(repository);
      if (!mounted || generation != _repositoryGeneration) return;
      setState(() => _index = index);
      await _restoreInstalledIcons(index, generation);
    } catch (error) {
      if (!mounted || generation != _repositoryGeneration) return;
      setState(() => _error = SourceException.sanitizeMessage('$error'));
    } finally {
      if (mounted && generation == _repositoryGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _restoreInstalledIcons(
    MihonRepositoryIndex index,
    int generation,
  ) async {
    try {
      final recovered = await MihonInstaller(
        http: ref.read(sourceHttpClientProvider),
        preferences: ref.read(preferencesProvider),
      ).cacheRepositoryIcons(index.extensions);
      if (!mounted ||
          generation != _repositoryGeneration ||
          recovered.isEmpty) {
        return;
      }
      setState(() {
        for (final entry in recovered.entries) {
          final status = _hostStatus[entry.key];
          if (status != null) status['iconUrl'] = entry.value;
        }
      });
    } catch (error) {
      // Optional artwork persistence must not hide a usable repository.
      debugPrint(
        'Mihon icon cache: ${SourceException.sanitizeMessage('$error')}',
      );
    }
  }

  Future<void> _editRepository([String? previous]) async {
    if (_savingRepositories) return;
    var text = previous ?? '';
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(previous == null ? '添加 Mihon 仓库' : '编辑 Mihon 仓库'),
        content: TextFormField(
          initialValue: text,
          onChanged: (value) => text = value,
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
            onPressed: () => Navigator.of(dialogContext).pop(text),
            child: Text(previous == null ? '添加' : '保存'),
          ),
        ],
      ),
    );
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      if (value != null && mounted) _toast('仓库地址必须是无凭据、无片段的 HTTPS URL');
      return;
    }
    if (!mounted || value == null) return;
    final repository = uri.toString();
    if (_repositories.contains(repository) && repository != previous) {
      _toast('此仓库已存在');
      return;
    }
    final repositories = [
      for (final item in _repositories)
        if (item != previous) item,
      repository,
    ];
    await _saveRepositories(repositories, selected: repository);
  }

  Future<void> _saveRepositories(
    List<String> repositories, {
    String? selected,
  }) async {
    if (_savingRepositories) return;
    setState(() => _savingRepositories = true);
    try {
      await ref
          .read(preferencesProvider)
          .set(_mihonRepositoriesKey, repositories);
      if (!mounted) return;
      setState(() {
        _repositories = repositories;
        _selectedRepository =
            selected ??
            (repositories.contains(_selectedRepository)
                ? _selectedRepository
                : repositories.firstOrNull);
        _index = null;
        _error = null;
        if (selected != null) _section = _ExtensionSection.browse;
      });
      unawaited(_refresh());
    } catch (error) {
      if (mounted) {
        _toast('仓库保存失败：${SourceException.sanitizeMessage('$error')}');
      }
    } finally {
      if (mounted) setState(() => _savingRepositories = false);
    }
  }

  Future<void> _removeRepository(String repository) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除扩展仓库？'),
        content: Text('$repository\n\n仅移除仓库地址，不卸载扩展，不删除书架或历史记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveRepositories([
      for (final item in _repositories)
        if (item != repository) item,
    ]);
  }

  Future<void> _download(
    MihonExtension extension,
    MihonRepositoryIndex repository,
  ) async {
    if (_downloading.contains(extension.packageName) ||
        _removing.contains(extension.packageName)) {
      return;
    }
    if (mounted) {
      setState(() {
        _downloading.add(extension.packageName);
        _installErrors.remove(extension.packageName);
      });
    }
    try {
      final probe =
          await MihonInstaller(
            http: ref.read(sourceHttpClientProvider),
            preferences: ref.read(preferencesProvider),
          ).install(
            extension,
            signerSha256: repository.signingKey,
            confirmPublisher: (candidate) async {
              if (!mounted) return false;
              return await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(
                        candidate.localApkConversion
                            ? '确认转换并执行 APK'
                            : candidate.desktopJarSha256 == null
                            ? '确认扩展发布者'
                            : '确认桌面扩展代码',
                      ),
                      content: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              candidate.localApkConversion
                                  ? '${extension.name} 的仓库未提供桌面 JAR。将使用本机兼容运行时转换已验签 APK 并执行；转换产物会记录独立 SHA-256，APK 签名仅覆盖原件。扩展在本机执行，不是权限沙箱。'
                                  : candidate.desktopJarSha256 == null
                                  ? '${extension.name} 的 APK 签名已验证，但发布者与聚合仓库默认签名不同。确认发布者指纹后才能加载。'
                                  : '${extension.name} 使用仓库提供的原生桌面 JAR，避免 APK 转换不兼容。APK 签名不为 JAR 背书；请同时核对桌面代码来源与独立指纹。扩展在本机执行，不是权限沙箱。',
                            ),
                            const SizedBox(height: 12),
                            Text('仓库：${repository.sourceUrl}'),
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
                            if (candidate.localApkConversion) ...[
                              const SizedBox(height: 12),
                              const Text('原始 APK SHA-256'),
                              SelectableText(candidate.apkHash),
                              const SizedBox(height: 8),
                              const Text('仓库声明的 APK 地址'),
                              SelectableText(
                                candidate.apkUrl ?? '本机备份中已验签的 APK',
                              ),
                            ],
                            if (candidate.desktopJarSha256 != null) ...[
                              const SizedBox(height: 12),
                              const Text('独立的桌面 JAR SHA-256'),
                              SelectableText(candidate.desktopJarSha256!),
                              const SizedBox(height: 8),
                              const Text('仓库声明的桌面代码地址'),
                              SelectableText(candidate.desktopJarUrl ?? ''),
                            ],
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
      if (probe['filterProbe'] == 'unknown') {
        _enabled.remove(extension.packageName);
      }
      _failedExtensions.remove(extension.packageName);
      _installationIssues.remove(extension.packageName);
      _installationGeneration++;
      // A previously enabled package may be reinstalled/updated. Keep the
      // persisted preference authoritative, but only after the new APK has
      // passed the host executable probe. First-time installs remain disabled.
      if (_enabled.contains(extension.packageName)) {
        final nativeOk = await platformChannel.setMihonEnabled(
          extension.packageName,
          true,
        );
        if (!nativeOk) {
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
            ? probe['filterProbe'] == 'unknown'
                  ? '已安装，筛选探测未完成；$_unknownProbeAction'
                  : '已加载 ${probe['sourceCount'] ?? 0} 个来源'
            : (probe['factoryLoaded'] == true
                  ? '已发现工厂，但宿主未执行：${probe['hostError'] ?? '等待 Mihon source-api 运行时'}'
                  : '宿主未加载：${probe['hostError'] ?? probe['error'] ?? '未知原因'}');
        _toast('${extension.name}：$detail');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _installErrors[extension.packageName] =
              SourceException.sanitizeMessage('$error'),
        );
        _failedExtensions[extension.packageName] = extension;
        _toast('扩展安装失败，点击插件查看原因后可重试');
      }
    } finally {
      if (mounted) {
        ref.invalidate(sourceRegistryProvider);
        setState(() => _downloading.remove(extension.packageName));
      }
    }
  }

  Future<void> _toggle(String packageName, bool enabled) async {
    if (_toggling ||
        _downloading.contains(packageName) ||
        _removing.contains(packageName)) {
      return;
    }
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
      if (!nativeOk) {
        await preferences.set(_mihonEnabledKey, _enabled.toList());
        if (mounted) _toast('宿主没有接受启用状态变更；请打开插件详情检查兼容性，或重新安装完整的扩展运行时后重试');
        return;
      }
      _enabled
        ..clear()
        ..addAll(next);
      ref.invalidate(sourceRegistryProvider);
    } catch (_) {
      await preferences.set(_mihonEnabledKey, _enabled.toList());
      if (mounted) _toast('启用状态保存失败，请重试');
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  Future<void> _removePackage(String packageName) async {
    if (_downloading.contains(packageName) || _removing.contains(packageName)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载扩展？'),
        content: Text(
          '${_packageName(packageName)}\n\n移除扩展代码与启用状态，保留书架、阅读历史、下载和来源设置。再次安装需要重新核验发布者。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _installationGeneration++;
    setState(() => _removing.add(packageName));
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await MihonInstaller(
        http: ref.read(sourceHttpClientProvider),
        preferences: ref.read(preferencesProvider),
      ).uninstall(packageName, pendingFiles: _apkFiles);
      container.invalidate(sourceRegistryProvider);
      if (!mounted) return;
      setState(() {
        _enabled.remove(packageName);
        _installed.remove(packageName);
        _hostStatus.remove(packageName);
        _installErrors.remove(packageName);
        _failedExtensions.remove(packageName);
        _installationIssues.remove(packageName);
        _pendingApks = _apkFiles?.pending.values.toList() ?? [];
      });
      _toast('扩展已卸载；书架和阅读历史已保留');
    } catch (error) {
      if (mounted) _toast('卸载失败：${SourceException.sanitizeMessage('$error')}');
    } finally {
      if (mounted) setState(() => _removing.remove(packageName));
    }
  }

  Widget _removePackageButton(String packageName) => IconButton(
    tooltip: '卸载扩展',
    onPressed:
        _downloading.contains(packageName) || _removing.contains(packageName)
        ? null
        : () => unawaited(_removePackage(packageName)),
    icon: const Icon(Icons.delete_outline),
  );

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
                            if (candidate.localApkConversion) ...[
                              const SizedBox(height: 12),
                              const Text(
                                '此备份没有独立桌面 JAR。确认后将转换并执行已验签 APK；本机转换产物会记录独立 SHA-256，APK 签名仅覆盖原件。',
                              ),
                            ],
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
                            if (candidate.desktopJarSha256 != null) ...[
                              const SizedBox(height: 12),
                              const Text(
                                '独立桌面 JAR：APK 签名不为这些代码背书。确认以下实际内容指纹后才会执行；备份中的信任不会迁移。',
                              ),
                              SelectableText(candidate.desktopJarSha256!),
                            ],
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
      subtitle: Text('v${row['versionName']}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '核验并加载',
              onPressed:
                  !kIsWeb &&
                      (defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.windows) &&
                      !_removing.contains('${row['packageName']}')
                  ? () => unawaited(_activatePending(row))
                  : null,
              icon: const Icon(Icons.verified_user_outlined),
            ),
          _removePackageButton('${row['packageName']}'),
        ],
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

  Future<void> _openSearch() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MihonExtensionsSheet._search(
          browse: _section == _ExtensionSection.browse,
          initialQuery: _filters.query,
          errors: _installErrors,
          failures: _failedExtensions,
          index: _index,
          repository: _selectedRepository,
        ),
      ),
    );
    await _reloadManagement();
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.code, size: 40),
              const SizedBox(height: 16),
              Text('iOS 使用 JS / API 规则来源',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text(
                'Mihon APK / DEX 扩展仅由 Android 或兼容桌面宿主执行，'
                '不能在 iOS 安装或启用。请返回「规则与来源设置」，'
                '通过规则目录或手动导入添加兼容的 JS / API 来源。'
                '已有书架、历史与离线文件不会被删除。',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final index = _index;
    final query = _filters.query.trim().toLowerCase();
    final entries = [
      ...?index?.filter(
        query: _filters.query,
        language: _filters.language,
        content: _filters.content,
      ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final packages = <String>{
      ..._installed.keys,
      ..._hostStatus.keys,
      ..._enabled,
      ..._installErrors.keys,
    }.toList()..sort();
    final installed = packages
        .where(
          (package) =>
              package.toLowerCase().contains(query) ||
              _packageName(package).toLowerCase().contains(query),
        )
        .toList();
    final pending = _pendingApks
        .where(
          (row) => '${row['packageName'] ?? ''}'.toLowerCase().contains(query),
        )
        .toList();
    final searchPage = widget._searchPage || widget.initialQuery != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          searchPage
              ? _section == _ExtensionSection.browse
                    ? '搜索可添加插件'
                    : '搜索插件库'
              : widget.browse
              ? '添加插件'
              : '插件库',
        ),
        actions: [
          if (!searchPage)
            IconButton(
              tooltip: '搜索插件',
              icon: const Icon(Icons.search),
              onPressed: () => unawaited(_openSearch()),
            ),
          if (!widget.browse && !searchPage)
            IconButton(
              tooltip: '添加插件',
              icon: const Icon(Icons.add),
              onPressed: () async {
                _searchController.clear();
                _setFilters(_filters.copyWith(query: ''));
                await Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MihonExtensionsSheet._add(
                      errors: _installErrors,
                      failures: _failedExtensions,
                    ),
                  ),
                );
                await _reloadManagement();
              },
            ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rules') {
                await widget.onRules?.call();
                await _reloadManagement();
              } else {
                _selectSection(
                  _section == _ExtensionSection.repositories
                      ? (widget.browse
                            ? _ExtensionSection.browse
                            : _ExtensionSection.installed)
                      : _ExtensionSection.repositories,
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'repositories', child: Text('仓库')),
              if (widget.onRules != null)
                const PopupMenuItem(value: 'rules', child: Text('规则与来源设置')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (searchPage)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _section == _ExtensionSection.browse
                          ? '搜索可添加插件'
                          : '搜索插件库',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          _searchController.clear();
                          _setFilters(_filters.copyWith(query: ''));
                        },
                        icon: const Icon(Icons.clear),
                      ),
                    ),
                    onChanged: (query) =>
                        _setFilters(_filters.copyWith(query: query)),
                    onSubmitted: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
              if (_section == _ExtensionSection.repositories) ...[
                FilledButton.icon(
                  onPressed: _savingRepositories ? null : _editRepository,
                  icon: const Icon(Icons.add_link),
                  label: const Text('添加扩展仓库'),
                ),
                const SizedBox(height: 8),
                const Text('支持 Mihon / Tachiyomi 仓库 index.json。'),
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
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '编辑扩展仓库',
                                onPressed: _savingRepositories
                                    ? null
                                    : () => _editRepository(repository),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '移除扩展仓库',
                                onPressed: _savingRepositories
                                    ? null
                                    : () => _removeRepository(repository),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          onTap: _savingRepositories
                              ? null
                              : () {
                                  setState(() {
                                    _selectedRepository = repository;
                                    _section = _ExtensionSection.browse;
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
                            _selectedRepository == null
                                ? '添加你自己的仓库'
                                : Uri.tryParse(_selectedRepository!)?.host ??
                                      _selectedRepository!,
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
                if (_section == _ExtensionSection.browse)
                  SourceFilterControls(
                    filters: _filters,
                    languages: [
                      for (final extension
                          in index?.extensions ?? const <MihonExtension>[])
                        if (extension.sources.isEmpty) '',
                      for (final extension
                          in index?.extensions ?? const <MihonExtension>[])
                        for (final source in extension.sources) source.language,
                    ],
                    types: const [],
                    showQuery: false,
                    visibleCount: entries.length,
                    totalCount: index?.extensions.length ?? 0,
                    onChanged: (value) {
                      if (_searchController.text != value.query) {
                        _searchController.text = value.query;
                      }
                      _setFilters(value);
                    },
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
                                  ? '尚未安装插件。点击右上角 + 添加。'
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
                        if (query.isEmpty && entries.isNotEmpty)
                          const ListTile(
                            title: Text('仓库推荐'),
                            subtitle: Text('来自当前仓库 · 按名称排序'),
                          ),
                        for (final entry in entries)
                          _extensionTile(entry, index!),
                        if (entries.isEmpty && !_loading && _error == null)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              _repositories.isEmpty
                                  ? '尚无仓库，请从右上角菜单添加。'
                                  : '没有匹配的扩展，请调整语言、内容分级或插件名称。',
                            ),
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
    final declared =
        _hostStatus[package]?['name']?.toString() ??
        _failedExtensions[package]?.name;
    if (declared != null && declared.isNotEmpty) return declared;
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

  Future<void> _details(String package) async {
    // Publish locally changed install/enable state before resolving its sources.
    ref.invalidate(sourceRegistryProvider);
    ref.invalidate(sourcesProvider);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MangaExtensionDetailsPage(
          packageName: package,
          diagnostic:
              _installErrors[package] ??
              _installationIssues[package]?.message ??
              (_hostStatus[package]?['filterProbe'] == 'unknown'
                  ? '扩展已安装，但筛选探测未完成；这也可能由网络、登录或来源设置引起。$_unknownProbeAction。'
                  : null),
        ),
      ),
    );
  }

  Widget _installedTile(String package) {
    final host = _hostStatus[package];
    final extension = _index?.extensions
        .where((row) => row.packageName == package)
        .firstOrNull;
    final ready =
        !_checkingInstallations &&
        host?['ok'] == true &&
        !_installationIssues.containsKey(package);
    final enabled = ready && _enabled.contains(package);
    final busy = _downloading.contains(package) || _removing.contains(package);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: MihonExtensionIcon(
        packageName: package,
        iconUrl: extension?.iconUrl,
      ),
      onTap: () => unawaited(_details(package)),
      title: Text(_packageName(package)),
      subtitle: Text(
        'v${_installed[package] ?? host?['versionName'] ?? host?['versionCode'] ?? '未知'}'
        '${host?['filterProbe'] == 'unknown' ? ' · 筛选待验证，$_unknownProbeAction' : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: '插件操作',
            onSelected: (action) {
              if (action == 'details') unawaited(_details(package));
              if (action == 'toggle') unawaited(_toggle(package, !enabled));
              if (action == 'disable') unawaited(_toggle(package, false));
              if (action == 'remove') unawaited(_removePackage(package));
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'details', child: Text('详情与来源设置')),
              PopupMenuItem(
                value: 'toggle',
                enabled: ready && !_toggling && !busy,
                child: Text(enabled ? '停用' : '启用'),
              ),
              if (!ready && _enabled.contains(package))
                PopupMenuItem(
                  value: 'disable',
                  enabled: !busy && !_toggling,
                  child: const Text('清除启用偏好'),
                ),
              PopupMenuItem(
                value: 'remove',
                enabled: !busy,
                child: const Text('卸载'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _extensionTile(
    MihonExtension extension,
    MihonRepositoryIndex repository,
  ) {
    final downloaded =
        _installed[extension.packageName] == extension.versionName;
    final downloading = _downloading.contains(extension.packageName);
    final host = _hostStatus[extension.packageName];
    final installationIssue = _installationIssues[extension.packageName];
    final hostReady =
        !_checkingInstallations &&
        host?['ok'] == true &&
        installationIssue == null;
    final savedEnabled = _enabled.contains(extension.packageName);
    final enabled = hostReady && savedEnabled;
    final installError = _installErrors[extension.packageName];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: installError != null || downloaded || host != null
          ? () => unawaited(_details(extension.packageName))
          : null,
      leading: MihonExtensionIcon(
        packageName: extension.packageName,
        iconUrl: extension.iconUrl,
      ),
      title: Text(extension.name),
      subtitle: Text('v${extension.versionName}'),
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (downloaded || host != null || installError != null)
            PopupMenuButton<String>(
              tooltip: '插件操作',
              onSelected: (action) {
                if (action == 'details') {
                  unawaited(_details(extension.packageName));
                }
                if (action == 'toggle') {
                  unawaited(_toggle(extension.packageName, !enabled));
                }
                if (action == 'remove') {
                  unawaited(_removePackage(extension.packageName));
                }
              },
              itemBuilder: (_) => [
                if (downloaded || host != null || installError != null)
                  const PopupMenuItem(value: 'details', child: Text('详情与来源设置')),
                PopupMenuItem(
                  value: 'toggle',
                  enabled:
                      hostReady &&
                      !_toggling &&
                      !downloading &&
                      !_removing.contains(extension.packageName),
                  child: Text(enabled ? '停用' : '启用'),
                ),
                if (downloaded || host != null)
                  PopupMenuItem(
                    value: 'remove',
                    enabled:
                        !downloading &&
                        !_removing.contains(extension.packageName),
                    child: const Text('卸载'),
                  ),
              ],
            ),
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
              tooltip: installationIssue?.requiresReinstall == true
                  ? '重新安装扩展'
                  : downloaded
                  ? '已下载但宿主未加载：请查看提示并修复兼容性'
                  : '下载 APK',
              onPressed: _removing.contains(extension.packageName)
                  ? null
                  : () => unawaited(_download(extension, repository)),
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      ),
    );
  }
}
