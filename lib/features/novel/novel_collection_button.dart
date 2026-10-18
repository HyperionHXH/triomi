import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/media_item.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../sources/source_account_entries.dart';

/// Site membership is read from the authenticated source, never from SQLite.
class NovelCollectionButton extends ConsumerStatefulWidget {
  const NovelCollectionButton({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<NovelCollectionButton> createState() =>
      _NovelCollectionButtonState();
}

class _NovelCollectionButtonState extends ConsumerState<NovelCollectionButton> {
  RemoteShelfProvider? _source;
  Future<bool>? _membership;
  int _generation = 0;
  bool _busy = false;
  Object? _writeError;

  bool _contains(List<MediaItem> shelf) => shelf.any(
    (book) =>
        book.sourceId == widget.item.sourceId &&
        book.remoteId == widget.item.remoteId,
  );

  void _reset() {
    _generation++;
    _source = null;
    _membership = null;
    _busy = false;
    _writeError = null;
  }

  @override
  void didUpdateWidget(covariant NovelCollectionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.sourceId != widget.item.sourceId ||
        oldWidget.item.remoteId != widget.item.remoteId) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sourcesProvider, (previous, next) {
      if (next.isLoading && previous?.asData != null) setState(_reset);
    });
    final snapshot = ref.watch(sourcesProvider);
    if (snapshot.isLoading) {
      return OutlinedButton.icon(
        key: const ValueKey('novel-collection-loading'),
        onPressed: null,
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: const Text('连接站点收藏'),
      );
    }
    if (snapshot.hasError) {
      return TextButton.icon(
        onPressed: () => ref.invalidate(sourcesProvider),
        icon: const Icon(Icons.refresh),
        label: const Text('重试站点收藏连接'),
      );
    }
    final entry = snapshot.asData?.value.entries
        .where((entry) => entry.descriptor.id == widget.item.sourceId)
        .firstOrNull;
    if (entry == null || !entry.enabled) {
      if (_source != null) _reset();
      return const Text('来源已停用或移除，站点收藏不可用');
    }
    final source = entry.source;
    if (source is! RemoteShelfProvider ||
        !entry.supports(SourceCapability.remoteShelf)) {
      return const SizedBox.shrink();
    }
    if (!source.isLoggedIn) {
      if (_source != null) _reset();
      return OutlinedButton.icon(
        onPressed: () => context.push(accountRouteFor(widget.item.sourceId)),
        icon: const Icon(Icons.account_circle_outlined),
        label: const Text('登录后使用站点收藏'),
      );
    }
    if (!identical(source, _source)) {
      _reset();
      _source = source;
      _membership = source.remoteShelf().then(_contains);
    }
    return FutureBuilder<bool>(
      future: _membership,
      builder: (context, state) {
        if (state.connectionState != ConnectionState.done || _busy) {
          return OutlinedButton.icon(
            key: const ValueKey('novel-collection-loading'),
            onPressed: null,
            icon: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: Text(_busy ? '保存站点收藏' : '读取站点收藏'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.hasError)
              TextButton.icon(
                onPressed: () => setState(() {
                  _membership = source.remoteShelf().then(_contains);
                }),
                icon: const Icon(Icons.refresh),
                label: const Text('站点收藏读取失败 · 重试'),
              )
            else
              OutlinedButton.icon(
                onPressed: () => _update(source, add: state.data != true),
                icon: Icon(
                  state.data == true
                      ? Icons.bookmark
                      : Icons.bookmark_add_outlined,
                ),
                label: Text(state.data == true ? '已在站点收藏 · 移除' : '加入站点收藏'),
              ),
            if (state.hasError || _writeError != null) ...[
              Text(
                _writeError != null ? '站点收藏修改未确认。' : '未能确认站点收藏状态。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('错误详情'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      SourceException.sanitizeMessage(
                        '${_writeError ?? state.error}',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _update(RemoteShelfProvider source, {required bool add}) async {
    if (_busy) return;
    final generation = _generation;
    final item = widget.item;
    bool current() =>
        mounted && generation == _generation && identical(source, _source);
    if (!add) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移出站点收藏'),
          content: Text('将《${item.title}》移出站点收藏；本机缓存、历史和离线收藏保留。'),
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
    }
    final snapshot = ref.read(sourcesProvider).asData?.value;
    if (!current() ||
        !source.isLoggedIn ||
        snapshot == null ||
        !snapshot.enabledEntries.any(
          (entry) => identical(entry.source, source),
        )) {
      return;
    }
    setState(() {
      _busy = true;
      _writeError = null;
    });
    try {
      await source.setInRemoteShelf(item, add);
      if (!current()) return;
      if (!source.isLoggedIn) throw StateError('登录已失效，请重新登录后确认站点收藏');
      final shelf = await source.remoteShelf();
      final member = shelf.any(
        (book) =>
            book.sourceId == item.sourceId && book.remoteId == item.remoteId,
      );
      if (!current()) return;
      setState(() {
        _membership = Future.value(member);
      });
      if (member != add) throw StateError('站点尚未确认收藏变更，请刷新后重试');
    } catch (error) {
      if (current()) setState(() => _writeError = error);
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }
}
