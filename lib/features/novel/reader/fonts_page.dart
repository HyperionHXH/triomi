import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/source/source_providers.dart';
import '../../../core/theme/app_tokens.dart';
import 'font_catalog.dart';
import 'user_font_store.dart';

/// 字体管理：导入本地 TTF/OTF，供小说阅读器选用。
class FontsPage extends ConsumerStatefulWidget {
  const FontsPage({super.key});

  @override
  ConsumerState<FontsPage> createState() => _FontsPageState();
}

class _FontsPageState extends ConsumerState<FontsPage> {
  List<UserFont> _fonts = const <UserFont>[];
  List<FontCatalogEntry> _catalog = const <FontCatalogEntry>[];
  bool _loading = true;
  bool _importing = false;
  String? _downloading;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await UserFontStore.instance.ensureLoaded();
    final fonts = await UserFontStore.instance.list();
    // 目录解析失败不阻塞本地字体列表（在线分区隐藏并提示）。
    var catalog = const <FontCatalogEntry>[];
    try {
      catalog = await loadFontCatalog();
    } catch (_) {
      catalog = const <FontCatalogEntry>[];
    }
    if (!mounted) return;
    setState(() {
      _fonts = fonts;
      _catalog = catalog;
      _loading = false;
    });
  }

  /// 下载在线字体 → 走既有导入流程 → 注册进引擎。
  Future<void> _download(FontCatalogEntry entry) async {
    if (_downloading != null) return;
    setState(() => _downloading = entry.fileName);
    try {
      final bytes = await ref
          .read(sourceHttpClientProvider)
          .fetchBytes(entry.url, sourceId: 'font-catalog');
      final font = await UserFontStore.instance.importBytes(
        entry.fileName,
        bytes,
      );
      await UserFontStore.instance.ensureLoaded();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已下载：${font.displayName}')));
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().contains('超时')
          ? '下载超时，请检查网络'
          : '下载失败：$error';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final font = await UserFontStore.instance.pickAndImport();
      if (!mounted) return;
      if (font == null) {
        setState(() => _importing = false);
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导入：${font.displayName}')));
      await _refresh();
    } catch (error) {
      if (mounted) {
        setState(() => _importing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$error')));
      }
    }
  }

  Future<void> _delete(UserFont font) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除字体'),
        content: Text('删除「${font.displayName}」？正在使用它的阅读会退回系统默认字体。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await UserFontStore.instance.delete(font);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('阅读字体')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: const Text('导入字体'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              children: <Widget>[
                _PreviewCard(fonts: _fonts),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '在线字体（开源授权）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (_catalog.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '字体目录不可用，可从本地导入。',
                      style: TextStyle(fontSize: 12),
                    ),
                  )
                else
                  for (final entry in _catalog)
                    _CatalogTile(
                      entry: entry,
                      downloaded: _fonts.any(
                        (font) => font.fileName == entry.fileName,
                      ),
                      downloading: _downloading == entry.fileName,
                      onDownload: () => unawaited(_download(entry)),
                    ),
                for (final font in _fonts) ...<Widget>[
                  ListTile(
                    leading: const Icon(Icons.font_download_outlined),
                    title: Text(font.displayName),
                    subtitle: Text(
                      '${font.fileName} · ${(font.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                    ),
                    trailing: IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => unawaited(_delete(font)),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// 字体预览：中文 / 标点 / 英文示例同页展示。
///
/// 顶部一行用系统字体（未下载时的效果），每款已下载字体一行用它自己的
/// family 渲染，可上下对比。
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.fonts});

  final List<UserFont> fonts;

  static const String sample = '永和九年，岁在癸丑。「」、；：！？The quick brown fox.';

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '预览（系统默认）',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(sample, style: const TextStyle(fontSize: 15)),
            for (final font in fonts) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '预览（${font.displayName}）',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                sample,
                style: TextStyle(fontSize: 15, fontFamily: font.familyName),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 在线字体目录条目。
class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.entry,
    required this.downloaded,
    required this.downloading,
    required this.onDownload,
  });

  final FontCatalogEntry entry;
  final bool downloaded;
  final bool downloading;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        downloaded ? Icons.check_circle_outline : Icons.cloud_download_outlined,
      ),
      title: Text(entry.name),
      subtitle: Text(
        '${entry.license}${entry.note == null ? '' : ' · ${entry.note}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: downloading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: downloaded ? null : onDownload,
              child: Text(downloaded ? '已下载' : '下载'),
            ),
    );
  }
}
