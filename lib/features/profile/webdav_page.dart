import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/backup/backup_restore_preview.dart';
import '../../core/backup/versioned_webdav_backup.dart';
import '../../core/backup/webdav_client.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_auto_sync.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_webdav_sync.dart';
import 'backup_restore_dialog.dart';
import 'data/sync_providers.dart';
import 'data/webdav_backup_operation.dart';
import 'webdav_status_cards.dart';

/// Lightweight cross-device sync and full backups share one WebDAV connection.
class WebDavSyncPage extends ConsumerStatefulWidget {
  const WebDavSyncPage({
    super.key,
    this.fullBackup = false,
    this.animeCollectionOnly = false,
  });

  final bool fullBackup;
  final bool animeCollectionOnly;

  @override
  ConsumerState<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends ConsumerState<WebDavSyncPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _fileController = TextEditingController();

  bool _initialized = false;
  bool _localBusy = false;
  bool get _busy => _localBusy || ref.read(webDavBackupOperationProvider).busy;
  bool _includeDownloadedMedia = false;
  bool _allowInsecureHttp = false;
  String _consentedBaseUrl = '';
  bool _failed = false;
  Future<void> Function()? _retry;
  String? _status;
  RemoteBackupInfo? _remote;

  @override
  void initState() {
    super.initState();
    final config = ref.read(webDavConfigProvider);
    _urlController.text = config.baseUrl;
    _userController.text = config.username;
    _passwordController.text = config.password;
    _pathController.text = config.remotePath;
    _fileController.text = config.fileName;
    _allowInsecureHttp = config.allowInsecureHttp;
    _consentedBaseUrl = config.baseUrl.trim();
    _initialized = true;
    _urlController.addListener(_resetHttpConsent);
  }

  @override
  void dispose() {
    _urlController.removeListener(_resetHttpConsent);
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _pathController.dispose();
    _fileController.dispose();
    super.dispose();
  }

  WebDavConfig get _config => WebDavConfig(
    baseUrl: _urlController.text.trim(),
    username: _userController.text.trim(),
    password: _passwordController.text,
    remotePath: _pathController.text.trim().isEmpty
        ? 'triomi'
        : _pathController.text.trim(),
    fileName: _fileController.text.trim(),
    allowInsecureHttp:
        _allowInsecureHttp && _consentedBaseUrl == _urlController.text.trim(),
  );
  Widget _card({required Widget child}) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.md,
      AppSpacing.lg,
      0,
    ),
    child: AppCard(child: child),
  );

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  void _resetHttpConsent() {
    if (_urlController.text.trim() != _consentedBaseUrl) {
      _allowInsecureHttp = false;
      _consentedBaseUrl = '';
    }
  }

  Future<WebDavConfig?> _prepareConfig() async {
    if (!_config.isConfigured) {
      setState(() {
        _status = '请先填写服务器地址与用户名';
        _failed = true;
      });
      return null;
    }
    // Guard concurrent taps during secure-store writes and consent dialogs too.
    setState(() => _localBusy = true);
    try {
      final uri = Uri.tryParse(_config.baseUrl);
      if (uri != null &&
          uri.scheme == 'http' &&
          uri.host.isNotEmpty &&
          !WebDavConfig.isLoopbackHost(uri.host) &&
          !_config.allowInsecureHttp) {
        final endpoint = _urlController.text.trim();
        final consent = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('确认使用未加密的 WebDAV'),
            content: Text(
              '此地址使用 HTTP，密码与收藏、历史或备份内容会明文传输，网络中的其他人可能读取。'
              '建议改用 HTTPS。仅在了解风险并信任网络时继续。\n\n目标：${uri.host}:${uri.port}${uri.path}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消并改用 HTTPS'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('接受此地址风险'),
              ),
            ],
          ),
        );
        if (!mounted ||
            consent != true ||
            endpoint != _urlController.text.trim()) {
          return null;
        }
        _allowInsecureHttp = true;
        _consentedBaseUrl = endpoint;
      }
      final config = _config;
      if (widget.fullBackup) {
        config.fileUrl;
      } else {
        config.directoryUrl;
      }
      await ref.read(webDavConfigProvider.notifier).update(config);
      return mounted ? config : null;
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '连接配置未保存：${SourceException.sanitizeMessage('$error')}';
          _failed = true;
        });
      }
      return null;
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _saveAndCheck() => _checkRemote();

  Future<bool> _requireConnection() async {
    await ref.read(libraryAutoSyncProvider.notifier).checkConnection();
    if (!mounted) return false;
    final connection = ref.read(libraryAutoSyncProvider);
    if (!connection.connected) {
      throw StateError(connection.error ?? '尚未通过服务器连接检测');
    }
    return true;
  }

  Future<void> _checkRemote() async {
    if (_busy) return;
    _retry = _checkRemote;
    final config = await _prepareConfig();
    if (config == null || !mounted) return;
    setState(() {
      _localBusy = true;
      _failed = false;
      _status = '正在检测远端…';
    });
    try {
      if (!await _requireConnection()) return;
      final client = ref.read(webDavClientProvider);
      final document = widget.fullBackup
          ? VersionedWebDavBackup(client).head(config)
          : widget.animeCollectionOnly
          ? ref.read(legacyAnimeWebDavImportProvider).document
          : ref.read(libraryWebDavSyncProvider).document;
      final info = await client.stat(document);
      if (!mounted) return;
      setState(() {
        _remote = info;
        _status = widget.fullBackup
            ? (info.exists ? '远端备份可用' : '远端尚无完整备份')
            : widget.animeCollectionOnly
            ? (info.exists ? '旧版追番收藏可用，可执行一次性兼容导入' : '远端没有旧版追番收藏文件')
            : (info.exists ? '连接成功，收藏与历史会按自动同步设置合并' : '连接成功；首次自动同步会创建收藏与历史文档');
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '检测失败：${SourceException.sanitizeMessage('$error')}';
        });
      }
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _syncLibrary() async {
    if (_busy) return;
    _retry = _syncLibrary;
    final automatic = ref.read(libraryAutoSyncProvider);
    if (automatic.configured || !automatic.bangumiEnabled) {
      final config = await _prepareConfig();
      if (config == null || !mounted) return;
    }
    setState(() {
      _localBusy = true;
      _status = null;
      _failed = false;
    });
    try {
      await ref.read(libraryAutoSyncProvider.notifier).syncNow();
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _syncAnimeCollection() async {
    if (_busy) return;
    _retry = _syncAnimeCollection;
    final config = await _prepareConfig();
    if (config == null || !mounted) return;
    setState(() {
      _localBusy = true;
      _failed = false;
      _status = '正在兼容导入旧版追番收藏…';
    });
    try {
      final count = await ref
          .read(legacyAnimeWebDavImportProvider)
          .importOnce();
      ref.invalidate(libraryByTypeProvider);
      ref.invalidate(animeFollowsProvider);
      ref.invalidate(inLibraryProvider);
      if (mounted) {
        setState(
          () => _status =
              '兼容导入完成：追番收藏 $count 部。此为一次性旧版导入；后续上传和修改请使用漫画、动画收藏与历史同步。',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '旧版追番收藏导入失败：${SourceException.sanitizeMessage('$error')}';
        });
      }
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _upload() async {
    if (_busy) return;
    _retry = _upload;
    final config = await _prepareConfig();
    if (config == null || !mounted) return;
    setState(() {
      _localBusy = true;
      _failed = false;
      _status = '正在读取远端状态…';
    });
    try {
      if (!await _requireConnection()) return;
      final client = ref.read(webDavClientProvider);
      final store = VersionedWebDavBackup(client);
      final expected = await client.stat(store.head(config));
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(expected.exists ? '确认覆盖远端备份' : '确认首次上传远端备份'),
          content: Text(
            '目标：${store.head(config).fileUrl}\n'
            '范围：元数据、设置、封面${_includeDownloadedMedia ? '、已完成/部分下载媒体' : ''}。\n'
            '不包含来源代码、APK 或发布者信任。上传会创建不可变内容块和版本清单；远端变化会拒绝覆盖。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消（不上传）'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认上传'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
      setState(() => _status = null);
      await ref
          .read(webDavBackupOperationProvider.notifier)
          .upload(
            config,
            includeDownloadedMedia: _includeDownloadedMedia,
            expected: expected,
          );
      if (!mounted) return;
      final result = ref.read(webDavBackupOperationProvider);
      if (result.phase == WebDavBackupPhase.complete) {
        final remote = await client.stat(store.head(config));
        if (mounted) setState(() => _remote = remote);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '完整备份上传失败：${SourceException.sanitizeMessage('$error')}';
        });
      }
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<void> _download() async {
    if (_busy) return;
    _retry = _download;
    final config = await _prepareConfig();
    if (config == null || !mounted) return;
    setState(() {
      _localBusy = true;
      _failed = false;
      _status = '正在拉取远端备份（磁盘流式校验）…';
    });
    Directory? operation;
    BackupArtifactLease? guard;
    try {
      if (!await _requireConnection()) return;
      guard = await BackupArtifactGuard.acquireOperation();
      final client = ref.read(webDavClientProvider);
      operation = await Directory.systemTemp.createTemp('triomi-media-input-');
      final destination = File(
        '${operation.path}${Platform.pathSeparator}backup.zip',
      );
      final store = VersionedWebDavBackup(client);
      final downloaded = await store.downloadToFile(config, destination);
      if (downloaded == null) {
        final legacy = await client.downloadToFile(
          config,
          destination,
          maxBytes: VersionedWebDavBackup.maxFileSize,
        );
        if (legacy == null) {
          if (mounted) setState(() => _status = '远端没有完整备份文件');
          return;
        }
      }
      final preview = await previewBackupRestoreFile(
        ref.read(databaseProvider),
        destination.path,
        preferences: ref.read(preferencesProvider),
        apkFiles: await ref.read(backupServiceProvider).openApkFiles(),
      );
      if (!mounted) return;
      final options = await confirmBackupRestore(
        context,
        preview,
        target: config.fileUrl,
      );
      if (options == null || !mounted) return;
      final summary = await ref
          .read(backupServiceProvider)
          .importFromFile(
            destination.path,
            options: options,
            expectedHash: preview.byteHash,
          );
      ref.invalidate(libraryByTypeProvider);
      ref.invalidate(libraryCategoriesForTypeProvider);
      ref.invalidate(historyProvider);
      ref.invalidate(sourcesProvider);
      if (mounted) {
        setState(() {
          _failed = false;
          _status =
              '完整备份合并完成：作品 ${summary.items}、书架 ${summary.libraryEntries}、历史 ${summary.historyEntries}、目录 ${summary.cachedChapters}、规则 ${summary.sourceRules}（停用）';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '完整备份拉取失败：${SourceException.sanitizeMessage('$error')}';
        });
      }
    } finally {
      try {
        await operation?.delete(recursive: true);
      } on FileSystemException {
        debugPrint(
          'WebDAV restore temporary-file cleanup deferred to maintenance.',
        );
      }
      if (mounted) setState(() => _localBusy = false);
      try {
        await guard?.release();
      } catch (_) {
        debugPrint('WebDAV restore artifact lease could not be released.');
      }
    }
  }

  Future<void> _setAutomaticSync(bool value, {bool bangumi = false}) async {
    try {
      final controller = ref.read(libraryAutoSyncProvider.notifier);
      if (bangumi) {
        await controller.setBangumiEnabled(value);
      } else {
        await controller.setEnabled(value);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '自动同步设置未保存：${SourceException.sanitizeMessage('$error')}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final automatic = ref.watch(libraryAutoSyncProvider);
    final backup = ref.watch(webDavBackupOperationProvider);
    return PageScaffold(
      title: widget.fullBackup ? 'WebDAV 应用备份' : 'WebDAV 收藏与历史',
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: <Widget>[
          _card(
            child: WebDavConnectionStatus(
              state: automatic,
              onCheck: _busy || automatic.checking ? null : _checkRemote,
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.fullBackup
                      ? '完整应用备份'
                      : widget.animeCollectionOnly
                      ? '旧版追番收藏兼容'
                      : '漫画与动画跨设备同步',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  widget.fullBackup
                      ? '独立保存完整应用快照，供换机恢复或故障回滚。日常收藏和阅读进度无需上传完整备份。'
                      : widget.animeCollectionOnly
                      ? '仅导入旧版 anime-follows.v1.json 收藏，不上传、不覆盖完整备份；后续请使用统一收藏与历史同步。'
                      : '连接一次即可自动合并收藏、章节与页码 / 秒数，不需要反复上传或拉取备份。',
                ),
                if (!widget.fullBackup && !widget.animeCollectionOnly) ...[
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(
                      bottom: AppSpacing.sm,
                    ),
                    title: const Text('同步范围与缺失来源处理'),
                    children: [
                      Text(
                        '同步漫画与动画收藏（含取消收藏）、阅读与观看历史，以及准确的插件包名和来源身份。'
                        '不上传媒体文件、下载、APK / JAR / 规则代码、账号密码、Cookie 或播放链接。'
                        '同一来源按最近访问保存位置，可回退；换来源须核对作品和章节，不能直接沿用页码或秒数。'
                        '缺少插件时可到插件库安装，或搜索其他已启用来源并确认迁移。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => context.push(
                          widget.fullBackup || widget.animeCollectionOnly
                              ? AppRoutes.webdav
                              : AppRoutes.webdavBackup,
                        ),
                  icon: Icon(
                    widget.fullBackup || widget.animeCollectionOnly
                        ? Icons.cloud_sync_outlined
                        : Icons.archive_outlined,
                  ),
                  label: Text(
                    widget.fullBackup || widget.animeCollectionOnly
                        ? '前往收藏与历史同步'
                        : '前往完整应用备份',
                  ),
                ),
              ],
            ),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '共用 WebDAV 连接',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  widget.animeCollectionOnly
                      ? '旧版导入仅读取 anime-follows.v1.json；密码仍只在本机设置。'
                      : '收藏与历史、完整备份使用同一服务器和账号。密码保存在本机安全存储，不随同步或备份导出。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _urlController,
                  enabled: _initialized && !_busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://dav.example.com/dav/',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _userController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _passwordController,
                  enabled: _initialized && !_busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '密码 / 应用密码'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _pathController,
                  enabled: _initialized && !_busy,
                  decoration: const InputDecoration(
                    labelText: '远端目录',
                    hintText: 'triomi',
                  ),
                ),
                if (widget.fullBackup) ...[
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _fileController,
                    enabled: _initialized && !_busy,
                    decoration: const InputDecoration(
                      labelText: '备份文件名',
                      hintText: 'backup.zip',
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _busy ? null : _saveAndCheck,
                      icon: const Icon(Icons.check),
                      label: const Text('保存并连接'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.animeCollectionOnly)
            _card(
              child: FilledButton.icon(
                onPressed: _busy ? null : _syncAnimeCollection,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('兼容导入旧版追番收藏'),
              ),
            )
          else if (!widget.fullBackup)
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步收藏与历史'),
                    subtitle: const Text('启动、返回应用及本机记录变化时自动合并；失败保留本机数据。'),
                    value: automatic.enabled,
                    onChanged: automatic.configured ? _setAutomaticSync : null,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同时自动同步 Bangumi 收藏'),
                    subtitle: const Text(
                      '需另行配置 Bangumi 账号；只同步收藏状态，WebDAV 保留页码和播放秒数。',
                    ),
                    value: automatic.bangumiEnabled,
                    onChanged: (value) =>
                        _setAutomaticSync(value, bangumi: true),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        context.push('${AppRoutes.tracking}?type=anime'),
                    icon: const Icon(Icons.manage_accounts_outlined),
                    label: const Text('管理 Bangumi 账号'),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  OutlinedButton.icon(
                    onPressed:
                        _busy ||
                            automatic.syncing ||
                            (!automatic.configured && !automatic.bangumiEnabled)
                        ? null
                        : _syncLibrary,
                    icon: const Icon(Icons.sync),
                    label: const Text('立即同步一次'),
                  ),
                ],
              ),
            ),
          if (widget.fullBackup) ...[
            _card(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeDownloadedMedia,
                onChanged: _busy
                    ? null
                    : (value) =>
                          setState(() => _includeDownloadedMedia = value),
                title: const Text('包含已完成/部分下载媒体'),
                subtitle: const Text('仅影响完整备份；收藏与历史同步始终不含媒体或插件代码。'),
              ),
            ),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('完整备份传输', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _remote == null
                        ? '尚未检测远端状态'
                        : _remote!.exists
                        ? '远端已有备份：${((_remote!.sizeBytes ?? 0) / 1024).toStringAsFixed(1)} KB'
                              '${_remote!.modifiedAt == null ? '' : ' · ${_formatTime(_remote!.modifiedAt!)}'}'
                        : '远端还没有备份文件',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (backup.phase != WebDavBackupPhase.idle) ...[
                    WebDavBackupProgress(
                      state: backup,
                      onCancel: ref
                          .read(webDavBackupOperationProvider.notifier)
                          .cancel,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  FilledButton.icon(
                    onPressed: _busy ? null : _upload,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: const Text('上传本机备份'),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _download,
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('拉取远端备份并合并'),
                  ),
                ],
              ),
            ),
          ],
          if (!widget.fullBackup && backup.busy)
            _card(
              child: WebDavBackupProgress(
                state: backup,
                onCancel: ref
                    .read(webDavBackupOperationProvider.notifier)
                    .cancel,
              ),
            ),
          if (_localBusy && !backup.busy)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: LinearProgressIndicator(semanticsLabel: 'WebDAV 操作进行中'),
            ),
          if (_status != null)
            _card(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: <Widget>[
                        Icon(
                          _failed ? Icons.error_outline : Icons.info_outline,
                          size: 18,
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            _status!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (_failed && _retry != null)
                      TextButton.icon(
                        onPressed: _busy ? null : _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
