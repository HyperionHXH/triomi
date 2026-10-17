import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_update_service.dart';

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
  List<AppUpdateRelease>? _releases;
  AppUpdateRelease? _selected;
  String? _message;
  String? _operation;
  AppUpdateProgress? _progress;
  AppUpdateCancellation? _token;
  final _progressClock = Stopwatch()..start();
  int _lastProgressAt = 0;
  bool get _busy => _operation != null;

  @override
  void initState() {
    super.initState();
    _service.onProgress = (progress) {
      final now = _progressClock.elapsedMilliseconds;
      if (mounted && _busy && (now - _lastProgressAt >= 100 || progress.bytes == progress.total)) {
        _lastProgressAt = now;
        setState(() => _progress = progress);
      }
    };
    _service.attachProgress();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrent());
  }
  @override
  void dispose() {
    final token = _token;
    if (token != null) _service.cancel(token).catchError((Object _) {});
    final candidate = _candidate;
    if (candidate != null && candidate.offered.platform == 'android') {
      _service.discard(candidate).catchError((Object _) {});
    }
    _zipPath.dispose(); _manifestPath.dispose();
    _service.close();
    super.dispose();
  }

  Future<void> _run(String operation, Future<void> Function(AppUpdateCancellation) action) async {
    if (_busy) return;
    final token = AppUpdateCancellation();
    setState(() { _operation = operation; _token = token; _progress = null; _message = null; });
    try { await action(token); }
    on AppUpdateCancelled { if (mounted) setState(() => _message = '操作已取消；未启动安装器，也未修改应用数据。'); }
    on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.code == 'cancelled' ? '操作已取消；未启动安装器。' : (error.message ?? '系统更新操作失败；未安装'));
    }
    on FormatException catch (error) { if (mounted) setState(() => _message = error.message); }
    on HttpException catch (error) { if (mounted) setState(() => _message = error.message); }
    catch (_) { if (mounted) setState(() => _message = '更新操作未完成；请检查网络、文件和可用磁盘空间。未安装或覆盖现有应用。'); }
    finally { if (mounted) setState(() { _operation = null; _token = null; _progress = null; }); }
  }
  Future<void> _loadCurrent() => _run('读取实际安装版本与字节散列', (token) async {
    final current = await _service.current(); token.check();
    if (mounted) setState(() => _current = current);
  });
  Future<void> _checkReleases() => _run('查询官方 GitHub 发布版本（包含测试版）', (token) async {
    final current = await _service.current(); token.check();
    final releases = await _service.releases(token); token.check();
    if (mounted) {
      setState(() {
        _current = current; _releases = releases; _selected = releases.firstOrNull;
        _message = releases.isEmpty ? '暂无可识别的发布版本。' : releases.first.isNewerThan(current)
          ? '发现新版本 ${releases.first.tag}，可选择版本下载。'
          : '当前构建 ${current.versionCode} 已是最新，或比公开发布版本更新。';
      });
    }
  });
  Future<void> _acceptCandidate(AppUpdateCandidate? candidate) async {
    if (candidate == null) { if (mounted) setState(() => _message = '已取消文件选择；未修改现有应用。'); return; }
    final old = _candidate;
    if (old != null) await _service.discard(old);
    if (!mounted || _token?.cancelled == true) {
      await _service.discard(candidate);
      if (_token?.cancelled == true) throw const AppUpdateCancelled();
      return;
    }
    setState(() { _candidate = candidate; _current = candidate.current; });
  }
  Future<void> _downloadRelease() async {
    final release = _selected;
    if (release == null || _current == null || !release.isNewerThan(_current!)) return;
    final consent = await _confirm('下载 ${release.tag}？',
      '从官方 GitHub $appUpdateRepository 下载${Platform.isAndroid ? '原签名 APK' : '完整 Windows ZIP 与成员清单'}。'
      '将核对 GitHub 摘要 / SHA256SUMS、实际版本与字节。最多 512 MiB；不会自动安装。'
      '${Platform.isWindows ? '\n\nWindows 发布包未签名，SHA-256 校验完整性不等同发布者签名。' : '\n\nAndroid 必须通过系统 APK 验签并匹配当前实际安装证书。'}', '下载并核验');
    if (consent != true || !mounted) return;
    await _run('下载并核验官方更新包', (token) async {
      await _acceptCandidate(await _service.downloadRelease(release, token));
    });
  }
  Future<void> _pickApk() => _run('选择并静态核验 APK', (token) async {
    await _acceptCandidate(await _service.pickApk(token));
  });
  Future<void> _windows() async {
    final consent = await _confirm('核验本地 Windows 独立更新包？',
      '只复制并验证 ZIP、外部完整性清单、所有成员及实际 EXE 版本。请自行确认文件来源。'
      '不会运行候选或覆盖正在运行的 EXE。哈希不代表发布者签名。', '确认来源并核验');
    if (consent != true || !mounted) return;
    await _run('核验 Windows ZIP 与所有成员', (token) async {
      await _acceptCandidate(await _service.stageWindowsBundle(_zipPath.text.trim(), _manifestPath.text.trim(), token));
    });
  }
  Future<bool?> _confirm(String title, String message, String action) => showDialog<bool>(
    context: context, builder: (context) => AlertDialog(title: Text(title),
      content: SingleChildScrollView(child: SelectableText(message)), actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ]));
  Future<void> _install() async {
    final candidate = _candidate;
    if (candidate == null || !candidate.canInstall || _busy) return;
    bool allowed;
    try { allowed = await _service.canInstall(); }
    catch (_) { if (mounted) setState(() => _message = '无法读取系统安装权限；未启动安装器。'); return; }
    if (!mounted) return;
    if (!allowed) {
      final open = await _confirm('允许 Triomi 请求安装',
        '可打开仅针对 Triomi 的系统设置，由你自行授权。允许后返回此页，再次确认具体候选。', '打开系统设置');
      if (open == true && mounted) {
        await _run('打开未知来源系统设置', (_) => _service.openUnknownSources());
      }
      return;
    }
    final consent = await _confirm('打开系统安装器？',
      '当前：${_identity(candidate.current)}\n\n候选：${_identity(candidate.offered)}\n'
      '来源：${candidate.source}\n\n交接前将再次核验。最终是否安装由系统和你决定，不清除应用数据。', '打开系统安装确认');
    if (consent != true || !mounted) return;
    await _run('再次核验并交给系统安装器', (_) async {
      await _service.launchInstaller(candidate);
      if (mounted) setState(() { _candidate = null; _message = '已打开系统安装器，尚未确认安装成功。暂存 APK 保留供系统读取。'; });
    });
  }
  Future<void> _revealWindows() async {
    final candidate = _candidate;
    if (candidate == null) return;
    final consent = await _confirm('打开已核验的完整 Windows 包？',
      '将在文件资源管理器中选中 ZIP。右键“全部解压缩”到一个新目录，然后关闭 Triomi，再从新目录运行 triomi.exe。'
      '所有 DLL 和 data 文件必须保留在一起。请更新原快捷方式指向新目录。\n\n'
      '不会覆盖正在运行的 EXE；原应用数据保留。此动作不代表已经安装。', '打开文件位置');
    if (consent != true || !mounted) return;
    await _run('重新核对 ZIP 并打开文件位置', (token) async {
      await _service.revealWindowsBundle(candidate, token);
      if (mounted) setState(() => _message = '已请求打开文件资源管理器。请解压到新目录，关闭 Triomi 后运行新目录中的 triomi.exe。尚未安装。');
    });
  }
  Future<void> _discard() async {
    final candidate = _candidate;
    if (candidate == null) return;
    await _run('移除本次更新暂存', (_) async {
      await _service.discard(candidate);
      if (mounted) setState(() { _candidate = null; _message = '已移除本次更新暂存，应用数据不变。'; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _current, candidate = _candidate, selected = _selected;
    final android = Platform.isAndroid, windows = Platform.isWindows;
    final assetName = android ? 'triomi-android.apk' : 'triomi-windows.zip';
    return Scaffold(appBar: AppBar(title: const Text('版本管理'), actions: [
      IconButton(tooltip: '重新读取安装身份', onPressed: _busy ? null : _loadCurrent, icon: const Icon(Icons.refresh)),
    ]), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('官方仓库 HyperionHXH/triomi。点击检查后匿名查询 GitHub Releases，包含测试版；不携带来源账号、Cookie 或令牌，不自动安装。'),
      if (_busy) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_operation!), const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress?.total == null || _progress!.total! <= 0 ? null
            : (_progress!.bytes / _progress!.total!).clamp(0.0, 1.0)),
          Text(_progress == null ? '正在处理；可取消。' : '${_progress!.phase}：${_progress!.bytes} 字节${_progress!.total == null ? '' : ' / ${_progress!.total}'}'),
          TextButton(onPressed: _token?.cancelled == true ? null : () => _service.cancel(_token!), child: const Text('取消')),
        ]))),
      if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(_message!)),
      if (current != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('已安装 ${current.version} · 构建 ${current.versionCode}'),
          ExpansionTile(title: const Text('实际安装身份与散列'), children: [SelectableText(_identity(current))]),
          if (android && current.signerSha256 != appUpdateProductionSigner)
            const Text('当前安装证书与正式证书不同；正式 APK 无法覆盖，仍严格核对实际安装证书。'),
        ]))),
      if (android || windows) FilledButton.icon(onPressed: _busy ? null : _checkReleases,
        icon: const Icon(Icons.system_update), label: const Text('检查 GitHub 新版本')),
      if (_releases != null && _releases!.isNotEmpty) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<AppUpdateRelease>(key: ValueKey(_releases), initialValue: selected, isExpanded: true,
          decoration: const InputDecoration(labelText: '选择发布版本（含测试版）'),
          items: _releases!.map((release) => DropdownMenuItem(value: release,
            child: Text('${release.tag}${release.prerelease ? ' · 测试版' : ''}', overflow: TextOverflow.ellipsis))).toList(),
          onChanged: _busy ? null : (value) => setState(() => _selected = value)),
      ],
      if (selected != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(selected.name, style: Theme.of(context).textTheme.titleMedium),
          Text('发布：${selected.publishedAt}'),
          Text(current == null ? '请先读取实际安装版本。' : selected.versionCode > current.versionCode
            ? '可更新：构建 ${current.versionCode} → ${selected.versionCode}'
            : selected.versionCode == current.versionCode ? '当前已安装此构建；不重复安装。' : '这是旧版本，不允许降级。'),
          const SizedBox(height: 8), SelectableText(selected.notes.isEmpty ? '此版本未提供发布说明。' : selected.notes),
          if (selected.assets[assetName] case final asset?) Text('完整更新包：${asset.name} · ${(asset.bytes / 1024 / 1024).toStringAsFixed(1)} MiB'),
          FilledButton(onPressed: _busy || current == null || !selected.isNewerThan(current) ||
              !selected.assets.containsKey(assetName) ? null : _downloadRelease,
            child: Text(windows ? '下载并核验完整 Windows ZIP' : '下载并核验 APK')),
        ]))),
      if (candidate != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('实际候选（尚未安装）'), SelectableText(_identity(candidate.offered)),
          SelectableText('文件大小：${candidate.bytes} 字节\n来源：${candidate.source}'),
          Text(_decision(candidate.decision)),
          if (android && candidate.canInstall) FilledButton(onPressed: _busy ? null : _install, child: const Text('打开系统安装器')),
          if (windows && candidate.canInstall) ...[
            const Text('Windows ZIP 未签名。解压到新目录，关闭 Triomi 后运行新目录中的 triomi.exe；不覆盖正在运行的程序。'),
            FilledButton.icon(onPressed: _busy ? null : _revealWindows, icon: const Icon(Icons.folder_open), label: const Text('打开文件位置，解压后更新')),
          ],
          TextButton(onPressed: _busy ? null : _discard, child: const Text('移除本次更新暂存')),
        ]))),
      if (android || windows) ExpansionTile(title: const Text('高级：核验本地更新包'), children: [
        if (android) OutlinedButton.icon(onPressed: _busy ? null : _pickApk,
          icon: const Icon(Icons.folder_open), label: const Text('选择本地 APK 并核验')),
        if (windows) ...[
          TextField(controller: _zipPath, enabled: !_busy, decoration: const InputDecoration(labelText: '可信本地 Windows ZIP 完整路径')),
          TextField(controller: _manifestPath, enabled: !_busy, decoration: const InputDecoration(labelText: '对应 triomi-windows.update.json 完整路径')),
          OutlinedButton(onPressed: _busy ? null : _windows, child: const Text('核验并暂存本地完整桌面包')),
        ],
      ]),
      if (!android && !windows) const Text('当前平台请使用平台发布渠道。'),
    ]));
  }
}

String _identity(AppUpdateInfo info) => '${info.packageName}\n版本 ${info.version}（${info.versionCode}）\n'
    '字节 SHA-256：${info.sha256}${info.artifactSha256 == null ? '' : '\nEXE SHA-256：${info.artifactSha256}'}\n'
    '签名证书 SHA-256：${info.signerSha256 ?? 'Windows 未签名；仅核验完整性'}';
String _decision(String value) => switch (value) {
  'upgrade' => '核验通过：高版本候选。尚未安装。',
  'wrongPackage' => '拒绝：包名或平台与当前应用不符。',
  'wrongSigner' => '拒绝：签名未核验或与实际安装签名不符。',
  'downgrade' => '拒绝：候选版本低于实际安装版本。',
  'sameVersionChanged' => '拒绝：相同版本号的字节内容已改变。',
  'alreadyInstalled' => '无需更新：相同版本和完全相同字节。',
  _ => '拒绝：未知的核验结果。',
};
