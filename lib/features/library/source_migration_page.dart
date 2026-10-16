import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database_provider.dart';
import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/widgets/page_scaffold.dart';
import 'data/library_providers.dart';
import 'data/source_migration_repository.dart';
import 'migration_plans_page.dart';

class SourceMigrationPage extends ConsumerStatefulWidget {
  const SourceMigrationPage({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<SourceMigrationPage> createState() =>
      _SourceMigrationPageState();
}

class _SourceMigrationPageState extends ConsumerState<SourceMigrationPage> {
  late final _query = TextEditingController(text: widget.item.title);
  late final _repository = SourceMigrationRepository(
    ref.read(databaseProvider),
  );
  MigrationOrigin? _origin;
  List<SourceEntry> _sources = [];
  SourceEntry? _source;
  List<MediaItem> _results = [];
  MediaItem? _target;
  List<Chapter> _chapters = [];
  String? _resumeId;
  List<Chapter> _oldChapters = [];
  final _chapterMappings = <String, String>{};
  bool _metadata = true,
      _categories = true,
      _history = false,
      _tracking = false,
      _downloads = false,
      _mergeExisting = false;
  String? _error;
  bool _loading = true;
  bool _committing = false;
  bool _searched = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final origin = await _repository.origin(widget.item);
      final oldChapters = await ref
          .read(libraryRepositoryProvider)
          .loadChapters(widget.item.sourceId, widget.item.remoteId);
      final snapshot = await ref
          .read(sourcesProvider.future)
          .timeout(const Duration(seconds: 30));
      final sources = snapshot.enabledEntries
          .where(
            (e) =>
                e.descriptor.id != widget.item.sourceId &&
                e.descriptor.type == widget.item.type &&
                e.supports(SourceCapability.content) &&
                e.source is SearchProvider &&
                e.source is DetailProvider &&
                e.source is ContentProvider,
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _origin = origin;
        _oldChapters = oldChapters;
        _sources = sources;
        _source = sources.firstOrNull;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = _message(error);
          _loading = false;
        });
      }
    }
  }

  String _message(Object error) =>
      error is StateError ? error.message : '$error';

  String _describe(Object error, SourceEntry source) => error is SourceException
      ? SourceRegistry.describeError(error, source.descriptor.name)
      : _message(error);

  Future<void> _search() async {
    final source = _source;
    final query = _query.text.trim();
    if (source == null || query.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _target = null;
      _results = [];
      _chapters = [];
      _chapterMappings.clear();
      _resumeId = null;
      _searched = false;
    });
    try {
      final items = await (source.source as SearchProvider)
          .search(query)
          .timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = items
            .where(
              (i) =>
                  i.sourceId == source.descriptor.id &&
                  i.type == widget.item.type &&
                  i.remoteId.isNotEmpty,
            )
            .toList();
        _searched = true;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _describe(error, source));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _select(MediaItem item) async {
    final source = _source!;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _target = null;
    });
    try {
      final provider = source.source as DetailProvider;
      final detail = await provider
          .detail(item)
          .timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) return;
      final chapters = await provider
          .chapters(detail)
          .timeout(const Duration(seconds: 30));
      if (!mounted || generation != _generation) return;
      if (detail.sourceId != source.descriptor.id ||
          detail.remoteId != item.remoteId ||
          detail.type != widget.item.type ||
          chapters.isEmpty ||
          chapters.any(
            (c) => c.sourceId != detail.sourceId || c.remoteId.isEmpty,
          ) ||
          chapters.map((c) => c.remoteId).toSet().length != chapters.length) {
        throw StateError('目标作品或目录不完整，请选择其他结果或重试');
      }
      setState(() {
        _target = detail;
        _chapters = chapters;
        _resumeId = _origin!.hasReadingHistory
            ? SourceMigrationRepository.suggestChapter(
                _origin!.lastChapter,
                chapters,
              )?.remoteId
            : null;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = _describe(error, source));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _commit() async {
    if (_committing || _target == null) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      final snapshot = await ref
          .read(sourcesProvider.future)
          .timeout(const Duration(seconds: 30));
      if (!snapshot.enabledEntries.any(
        (e) => e.descriptor.id == _target!.sourceId,
      )) {
        throw StateError('目标来源已停用或移除，请重新选择');
      }
      final plan = await _repository.prepareMigration(
        origin: _origin!,
        target: _target!,
        chapters: _chapters,
        resumeChapterId: _resumeId,
        scope: MigrationScope(
          metadata: _metadata,
          categories: _categories,
          history: _history,
          tracking: _tracking,
          downloads: _downloads,
          mergeExisting: _mergeExisting,
        ),
        chapterMappings: _chapterMappings,
      );
      await _repository.executeMigration(plan);
      ref.invalidate(libraryProvider);
      ref.invalidate(historyProvider);
      ref.invalidate(
        inLibraryProvider((
          sourceId: _target!.sourceId,
          remoteId: _target!.remoteId,
        )),
      );
      if (mounted) Navigator.of(context).pop(_target);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_committing,
    child: PageScaffold(
      title: '复制到其他来源',
      actions: [
        IconButton(
          tooltip: '持久迁移计划',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const MigrationPlansPage()),
          ),
          icon: const Icon(Icons.pending_actions),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.item.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text('确认同一作品的目标版本及迁移范围。原收藏、历史、文件和追踪全部保留；目标已有数据只能显式合并，不倒退目标进度。'),
          const SizedBox(height: 16),
          if (_origin != null && _sources.isEmpty && !_loading)
            const Text('没有其他已启用且可搜索、阅读的同类来源。请先在来源管理中启用其他来源。'),
          if (_sources.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              initialValue: _source?.descriptor.id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '目标来源'),
              items: [
                for (final s in _sources)
                  DropdownMenuItem(
                    value: s.descriptor.id,
                    child: Text(
                      '${s.descriptor.name} · ${s.descriptor.lang}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _committing
                  ? null
                  : (id) {
                      _generation++;
                      setState(() {
                        _source = _sources.firstWhere(
                          (s) => s.descriptor.id == id,
                        );
                        _results = [];
                        _target = null;
                        _chapters = [];
                        _resumeId = null;
                        _error = null;
                        _searched = false;
                        _loading = false;
                      });
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              enabled: !_committing,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(labelText: '作品关键词'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _loading || _committing ? null : _search,
              child: const Text('搜索目标作品'),
            ),
          ],
          if (_loading || _committing)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_searched && _results.isEmpty && !_loading)
            const Text('没有搜索结果，请修改关键词后重试。'),
          if (_target == null && !_loading)
            for (final item in _results)
              ListTile(
                title: Text(item.title),
                subtitle: Text(item.author ?? _source!.descriptor.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _select(item),
              ),
          if (_target != null && !_loading) ...[
            const Divider(),
            Text(
              '目标作品：${_target!.title}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('${_source!.descriptor.name} · ${_chapters.length} 章'),
            CheckboxListTile(
              title: const Text('收藏状态、评分、置顶'),
              value: _metadata,
              onChanged: (v) => setState(() => _metadata = v == true),
            ),
            CheckboxListTile(
              title: const Text('分类'),
              value: _categories,
              onChanged: (v) => setState(() => _categories = v == true),
            ),
            CheckboxListTile(
              title: const Text('所选章节的阅读历史'),
              subtitle: const Text('跨源页码重置；只有校验复制的完全相同文件才保留页码'),
              value: _history,
              onChanged: (v) => setState(() => _history = v == true),
            ),
            CheckboxListTile(
              title: const Text('本地追踪绑定'),
              subtitle: const Text('不写远端；目标冲突则拒绝'),
              value: _tracking,
              onChanged: (v) => setState(() => _tracking = v == true),
            ),
            if (widget.item.type == MediaType.manga)
              CheckboxListTile(
                title: const Text('复制所选旧版离线文件'),
                subtitle: const Text('人工接受旧版内容；逐文件SHA256验证后才发布目标引用，旧文件保留'),
                value: _downloads,
                onChanged: (v) => setState(() => _downloads = v == true),
              ),
            CheckboxListTile(
              title: const Text('合并到已有目标（保留目标状态/进度）'),
              value: _mergeExisting,
              onChanged: (v) => setState(() => _mergeExisting = v == true),
            ),
            if (_history || _downloads) ...[
              const Text('逐章确认映射；未选章节不迁移，重复章号/标题/译组不自动猜配'),
              for (final old in _oldChapters.where((c) => !c.locked))
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    '${_target!.sourceId}/${_target!.remoteId}/${old.remoteId}',
                  ),
                  isExpanded: true,
                  initialValue: _chapterMappings[old.remoteId] ?? '',
                  decoration: InputDecoration(labelText: '旧版 · ${old.title}'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不迁移此章')),
                    for (final c in _chapters.where((c) => !c.locked))
                      DropdownMenuItem(
                        value: c.remoteId,
                        child: Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(
                    () => v == null || v.isEmpty
                        ? _chapterMappings.remove(old.remoteId)
                        : _chapterMappings[old.remoteId] = v,
                  ),
                ),
            ],
            if (_origin!.lastChapter != null)
              Text('原来源续读章节：${_origin!.lastChapter!.title}'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('${_target!.sourceId}/${_target!.remoteId}'),
              initialValue: _resumeId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '确认目标续读章节'),
              items: [
                const DropdownMenuItem(value: '', child: Text('从头开始')),
                for (final c in _chapters)
                  DropdownMenuItem(
                    value: c.remoteId,
                    enabled: !c.locked,
                    child: Text(
                      '${c.volumeTitle == null ? '' : '${c.volumeTitle} · '}${c.title}${c.locked ? '（锁定）' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _committing
                  ? null
                  : (id) => setState(() => _resumeId = id == '' ? null : id),
            ),
            const SizedBox(height: 12),
            const Text('不同来源的分页与正文可能不同。续读从所选章节开头开始；未读数由新来源刷新。请核对作品和章节后再复制。'),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('commitMigration'),
              onPressed: _committing ? null : _commit,
              child: const Text('确认范围并复制到本地书架'),
            ),
            TextButton(
              onPressed: _committing
                  ? null
                  : () async {
                      try {
                        await _repository.prepareMigration(
                          origin: _origin!,
                          target: _target!,
                          chapters: _chapters,
                          resumeChapterId: _resumeId,
                          scope: MigrationScope(
                            metadata: _metadata,
                            categories: _categories,
                            history: _history,
                            tracking: _tracking,
                            downloads: _downloads,
                            mergeExisting: _mergeExisting,
                          ),
                          chapterMappings: _chapterMappings,
                        );
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => const MigrationPlansPage(),
                          ),
                        );
                      } catch (error) {
                        if (mounted) setState(() => _error = _message(error));
                      }
                    },
              child: const Text('只保存计划，稍后或批量执行'),
            ),
            TextButton(
              onPressed: _committing
                  ? null
                  : () => setState(() => _target = null),
              child: const Text('重新选择作品'),
            ),
          ],
        ],
      ),
    ),
  );
}
