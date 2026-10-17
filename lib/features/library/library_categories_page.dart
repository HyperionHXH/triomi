import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/models/media_type.dart';
import '../tracking/data/tracking_models.dart';
import 'data/library_category.dart';
import 'data/library_providers.dart';
import 'data/library_repository.dart';

class LibraryCategoriesPage extends ConsumerWidget {
  const LibraryCategoriesPage({super.key, required this.type});
  final MediaType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(libraryCategoriesForTypeProvider(type));
    final entries =
        ref.watch(libraryByTypeProvider(type)).asData?.value ??
        <LibraryItemView>[];
    final labels = ref.watch(librarySourceLabelsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('管理书架分类')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => editLibraryCategory(context, ref, type: type),
        icon: const Icon(Icons.add),
        label: const Text('新建分类'),
      ),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('分类加载失败：$error')),
        data: (data) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '作品可属于多个手动分类。动态分类实时匹配本地缓存，无需来源在线。下列数量对应当前内容形态的全部收藏作品。',
              ),
            ),
            Expanded(
              child: data.categories.isEmpty
                  ? const Center(child: Text('尚无分类，点击「新建分类」'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount: data.categories.length,
                      onReorderItem: (oldIndex, newIndex) async {
                        final ids = data.categories.map((c) => c.id).toList();
                        ids.insert(newIndex, ids.removeAt(oldIndex));
                        await _categoryAction(
                          context,
                          () => ref
                              .read(libraryRepositoryProvider)
                              .reorderCategories(ids, type: type),
                        );
                      },
                      itemBuilder: (context, index) {
                        final category = data.categories[index];
                        final rule = category.rulesJson == null
                            ? null
                            : LibraryCategoryRule.decode(category.rulesJson!);
                        final count = entries
                            .where((entry) => data.belongs(category, entry))
                            .length;
                        return ListTile(
                          key: ValueKey(category.id),
                          leading: Icon(
                            rule == null
                                ? Icons.folder_outlined
                                : Icons.rule_folder_outlined,
                          ),
                          title: Text('${category.name} · $count'),
                          subtitle: Text(
                            rule?.describe(labels) ?? '手动分类 · 可批量加入/移除',
                          ),
                          onTap: () => editLibraryCategory(
                            context,
                            ref,
                            type: type,
                            category: category,
                          ),
                          trailing: SizedBox(
                            width: 112,
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '上移 ${category.name}',
                                  onPressed: index == 0
                                      ? null
                                      : () async {
                                          final ids = data.categories
                                              .map((c) => c.id)
                                              .toList();
                                          ids.insert(
                                            index - 1,
                                            ids.removeAt(index),
                                          );
                                          await _categoryAction(
                                            context,
                                            () => ref
                                                .read(libraryRepositoryProvider)
                                                .reorderCategories(
                                                  ids,
                                                  type: type,
                                                ),
                                          );
                                        },
                                  icon: const Icon(Icons.arrow_upward),
                                ),
                                IconButton(
                                  tooltip: '删除 ${category.name}',
                                  onPressed: () async {
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (dialog) => AlertDialog(
                                        title: Text('删除分类「${category.name}」？'),
                                        content: const Text(
                                          '只删除分组、关联和规则。收藏、进度、历史、下载和追踪绑定全部保留。',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, false),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, true),
                                            child: const Text('删除分类'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed == true && context.mounted) {
                                      await _categoryAction(
                                        context,
                                        () => ref
                                            .read(libraryRepositoryProvider)
                                            .deleteCategory(
                                              category.id,
                                              type: type,
                                            ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _categoryAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Future<void> editLibraryCategory(
  BuildContext context,
  WidgetRef ref, {
  required MediaType type,
  CategoryRow? category,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CategoryEditor(type: type, category: category),
);

class _CategoryEditor extends ConsumerStatefulWidget {
  const _CategoryEditor({required this.type, this.category});
  final MediaType type;
  final CategoryRow? category;
  @override
  ConsumerState<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<_CategoryEditor> {
  late final TextEditingController _name;
  late final TextEditingController _query;
  late final TextEditingController _status;
  late bool _dynamic;
  late bool _all;
  late Set<String> _sources;
  bool? _unread;
  String _localStatus = '';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final category = widget.category;
    final rule = category?.rulesJson == null
        ? const LibraryCategoryRule()
        : LibraryCategoryRule.decode(category!.rulesJson!);
    _name = TextEditingController(text: category?.name ?? '');
    _query = TextEditingController(text: rule.query);
    _status = TextEditingController(text: rule.status);
    _dynamic = category?.rulesJson != null;
    _all = rule.matchAll;
    _sources = Set.of(rule.sources);
    _unread = rule.unread;
    _localStatus = rule.localStatus;
  }

  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    _status.dispose();
    super.dispose();
  }

  LibraryCategoryRule _currentRule() => LibraryCategoryRule(
    sources: Set.of(_sources),
    unread: _unread,
    status: _status.text,
    localStatus: _localStatus,
    query: _query.text,
    matchAll: _all,
  );

  @override
  Widget build(BuildContext context) {
    final entries =
        ref.watch(libraryByTypeProvider(widget.type)).asData?.value ??
        <LibraryItemView>[];
    final labels = ref.watch(librarySourceLabelsProvider);
    final sourceIds = {
      ...entries.map((e) => e.item.sourceId),
      ..._sources,
    }.toList()..sort();
    final rule = _currentRule();
    return AlertDialog(
      title: Text(widget.category == null ? '新建分类' : '编辑分类'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '分类名称'),
                enabled: !_saving,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('动态分类'),
                value: _dynamic,
                subtitle: const Text('根据本地规则实时匹配；不能手动加入或移除。创建后分类种类不变。'),
                onChanged: _saving || widget.category != null
                    ? null
                    : (value) => setState(() => _dynamic = value),
              ),
              if (_dynamic) ...[
                const Text('以下条件同时满足；来源多选为任选一个。空规则不匹配，除非显式选择匹配全部。'),
                DropdownButtonFormField<bool>(
                  initialValue: _unread,
                  decoration: const InputDecoration(labelText: '本地未读'),
                  items: const [
                    DropdownMenuItem<bool>(value: null, child: Text('不限未读')),
                    DropdownMenuItem(value: true, child: Text('有未读')),
                    DropdownMenuItem(value: false, child: Text('无未读')),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _unread = value),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _localStatus,
                  decoration: const InputDecoration(labelText: '本地阅读状态'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不限阅读状态')),
                    for (final status in {
                      ...TrackStatusMap.localStatuses,
                      if (_localStatus.isNotEmpty) _localStatus,
                    })
                      DropdownMenuItem(
                        value: status,
                        child: Text(switch (status) {
                          'want' => '想读',
                          'doing' => '在读',
                          'done' => '读完',
                          'paused' => '暂停',
                          'dropped' => '弃坑',
                          _ => status,
                        }),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _localStatus = value ?? ''),
                ),
                TextField(
                  controller: _status,
                  decoration: const InputDecoration(
                    labelText: '作品状态（完整匹配，留空不限）',
                  ),
                  onChanged: (_) => setState(() {}),
                  enabled: !_saving,
                ),
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(labelText: '标题、作者或标签包含'),
                  onChanged: (_) => setState(() {}),
                  enabled: !_saving,
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('来源（不选表示不限来源）'),
                ),
                for (final id in sourceIds)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(labels[id] ?? id),
                    value: _sources.contains(id),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              _sources.add(id);
                            } else {
                              _sources.remove(id);
                            }
                          }),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('无条件时显式匹配全部'),
                  value: _all,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _all = value ?? false),
                ),
                Text(
                  '实时匹配 ${entries.where(rule.matches).length} 部（当前内容形态，包含隐藏作品）',
                ),
                Text(rule.describe(labels)),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  try {
                    await ref
                        .read(libraryRepositoryProvider)
                        .saveCategory(
                          type: widget.type,
                          id: widget.category?.id,
                          name: _name.text,
                          hidden: widget.category?.hidden ?? false,
                          rule: _dynamic ? _currentRule() : null,
                        );
                    if (context.mounted) Navigator.pop(context);
                  } catch (error) {
                    if (mounted) {
                      setState(() {
                        _error = '$error';
                        _saving = false;
                      });
                    }
                  }
                },
          child: const Text('保存分类'),
        ),
      ],
    );
  }
}
