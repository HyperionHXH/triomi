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
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/page_scaffold.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
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

class NovelShelfView extends ConsumerStatefulWidget {
  const NovelShelfView({super.key, this.active = true});

  final bool active;

  @override
  ConsumerState<NovelShelfView> createState() => _NovelShelfViewState();
}

class _NovelShelfViewState extends ConsumerState<NovelShelfView> {
  bool _downloaded = false;
  bool _refreshing = false;
  int _refreshGeneration = 0;
  bool _registryChanged = false;
  bool _remoteRegistryFailed = false;
  final _remoteSummary = <String, String>{};
  final _remoteAuthFailures = <String>{};
  // Membership is an authenticated session snapshot, not a local favourite.
  final _remoteShelves = <String, List<MediaItem>>{};
  final _remoteProviders = <String, RemoteShelfProvider>{};
  final _remoteUnread = <(String, String), int>{};
  final _remoteStale = <String>{};
  final _remoteEpochs = <String, int>{};
  final _mutatingSources = <String>{};

  void _clearRemote(String sourceId) {
    _remoteShelves.remove(sourceId);
    _remoteProviders.remove(sourceId);
    _remoteUnread.removeWhere((key, _) => key.$1 == sourceId);
    _remoteStale.remove(sourceId);
    _remoteEpochs[sourceId] = (_remoteEpochs[sourceId] ?? 0) + 1;
  }

  void _observeRemoteAccounts(
    AsyncValue<SourceRegistrySnapshot>? previous,
    AsyncValue<SourceRegistrySnapshot> next,
  ) {
    if (!mounted) return;
    // Login/logout invalidates the registry, even when an adapter is reused.
    // Never retain an authenticated collection across that transition.
    if (next.isLoading && previous?.asData != null) {
      _registryChanged = true;
      setState(() {
        for (final id in _remoteProviders.keys.toList()) {
          _clearRemote(id);
        }
        _remoteSummary.clear();
        _remoteAuthFailures.clear();
        _refreshGeneration++;
        _refreshing = false;
      });
      return;
    }
    final snapshot = next.asData?.value;
    if (snapshot == null) return;
    final revoked = _remoteProviders.keys.where((id) {
      final source = snapshot.enabledEntries
          .where((entry) => entry.descriptor.id == id)
          .firstOrNull
          ?.source;
      return !identical(source, _remoteProviders[id]) ||
          source is! RemoteShelfProvider ||
          !source.isLoggedIn;
    }).toList();
    if (revoked.isNotEmpty) {
      setState(() {
        for (final id in revoked) {
          _clearRemote(id);
        }
      });
    }
    final needsRefresh = _registryChanged || revoked.isNotEmpty;
    _registryChanged = false;
    if (needsRefresh && widget.active && !_downloaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active && !_downloaded) {
          unawaited(_refreshRemote());
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _downloaded =
        ref.read(preferencesProvider).get<bool>('novel.shelf.downloaded') ??
        false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active && !_downloaded) {
        unawaited(_refreshRemote());
      }
    });
  }

  @override
  void didUpdateWidget(covariant NovelShelfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && !_downloaded) {
      unawaited(_refreshRemote());
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    ref.invalidate(_localNovelsProvider);
    await Future.wait([
      ref.read(_localNovelsProvider.future),
      if (!_downloaded) _refreshRemote(),
    ]);
  }

  Future<void> _removeRemote(MediaItem item) async {
    final sourceId = item.sourceId;
    final provider = _remoteProviders[sourceId];
    if (provider == null ||
        !provider.isLoggedIn ||
        _mutatingSources.contains(sourceId)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出站点收藏？'),
        content: Text('将《${item.title}》从对应站点书架移除。本机收藏、阅读进度和已下载章节不会删除。'),
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
    if (confirmed != true ||
        !mounted ||
        !provider.isLoggedIn ||
        !identical(_remoteProviders[sourceId], provider) ||
        _mutatingSources.contains(sourceId)) {
      return;
    }
    setState(() => _mutatingSources.add(sourceId));
    try {
      await provider.setInRemoteShelf(item, false);
      if (!mounted || !identical(_remoteProviders[sourceId], provider)) return;
      setState(() {
        // A refresh started while the write was pending may still contain the
        // removed book. Retire it before publishing the confirmed mutation.
        _refreshGeneration++;
        _refreshing = false;
        _remoteShelves[sourceId]?.removeWhere(
          (book) => book.remoteId == item.remoteId,
        );
        _remoteUnread.remove((sourceId, item.remoteId));
      });
      await _refreshRemote();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移出站点收藏失败：${_describe(error)}')));
      }
    } finally {
      if (mounted) setState(() => _mutatingSources.remove(sourceId));
    }
  }

  Future<void> _refreshRemote() async {
    if (!mounted || _refreshing) return;
    final refreshGeneration = ++_refreshGeneration;
    setState(() {
      _refreshing = true;
      _remoteRegistryFailed = false;
      _remoteSummary.clear();
      _remoteAuthFailures.clear();
    });
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted || _refreshGeneration != refreshGeneration) return;
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
                _clearRemote(sourceId);
              });
            }
            return;
          }
          setState(() => _remoteProviders[sourceId] = provider);
          final epoch = _remoteEpochs[sourceId] ?? 0;
          bool currentSession() =>
              mounted &&
              (_remoteEpochs[sourceId] ?? 0) == epoch &&
              identical(_remoteProviders[sourceId], provider) &&
              _refreshGeneration == refreshGeneration;
          bool current() => currentSession() && provider.isLoggedIn;
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
              MediaItem? existing;
              try {
                existing = await repository.itemByKey(sourceId, book.remoteId);
              } catch (error) {
                warnings.add('${book.title}本地资料读取失败：${_describe(error)}');
              }
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
              try {
                await repository.cacheItem(item);
              } catch (error) {
                warnings.add('${book.title}资料缓存失败：${_describe(error)}');
              }
              cached.add(item);
            }
            if (!current()) return;
            shelfCount = cached.length;
            setState(() {
              _remoteShelves[sourceId] = cached;
              _remoteStale.remove(sourceId);
            });
          } catch (error) {
            authenticationFailed =
                error is SourceException && error.type == SourceErrorType.auth;
            warnings.add(
              '站点收藏失败：${_describe(error)}'
              '${!authenticationFailed && _remoteShelves.containsKey(sourceId) ? '（保留上次成功结果）' : ''}',
            );
            if (currentSession()) {
              setState(() {
                if (authenticationFailed) {
                  _remoteShelves.remove(sourceId);
                  _remoteUnread.removeWhere((key, _) => key.$1 == sourceId);
                  _remoteSummary[name] = warnings.join('；');
                  _remoteAuthFailures.add(sourceId);
                } else {
                  _remoteStale.add(sourceId);
                }
              });
            }
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
              if (authenticationFailed && currentSession()) {
                setState(() {
                  _remoteSummary[name] = warnings.join('；');
                  _remoteAuthFailures.add(sourceId);
                  if (!provider.isLoggedIn) {
                    _remoteShelves.remove(sourceId);
                    _remoteUnread.removeWhere((key, _) => key.$1 == sourceId);
                  }
                });
              }
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
                    view.item.sourceSnapshot,
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
              _remoteAuthFailures.add(sourceId);
            } else {
              _remoteAuthFailures.remove(sourceId);
            }
            _remoteSummary[name] = [
              if (shelfCount != null) '站点收藏 $shelfCount 本（未自动加入本机收藏）',
              if (!authoritativeUnread &&
                  !authenticationFailed &&
                  provider is DetailProvider)
                '已刷新 $directoryCount 本本机收藏的目录基线',
              ...warnings,
            ].join('；');
          });
        }),
      );
    } catch (error) {
      if (mounted && _refreshGeneration == refreshGeneration) {
        setState(() {
          _remoteRegistryFailed = true;
          _remoteSummary['小说来源'] = '无法刷新：${_describe(error)}；本地书架仍可使用';
        });
      }
    } finally {
      if (mounted && _refreshGeneration == refreshGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  String _describe(Object error) => error is SourceException
      ? error.userMessage
      : SourceException.sanitizeMessage('$error');

  Future<void> _read(_LocalNovel book) async {
    final chapters = await ref
        .read(libraryRepositoryProvider)
        .loadChapters(book.item.sourceId, book.item.remoteId);
    final history = await ref
        .read(libraryRepositoryProvider)
        .lastReadOf(book.item.sourceId, book.item.remoteId);
    if (!mounted) return;
    if (chapters.isEmpty) {
      await _openDetail(book.item);
      return;
    }
    var index = chapters.indexWhere(
      (c) => c.remoteId == history?.chapterRemoteId,
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
    if (mounted) await _refresh();
  }

  Future<void> _openDetail(MediaItem item) async {
    await context.push(AppRoutes.detailFor(item), extra: item);
    if (mounted) await _refresh();
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
          '仅清除当前书架内 ${keys.length} 本小说的本地未读数。'
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

  @override
  Widget build(BuildContext context) {
    if ((widget.active && !_downloaded) || _remoteProviders.isNotEmpty) {
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
    final filtered = combined.values.where((book) {
      final key = (book.item.sourceId, book.item.remoteId);
      final entry = entries[key];
      if (_downloaded) {
        return book.readableIds.isNotEmpty &&
            (entry == null || categories?.matches(entry) == true);
      }
      // A cached body or reading history is not consent to collect a book.
      // Remote membership is owned by the current source session, not SQLite.
      return remoteKeys.contains(key) ||
          (entry != null && categories?.matches(entry) == true);
    }).toList();
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
                  unawaited(
                    ref
                        .read(preferencesProvider)
                        .set('novel.shelf.downloaded', value.single),
                  );
                  if (!value.single) unawaited(_refreshRemote());
                },
              ),
              Text('${filtered.length} 本'),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Divider(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              key: PageStorageKey('novel-shelf-$_downloaded'),
              padding: const EdgeInsets.all(AppSpacing.md),
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: filtered.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!_downloaded)
                            TextButton(
                              onPressed: filtered.isEmpty
                                  ? null
                                  : () => _markRead(filtered, entries),
                              child: const Text('本机收藏标为已读'),
                            ),
                        ],
                      ),
                      if (!_downloaded)
                        for (final summary in _remoteSummary.entries) ...[
                          const SizedBox(height: 8),
                          Text('${summary.key}：${summary.value}'),
                        ],
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Text('本机收藏 / 下载加载失败：$error'),
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
                      else if (filtered.isEmpty &&
                          !_refreshing &&
                          (_downloaded ||
                              (!_remoteRegistryFailed &&
                                  _remoteStale.isEmpty &&
                                  _remoteAuthFailures.isEmpty)))
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _downloaded
                                ? '暂无可离线阅读的小说。下载章节正文与所需字体后显示在这里。'
                                : '书架暂无收藏。在作品详情加入本机收藏，或通过右上角设置管理站点收藏。',
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
                  onReturn: _refresh,
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
                          : '已下载 · 未加入收藏',
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
                      onPressed: () => _openDetail(book.item),
                      child: const Text('目录 / 下载 / 导出'),
                    ),
                    if (!_downloaded &&
                        remoteKeys.contains((
                          book.item.sourceId,
                          book.item.remoteId,
                        )))
                      TextButton(
                        onPressed:
                            _refreshing ||
                                _mutatingSources.contains(book.item.sourceId)
                            ? null
                            : () => _removeRemote(book.item),
                        child: const Text('移出站点收藏'),
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
              '在详情选择章节缓存，或通过导出菜单导出 EPUB / TXT；'
              '仅可导出有权限的正文，轻书架官方整书下载仍受站点权限限制。',
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
                      message: '先从小说发现或搜索打开作品、收藏或阅读，再在作品详情缓存章节或导出。',
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
