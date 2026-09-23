import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import 'user_font_store.dart';

/// 字体管理：导入本地 TTF/OTF，供小说阅读器选用。
class FontsPage extends ConsumerStatefulWidget {
  const FontsPage({super.key});

  @override
  ConsumerState<FontsPage> createState() => _FontsPageState();
}

class _FontsPageState extends ConsumerState<FontsPage> {
  List<UserFont> _fonts = const <UserFont>[];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    await UserFontStore.instance.ensureLoaded();
    final fonts = await UserFontStore.instance.list();
    if (!mounted) return;
    setState(() {
      _fonts = fonts;
      _loading = false;
    });
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
          : _fonts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.font_download_outlined,
                      size: 44,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const Text('还没有导入字体'),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      '支持 TTF / OTF；导入后在小说阅读器设置里选用。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              children: <Widget>[
                for (final font in _fonts)
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
            ),
    );
  }
}
