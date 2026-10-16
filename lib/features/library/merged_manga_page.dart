import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_providers.dart';
import '../../core/widgets/page_scaffold.dart';
import '../reader/manga_reader_page.dart';
import 'data/library_providers.dart';
import 'data/merged_manga_repository.dart';

class MergedMangaPage extends ConsumerStatefulWidget {
  const MergedMangaPage({super.key, required this.anchor});
  final MediaItem anchor;
  @override
  ConsumerState<MergedMangaPage> createState() => _MergedMangaPageState();
}

class _MergedMangaPageState extends ConsumerState<MergedMangaPage> {
  Future<MergedMangaDirectory?>? _directory;
  List<MediaItem> _members = [];
  Map<String, String> _groups = {};
  String? _error;
  MergedMangaRepository get _repository =>
      ref.read(mergedMangaRepositoryProvider);
  @override
  void initState() {
    super.initState();
    _directory = _load();
  }

  Future<MergedMangaDirectory?> _load() async {
    final row = await _repository.reference(widget.anchor);
    _members = await _repository.members(widget.anchor);
    _groups = row == null
        ? {}
        : Map<String, String>.from(jsonDecode(row.chapterGroupsJson) as Map);
    if (row == null) return null;
    return _repository.directory(
      widget.anchor,
      snapshot: () => ref.read(sourceRegistryProvider).load(),
    );
  }

  void _refresh() {
    final next = _load();
    setState(() => _directory = next);
  }

  Future<void> _chooseMembers() async {
    final library = await ref
        .read(libraryRepositoryProvider)
        .listLibrary(type: MediaType.manga);
    if (!mounted) return;
    final chosen = _members.map(mangaWorkKey).toSet()
      ..add(mangaWorkKey(widget.anchor));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('确认同一漫画的版本'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('只选你确认属于同一作品的版本。章节号、标题和译组相似不代表同一章；未确认等价的章节全部保留。'),
                  for (final entry in library)
                    CheckboxListTile(
                      title: Text(entry.item.title),
                      subtitle: Text(entry.item.sourceId),
                      value: chosen.contains(mangaWorkKey(entry.item)),
                      onChanged:
                          mangaWorkKey(entry.item) ==
                              mangaWorkKey(widget.anchor)
                          ? null
                          : (v) => set(
                              () => v == true
                                  ? chosen.add(mangaWorkKey(entry.item))
                                  : chosen.remove(mangaWorkKey(entry.item)),
                            ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认合并'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final members = [
      widget.anchor,
      for (final entry in library)
        if (mangaWorkKey(entry.item) != mangaWorkKey(widget.anchor) &&
            chosen.contains(mangaWorkKey(entry.item)))
          entry.item,
    ];
    try {
      await _repository.save(
        anchor: widget.anchor,
        members: members,
        chapterGroups: _groups,
      );
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _priority() async {
    final members = List<MediaItem>.of(_members);
    if (members.length < 2) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => SafeArea(
          child: Column(
            children: [
              const ListTile(
                title: Text('版本优先级'),
                subtitle: Text('只在你确认等价的章节中按优先级选择可读版本'),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: members.length,
                  onReorderItem: (old, next) => set(() {
                    members.insert(next, members.removeAt(old));
                  }),
                  itemBuilder: (context, i) => ListTile(
                    key: ValueKey(mangaWorkKey(members[i])),
                    title: Text(members[i].title),
                    subtitle: Text(members[i].sourceId),
                  ),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存优先级'),
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      await _repository.save(
        anchor: widget.anchor,
        members: members,
        chapterGroups: _groups,
      );
      if (mounted) _refresh();
    }
  }

  Future<void> _equivalence() async {
    final library = ref.read(libraryRepositoryProvider);
    final chapters = <Chapter>[];
    for (final item in _members) {
      chapters.addAll(await library.loadChapters(item.sourceId, item.remoteId));
    }
    if (!mounted || chapters.length < 2) return;
    String? a, b;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('人工确认等价章节'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('核对章节号、标题、译组和内容后确认。锁章不会被解锁；阅读位置仍按原版本独立恢复。'),
                for (final first in [true, false])
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: first ? a : b,
                    decoration: InputDecoration(
                      labelText: first ? '版本A章节' : '版本B章节',
                    ),
                    items: [
                      for (final c in chapters)
                        DropdownMenuItem(
                          value: mangaChapterKey(c),
                          child: Text(
                            '${c.sourceId} · ${c.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => set(() => first ? a = v : b = v),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: a == null || b == null || a == b
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('确认两章等价'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final ca = chapters.firstWhere((c) => mangaChapterKey(c) == a),
        cb = chapters.firstWhere((c) => mangaChapterKey(c) == b);
    if (ca.sourceId == cb.sourceId) {
      setState(() => _error = '同一来源的两章不能自动折叠，请核对作品归属');
      return;
    }
    final previous = _groups[b], group = _groups[a] ?? a!;
    final groups = {..._groups, a!: group, b!: group};
    if (previous != null) {
      for (final key in groups.keys.toList()) {
        if (groups[key] == previous) groups[key] = group;
      }
    }
    await _repository.save(
      anchor: widget.anchor,
      members: _members,
      chapterGroups: groups,
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '多来源合并',
    actions: [
      IconButton(
        tooltip: '刷新合并目录',
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ],
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: _chooseMembers, child: const Text('选择版本')),
            TextButton(onPressed: _priority, child: const Text('版本优先级')),
            TextButton(onPressed: _equivalence, child: const Text('确认等价章节')),
            TextButton(
              onPressed: () async {
                await _repository.remove(widget.anchor);
                if (mounted) _refresh();
              },
              child: const Text('解除合并（保留原数据）'),
            ),
          ],
        ),
        if (_error != null) Text(_error!),
        Expanded(
          child: FutureBuilder<MergedMangaDirectory?>(
            future: _directory,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('${snapshot.error}'));
              }
              final directory = snapshot.data;
              if (directory == null) {
                return const Center(child: Text('先选择至少两个已确认版本；原收藏、目录和进度不移动。'));
              }
              return ListView(
                children: [
                  for (final failure in directory.failures)
                    ListTile(
                      leading: const Icon(Icons.warning_amber),
                      title: Text(failure),
                    ),
                  if (_groups.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await _repository.save(
                          anchor: widget.anchor,
                          members: _members,
                        );
                        if (mounted) _refresh();
                      },
                      child: const Text('撤销全部等价映射（恢复所有版本章节）'),
                    ),
                  for (var i = 0; i < directory.chapters.length; i++)
                    ListTile(
                      title: Text(directory.chapters[i].title),
                      subtitle: Text(directory.chapters[i].sourceId),
                      trailing: directory.chapters[i].locked
                          ? const Icon(Icons.lock)
                          : const Icon(Icons.chevron_right),
                      onTap: directory.chapters[i].locked
                          ? null
                          : () => context.push(
                              AppRoutes.reader,
                              extra: MangaReaderArgs(
                                item: widget.anchor,
                                chapters: directory.chapters,
                                initialIndex: i,
                                chapterOwners: directory.owners,
                              ),
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
