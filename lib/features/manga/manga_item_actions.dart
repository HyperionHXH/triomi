import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/manga_metadata_override.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_providers.dart';
import '../library/data/library_providers.dart';
import '../library/library_categories_page.dart';

final mangaItemMetadataProvider = StreamProvider.autoDispose
    .family<MangaMetadataOverride?, (String, String)>(
      (ref, key) =>
          ref.watch(libraryRepositoryProvider).watchMangaMetadata(key),
    );

/// Browse/search operate on a fixed source + remote ID, never a remote account.
/// Reading state applies only to a still-collected local manga.
Future<void> showMangaItemActions(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  if (item.type != MediaType.manga) return;
  final repository = ref.read(libraryRepositoryProvider);
  try {
    final current = await repository.applyMangaMetadata(item);
    final collected = await repository.isInLibrary(
      item.sourceId,
      item.remoteId,
    );
    if (!context.mounted) return;
    final uri = Uri.tryParse(item.url ?? '');
    final web =
        item.sourceId.startsWith('mihon:') ||
        uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        Widget entry(String value, IconData icon, String label) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          onTap: () => Navigator.pop(sheet, value),
        );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(current.title),
                  subtitle: const Text('本地漫画操作 · 不修改站点账号'),
                ),
                entry('detail', Icons.info_outline, '打开详情'),
                entry('edit', Icons.edit_outlined, '编辑漫画资料'),
                if (collected) ...[
                  entry('read', Icons.done_all, '标记已读'),
                  entry('unread', Icons.remove_done, '标记未读'),
                  entry('category', Icons.folder_outlined, '分配分类'),
                  entry('remove', Icons.bookmark_remove_outlined, '移出书架'),
                ] else
                  entry('add', Icons.bookmark_add_outlined, '加入书架'),
                if (web) entry('browser', Icons.open_in_browser, '在浏览器打开'),
              ],
            ),
          ),
        );
      },
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'detail':
        await context.push(AppRoutes.detailFor(current), extra: current);
      case 'edit':
        await showMangaMetadataEditor(context, ref, current);
      case 'add':
        final cached = await repository.itemByKey(item.sourceId, item.remoteId);
        if (cached != null && cached.type != MediaType.manga) {
          throw StateError('本地作品不属于漫画，未修改收藏');
        }
        await repository.addToLibrary(cached ?? current);
        if (context.mounted) {
          ref.invalidate(
            inLibraryProvider((
              sourceId: item.sourceId,
              remoteId: item.remoteId,
            )),
          );
        }
      case 'remove':
        if (!await _confirm(
          context,
          '移出书架',
          '将「${current.title}」移出本地漫画书架？阅读历史、下载文件和自定义资料保留。',
        )) {
          return;
        }
        if (!context.mounted) return;
        await repository.removeFromLibrary(
          item.sourceId,
          item.remoteId,
          type: MediaType.manga,
        );
        if (context.mounted) {
          ref.invalidate(
            inLibraryProvider((
              sourceId: item.sourceId,
              remoteId: item.remoteId,
            )),
          );
        }
      case 'read':
      case 'unread':
        final read = action == 'read';
        if (!await _confirm(
          context,
          read ? '标记已读' : '标记未读',
          '仅修改「${current.title}」的本地整部阅读状态，不同步站点，实际阅读历史和下载保留。'
          '${read ? '进度设为不低于缓存目录末章并清空未读数；无目录时仅标为已读。' : '重置进度，未读数设为缓存目录章数；无目录时仍标为未读。'}',
        )) {
          return;
        }
        if (!context.mounted) return;
        await repository.setMangaRead({
          (item.sourceId, item.remoteId),
        }, read: read);
      case 'category':
        await _assignCategory(context, ref, current);
      case 'browser':
        final String website;
        if (item.sourceId.startsWith('mihon:')) {
          final snapshot = await ref.read(sourcesProvider.future);
          if (!context.mounted) return;
          final source = snapshot.enabledEntries
              .where((entry) => entry.descriptor.id == item.sourceId)
              .firstOrNull
              ?.source;
          if (source is! MihonSource) {
            throw StateError('此插件来源未启用、未受信任或宿主不可用，无法解析作品网站');
          }
          website = (await source.websiteUri(item: item)).toString();
        } else {
          website = item.url!;
        }
        if (!context.mounted) return;
        if (!await platformChannel.launchExternalUrl(website)) {
          throw StateError('无法打开浏览器');
        }
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('漫画操作失败：$error')));
    }
  }
}

/// Saving keeps source metadata separate; blank fields follow the source.
/// [stillInScope] lets a library selection be revalidated after the dialog.
Future<bool> showMangaMetadataEditor(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  Future<bool> Function()? stillInScope,
}) async {
  if (item.type != MediaType.manga) return false;
  final repository = ref.read(libraryRepositoryProvider);
  try {
    final cached = await repository.itemByKey(item.sourceId, item.remoteId);
    if (!context.mounted) return false;
    if (cached != null && cached.type != MediaType.manga) {
      throw StateError('该条目不属于漫画');
    }
    final current = cached ?? item;
    final result = await showDialog<_MetadataEdit>(
      context: context,
      builder: (_) => _MangaMetadataDialog(item: current),
    );
    if (result == null || !context.mounted) return false;
    if (stillInScope != null && !await stillInScope()) return false;
    if (!context.mounted) return false;
    // Browsing an uncollected manga must not create a library entry. Delay
    // caching until Save, so cancelling an editor performs no DB mutation.
    await repository.setMangaMetadata(
      item.sourceId,
      item.remoteId,
      title: result.title,
      author: result.author,
      description: result.description,
      initialItem: cached == null ? item : null,
    );
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存漫画资料失败：$error')));
    }
    return false;
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> _assignCategory(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  final repository = ref.read(libraryRepositoryProvider);
  final snapshot = await repository.categorySnapshot(type: MediaType.manga);
  if (!context.mounted) return;
  final categories = snapshot.categories
      .where((c) => c.rulesJson == null)
      .toList();
  if (categories.isEmpty) {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => const LibraryCategoriesPage(type: MediaType.manga),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('创建手动分类后，请再次选择分配分类')));
    }
    return;
  }
  var id = categories.first.id;
  var add = true;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (dialog, update) => AlertDialog(
        title: const Text('分配分类'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(item.title),
            DropdownButton<int>(
              isExpanded: true,
              value: id,
              items: [
                for (final category in categories)
                  DropdownMenuItem(
                    value: category.id,
                    child: Text(category.name),
                  ),
              ],
              onChanged: (value) {
                if (value != null) update(() => id = value);
              },
            ),
            SwitchListTile(
              title: Text(add ? '加入此分类' : '从此分类移除'),
              value: add,
              onChanged: (value) => update(() => add = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;
  // Re-read membership after the asynchronous dialog. The repository also
  // validates that both the category and item still belong to manga.
  if (!await repository.isInLibrary(item.sourceId, item.remoteId)) return;
  await repository.assignCategory(
    id,
    {(item.sourceId, item.remoteId)},
    type: MediaType.manga,
    add: add,
  );
}

class _MetadataEdit {
  const _MetadataEdit(this.title, this.author, this.description);
  final String? title, author, description;
}

class _MangaMetadataDialog extends StatefulWidget {
  const _MangaMetadataDialog({required this.item});
  final MediaItem item;

  @override
  State<_MangaMetadataDialog> createState() => _MangaMetadataDialogState();
}

class _MangaMetadataDialogState extends State<_MangaMetadataDialog> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _author = TextEditingController(text: widget.item.author);
  late final _description = TextEditingController(
    text: widget.item.description,
  );
  bool _reset = false;

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _override(
    String value,
    String initial,
    String? source,
    String? existing,
  ) {
    if (!_reset && value == initial) return existing;
    return value.trim().isEmpty || value.trim() == source?.trim()
        ? null
        : value.trim();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('编辑漫画资料'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('仅保存在本机，来源与作品编号不变。留空使用来源资料；自定义内容在刷新后保留。'),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          TextField(
            controller: _author,
            decoration: const InputDecoration(labelText: '作者'),
          ),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 7,
            decoration: const InputDecoration(labelText: '简介'),
          ),
          TextButton.icon(
            onPressed: () {
              _title.text = widget.item.sourceTitle;
              _author.text = widget.item.sourceAuthor ?? '';
              _description.text = widget.item.sourceDescription ?? '';
              _reset = true;
            },
            icon: const Icon(Icons.restore),
            label: const Text('恢复来源资料（保存后生效）'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _MetadataEdit(
            _override(
              _title.text,
              widget.item.title,
              widget.item.sourceTitle,
              widget.item.localMangaMetadata?.title,
            ),
            _override(
              _author.text,
              widget.item.author ?? '',
              widget.item.sourceAuthor,
              widget.item.localMangaMetadata?.author,
            ),
            _override(
              _description.text,
              widget.item.description ?? '',
              widget.item.sourceDescription,
              widget.item.localMangaMetadata?.description,
            ),
          ),
        ),
        child: const Text('保存'),
      ),
    ],
  );
}
