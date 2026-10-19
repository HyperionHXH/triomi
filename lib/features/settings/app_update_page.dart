import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import 'app_update_service.dart';
import 'app_update_widgets.dart';

/// Network checks and installation always require an explicit user action.
class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.service});
  final AppUpdateService? service;

  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final AppUpdateService _service = widget.service ?? AppUpdateService();
  final _zipPath = TextEditingController();
  final _manifestPath = TextEditingController();
  AppUpdateInfo? _current;
  AppUpdateCandidate? _candidate;
  AppUpdateCandidate? _handoffInFlight;
  List<AppUpdateRelease>? _releases;
  AppUpdateRelease? _selected;
  String? _message;
  String? _operation;
  String? _operationTarget;
  AppUpdateProgress? _progress;
  AppUpdateCancellation? _token;
  Future<void> Function()? _retry;
  final _progressClock = Stopwatch()..start();
  int _lastProgressAt = 0;
  bool _failed = false;
  bool _prompting = false;
  bool _backPrompting = false;
  bool _cancellable = true;
  bool _handedOff = false;
  bool _handoffWindows = false;
  bool _unsupportedPlatform = false;

  bool get _busy => _operation != null;
  bool get _locked => _busy || _prompting || _backPrompting;
  bool get _android => _current?.platform == 'android';
  bool get _windows => _current?.platform == 'windows';
  bool get _supported => !_unsupportedPlatform && (_android || _windows);
  String get _assetName =>
      _windows ? 'triomi-windows.zip' : 'triomi-android.apk';

  Object get _listStage {
    if (_busy) {
      return _token!;
    }
    if (_message != null) {
      return 'result';
    }
    if (_handedOff) {
      return 'handoff';
    }
    if (_candidate != null) {
      return 'ready';
    }
    return 'overview';
  }

  @override
  void initState() {
    super.initState();
    _service.onProgress = (progress) {
      final now = _progressClock.elapsedMilliseconds;
      if (mounted &&
          _busy &&
          _token?.cancelled != true &&
          (progress.phase != _progress?.phase ||
              now - _lastProgressAt >= 100 ||
              progress.bytes == progress.total)) {
        _lastProgressAt = now;
        setState(() => _progress = progress);
      }
    };
    _service.attachProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadCurrent();
    });
  }

  @override
  void dispose() {
    _service.onProgress = null;
    final token = _token;
    if (token != null && _cancellable) {
      token.cancel();
      _service.cancel(token).catchError((Object _) {});
    }
    final candidate = _candidate;
    // Once a launcher is reading the verified file, route disposal must not
    // remove it. A failed launcher still cleans it below, even after disposal.
    if (candidate != null &&
        !_handedOff &&
        !identical(candidate, _handoffInFlight)) {
      _service.discard(candidate).catchError((Object _) {});
    }
    _zipPath.dispose();
    _manifestPath.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _run(
    String operation,
    Future<void> Function(AppUpdateCancellation) action, {
    required String targetLabel,
    Future<void> Function()? retry,
    bool cancellable = true,
  }) async {
    if (!mounted || _busy) return;
    final token = AppUpdateCancellation();
    setState(() {
      _operation = operation;
      _operationTarget = targetLabel;
      _token = token;
      _cancellable = cancellable;
      _progress = null;
      _message = null;
      _failed = false;
      _retry = null;
    });
    try {
      await action(token);
    } on AppUpdateCancelled {
      if (mounted) {
        setState(() {
          _message = '已取消本次操作，未启动安装器。应用和个人数据保持不变。';
        });
      }
    } on PlatformException catch (error) {
      _reportFailure(
        error.code == 'cancelled'
            ? '系统已取消本次操作，未安装更新。'
            : error.message ?? '系统未能完成更新操作，尚未安装。',
        retry,
      );
    } on FormatException catch (error) {
      _reportFailure(error.message, retry);
    } on HttpException catch (error) {
      _reportFailure(error.message, retry);
    } catch (_) {
      _reportFailure('更新操作未完成。请检查网络、文件及可用空间；未安装或覆盖现有应用。', retry);
    } finally {
      if (mounted) {
        setState(() {
          _operation = null;
          _token = null;
          _progress = null;
        });
      }
    }
  }

  void _reportFailure(String message, Future<void> Function()? retry) {
    if (!mounted) return;
    setState(() {
      _failed = true;
      _message = message;
      _retry = retry;
    });
  }

  Future<AppUpdateInfo?> _readCurrent(AppUpdateCancellation token) async {
    try {
      final current = await _service.current();
      token.check();
      return current;
    } on UnsupportedError {
      token.check();
      if (mounted) {
        setState(() {
          _unsupportedPlatform = true;
          _current = null;
        });
      }
      return null;
    }
  }

  Future<void> _loadCurrent() async {
    if (_unsupportedPlatform) {
      return;
    }
    await _run(
      '正在读取当前版本',
      (token) async {
        final current = await _readCurrent(token);
        if (current != null) {
          _publishCurrent(current);
        }
      },
      targetLabel: '当前安装版本',
      retry: _loadCurrent,
    );
  }

  void _publishCurrent(AppUpdateInfo current) {
    if (!mounted) return;
    final candidate = _candidate;
    final refreshed = candidate == null
        ? null
        : AppUpdateCandidate(
            current: current,
            offered: candidate.offered,
            path: candidate.path,
            bytes: candidate.bytes,
            source: candidate.source,
            decision: appUpdateDecision(
              current,
              candidate.offered,
              signatureVerified: candidate.signatureVerified,
            ),
            signatureVerified: candidate.signatureVerified,
            manifestPath: candidate.manifestPath,
          );
    setState(() {
      _current = current;
      _unsupportedPlatform =
          current.platform != 'android' && current.platform != 'windows';
      _candidate = refreshed;
    });
  }

  Future<void> _checkReleases() async {
    if (_unsupportedPlatform) {
      return;
    }
    await _run(
      '正在检查官方更新',
      (token) async {
        final current = await _readCurrent(token);
        if (current == null) {
          return;
        }
        _publishCurrent(current);
        if (!_supported) {
          return;
        }
        final releases = await _service.releases(token);
        token.check();
        if (mounted) {
          setState(() {
            _releases = releases;
            _selected = releases.firstOrNull;
            if (releases.isEmpty) {
              _message = '官方仓库暂时没有可识别的发布版本，请稍后再检查。';
            }
          });
        }
      },
      targetLabel: 'Triomi 官方更新',
      retry: _checkReleases,
    );
  }

  Future<void> _cancelActive() async {
    final token = _token;
    if (token == null || token.cancelled || !_cancellable) return;
    token.cancel();
    setState(() {});
    try {
      await _service.cancel(token);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '已请求停止，正在等待当前系统操作结束。请留在此页。';
        });
      }
    }
  }

  Future<T?> _prompt<T>(Future<T?> Function() show) async {
    if (!mounted || _locked) return null;
    setState(() => _prompting = true);
    try {
      return await show();
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  Future<bool?> _confirm(
    String title,
    String message,
    String action, {
    String? actionKey,
  }) => _prompt(
    () => showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        constraints: const BoxConstraints(maxWidth: 560),
        title: Text(title),
        content: SizedBox(width: 480, child: Text(message)),
        actions: [
          TextButton(
            key: const ValueKey('app-update-confirm-cancel'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: actionKey == null ? null : ValueKey(actionKey),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ),
  );

  String? _releaseIssue(AppUpdateRelease release) {
    final current = _current;
    if (current == null) return '请先读取当前安装版本。';
    if (!_supported) return '此平台请使用对应的平台发布渠道。';
    if (release.versionCode < current.versionCode) {
      return '这是较早的版本，为保护应用数据不提供降级。';
    }
    if (release.versionCode == current.versionCode) return '已安装此构建，无需重复安装。';
    if (!release.assets.containsKey(_assetName)) {
      return '此版本尚未提供 ${_windows ? 'Windows 完整 ZIP' : 'Android APK'}，可选择其他发布版本。';
    }
    if (_windows && !release.assets.containsKey('triomi-windows.update.json')) {
      return '此版本尚未提供 Windows 完整成员清单，暂时无法安全更新。';
    }
    return null;
  }

  Future<void> _acceptCandidate(
    AppUpdateCandidate? candidate,
    AppUpdateCancellation token,
  ) async {
    if (candidate == null) {
      token.check();
      if (mounted) setState(() => _message = '已取消文件选择，未修改现有应用。');
      return;
    }
    try {
      token.check();
      if (!mounted) {
        await _service.discard(candidate);
        return;
      }
      final old = _candidate;
      if (old != null && !_handedOff) await _service.discard(old);
      token.check();
      if (!mounted) {
        await _service.discard(candidate);
        return;
      }
      setState(() {
        _candidate = candidate;
        _current = candidate.current;
        _handedOff = false;
      });
    } catch (_) {
      await _service.discard(candidate);
      rethrow;
    }
  }

  Future<void> _downloadRelease() async {
    final release = _selected;
    if (_locked || release == null || _releaseIssue(release) != null) return;
    final consent = await _confirm(
      '下载 ${release.version} · 构建 ${release.versionCode}',
      '从官方 GitHub $appUpdateRepository 匿名下载${_windows ? '完整 Windows ZIP 与成员清单' : 'Android APK'}。'
          '下载后将核对文件大小、SHA-256 和实际版本，最多 512 MiB，不会自动安装。\n\n'
          '${_windows ? 'Windows 包未签名：完整性校验不等同发布者签名。' : 'Android 还需通过系统验签，并匹配当前实际安装证书。'}',
      '下载并核验',
      actionKey: 'app-update-download-confirm',
    );
    if (consent != true || !mounted) return;
    AppUpdateCandidate? downloaded;
    await _run(
      '正在下载更新',
      (token) async {
        downloaded = await _service.downloadRelease(release, token);
        await _acceptCandidate(downloaded, token);
      },
      targetLabel: '${release.version} · 构建 ${release.versionCode}',
      retry: _downloadRelease,
    );
    if (mounted && identical(downloaded, _candidate)) {
      await _offerReady(downloaded: true);
    }
  }

  Future<void> _pickApk() async {
    AppUpdateCandidate? picked;
    await _run(
      '正在核验本地 APK',
      (token) async {
        picked = await _service.pickApk(token);
        await _acceptCandidate(picked, token);
      },
      targetLabel: '本地更新包',
      retry: _pickApk,
    );
    if (mounted && picked != null && identical(picked, _candidate)) {
      await _offerReady();
    }
  }

  Future<void> _windowsPackage() async {
    final consent = await _confirm(
      '核验本地 Windows 更新包',
      '仅复制并核验 ZIP、外部完整性清单、所有成员和 EXE 实际版本。'
          '请自行确认文件来源；哈希不代表发布者签名。不会运行候选文件或覆盖当前程序。',
      '确认来源并核验',
    );
    if (consent != true || !mounted) return;
    AppUpdateCandidate? staged;
    await _run(
      '正在核验 Windows 更新包',
      (token) async {
        staged = await _service.stageWindowsBundle(
          _zipPath.text.trim(),
          _manifestPath.text.trim(),
          token,
        );
        await _acceptCandidate(staged, token);
      },
      targetLabel: '本地更新包',
      retry: _windowsPackage,
    );
    if (mounted && staged != null && identical(staged, _candidate)) {
      await _offerReady();
    }
  }

  Future<void> _offerReady({bool downloaded = false}) async {
    final candidate = _candidate;
    if (candidate == null || !candidate.canInstall || _locked) return;
    final consent = await _prompt(
      () => showAppUpdateReadyDialog(
        context,
        candidate: candidate,
        windows: candidate.offered.platform == 'windows',
        downloaded: downloaded,
      ),
    );
    if (consent != true || !mounted || !identical(candidate, _candidate)) {
      return;
    }
    // This dialog is the app's explicit consent. The native installer still
    // requires its own OS confirmation; do not add a second app confirmation.
    if (candidate.offered.platform == 'android') {
      await _install(candidate);
    } else if (candidate.offered.platform == 'windows') {
      await _handoff(candidate, windows: true);
    }
  }

  Future<void> _install(AppUpdateCandidate candidate) async {
    if (_locked || !candidate.canInstall || !identical(candidate, _candidate)) {
      return;
    }
    bool allowed = false;
    bool permissionRead = false;
    await _run(
      '正在读取系统安装权限',
      (token) async {
        allowed = await _service.canInstall();
        token.check();
        permissionRead = true;
      },
      targetLabel:
          '${candidate.offered.version} · 构建 ${candidate.offered.versionCode}',
      retry: _offerReady,
    );
    if (!mounted ||
        !permissionRead ||
        _failed ||
        _backPrompting ||
        !identical(candidate, _candidate)) {
      return;
    }
    if (!allowed) {
      final open = await _prompt(() => showAppUpdatePermissionDialog(context));
      if (open == true && mounted) {
        await _run(
          '正在打开 Triomi 安装权限设置',
          (_) => _service.openUnknownSources(),
          targetLabel:
              '${candidate.offered.version} · 构建 ${candidate.offered.versionCode}',
          cancellable: false,
        );
        if (mounted && !_failed) {
          setState(() {
            _message = '返回后请再次点击安装并确认此更新包；不会自动启动安装。';
          });
        }
      }
      return;
    }
    await _handoff(candidate, windows: false);
  }

  Future<void> _handoff(
    AppUpdateCandidate candidate, {
    required bool windows,
  }) async {
    final alreadyHandedOff = _handedOff;
    await _run(
      windows ? '正在打开更新包位置' : '正在打开系统安装器',
      (token) async {
        _handoffInFlight = candidate;
        try {
          if (windows) {
            await _service.revealWindowsBundle(candidate, token);
          } else {
            await _service.launchInstaller(candidate);
          }
          if (mounted) {
            setState(() {
              _handedOff = true;
              _handoffWindows = windows;
            });
          }
        } catch (_) {
          if (!mounted && !alreadyHandedOff) await _service.discard(candidate);
          rethrow;
        } finally {
          _handoffInFlight = null;
        }
      },
      targetLabel:
          '${candidate.offered.version} · 构建 ${candidate.offered.versionCode}',
      retry: _offerReady,
      cancellable: false,
    );
  }

  Future<void> _discard() async {
    final candidate = _candidate;
    if (candidate == null) return;
    await _run(
      '正在移除更新暂存',
      (_) async {
        await _service.discard(candidate);
        if (mounted) {
          setState(() {
            _candidate = null;
            _message = '已移除本次更新包，应用和个人数据保持不变。';
          });
        }
      },
      targetLabel:
          '${candidate.offered.version} · 构建 ${candidate.offered.versionCode}',
      retry: _discard,
    );
  }

  Future<void> _showHistory() async {
    final releases = _releases;
    if (_locked || releases == null || releases.isEmpty) return;
    final selected = await _prompt(
      () => showModalBottomSheet<AppUpdateRelease>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  0,
                  AppSpacing.md,
                  AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择发布版本',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭版本列表',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Text('包含测试版。只允许更高构建，文件仍需下载后完整核验。'),
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: releases.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.xs),
                  itemBuilder: (context, index) {
                    final release = releases[index];
                    final chosen = identical(release, _selected);
                    return AppCard(
                      key: ValueKey(
                        'app-update-release-${release.versionCode}',
                      ),
                      onTap: () => Navigator.pop(context, release),
                      child: Row(
                        children: [
                          Icon(
                            chosen
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: chosen
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${release.version} · 构建 ${release.versionCode}',
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                Text(
                                  '${release.prerelease ? '测试版 · ' : ''}${_releaseDate(release.publishedAt)}',
                                ),
                                Text(
                                  _releaseIssue(release) ?? '可下载更新',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && selected != null) {
      setState(() {
        _selected = selected;
        _message = null;
        _failed = false;
        _retry = null;
      });
    }
  }

  Future<void> _showNotes(AppUpdateRelease release) async {
    await _prompt(
      () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${release.version} · 更新说明'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                release.notes.isEmpty ? '此版本未提供更新说明。' : release.notes,
              ),
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _explainBusyBack() async {
    if (_prompting || _backPrompting || !_busy) return;
    setState(() => _backPrompting = true);
    bool? cancel;
    try {
      cancel = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_cancellable ? '更新操作正在进行' : '正在交给系统处理'),
          content: SingleChildScrollView(
            child: Text(
              _cancellable
                  ? '离开前请先取消当前操作，等待临时文件清理完成。也可以留在此页继续等待。'
                  : '系统交接尚未返回，请留在此页等待，避免移除系统正在读取的更新包。',
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('app-update-back-wait'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续等待'),
            ),
            if (_cancellable)
              FilledButton(
                key: const ValueKey('app-update-back-cancel'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('取消当前操作'),
              ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _backPrompting = false);
    }
    if (cancel == true && mounted && _busy) await _cancelActive();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final candidate = _candidate;
    final selected = _selected;
    final theme = Theme.of(context);
    final latest = _releases?.firstOrNull;
    final hasUpdate =
        current != null && latest != null && latest.isNewerThan(current);
    final status = _unsupportedPlatform
        ? '请使用平台发布渠道'
        : current == null
        ? (_failed ? '当前版本暂时无法读取' : '正在了解当前版本')
        : _releases == null
        ? '尚未检查更新'
        : latest == null
        ? '暂时没有发布版本'
        : hasUpdate
        ? '有新版本等你体验'
        : '当前已是最新构建';
    final issue = selected == null ? null : _releaseIssue(selected);
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _explainBusyBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('应用更新'),
          actions: [
            if (!_unsupportedPlatform)
              IconButton(
                key: const ValueKey('app-update-refresh-current'),
                tooltip: '重新读取当前安装版本',
                onPressed: _locked ? null : _loadCurrent,
                icon: const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 768),
              child: ListView(
                key: ValueKey(_listStage),
                primary: false,
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  if (_busy) ...[
                    AppUpdateTransferView(
                      versionLabel: _operationTarget!,
                      operationLabel: _operation!,
                      progress: _progress,
                      onCancel: _cancellable ? _cancelActive : null,
                      cancelling: _token?.cancelled == true,
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _failed
                                    ? Icons.error_outline_rounded
                                    : Icons.info_outline_rounded,
                                color: _failed
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.primary,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(child: Text(_message!)),
                            ],
                          ),
                          if (_retry != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            OutlinedButton.icon(
                              key: const ValueKey('app-update-retry'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _locked ? null : _retry,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('重试这一步'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (candidate != null && !_handedOff) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppUpdateReadyView(
                      candidate: candidate,
                      busy: _locked,
                      onInstall: _android ? _offerReady : null,
                      onRevealWindows: _windows ? _offerReady : null,
                      onDiscard: _discard,
                    ),
                  ],
                  if (_handedOff) ...[
                    const SizedBox(height: AppSpacing.md),
                    AppUpdateHandoffView(
                      windows: _handoffWindows,
                      onRefreshCurrent: _locked ? null : _loadCurrent,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (candidate?.canInstall == true)
                      OutlinedButton.icon(
                        key: const ValueKey('app-update-handoff-reopen'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _locked ? null : _offerReady,
                        icon: Icon(
                          _handoffWindows
                              ? Icons.folder_open_rounded
                              : Icons.install_mobile_rounded,
                        ),
                        label: Text(
                          _handoffWindows ? '再次打开更新包位置' : '需要时再次打开安装器',
                        ),
                      )
                    else
                      const Text('此更新包已不再适用于当前安装版本，无需再次交接。'),
                  ],
                  if (_busy ||
                      _message != null ||
                      candidate != null ||
                      _handedOff)
                    const SizedBox(height: AppSpacing.md),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: AppRadius.cardRadius,
                              ),
                              child: Icon(
                                Icons.auto_stories_rounded,
                                size: 36,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Triomi',
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          fontWeight: AppTypography.strong,
                                        ),
                                  ),
                                  const SizedBox(height: AppSpacing.xxs),
                                  Text(
                                    _unsupportedPlatform
                                        ? '此平台不支持应用内更新'
                                        : current == null
                                        ? '正在读取已安装版本…'
                                        : '${current.version} · 构建 ${current.versionCode}',
                                    key: const ValueKey(
                                      'app-update-installed-version',
                                    ),
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _failed
                                  ? Icons.info_outline_rounded
                                  : hasUpdate
                                  ? Icons.new_releases_outlined
                                  : _releases == null
                                  ? Icons.tips_and_updates_outlined
                                  : Icons.verified_outlined,
                              color: _failed
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                status,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _unsupportedPlatform
                              ? '请通过当前平台的发布渠道更新 Triomi。此处不提供应用内下载或安装。'
                              : '仅在你点击时匿名检查官方 GitHub 发布（含测试版）。不发送来源账号、Cookie 或令牌，也不自动安装。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (!_unsupportedPlatform &&
                            (current == null || _supported)) ...[
                          const SizedBox(height: AppSpacing.md),
                          if (_releases == null &&
                              candidate == null &&
                              !_handedOff)
                            FilledButton.icon(
                              key: const ValueKey('app-update-check'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _locked ? null : _checkReleases,
                              icon: const Icon(Icons.sync_rounded),
                              label: const Text('检查更新'),
                            )
                          else
                            OutlinedButton.icon(
                              key: const ValueKey('app-update-check'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _locked ? null : _checkReleases,
                              icon: const Icon(Icons.sync_rounded),
                              label: const Text('再次检查更新'),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (selected != null && !_unsupportedPlatform) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            identical(selected, latest) ? '最新发布' : '所选发布',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('app-update-history'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: _locked ? null : _showHistory,
                          icon: const Icon(Icons.history_rounded),
                          label: const Text('其他版本'),
                        ),
                      ],
                    ),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                selected.version,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: AppTypography.strong,
                                ),
                              ),
                              if (selected.prerelease)
                                const Chip(
                                  label: Text('测试版'),
                                  visualDensity: VisualDensity.compact,
                                ),
                            ],
                          ),
                          Text(
                            '构建 ${selected.versionCode} · ${_releaseDate(selected.publishedAt)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (selected.name != selected.tag &&
                              selected.name != selected.version) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              selected.name,
                              style: theme.textTheme.titleSmall,
                            ),
                          ],
                          const SizedBox(height: AppSpacing.md),
                          Container(
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                              borderRadius: AppRadius.controlRadius,
                            ),
                            child: Text(
                              issue ??
                                  '构建 ${current!.versionCode} → ${selected.versionCode} · 可更新',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text('更新内容', style: theme.textTheme.titleSmall),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            selected.notes.isEmpty
                                ? '此版本未提供更新说明。'
                                : selected.notes,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (selected.notes.isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                ),
                                onPressed: _locked
                                    ? null
                                    : () => _showNotes(selected),
                                icon: const Icon(Icons.article_outlined),
                                label: const Text('完整更新说明'),
                              ),
                            ),
                          if (selected.assets[_assetName]
                              case final asset?) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Container(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              decoration: BoxDecoration(
                                borderRadius: AppRadius.controlRadius,
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant,
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    _windows
                                        ? Icons.desktop_windows_outlined
                                        : Icons.android_rounded,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _windows
                                              ? 'Windows 完整更新包'
                                              : 'Android 安装包',
                                          style: theme.textTheme.titleSmall,
                                        ),
                                        Text(
                                          '${(asset.bytes / 1024 / 1024).toStringAsFixed(1)} MiB · ${_windows ? 'ZIP + 成员清单，未签名' : 'APK，核对实际安装签名'}',
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.md),
                          if (candidate == null)
                            FilledButton(
                              key: const ValueKey('app-update-download'),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _locked || issue != null
                                  ? null
                                  : _downloadRelease,
                              child: const Text('下载更新'),
                            )
                          else
                            OutlinedButton(
                              key: const ValueKey('app-update-download'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: _locked || issue != null
                                  ? null
                                  : _downloadRelease,
                              child: const Text('重新下载此版本'),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (current != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    AppCard(
                      padding: EdgeInsets.zero,
                      child: ExpansionTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: const Text('安装身份与安全信息'),
                        subtitle: const Text('实际版本、证书及完整性校验'),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          0,
                          AppSpacing.md,
                          AppSpacing.md,
                        ),
                        children: [
                          SelectableText(_currentIdentity(current)),
                          if (_android &&
                              current.signerSha256 !=
                                  appUpdateProductionSigner) ...[
                            const SizedBox(height: AppSpacing.sm),
                            const Text(
                              '当前证书与正式证书不同，正式 APK 无法直接覆盖。更新仍必须匹配实际安装证书，不会跳过验签。',
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm),
                          const Text(
                            '官方仓库：HyperionHXH/triomi。SHA-256 仅核验文件完整性；Windows 包未作发布者签名。',
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_supported) ...[
                    const SizedBox(height: AppSpacing.sm),
                    ExpansionTile(
                      key: const ValueKey('app-update-local-packages'),
                      leading: const Icon(Icons.folder_open_outlined),
                      title: const Text('本地更新包'),
                      subtitle: const Text('高级选项 · 仍需完整核验'),
                      childrenPadding: const EdgeInsets.all(AppSpacing.md),
                      children: [
                        if (_android)
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _locked ? null : _pickApk,
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text('选择本地 APK'),
                          ),
                        if (_windows) ...[
                          TextField(
                            key: const ValueKey('app-update-local-zip'),
                            controller: _zipPath,
                            enabled: !_locked,
                            decoration: const InputDecoration(
                              labelText: '可信 Windows ZIP 完整路径',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          TextField(
                            key: const ValueKey('app-update-local-manifest'),
                            controller: _manifestPath,
                            enabled: !_locked,
                            decoration: const InputDecoration(
                              labelText: 'triomi-windows.update.json 完整路径',
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          OutlinedButton(
                            key: const ValueKey('app-update-local-verify'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: _locked ? null : _windowsPackage,
                            child: const Text('核验本地完整更新包'),
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _releaseDate(String value) {
  final date = DateTime.tryParse(value)?.toLocal();
  if (date == null) return '发布日期未提供';
  return '${date.year} 年 ${date.month} 月 ${date.day} 日';
}

String _currentIdentity(AppUpdateInfo info) =>
    '${info.packageName}\n'
    '版本 ${info.version} · 构建 ${info.versionCode}\n'
    '字节 SHA-256：${info.sha256}'
    '${info.artifactSha256 == null ? '' : '\nEXE SHA-256：${info.artifactSha256}'}\n'
    '签名证书 SHA-256：${info.signerSha256 ?? 'Windows 未签名；仅核验完整性'}';
