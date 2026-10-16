import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database_provider.dart';
import '../../core/storage/cover_store.dart';
import 'cache_management_service.dart';

/// Explicit preview/confirmation only; opening this page never clears anything.
class CacheManagementPage extends ConsumerStatefulWidget {
  const CacheManagementPage({super.key, this.service});

  /// Allows the same production workflow against explicit owned test roots.
  final CacheManagementService? service;

  @override
  ConsumerState<CacheManagementPage> createState() => _CacheManagementPageState();
}

class _CacheManagementPageState extends ConsumerState<CacheManagementPage> {
  CacheManagementService? _service;
  CoverCachePreview? _preview;
  RetainedContentSummary? _content;
  CacheCancellation? _cancellation;
  CacheProgress? _progress;
  String? _message;
  String? _operation;
  bool get _busy => _operation != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    if (_busy) return;
    final token = CacheCancellation();
    setState(() {
      _operation = '正在扫描封面';
      _cancellation = token;
      _progress = null;
      _preview = null;
      _message = null;
    });
    try {
      final service = _service ??= widget.service ?? CacheManagementService(
        database: ref.read(databaseProvider), covers: await CoverStore.open(),
      );
      final content = await service.retainedContent();
      if (mounted) setState(() => _content = content);
      final preview = await service.previewCovers(cancellation: token, onProgress: _onProgress);
      if (!mounted) return;
      setState(() {
        _preview = preview.cancelled ? null : preview;
        if (preview.cancelled) _message = '扫描已取消；未清理任何文件。';
      });
    } catch (error) {
      if (mounted) setState(() => _message = '扫描未完成：$error');
    } finally {
      if (mounted) setState(() { _operation = null; _cancellation = null; });
    }
  }

  void _onProgress(CacheProgress progress) {
    // UI updates are bounded even for a large directory; cancellation remains
    // checked by the service for every entry/file.
    if (mounted && (progress.total != null || progress.processed % 32 == 0)) {
      setState(() => _progress = progress);
    }
  }

  Future<void> _clearCovers() async {
    final preview = _preview;
    if (_busy || preview == null || preview.files.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清理恢复封面？'),
        content: Text('仅删除本次预览的 ${preview.files.length} 个已发布封面文件（${_bytes(preview.bytes)}）。\n\n'
            '清理后这些封面不能离线读取；联网时按来源重新加载。当前已显示的图片会保留到离开页面。\n\n'
            '不删除正文、下载、续传检查点、历史、收藏、追踪、凭据、来源、备份或本地导入。新增或已变化文件会跳过。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清理这批封面')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final token = CacheCancellation();
    setState(() { _operation = '正在清理恢复封面'; _cancellation = token; _progress = CacheProgress(0, preview.files.length); });
    try {
      final result = await _service!.clearCovers(preview, cancellation: token, onProgress: _onProgress);
      if (!mounted) return;
      setState(() {
        _preview = null;
        _message = '${result.complete ? '本批清理完成' : result.cancelled ? '已取消，未开始的文件保留' : '清理未全部完成'}：'
            '删除 ${result.removed} 个（${_bytes(result.removedBytes)}），跳过 ${result.skipped} 个，失败 ${result.failures.length} 个，未处理 ${result.unprocessed} 个。'
            '${result.failures.isEmpty ? '' : '\n失败文件：${result.failures.join('、')}'}\n请重新扫描查看当前状态。';
      });
    } catch (error) {
      if (mounted) setState(() { _preview = null; _message = '清理未完成：$error\n请重新扫描；未声称已清空。'; });
    } finally {
      if (mounted) setState(() { _operation = null; _cancellation = null; });
    }
  }

  Future<void> _clearMemory() async {
    final cache = PaintingBinding.instance.imageCache;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理图片内存缓存？'),
        content: Text('当前可复用缓存 ${cache.currentSize} 项 / ${_bytes(cache.currentSizeBytes)}，'
            '等待解码 ${cache.pendingImageCount} 项；这是内存而非磁盘用量。\n\n'
            '只释放非活跃图片的缓存引用；保留正在显示的图片，不删除文件、Cookie 或账号。'
            '正在进行的请求不会被强制取消，图片仍可能重新进入缓存。此操作立即完成，不支持中途取消。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('释放缓存引用')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    cache.clear();
    setState(() => _message = '已释放图片可复用缓存引用；活跃图片、文件与凭据保留。后续请求可能重新填充缓存。');
  }

  @override
  Widget build(BuildContext context) {
    final cache = PaintingBinding.instance.imageCache;
    final preview = _preview;
    final content = _content;
    final progress = _progress;
    return Scaffold(
      appBar: AppBar(title: const Text('缓存管理'), actions: [
        IconButton(tooltip: '重新扫描', onPressed: _busy ? null : _scan, icon: const Icon(Icons.refresh)),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('按类别预览后单独确认，没有“一键删除全部”。下载与个人数据始终保留。'),
        if (_busy) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_operation!),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress == null || progress.total == null || progress.total == 0
                ? null : progress.processed / progress.total!),
            Text(progress == null || progress.total == null
                ? '已扫描 ${progress?.processed ?? 0} 个目录条目；总数尚未知'
                : '已处理 ${progress.processed}/${progress.total}，已删除 ${progress.removed} 个'),
            TextButton(onPressed: () { _cancellation?.cancel(); setState(() {}); },
              child: Text(_cancellation?.cancelled == true ? '正在停止（当前文件完成后）' : '取消')),
          ],
        ))),
        if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: SelectableText(_message!)),
        Card(child: Column(children: [
          ListTile(title: const Text('图片内存缓存'),
            subtitle: Text('${cache.currentSize} 项 · ${_bytes(cache.currentSizeBytes)}（内存）\n'
                '活跃图片 ${cache.liveImageCount} 项不清理；没有可统计的应用网络图片磁盘缓存。')),
          TextButton(onPressed: _busy ? null : _clearMemory, child: const Text('预览并释放内存')),
        ])),
        Card(child: Column(children: [
          ListTile(title: const Text('从备份恢复的封面'),
            subtitle: Text(preview == null ? '尚无完整预览；请扫描。'
                : '${preview.files.length} 个 · ${_bytes(preview.bytes)}（文件字节）\n'
                  '仅 covers 中 URL 散列命名的已发布文件；不清理临时写入文件或子目录。')),
          TextButton(onPressed: _busy || preview == null || preview.files.isEmpty ? null : _clearCovers,
              child: const Text('预览并清理恢复封面')),
        ])),
        Card(child: ListTile(title: const Text('离线章节内容（保留）'),
          subtitle: Text('${content == null ? '尚未统计' : '${content.chapters} 章 · ${_bytes(content.bytes)}（JSON UTF-8 载荷）'}\n'
              '正文与字体属于已下载离线内容，不作为临时缓存删除。此值不是数据库文件大小，也不代表可回收空间。'))),
        const Padding(padding: EdgeInsets.only(top: 12), child: Text(
          '保护范围：所有下载媒体和断点、章节ID与正文、阅读进度、历史、收藏、追踪、登录凭据、来源定义、备份、待安装APK和本地导入。'
          '不会递归清空临时目录或应用数据目录。恢复进行中或残留恢复日志时拒绝清理封面。')),
      ]),
    );
  }
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}
