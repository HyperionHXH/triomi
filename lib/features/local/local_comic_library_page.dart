import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/backup/backup_artifact_recovery.dart';
import '../../core/db/database_provider.dart';
import '../../core/models/media_item.dart';
import '../detail/detail_page.dart';
import '../downloads/data/download_repository.dart';
import '../library/data/library_providers.dart';
import 'local_comic_importer.dart';

/// Explicit local import workspace; ordinary library/detail/reader consumers
/// receive the same source-qualified cached identities and completed manifests.
class LocalComicLibraryPage extends ConsumerStatefulWidget {
  const LocalComicLibraryPage({super.key});
  @override
  ConsumerState<LocalComicLibraryPage> createState() =>
      _LocalComicLibraryPageState();
}

class _LocalComicLibraryPageState extends ConsumerState<LocalComicLibraryPage> {
  static const _channel = MethodChannel('triomi/platform');
  LocalComicCancellation? _cancellation;
  LocalComicProgress? _progress;
  bool _busy = false;
  String? _notice;

  Future<LocalComicImporter> _importer() async => LocalComicImporter(
    database: ref.read(databaseProvider),
    downloadRoot: Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'downloads'),
    ),
  );

  @override
  void dispose() {
    _cancellation?.cancel();
    if (Platform.isAndroid && _busy) {
      _channel.invokeMethod<void>('cancelLocalComicPick');
    }
    super.dispose();
  }

  Future<void> _choose() async {
    final pathController = TextEditingController();
    final titleController = TextEditingController();
    final options = await showDialog<(String, String)>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('导入本地漫画'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '支持ZIP/CBZ、图片目录和PNG/JPEG/WebP/GIF/AVIF（不支持CBR）。按自然文件名排序；子目录作为章节，上层目录作为卷。只复制到应用存储，原件不会改动。',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: '作品名（必填）'),
              ),
              if (!Platform.isAndroid) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: pathController,
                  decoration: const InputDecoration(
                    labelText: '本机绝对路径：ZIP/CBZ、图片或图片目录',
                    hintText: r'D:\Comics\My Comic',
                  ),
                  maxLines: 3,
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                '限制：ZIP≤1GiB、图片总量≤2GiB、5000页；单图≤64MiB / 4000万像素。符号链接、路径穿越、重复压缩条目和过高压缩比会拒绝。系统选择后将显示最终导入确认。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          if (Platform.isAndroid)
            TextButton(
              onPressed: () {
                final title = titleController.text.trim();
                if (title.isNotEmpty) {
                  Navigator.pop(dialog, (title, 'directory'));
                }
              },
              child: const Text('选择图片目录'),
            ),
          FilledButton(
            onPressed: () {
              final title = titleController.text.trim(),
                  path = pathController.text.trim();
              if (title.isEmpty || (!Platform.isAndroid && path.isEmpty)) {
                return;
              }
              Navigator.pop(dialog, (title, path));
            },
            child: Text(Platform.isAndroid ? '选择系统文件' : '预览导入范围'),
          ),
        ],
      ),
    );
    pathController.dispose();
    titleController.dispose();
    if (options == null || !mounted) return;
    List<String> paths = [options.$2];
    Directory? pickerDirectory;
    BackupArtifactLease? pickerLease;
    final cancellation = LocalComicCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _notice = null;
      _progress = const LocalComicProgress('等候系统选择 / 复制所选文件（大小由系统提供者决定）', 0, 0);
    });
    try {
      if (Platform.isAndroid) {
        pickerLease = await BackupArtifactGuard.acquireOperation();
        final selected = await _channel.invokeMapMethod<String, Object?>(
          'pickLocalComic',
          {'directory': options.$2 == 'directory'},
        );
        if (selected == null) return;
        paths = (selected['paths'] as List).cast<String>();
        pickerDirectory = Directory(selected['directory'] as String);
      }
      if (!mounted || cancellation.cancelled) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('确认复制导入'),
          content: Text(
            '作品：${options.$1}\n范围：${paths.length == 1 ? paths.single : '${paths.length}个所选图片文件'}\n\n仅写入应用私有离线存储并加入书架；不访问任何网络来源、不覆盖相同内容已导入作品。原始文件不会改动。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确认导入'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || cancellation.cancelled) return;
      final result = await (await _importer()).importPaths(
        paths,
        title: options.$1,
        cancellation: cancellation,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (mounted) {
        setState(
          () => _notice = result.duplicate
              ? '相同内容已存在，未覆盖作品、进度或图片。'
              : '已导入「${result.item.title}」，可完全离线打开详情和阅读。',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _notice = '$error');
    } finally {
      try {
        if (pickerDirectory != null && await pickerDirectory.exists()) {
          await pickerDirectory.delete(recursive: true);
        }
      } finally {
        await pickerLease?.release();
        _cancellation = null;
        if (mounted) {
          setState(() {
            _busy = false;
            _progress = null;
          });
        }
      }
    }
  }

  Future<void> _remove(MediaItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('移除此本地导入？'),
        content: Text(
          '仅移除「${item.title}」的本地导入图片、目录、收藏及阅读历史。\n身份：${item.remoteId}\n\n不会删除原始ZIP/CBZ/图片文件，不会删除其他来源或其他作品的下载。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认移除此导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await (await _importer()).remove(item.remoteId);
    } catch (error) {
      if (mounted) {
        setState(() => _notice = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryRepositoryProvider);
    final database = ref.watch(databaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('本地漫画文件库')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _choose,
        icon: const Icon(Icons.add),
        label: const Text('导入漫画'),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '本地漫画 · 完全离线。图片保存在应用存储；跨设备请明确选择包含下载媒体的备份，只有目录的备份不能恢复图片。',
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const LinearProgressIndicator(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _progress == null
                              ? '正在移除此导入'
                              : '${_progress!.phase} · ${(_progress!.bytes / 1048576).toStringAsFixed(1)}MiB · ${_progress!.pages}页已校验',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_cancellation != null)
                        TextButton(
                          onPressed: () {
                            _cancellation!.cancel();
                            if (Platform.isAndroid) {
                              _channel.invokeMethod<void>(
                                'cancelLocalComicPick',
                              );
                            }
                          },
                          child: const Text('取消'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          if (_notice != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_notice!)),
          Expanded(
            child: StreamBuilder(
              // Shelf removal does not remove an import or its private files.
              stream:
                  (database.select(database.mediaItems)..where(
                        (table) => table.sourceId.equals(localComicSourceId),
                      ))
                      .watch()
                      .asyncMap(
                        (rows) async => [
                          for (final row in rows)
                            if (await library.itemByKey(
                                  row.sourceId,
                                  row.remoteId,
                                )
                                case final MediaItem item)
                              item,
                        ],
                      ),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('${snapshot.error}'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final items = snapshot.data!;
                if (items.isEmpty) {
                  return const Center(child: Text('尚未导入本地漫画。点击「导入漫画」选择原始文件。'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: const Icon(Icons.offline_pin_outlined),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: FutureBuilder(
                        future: DownloadRepository(ref.read(databaseProvider))
                            .listForItem(localComicSourceId, item.remoteId),
                        builder: (context, rows) {
                          final entries = rows.data;
                          final done =
                              entries
                                  ?.where((row) => row.status == 'done')
                                  .length ??
                              0;
                          return Text(
                            entries == null
                                ? '本地漫画 · 离线'
                                : done == entries.length && done > 0
                                ? '本地漫画 · 离线 · $done章'
                                : '本地漫画 · 仅目录 / 图片缺失；恢复包含媒体的备份',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
                      onTap: _busy
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => DetailPage(item: item),
                              ),
                            ),
                      trailing: IconButton(
                        tooltip: '移除此本地导入',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy ? null : () => _remove(item),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
