import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/database_provider.dart';
import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_preferences.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../sources/source_account_entries.dart';
import 'data/lk/lk_source.dart';
import 'novel_book_card.dart';
import 'reader/chapter_font.dart';
import 'reader/novel_reader_page.dart';

class _LocalNovel {
  const _LocalNovel(
    this.item,
    this.chapters,
    this.history,
    this.readableIds,
    this.missingFonts,
  );
  final MediaItem item;
  final List<Chapter> chapters;
  final HistoryView? history;
  final Set<String> readableIds;
  final int missingFonts;
}

/// Local shelf inspection never watches the executable source registry. Chapter
/// bodies and portable fonts, not a completed task flag, establish availability.
final _localNovelsProvider = StreamProvider<List<_LocalNovel>>((ref) {
  final db = ref.watch(databaseProvider);
  final repository = ref.watch(libraryRepositoryProvider);
  return db
      .customSelect(
        '''
    SELECT m.source_id, m.remote_id FROM media_items m
    WHERE m.type = 'novel' AND (
      EXISTS (SELECT 1 FROM library_entries l
        WHERE l.source_id = m.source_id AND l.remote_id = m.remote_id)
      OR EXISTS (SELECT 1 FROM histories h
        WHERE h.source_id = m.source_id AND h.remote_id = m.remote_id)
      OR EXISTS (SELECT 1 FROM chapters c
        WHERE c.item_source_id = m.source_id AND c.item_remote_id = m.remote_id
        AND c.content_json IS NOT NULL)
    )
  ''',
        readsFrom: {
          db.mediaItems,
          db.libraryEntries,
          db.histories,
          db.chapters,
        },
      )
      .watch()
      .asyncMap((rows) async {
        final result = <_LocalNovel>[];
        final fonts = <String, bool>{};
        for (final row in rows) {
          final sourceId = row.read<String>('source_id');
          final remoteId = row.read<String>('remote_id');
          final item = await repository.itemByKey(sourceId, remoteId);
          if (item == null || item.type != MediaType.novel) continue;
          final chapters = await repository.loadChapters(sourceId, remoteId);
          final readable = <String>{};
          var missingFonts = 0;
          for (final chapter in chapters) {
            final body = chapter.content;
            if (chapter.locked ||
                body == null ||
                ((body.html?.trim().isEmpty ?? true) &&
                    (body.text?.trim().isEmpty ?? true))) {
              continue;
            }
            if (body.fontFamily?.isNotEmpty == true) {
              final data = body.fontData;
              if (data == null ||
                  !fonts.putIfAbsent(data, () {
                    try {
                      ChapterFont.decode(data);
                      return true;
                    } catch (_) {
                      return false;
                    }
                  })) {
                missingFonts++;
                continue;
              }
            }
            readable.add(chapter.remoteId);
          }
          // Keep only directory metadata in a retained workspace. Large chapter
          // bodies and base64 fonts are reloaded for the chosen book on reader open.
          final directory = [
            for (final chapter in chapters)
              Chapter(
                sourceId: chapter.sourceId,
                remoteId: chapter.remoteId,
                title: chapter.title,
                url: chapter.url,
                number: chapter.number,
                sortIndex: chapter.sortIndex,
                volumeTitle: chapter.volumeTitle,
                releaseDate: chapter.releaseDate,
                locked: chapter.locked,
              ),
          ];
          result.add(
            _LocalNovel(
              item,
              directory,
              await repository.lastReadOf(sourceId, remoteId),
              readable,
              missingFonts,
            ),
          );
        }
        return result;
      });
});

class _ShelfFilters {
  _ShelfFilters({
    Set<String>? sources,
    Set<String>? tags,
    this.unread = 'all',
    this.download = 'all',
    this.sort = 'recent',
    this.revealHidden = false,
  }) : sources = sources ?? {},
       tags = tags ?? {};
  final Set<String> sources;
  final Set<String> tags;
  String unread;
  String download;
  String sort;
  bool revealHidden;
  int get count =>
      sources.length +
      tags.length +
      (unread == 'all' ? 0 : 1) +
      (download == 'all' ? 0 : 1) +
      (revealHidden ? 1 : 0);
  _ShelfFilters copy() => _ShelfFilters(
    sources: {...sources},
    tags: {...tags},
    unread: unread,
    download: download,
    sort: sort,
    revealHidden: revealHidden,
  );
}

class NovelShelfView extends ConsumerStatefulWidget {
  const NovelShelfView({super.key});

  @override
  ConsumerState<NovelShelfView> createState() => _NovelShelfViewState();
}

class _NovelShelfViewState extends ConsumerState<NovelShelfView> {
  bool _downloaded = false;
  bool _refreshing = false;
  String _query = '';
  _ShelfFilters _filters = _ShelfFilters();
  final _remoteSummary = <String, String>{};
  final _remoteAccountRoutes = <String, String>{};
  // Membership is an authenticated session snapshot, not a local favourite.
  final _remoteShelves = <String, List<MediaItem>>{};
  final _remoteProviders = <String, RemoteShelfProvider>{};
  final _remoteUnread = <(String, String), int>{};
  final _remoteStale = <String>{};
  final _remoteEpochs = <String, int>{};

  void _observeRemoteAccounts(
    AsyncValue<SourceRegistrySnapshot>? previous,
    AsyncValue<SourceRegistrySnapshot> next,
  ) {
    final snapshot = next.asData?.value;
    if (snapshot == null || !mounted) return;
    final revoked = _remoteProviders.keys.where((id) {
      final source = snapshot.enabledEntries
          .where((entry) => entry.descriptor.id == id)
          .firstOrNull
          ?.source;
      return source is! RemoteShelfProvider || !source.isLoggedIn;
    }).toList();
    if (revoked.isEmpty) return;
    setState(() {
      for (final id in revoked) {
        _remoteShelves.remove(id);
        _remoteProviders.remove(id);
        _remoteUnread.removeWhere((key, _) => key.$1 == id);
        _remoteStale.remove(id);
        _remoteEpochs[id] = (_remoteEpochs[id] ?? 0) + 1;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _downloaded = ref.read(preferencesProvider).get<bool>('novel.shelf.downloaded') ?? false;
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final preferences = ref.read(preferencesProvider);
    await migrateLibraryPreferences(preferences);
    final saved = preferences.get<String>('library.novel.sort');
    if (mounted &&
        const {
          'recent',
          'updated',
          'title',
          'added',
          'progress',
        }.contains(saved)) {
      setState(() => _filters.sort = saved!);
    }
  }

  Future<void> _refreshRemote() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _remoteSummary.clear();
      _remoteAccountRoutes.clear();
    });
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted) return;
      final entries = snapshot
          .enabledWith(SourceCapability.remoteShelf)
          .where(
            (entry) =>
                entry.descriptor.type == MediaType.novel &&
                entry.source is RemoteShelfProvider,
          )
          .toList();
      if (entries.isEmpty) {
        setState(() => _remoteSummary['小说来源'] = '没有已启用的站点书架来源');
      }
      await Future.wait(
        entries.map((entry) async {
          final provider = entry.source as RemoteShelfProvider;
          final sourceId = entry.descriptor.id;
          final name = entry.descriptor.name;
          if (!provider.isLoggedIn) {
            if (mounted) {
              setState(() {
                _remoteShelves.remove(sourceId);
                _remoteProviders.remove(sourceId);
                _remoteUnread.removeWhere((key, _) => key.$1 == sourceId);
                _remoteSummary[name] = '未登录；保留本机收藏，未发起站点请求';
                _remoteAccountRoutes[name] = accountRouteFor(sourceId);
              });
            }
            return;
          }
          setState(() => _remoteProviders[sourceId] = provider);
          final epoch = _remoteEpochs[sourceId] ?? 0;
          bool current() =>
              mounted &&
              provider.isLoggedIn &&
              (_remoteEpochs[sourceId] ?? 0) == epoch;
          final repository = ref.read(libraryRepositoryProvider);
          final warnings = <String>[];
          int? shelfCount;
          var directoryCount = 0;
          var authenticationFailed = false;
          try {
            final books = await provider.remoteShelf();
            if (!current()) return;
            final cached = <MediaItem>[];
            final ids = <String>{};
            String? keep(String? incoming, String? local) =>
                incoming?.trim().isNotEmpty == true ? incoming : local;
            for (final book in books) {
              if (!current()) return;
              if (book.sourceId != sourceId ||
                  book.type != MediaType.novel ||
                  !ids.add(book.remoteId)) {
                continue;
              }
              final existing = await repository.itemByKey(
                sourceId,
                book.remoteId,
              );
              if (!current()) return;
              final item = MediaItem(
                sourceId: sourceId,
                remoteId: book.remoteId,
                type: MediaType.novel,
                title: book.title.trim().isEmpty
                    ? existing?.title ?? book.title
                    : book.title,
                url: keep(book.url, existing?.url),
                coverUrl: keep(book.coverUrl, existing?.coverUrl),
                author: keep(book.author, existing?.author),
                description: keep(book.description, existing?.description),
                tags: book.tags.isEmpty
                    ? existing?.tags ?? const []
                    : book.tags,
                status: keep(book.status, existing?.status),
                rating: book.rating ?? existing?.rating,
              );
              // Cache public book metadata only. Refresh never grants consent to
              // create a local favourite or write to the remote collection.
              await repository.cacheItem(item);
              cached.add(item);
            }
            if (!current()) return;
            shelfCount = cached.length;
            setState(() {
              _remoteShelves[sourceId] = cached;
              _remoteStale.remove(sourceId);
            });
          } catch (error) {
            warnings.add('站点收藏失败：${_describe(error)}（保留上次快照）');
            if (current()) setState(() => _remoteStale.add(sourceId));
            authenticationFailed =
                error is SourceException && error.type == SourceErrorType.auth;
          }
          if (!current()) return;
          var authoritativeUnread = sourceId == LkSource.id;
          if (!authenticationFailed) {
            try {
              final counts = await provider.remoteUnreadCounts();
              if (!current()) return;
              authoritativeUnread = authoritativeUnread || counts.isNotEmpty;
              await repository.applyRemoteUnreadCounts(
                sourceId: sourceId,
                counts: counts,
              );
              if (!current()) return;
              setState(() {
                _remoteUnread.removeWhere((key, _) => key.$1 == sourceId);
                for (final count in counts.entries) {
                  if (count.value >= 0) {
                    _remoteUnread[(sourceId, count.key)] = count.value;
                  }
                }
              });
            } catch (error) {
              warnings.add('站点未读失败：${_describe(error)}（保留原值）');
              authenticationFailed =
                  error is SourceException &&
                  error.type == SourceErrorType.auth;
            }
          }
          // LNS and other non-authoritative sources use the existing local
          // directory baseline. Refresh each local favourite independently.
          if (!authoritativeUnread &&
              !authenticationFailed &&
              provider is DetailProvider) {
            try {
              final local = await repository.listLibrary(
                type: MediaType.novel,
                revealHidden: true,
              );
              for (final view in local.where(
                (view) => view.item.sourceId == sourceId,
              )) {
                if (!current()) return;
                try {
                  final fresh = await (provider as DetailProvider).chapters(
                    view.item,
                  );
                  if (!current()) return;
                  if (fresh.isEmpty) throw StateError('站点返回空目录，保留本地目录');
                  final existing = await repository.loadChapters(
                    sourceId,
                    view.item.remoteId,
                  );
                  if (!current()) return;
                  final freshIds = fresh
                      .map((chapter) => chapter.remoteId)
                      .toSet();
                  // Keep already downloaded historical chapters if the station
                  // removes them; saveChapters preserves bodies for retained IDs.
                  final retained = existing.where(
                    (chapter) =>
                        chapter.content != null &&
                        !freshIds.contains(chapter.remoteId),
                  );
                  await repository.saveChapters(
                    itemSourceId: sourceId,
                    itemRemoteId: view.item.remoteId,
                    chapters: [...fresh, ...retained],
                  );
                  directoryCount++;
                } catch (error) {
                  warnings.add(
                    '${view.item.title}目录失败：${_describe(error)}（保留本地）',
                  );
                }
              }
            } catch (error) {
              warnings.add('本地目录刷新失败：${_describe(error)}（保留本地）');
            }
          }
          if (!current()) return;
          setState(() {
            if (authenticationFailed) {
              _remoteAccountRoutes[name] = accountRouteFor(sourceId);
            } else {
              _remoteAccountRoutes.remove(name);
            }
            _remoteSummary[name] = [
              if (shelfCount != null) '站点收藏 $shelfCount 本（未自动加入本机收藏）',
              if (!authoritativeUnread &&
                  !authenticationFailed &&
                  provider is DetailProvider)
                '已刷新 $directoryCount 本本机收藏的目录基线',
              ...warnings,
              '本机收藏与阅读位置保留',
            ].join('；');
          });
        }),
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _remoteSummary['小说来源'] = '无法刷新：${_describe(error)}；本地书架仍可使用',
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _describe(Object error) => error is SourceException
      ? error.userMessage
      : SourceException.sanitizeMessage('$error');

  Future<void> _read(_LocalNovel book) async {
    final chapters = await ref
        .read(libraryRepositoryProvider)
        .loadChapters(book.item.sourceId, book.item.remoteId);
    if (!mounted) return;
    if (chapters.isEmpty) {
      await context.push(AppRoutes.detailFor(book.item), extra: book.item);
      return;
    }
    var index = chapters.indexWhere(
      (c) => c.remoteId == book.history?.chapterRemoteId,
    );
    if (index < 0) index = 0;
    if (_downloaded && !book.readableIds.contains(chapters[index].remoteId)) {
      index = chapters.indexWhere((c) => book.readableIds.contains(c.remoteId));
    }
    if (index < 0) return;
    await context.push(
      AppRoutes.novelReader,
      extra: NovelReaderArgs(
        item: book.item,
        chapters: chapters,
        initialIndex: index,
      ),
    );
  }

  Future<void> _markRead(
    List<_LocalNovel> books,
    Map<(String, String), LibraryItemView> entries,
  ) async {
    final keys = <(String, String)>{
      for (final book in books)
        if ((entries[(book.item.sourceId, book.item.remoteId)]
                    ?.entry
                    .unreadCount ??
                0) >
            0)
          (book.item.sourceId, book.item.remoteId),
    };
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('当前小说结果标为已读？'),
        content: Text(
          '仅清除当前筛选内 ${keys.length} 本小说的本地未读数。'
          '不会向站点写入阅读进度；下一次成功刷新可能恢复站点权威未读数。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(libraryRepositoryProvider)
          .markEntriesRead(keys, type: MediaType.novel);
    }
  }

  Future<void> _editFilters(
    List<_LocalNovel> books,
    Map<String, String> labels,
  ) async {
    final result = await showModalBottomSheet<_ShelfFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => _NovelShelfFilterSheet(
        initial: _filters,
        sourceIds: {
          ...books.map((book) => book.item.sourceId),
          ..._filters.sources,
        }.toList()..sort(),
        tags: {
          ...books.expand((book) => book.item.tags),
          ..._filters.tags,
        }.toList()..sort(),
        labels: labels,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _filters = result);
    await ref.read(preferencesProvider).set('library.novel.sort', result.sort);
  }

  @override
  Widget build(BuildContext context) {
    if (_remoteProviders.isNotEmpty) {
      ref.listen(sourcesProvider, _observeRemoteAccounts);
    }
    final library = ref.watch(libraryByTypeProvider(MediaType.novel));
    final categoryState = ref.watch(
      libraryCategoriesForTypeProvider(MediaType.novel),
    );
    final local = ref.watch(_localNovelsProvider);
    final labels = ref.watch(librarySourceLabelsProvider);
    final categories = categoryState.asData?.value;
    final raw = library.asData?.value ?? const <LibraryItemView>[];
    final entries = <(String, String), LibraryItemView>{
      for (final view in raw) (view.item.sourceId, view.item.remoteId): view,
    };
    final combined = <(String, String), _LocalNovel>{
      for (final book in local.asData?.value ?? <_LocalNovel>[])
        (book.item.sourceId, book.item.remoteId): book,
    };
    final remoteKeys = <(String, String)>{};
    for (final shelf in _remoteShelves.entries) {
      if (_remoteProviders[shelf.key]?.isLoggedIn != true) continue;
      for (final item in shelf.value) {
        final key = (item.sourceId, item.remoteId);
        remoteKeys.add(key);
        combined.putIfAbsent(
          key,
          () => _LocalNovel(item, const [], null, const {}, 0),
        );
      }
    }
    final books = categories == null || library.asData == null
        ? <_LocalNovel>[]
        : combined.values.where((book) {
            final entry = entries[(book.item.sourceId, book.item.remoteId)];
            return entry == null ||
                categories.matches(entry, revealHidden: _filters.revealHidden);
          }).toList();
    final filtered = books.where((book) {
      final item = book.item;
      final entry = entries[(item.sourceId, item.remoteId)]?.entry;
      final count = book.readableIds.length;
      final complete = count > 0 && count == book.chapters.length;
      final needle = _query.trim().toLowerCase();
      return (!_downloaded || count > 0) &&
          (_filters.sources.isEmpty ||
              _filters.sources.contains(item.sourceId)) &&
          (_filters.tags.isEmpty || _filters.tags.every(item.tags.contains)) &&
          (_filters.unread == 'all' ||
              ((entry?.unreadCount ??
                          _remoteUnread[(item.sourceId, item.remoteId)] ??
                          0) >
                      0) ==
                  (_filters.unread == 'unread')) &&
          (switch (_filters.download) {
            'any' => count > 0,
            'complete' => complete,
            'partial' => count > 0 && !complete,
            'none' => count == 0,
            _ => true,
          }) &&
          (needle.isEmpty ||
              item.title.toLowerCase().contains(needle) ||
              (item.author?.toLowerCase().contains(needle) ?? false) ||
              item.tags.any((tag) => tag.toLowerCase().contains(needle)));
    }).toList();
    filtered.sort((a, b) {
      final first = entries[(a.item.sourceId, a.item.remoteId)]?.entry;
      final second = entries[(b.item.sourceId, b.item.remoteId)]?.entry;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final order = switch (_filters.sort) {
        'title' => a.item.title.compareTo(b.item.title),
        'added' => (second?.addedAt ?? epoch).compareTo(
          first?.addedAt ?? epoch,
        ),
        'updated' => (second?.updatedAt ?? epoch).compareTo(
          first?.updatedAt ?? epoch,
        ),
        'progress' => (second?.progress ?? 0).compareTo(first?.progress ?? 0),
        _ => (b.history?.visitedAt ?? second?.updatedAt ?? epoch).compareTo(
          a.history?.visitedAt ?? first?.updatedAt ?? epoch,
        ),
      };
      return order != 0
          ? order
          : '${a.item.sourceId}/${a.item.remoteId}'.compareTo(
              '${b.item.sourceId}/${b.item.remoteId}',
            );
    });
    final error = local.error ?? library.error ?? categoryState.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('全部')),
                  ButtonSegment(value: true, label: Text('已下载')),
                ],
                selected: {_downloaded},
                onSelectionChanged: (value) {
                  setState(() => _downloaded = value.single);
                  unawaited(ref.read(preferencesProvider).set('novel.shelf.downloaded', value.single));
                },
              ),
              OutlinedButton.icon(
                onPressed: () => _editFilters(books, labels),
                icon: const Icon(Icons.tune),
                label: Text(
                  '筛选 / 排序${_filters.count == 0 ? '' : ' (${_filters.count})'}',
                ),
              ),
              Text('${filtered.length} 本'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            decoration: const InputDecoration(
              labelText: '查找本地书架与最近阅读',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (_filters.count > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final id in _filters.sources)
                  InputChip(
                    label: Text(labels[id] ?? id),
                    onDeleted: () =>
                        setState(() => _filters.sources.remove(id)),
                  ),
                for (final tag in _filters.tags)
                  InputChip(
                    label: Text(tag),
                    onDeleted: () => setState(() => _filters.tags.remove(tag)),
                  ),
                if (_filters.unread != 'all')
                  InputChip(
                    label: Text(_filters.unread == 'unread' ? '有未读' : '无未读'),
                    onDeleted: () => setState(() => _filters.unread = 'all'),
                  ),
                if (_filters.download != 'all')
                  InputChip(
                    label: Text(_downloadLabels[_filters.download]!),
                    onDeleted: () => setState(() => _filters.download = 'all'),
                  ),
                if (_filters.revealHidden)
                  InputChip(
                    label: const Text('显示隐藏分类'),
                    onDeleted: () =>
                        setState(() => _filters.revealHidden = false),
                  ),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              // Pull-to-refresh is local only. The labelled explicit button below
              // is the consent to contact authenticated remote shelves.
              ref.invalidate(_localNovelsProvider);
              await ref.read(_localNovelsProvider.future);
            },
            child: ListView.builder(
              key: PageStorageKey('novel-shelf-$_downloaded'),
              padding: const EdgeInsets.all(12),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: filtered.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('本地优先 · 刷新不会删除本地收藏，也不会修改站点书架'),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _refreshing
                                        ? null
                                        : _refreshRemote,
                                    icon: _refreshing
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.cloud_sync_outlined),
                                    label: const Text('刷新已登录站点收藏 / 未读'),
                                  ),
                                  TextButton(
                                    onPressed: filtered.isEmpty
                                        ? null
                                        : () => _markRead(filtered, entries),
                                    child: const Text('当前结果本地标已读'),
                                  ),
                                ],
                              ),
                              for (final summary in _remoteSummary.entries) ...[
                                const SizedBox(height: 8),
                                Text('${summary.key}：${summary.value}'),
                                if (_remoteAccountRoutes.containsKey(
                                  summary.key,
                                ))
                                  TextButton(
                                    onPressed: () => context.push(
                                      _remoteAccountRoutes[summary.key]!,
                                    ),
                                    child: Text('${summary.key}账号'),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Text('本地小说快照加载失败：$error'),
                              OutlinedButton(
                                onPressed: () {
                                  ref.invalidate(_localNovelsProvider);
                                  ref.invalidate(
                                    libraryByTypeProvider(MediaType.novel),
                                  );
                                  ref.invalidate(
                                    libraryCategoriesForTypeProvider(
                                      MediaType.novel,
                                    ),
                                  );
                                },
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        )
                      else if (local.isLoading ||
                          library.isLoading ||
                          categoryState.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _downloaded
                                ? '暂无符合条件的离线小说。已下载视图只统计真实正文与可用专用字体；部分下载不会冒充整本。'
                                : '暂无符合条件的小说。本地收藏与最近阅读先显示；站点收藏需显式刷新。',
                          ),
                        ),
                    ],
                  );
                }
                final book = filtered[index - 1];
                final entry =
                    entries[(book.item.sourceId, book.item.remoteId)]?.entry;
                final count = book.readableIds.length;
                final full = count > 0 && count == book.chapters.length;
                final resumeAvailable = book.readableIds.contains(
                  book.history?.chapterRemoteId,
                );
                return NovelBookCard(
                  item: book.item,
                  sourceLabel:
                      labels[book.item.sourceId] ??
                      switch (book.item.sourceId) {
                        'light-novel-kingdom' => '轻之国度',
                        'light-novel-shelf' => '轻书架',
                        _ => book.item.sourceId,
                      },
                  status: [
                    if (entry != null) '本机收藏',
                    if (remoteKeys.contains((
                      book.item.sourceId,
                      book.item.remoteId,
                    )))
                      _remoteStale.contains(book.item.sourceId)
                          ? '站点收藏 · 上次成功快照（本次刷新失败）'
                          : '站点收藏 · 本次成功刷新',
                    if (entry == null)
                      remoteKeys.contains((
                            book.item.sourceId,
                            book.item.remoteId,
                          ))
                          ? '尚未加入本机收藏'
                          : '最近阅读 / 本地快照 · 尚未本机收藏',
                    if ((entry?.unreadCount ??
                            _remoteUnread[(
                              book.item.sourceId,
                              book.item.remoteId,
                            )] ??
                            0) >
                        0)
                      '${entry?.unreadCount ?? _remoteUnread[(book.item.sourceId, book.item.remoteId)]} 章未读',
                    if (book.history != null)
                      '读至：${book.chapters.where((c) => c.remoteId == book.history!.chapterRemoteId).firstOrNull?.title ?? '已保存章节'} · 已保存文字位置',
                    if (book.chapters.isNotEmpty)
                      '本地目录 ${book.chapters.length} 章',
                    if (count > 0)
                      '${full ? '完整下载' : '部分下载'} $count/${book.chapters.length} 章 · 正文 / 字体可离线',
                    if (book.missingFonts > 0)
                      '${book.missingFonts} 章缺少有效专用字体，不能离线阅读',
                    if (_downloaded && book.history != null && !resumeAvailable)
                      '上次阅读章节未离线，将打开首个可用下载章节',
                  ].join('\n'),
                  actions: [
                    FilledButton.tonalIcon(
                      onPressed: () => _read(book),
                      icon: const Icon(Icons.auto_stories_outlined),
                      label: Text(
                        _downloaded && book.history != null && !resumeAvailable
                            ? '阅读已下载章节'
                            : book.history != null
                            ? '继续阅读'
                            : '开始阅读',
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.push(
                        AppRoutes.detailFor(book.item),
                        extra: book.item,
                      ),
                      child: const Text('目录 / 下载 / 导出'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

const _downloadLabels = <String, String>{
  'all': '不限下载状态',
  'any': '有离线章节',
  'complete': '完整下载',
  'partial': '部分下载',
  'none': '无可用离线正文',
};

class _NovelShelfFilterSheet extends StatefulWidget {
  const _NovelShelfFilterSheet({
    required this.initial,
    required this.sourceIds,
    required this.tags,
    required this.labels,
  });
  final _ShelfFilters initial;
  final List<String> sourceIds;
  final List<String> tags;
  final Map<String, String> labels;
  @override
  State<_NovelShelfFilterSheet> createState() => _NovelShelfFilterSheetState();
}

class _NovelShelfFilterSheetState extends State<_NovelShelfFilterSheet> {
  late _ShelfFilters _draft;
  String _tagQuery = '';
  @override
  void initState() {
    super.initState();
    _draft = widget.initial.copy();
  }

  Widget _group(String title, String summary, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(summary, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        ...children,
        const SizedBox(height: 16),
        const Divider(height: 1),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .88,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '小说书架筛选 · ${_draft.count} 项',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '取消筛选',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    _group('题材', '仅筛选本地收藏与最近阅读的真实标签；不代表整站题材搜索。多标签同时满足。', [
                      if (widget.tags.isEmpty)
                        const Text('当前本地作品没有可用标签')
                      else ...[
                        if (widget.tags.length > 16)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextField(
                              decoration: const InputDecoration(
                                labelText: '查找可选标签',
                                prefixIcon: Icon(Icons.search),
                              ),
                              onChanged: (value) => setState(
                                () => _tagQuery = value.trim().toLowerCase(),
                              ),
                            ),
                          ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final tag in widget.tags.where(
                              (tag) => tag.toLowerCase().contains(_tagQuery),
                            ))
                              FilterChip(
                                label: Text(tag),
                                selected: _draft.tags.contains(tag),
                                onSelected: (selected) => setState(
                                  () => selected
                                      ? _draft.tags.add(tag)
                                      : _draft.tags.remove(tag),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ]),
                    _group(
                      '来源',
                      _draft.sources.isEmpty
                          ? '全部本地小说来源'
                          : '已选 ${_draft.sources.length} 个来源',
                      [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final id in widget.sourceIds)
                              FilterChip(
                                label: Text(widget.labels[id] ?? id),
                                selected: _draft.sources.contains(id),
                                onSelected: (selected) => setState(
                                  () => selected
                                      ? _draft.sources.add(id)
                                      : _draft.sources.remove(id),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                    _group('更新 / 未读', '使用成功刷新的站点未读或本地目录基线；不伪造站点状态。', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in const {
                            'all': '不限未读',
                            'unread': '有未读',
                            'read': '无未读',
                          }.entries)
                            ChoiceChip(
                              label: Text(option.value),
                              selected: _draft.unread == option.key,
                              onSelected: (_) =>
                                  setState(() => _draft.unread = option.key),
                            ),
                        ],
                      ),
                    ]),
                    _group('下载状态', _downloadLabels[_draft.download]!, [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in _downloadLabels.entries)
                            ChoiceChip(
                              label: Text(option.value),
                              selected: _draft.download == option.key,
                              onSelected: (_) =>
                                  setState(() => _draft.download = option.key),
                            ),
                        ],
                      ),
                    ]),
                    _group('本地分类可见性', '隐藏分类只影响本地展示，不改变站点收藏。', [
                      FilterChip(
                        label: const Text('显示隐藏分类中的小说'),
                        selected: _draft.revealHidden,
                        onSelected: (selected) =>
                            setState(() => _draft.revealHidden = selected),
                      ),
                    ]),
                    _group('排序', '仅改变小说书架，不改变漫画或追番偏好。', [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in const {
                            'recent': '最近阅读',
                            'updated': '最近更新',
                            'title': '标题',
                            'added': '加入时间',
                            'progress': '阅读章节',
                          }.entries)
                            ChoiceChip(
                              label: Text(option.value),
                              selected: _draft.sort == option.key,
                              onSelected: (_) =>
                                  setState(() => _draft.sort = option.key),
                            ),
                        ],
                      ),
                    ]),
                  ],
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(() => _draft = _ShelfFilters()),
                      child: const Text('重置草稿'),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, _draft),
                        child: const Text('应用'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reuses the permission-aware detail actions rather than creating another
/// exporter or bypassing the LNS official-download restriction.
class NovelExportChooser extends ConsumerWidget {
  const NovelExportChooser({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final local = ref.watch(_localNovelsProvider);
    final library = ref.watch(libraryByTypeProvider(MediaType.novel));
    final categories = ref.watch(
      libraryCategoriesForTypeProvider(MediaType.novel),
    );
    final entries = {
      for (final view in library.asData?.value ?? <LibraryItemView>[])
        (view.item.sourceId, view.item.remoteId): view,
    };
    final AsyncValue<List<_LocalNovel>> books =
        library.hasError || categories.hasError
        ? AsyncValue.error(
            library.error ?? categories.error!,
            library.asError?.stackTrace ?? categories.asError!.stackTrace,
          )
        : library.isLoading || categories.isLoading
        ? const AsyncValue.loading()
        : local.whenData(
            (items) => items.where((book) {
              final entry = entries[(book.item.sourceId, book.item.remoteId)];
              return categories.asData != null &&
                  library.asData != null &&
                  (entry == null || categories.asData!.value.matches(entry));
            }).toList(),
          );
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择小说 · 导出',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              '选择书籍后，在详情更多中使用 EPUB / TXT 或下载。'
              '仅可导出有权限的正文；轻书架保留官方整书下载限制。',
            ),
          ),
          Expanded(
            child: books.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyStateView(
                icon: Icons.error_outline,
                title: '本地小说加载失败',
                message: '$error',
                action: OutlinedButton(
                  onPressed: () => ref.invalidate(_localNovelsProvider),
                  child: const Text('重试'),
                ),
              ),
              data: (items) => items.isEmpty
                  ? const EmptyStateView(
                      icon: Icons.menu_book_outlined,
                      title: '还没有本地小说',
                      message: '先从小说发现或搜索打开作品、收藏或阅读，再在该作品详情更多中下载 / 导出。',
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index].item;
                        return ListTile(
                          title: Text(item.title),
                          subtitle: Text(
                            [
                              if (item.author != null) item.author!,
                              ref.watch(
                                    librarySourceLabelsProvider,
                                  )[item.sourceId] ??
                                  item.sourceId,
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            final router = GoRouter.of(context);
                            Navigator.pop(context);
                            router.push(AppRoutes.detailFor(item), extra: item);
                          },
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
