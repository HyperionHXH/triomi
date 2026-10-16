import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_update_service.dart';

/// Opening this page only reads installed identity. No automatic network call.
class AppUpdatePage extends StatefulWidget {
  const AppUpdatePage({super.key, this.service});
  final AppUpdateService? service;
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final AppUpdateService _service = widget.service ?? AppUpdateService();
  final _endpoint = TextEditingController();
  final _zipPath = TextEditingController();
  final _manifestPath = TextEditingController();
  AppUpdateInfo? _current;
  AppUpdateCandidate? _candidate;
  AppUpdateManifest? _manifest;
  String? _checkedEndpoint;
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
    _endpoint.dispose(); _zipPath.dispose(); _manifestPath.dispose();
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
    catch (_) { if (mounted) setState(() => _message = '更新操作未完成；请核对文件、当前平台和可用磁盘空间。未安装或覆盖现有应用。'); }
    finally { if (mounted) setState(() { _operation = null; _token = null; _progress = null; }); }
  }
  Future<void> _loadCurrent() => _run('读取实际安装版本与字节散列', (token) async {
    final current = await _service.current(); token.check();
    if (mounted) setState(() => _current = current);
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
  Future<void> _pickApk() => _run('选择并静态核验 APK（不执行候选）', (token) async {
    await _acceptCandidate(await _service.pickApk(token));
  });
  Future<void> _checkManifest() async {
    final endpoint = _endpoint.text.trim();
    try { AppUpdateManifest.https(endpoint); }
    on FormatException catch (error) { setState(() => _message = error.message); return; }
    final consent = await _confirm('查询手动更新来源？',
      '将向你填写的 HTTPS 地址发送一次匿名 GET 请求。不会携带来源账号、Cookie 或私密凭据；不跟随重定向。\n\n'
      '尚无配置的公开生产发布端点。你填写的清单及其哈希不是发布者身份证明；Android APK 仍必须与实际安装签名一致。', '查询这个来源');
    if (consent != true || !mounted) return;
    await _run('读取手动 HTTPS 更新清单', (token) async {
      final manifest = await _service.checkManifest(endpoint, token);
      token.check();
      if (mounted) setState(() { _manifest = manifest; _checkedEndpoint = endpoint; });
    });
  }
  Future<void> _download() async {
    final manifest = _manifest, endpoint = _checkedEndpoint;
    if (manifest == null || endpoint == null) return;
    final uri = manifest.url;
    final consent = await _confirm('下载这个候选 APK？',
      '提供方宣称 ${manifest.version}（${manifest.versionCode}）\n下载地址：${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}\n'
      '预期 SHA-256：${manifest.sha256}\n\n最多 512 MiB。下载后核验实际包名、版本、字节散列和实际安装签名，不会自动进入安装器。', '下载并核验');
    if (consent != true || !mounted) return;
    await _run('下载并核验 APK', (token) async {
      await _acceptCandidate(await _service.downloadApk(manifest, endpoint, token));
    });
  }
  Future<void> _windows() async {
    final consent = await _confirm('暂存 Windows 独立更新包？',
      '只复制并验证所选 ZIP、外部清单完整性和所有成员 SHA-256/CRC。不会运行候选、展开到程序目录或覆盖正在运行的 EXE。\n\n'
      'ZIP 与清单可能一起被替换，哈希不是签名：你必须自行从可信发布渠道取得二者。Android APK 无法用于 Windows。', '确认来源并核验');
    if (consent != true || !mounted) return;
    await _run('复制并核验 Windows ZIP 与所有成员', (token) async {
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
      final open = await _confirm('由你自行决定未知来源权限',
        '此应用尚未获系统允许请求安装。可打开仅针对 Triomi 的系统设置；不会自动授权或自动返回安装。允许后返回此页，再次确认具体候选。', '打开此应用的系统设置');
      if (open == true && mounted) {
        await _run('打开未知来源系统设置（不自动授权）', (_) => _service.openUnknownSources());
      }
      return;
    }
    final consent = await _confirm('将这个核验候选交给系统安装器？',
      '${_identity(candidate.current)}\n\n候选：${_identity(candidate.offered)}\n'
      '来源：${candidate.source}\n\n只授权系统读取这一份应用专用 APK。交接前再次核验；不会静默安装、自动点击系统确认、自动授权或清除应用数据。'
      '最终是否安装由系统和你决定。', '打开系统安装确认');
    if (consent != true || !mounted) return;
    await _run('再次核验并交给系统安装器', (_) async {
      await _service.launchInstaller(candidate);
      if (mounted) setState(() { _candidate = null; _message = '已打开系统安装器；未声称安装成功。请在系统中自行决定，暂存 APK 保留供系统读取。'; });
    });
  }
  Future<void> _discard() async {
    final candidate = _candidate;
    if (candidate == null) return;
    await _run('移除本次更新暂存', (_) async {
      await _service.discard(candidate);
      if (mounted) setState(() { _candidate = null; _message = '已移除本次未交给安装器的暂存；原 APK/ZIP 和应用数据不变。'; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _current, candidate = _candidate, manifest = _manifest;
    final android = Platform.isAndroid, windows = Platform.isWindows;
    return Scaffold(appBar: AppBar(title: const Text('应用更新'), actions: [
      IconButton(tooltip: '重新读取安装身份', onPressed: _busy ? null : _loadCurrent, icon: const Icon(Icons.refresh)),
    ]), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('不需要新账号。不自动查询、不信任任意更新端点、不静默安装。当前未配置公开生产发布地址；本地签名 APK 可独立使用。'),
      if (_busy) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_operation!), const SizedBox(height: 8),
          LinearProgressIndicator(value: _progress?.total == null || _progress!.total! <= 0 ? null
            : (_progress!.bytes / _progress!.total!).clamp(0.0, 1.0)),
          Text(_progress == null ? '核验期间不会执行候选；可取消后等待当前密码学核验结束。'
            : '${_progress!.phase}：${_progress!.bytes} 字节${_progress!.total == null ? '' : ' / ${_progress!.total}'}'),
          TextButton(onPressed: _token?.cancelled == true ? null : () => _service.cancel(_token!),
            child: const Text('取消（系统文件选择器请返回取消）')),
        ]))),
      if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(_message!)),
      if (current != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('实际安装身份'), SelectableText(_identity(current)),
          if (android) Text(current.signerSha256 == appUpdateProductionSigner
            ? '与已知正式证书一致。候选仍必须匹配实际安装证书。'
            : '此设备不是已知正式签名；仍严格比较实际安装签名，无调试绕过。'),
        ]))),
      if (android) ...[
        FilledButton.icon(onPressed: _busy ? null : _pickApk, icon: const Icon(Icons.folder_open), label: const Text('选择本地 APK 并核验')),
        const SizedBox(height: 16),
        TextField(controller: _endpoint, enabled: !_busy, decoration: const InputDecoration(
          labelText: '可选：自己指定 HTTPS JSON 清单地址', hintText: '无默认生产地址；不自动保存或查询')),
        const SelectableText('JSON：{"versionCode":2,"version":"0.1.1","url":"https://你信任的主机/update.apk","sha256":"完整64位小写SHA256"}\n这些字段仅为格式说明，不是可用发布地址。所有重定向被拒绝。'),
        OutlinedButton(onPressed: _busy ? null : _checkManifest, child: const Text('手动查询此清单')),
        if (manifest != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText('清单宣称 ${manifest.version}（${manifest.versionCode}）\nSHA-256：${manifest.sha256}'),
            TextButton(onPressed: _busy ? null : _download, child: const Text('确认下载并核验实际 APK')),
          ]))),
      ],
      if (windows) ...[
        const Text('Windows 使用独立桌面 ZIP + 外部文件清单，只做安全暂存交接；Android APK 不可运行。哈希不代表发布者签名。'),
        TextField(controller: _zipPath, enabled: !_busy, decoration: const InputDecoration(labelText: '你选择的本地 Windows ZIP 完整路径')),
        TextField(controller: _manifestPath, enabled: !_busy, decoration: const InputDecoration(labelText: '可信外部 JSON 清单完整路径')),
        const SelectableText('清单格式：platform 为 windows；packageName 为 io.github.hyperionhxh.triomi；versionCode 为递增构建号；version 为显示版本；sha256 为整个ZIP散列；files 为每个文件相对路径到 {"size":字节数,"sha256":"完整散列"} 的映射。必须覆盖所有文件并包含 triomi.exe、flutter_windows.dll。'),
        FilledButton(onPressed: _busy ? null : _windows, child: const Text('确认来源，核验并暂存桌面包')),
      ],
      if (!android && !windows) const Text('当前平台没有受支持的更新交接实现；请使用平台发布渠道。'),
      if (candidate != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('实际候选（未执行）'), SelectableText(_identity(candidate.offered)),
          SelectableText('文件大小：${candidate.bytes} 字节\n来源：${candidate.source}'),
          Text(_decision(candidate.decision)),
          if (android && candidate.canInstall) FilledButton(onPressed: _busy ? null : _install, child: const Text('确认后打开系统安装器')),
          if (windows && candidate.canInstall) SelectableText('已核验暂存：${candidate.path}\n清单：${candidate.manifestPath}\n'
            '从可信发布渠道另行核对后，关闭 Triomi，再将此 ZIP 解压到新目录并自行运行；不要覆盖运行中的 EXE。'
            '本页没有执行或安装任何候选。'),
          TextButton(onPressed: _busy ? null : _discard, child: const Text('移除本次更新暂存')),
        ]))),
    ]));
  }
}

String _identity(AppUpdateInfo info) => '${info.packageName}\n版本 ${info.version}（${info.versionCode}）\n'
    '字节 SHA-256：${info.sha256}${info.artifactSha256 == null ? '' : '\nEXE SHA-256：${info.artifactSha256}'}\n'
    '签名证书 SHA-256：${info.signerSha256 ?? '不适用；桌面ZIP仅校验完整性，不声称签名'}';
String _decision(String value) => switch (value) {
  'upgrade' => '核验通过：高版本候选。尚未安装。',
  'wrongPackage' => '拒绝：包名或平台与当前应用不符。',
  'wrongSigner' => '拒绝：签名未核验或与实际安装签名不符。',
  'downgrade' => '拒绝：候选版本低于实际安装版本。',
  'sameVersionChanged' => '拒绝：相同版本号的字节内容已改变；不会启动安装器。',
  'alreadyInstalled' => '无需更新：相同版本和完全相同字节；不会启动安装器。',
  _ => '拒绝：未知的核验结果。',
};
