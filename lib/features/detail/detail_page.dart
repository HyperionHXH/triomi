import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_descriptor.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/kazumi_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/page_scaffold.dart';
import '../anime/anime_collection_button.dart';
import '../anime/anime_follows_page.dart';
import '../discover/widgets/media_item_card.dart';
import '../downloads/data/download_providers.dart';
import '../library/data/anime_identity_repository.dart';
import '../library/data/library_providers.dart';
import '../library/merged_manga_page.dart';
import '../library/source_migration_page.dart';
import '../novel/data/lns/lns_source.dart';
import '../novel/export/novel_export_service.dart';
import '../novel/lk/book_comments_section.dart';
import '../novel/novel_collection_button.dart';
import '../novel/reader/novel_reader_page.dart';
import '../player/episode_selector.dart';
import '../player/player_page.dart';
import '../reader/manga_reader_page.dart';
import '../search/search_page.dart';
import '../tracking/bind_sheet.dart';
import '../tracking/data/tracking_models.dart';
import '../tracking/tracking_sync_page.dart';
import 'anime_info_repository.dart';
import 'anime_info_sheet.dart';
import 'anime_source_sheet.dart';
import 'manga_related_section.dart';

/// 详情页：作品信息 + 章节目录。
///
/// 列表页带来的信息往往不全（封面尺寸、简介、标签常缺失），
/// 因此进入详情后会用 DetailProvider 补全一次。
class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({super.key, required this.item});

  final MediaItem item;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  Future<_DetailData>? _future;
  late _DetailData _data = _DetailData(
    item: widget.item,
    supportsContent: widget.item.sourceId != 'bangumi-anime',
  );
  _DetailData? _playback;
  SourceRequestCancellation? _metadataOwner, _directoryOwner;
  int _generation = 0, _directoryGeneration = 0;
  bool _metadataBusy = false, _directoryBusy = false;
  String? _selectedEpisodeId;
  String? _metadataError, _directoryError;
  Map<String, Object?>? _animeOverview;

  @override
  void initState() {
    super.initState();
    _future = _load();
    if (widget.item.type == MediaType.anime) unawaited(_restoreSelection());
  }

  @override
  void dispose() {
    _generation++;
    _directoryGeneration++;
    _metadataOwner?.cancel();
    _directoryOwner?.cancel();
    super.dispose();
  }

  Future<void> _restoreSelection() async {
    final directoryGeneration = _directoryGeneration;
    final identity = ref.read(animeIdentityRepositoryProvider);
    final subject = await identity.subjectFor(widget.item) ?? widget.item;
    if (!mounted) return;
    if (subject.sourceId != widget.item.sourceId ||
        subject.remoteId != widget.item.remoteId) {
      setState(
        () => _data = _DetailData(item: subject, supportsContent: false),
      );
      _future = _load();
    }
    final selected = await identity.lastSelection(subject);
    if (!mounted || directoryGeneration != _directoryGeneration) return;
    if (widget.item.sourceId != 'bangumi-anime') {
      await _loadPlayback(
        widget.item,
        preferredChapterId: selected?.item.sourceId == widget.item.sourceId &&
                selected?.item.remoteId == widget.item.remoteId
            ? selected?.chapter?.remoteId
            : null,
      );
    } else if (selected != null) {
      await _loadPlayback(
        selected.item,
        preferredChapterId: selected.chapter?.remoteId,
      );
    }
  }

  void _publish(_DetailData data, int generation) {
    if (!mounted || generation != _generation) return;
    setState(() => _data = data);
  }

  Future<_DetailData> _load() async {
    final generation = ++_generation;
    _metadataOwner?.cancel();
    final owner = _metadataOwner = SourceRequestCancellation();
    _metadataBusy = true;
    _metadataError = null;
    final cached = await _loadFromCache(
      fallbackItem: _data.item ?? widget.item,
    );
    if (!mounted || generation != _generation) return _data;
    if (cached != null) _publish(cached, generation);
    final item = _data.item ?? widget.item;
    if (item.sourceId == 'local-comic') {
      _metadataBusy = false;
      return _data;
    }
    if (item.type == MediaType.anime && item.sourceId != 'bangumi-anime') {
      // The playback chain owns the provider detail request, avoiding a second
      // metadata fetch for the same site item.
      _metadataBusy = false;
      return _data;
    }
    if (item.sourceId == 'bangumi-anime') {
      try {
        if (item.type != MediaType.anime) throw StateError('资料来源不属于当前工作区');
        final info = await owner.run(
          () => ref.read(animeInfoRepositoryProvider).section(item.remoteId, 'info'),
        );
        final row = info.rows.single;
        if (!mounted || generation != _generation || owner.cancelled) {
          return _data;
        }
        final detail = bangumiItem(row);
        _animeOverview = row;
        if (info.refreshError != null) {
          _metadataError = 'Bangumi 资料刷新失败：${info.refreshError}';
        }
        _publish(
          _DetailData(
            item: detail,
            sourceName: 'Bangumi · 公开兼容资料',
            supportsContent: false,
          ),
          generation,
        );
        unawaited(
          ref
              .read(libraryRepositoryProvider)
              .cacheItem(detail)
              .catchError((Object _) {}),
        );
      } catch (error) {
        if (mounted && generation == _generation && !owner.cancelled) {
          setState(() => _metadataError = '资料暂不可用：$error');
        }
      } finally {
        if (mounted && generation == _generation) {
          setState(() => _metadataBusy = false);
        }
      }
      return _data;
    }
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      if (!mounted || generation != _generation) return _data;
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == item.sourceId)
          .firstOrNull;
      if (entry == null || !entry.enabled) {
        throw StateError(entry == null ? '该来源已移除' : '该来源已停用');
      }
      if (entry.descriptor.type != item.type) throw StateError('来源不属于当前工作区');
      final provider = entry.source;
      if (provider is! DetailProvider) throw StateError('来源不支持详情');
      var detail = item;
      final metadata = owner.run(() async {
        try {
          detail = await provider.detail(item);
          if (detail.type != item.type ||
              detail.sourceId != item.sourceId ||
              detail.remoteId != item.remoteId) {
            throw StateError('来源返回的作品身份不一致');
          }
          if (owner.cancelled || !mounted || generation != _generation) return;
          _publish(
            _DetailData(
              item: detail,
              sourceName: entry.descriptor.name,
              chapters: _data.chapters,
              supportsContent: entry.supports(SourceCapability.content),
            ),
            generation,
          );
          unawaited(
            ref
                .read(libraryRepositoryProvider)
                .cacheItem(detail)
                .catchError((Object _) {}),
          );
        } catch (error) {
          if (mounted && generation == _generation && !owner.cancelled) {
            setState(() => _metadataError = _describe(error, entry));
          }
        }
      });
      // Directory reads are independent: metadata failure must not suppress
      // an otherwise available cached/live reader directory.
      if (item.type != MediaType.anime) {
        final directory = _loadReaderDirectory(item, entry, generation);
        await Future.wait([metadata, directory]);
      } else {
        await metadata;
      }
    } catch (error) {
      if (mounted && generation == _generation && !owner.cancelled) {
        setState(() {
          _metadataError = '$error';
          if (item.type != MediaType.anime) _directoryError = '$error';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _metadataBusy = false);
      }
    }
    return _data;
  }

  Future<void> _loadReaderDirectory(
    MediaItem item,
    SourceEntry entry,
    int generation,
  ) async {
    _directoryBusy = true;
    _directoryError = null;
    try {
      final chapters = await _metadataOwner!.run(
        () => (entry.source as DetailProvider).chapters(item),
      );
      if (!mounted || generation != _generation) return;
      _publish(
        _DetailData(
          item: _data.item,
          sourceName: entry.descriptor.name,
          chapters: chapters,
          supportsContent: entry.supports(SourceCapability.content),
        ),
        generation,
      );
      unawaited(
        ref
            .read(libraryRepositoryProvider)
            .saveChapters(
              itemSourceId: item.sourceId,
              itemRemoteId: item.remoteId,
              chapters: chapters,
            )
            .catchError((Object _) {}),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _directoryError = _describe(error, entry));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _directoryBusy = false);
      }
    }
  }

  Future<void> _chooseSource() async {
    final selected = await showAnimeSources(context, _data.item ?? widget.item);
    if (!mounted || selected == null) return;
    await _loadPlayback(selected);
    if (!mounted || _playback?.item?.sourceId != selected.sourceId ||
        _playback?.item?.remoteId != selected.remoteId ||
        _playback!.chapters.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: EpisodeSelector(
            chapters: _playback!.chapters,
            currentIndex: _playback!.chapters.indexWhere(
              (chapter) => chapter.remoteId == _selectedEpisodeId,
            ),
            onSelected: (index) {
              final playback = _playback!;
              Navigator.pop(sheetContext);
              _ChapterSection(
                item: playback.item,
                chapters: playback.chapters,
                supportsContent: true,
                onSelected: (id) => setState(() => _selectedEpisodeId = id),
              )._openChapter(context, index);
            },
          ),
        ),
      ),
    );
  }

  Future<void> _loadPlayback(
    MediaItem item, {
    String? preferredChapterId,
  }) async {
    final generation = ++_directoryGeneration;
    _directoryOwner?.cancel();
    final owner = _directoryOwner = SourceRequestCancellation();
    setState(() {
      _directoryBusy = true;
      _directoryError = null;
      _playback = _DetailData(item: item, sourceName: item.sourceId);
      _selectedEpisodeId = preferredChapterId;
    });
    final library = ref.read(libraryRepositoryProvider);
    try {
      final cachedItem =
          await library.itemByKey(item.sourceId, item.remoteId) ?? item;
      final cachedChapters = await library.loadChapters(
        item.sourceId,
        item.remoteId,
      );
      final history = await library.lastReadOf(item.sourceId, item.remoteId);
      if (!mounted || generation != _directoryGeneration) return;
      setState(() {
        _selectedEpisodeId = preferredChapterId ?? history?.chapterRemoteId;
        _playback = _DetailData(
          item: cachedItem,
          chapters: cachedChapters,
          offline: true,
        );
      });
      await owner.run(() async {
        final snapshot = await ref.read(sourcesProvider.future);
        final entry = snapshot.enabledEntries
            .where((e) => e.descriptor.id == item.sourceId)
            .firstOrNull;
        if (entry == null ||
            entry.descriptor.type != MediaType.anime ||
            item.type != MediaType.anime ||
            !entry.supports(SourceCapability.content) ||
            entry.source is! DetailProvider) {
          throw StateError('该播放来源已停用或不支持播放');
        }
        final source = entry.source as DetailProvider;
        // A playable provider may need hidden playlist ids from its detail.
        final detail = await source.detail(cachedItem);
        if (detail.sourceId != item.sourceId || detail.remoteId != item.remoteId ||
            detail.type != MediaType.anime) {
          throw StateError('播放来源返回的作品身份不一致');
        }
        final chapters = await source.chapters(detail);
        if (chapters.any((chapter) => chapter.sourceId != item.sourceId)) {
          throw StateError('播放目录包含其他来源的剧集');
        }
        if (!mounted || owner.cancelled || generation != _directoryGeneration) {
          return;
        }
        setState(() {
          _playback = _DetailData(
            item: detail,
            sourceName: entry.descriptor.name,
            chapters: chapters,
          );
          final subject = _data.item;
          if (subject?.sourceId == detail.sourceId &&
              subject?.remoteId == detail.remoteId) {
            _data = _DetailData(
              item: detail,
              sourceName: entry.descriptor.name,
              supportsContent: false,
            );
          }
        });
        await library.cacheItem(detail);
        if (owner.cancelled || generation != _directoryGeneration) return;
        await library.saveChapters(
          itemSourceId: detail.sourceId,
          itemRemoteId: detail.remoteId,
          chapters: chapters,
        );
      });
    } catch (error) {
      if (mounted && generation == _directoryGeneration && !owner.cancelled) {
        final message = error is SourceException
            ? error.userMessage
            : SourceException.sanitizeMessage('$error');
        setState(() => _directoryError = '获取播放目录失败：$message');
      }
    } finally {
      if (mounted && generation == _directoryGeneration) {
        setState(() => _directoryBusy = false);
      }
    }
  }

  Future<_DetailData?> _loadFromCache({
    String sourceName = '',
    MediaItem? fallbackItem,
  }) async {
    final item = fallbackItem ?? widget.item;
    try {
      final library = ref.read(libraryRepositoryProvider);
      final storedItem = await library.itemByKey(item.sourceId, item.remoteId);
      if (storedItem != null && storedItem.type != item.type) return null;
      final chapters = await library.loadChapters(item.sourceId, item.remoteId);
      return _DetailData(
        item: storedItem ?? fallbackItem ?? item,
        sourceName: sourceName,
        chapters: chapters,
        offline: storedItem != null || chapters.isNotEmpty,
        supportsContent: item.sourceId != 'bangumi-anime',
      );
    } catch (_) {
      return null;
    }
  }

  String _describe(Object error, SourceEntry entry) => error is SourceException
      ? (widget.item.type == MediaType.anime
            ? '${entry.descriptor.name}：${error.userMessage}，可以重试或选择其他播放来源'
            : SourceRegistry.describeError(error, entry.descriptor.name))
      : '${entry.descriptor.name}：$error';

  // ---------------------------------------------------------------- 整书导出

  /// 下载整本可读章节（漫画存图片、小说存正文；锁定章节自动跳过）。
  Future<void> _downloadOffline() async {
    if (widget.item.sourceId == 'local-comic') {
      _toast('本地漫画无需网络下载；图片缺失时请恢复包含媒体的备份或重新导入原始文件');
      return;
    }
    if (widget.item.sourceId == LnsSource.id) {
      await _showLnsDownloadPermission();
      return;
    }
    final data = widget.item.type == MediaType.anime
        ? _playback ?? _data
        : await (_future ?? _load());
    if (!mounted) return;
    final item = data.item;
    if (item == null || data.chapters.isEmpty) {
      _toast('还没有拿到章节目录，无法下载');
      return;
    }
    var downloadable = data.chapters
        .where((chapter) => !chapter.locked)
        .toList();
    if (downloadable.isEmpty) {
      _toast('目录里没有可下载的章节（全部为锁定章节）');
      return;
    }
    if (item.type == MediaType.anime) {
      final selected = await _selectAnimeDownloads(data.chapters);
      if (!mounted || selected == null || selected.isEmpty) return;
      downloadable = selected;
    }

    final lockedCount = data.chapters.where((chapter) => chapter.locked).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载到本地'),
        content: Text(
          '将下载 ${downloadable.length} 章'
          '${lockedCount == 0 ? '' : '（跳过 $lockedCount 个锁定章节）'}。\n'
          '${switch (item.type) {
            MediaType.novel => '小说正文会存进本地数据库。',
            MediaType.anime => '剧集视频会存到应用目录（只下明文线路）。',
            MediaType.manga => '漫画图片会存到应用目录。',
          }}\n'
          '下载在后台进行，可在「我的 → 下载管理」查看进度。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final queued = await ref
        .read(downloadsProvider.notifier)
        .enqueue(
          item: item,
          chapters: data.chapters,
          selectedChapterIds: downloadable.map((c) => c.remoteId).toSet(),
        );
    _toast('已加入下载队列：$queued 章');
  }

  Future<List<Chapter>?> _selectAnimeDownloads(List<Chapter> chapters) {
    final lists = chapters.map((c) => c.volumeTitle ?? '默认列表').toSet().toList();
    var selectedList = lists.first;
    final selected = <String>{};
    return showDialog<List<Chapter>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('选择播放列表和下载剧集'),
          content: SizedBox(
            width: 440,
            height: 440,
            child: Column(
              children: [
                DropdownButton<String>(
                  value: selectedList,
                  isExpanded: true,
                  items: [
                    for (final list in lists)
                      DropdownMenuItem(value: list, child: Text(list)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      update(() {
                        selectedList = value;
                        selected.clear();
                      });
                    }
                  },
                ),
                TextButton(
                  onPressed: () => update(() {
                    selected.addAll(
                      chapters
                          .where(
                            (c) =>
                                !c.locked &&
                                (c.volumeTitle ?? '默认列表') == selectedList,
                          )
                          .map((c) => c.remoteId),
                    );
                  }),
                  child: const Text('选择此列表全部未锁剧集'),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final chapter in chapters.where(
                        (c) => (c.volumeTitle ?? '默认列表') == selectedList,
                      ))
                        CheckboxListTile(
                          title: Text(chapter.title),
                          value: selected.contains(chapter.remoteId),
                          subtitle: chapter.locked
                              ? const Text('锁定，不可下载')
                              : null,
                          onChanged: chapter.locked
                              ? null
                              : (value) => update(() {
                                  if (value == true) {
                                    selected.add(chapter.remoteId);
                                  } else {
                                    selected.remove(chapter.remoteId);
                                  }
                                }),
                        ),
                    ],
                  ),
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
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      chapters
                          .where((c) => selected.contains(c.remoteId))
                          .toList(),
                    ),
              child: Text('下载 ${selected.length} 集'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export({required bool epub}) async {
    if (widget.item.sourceId == LnsSource.id) {
      await _showLnsDownloadPermission();
      return;
    }
    final data = await (_future ?? _load());
    if (!mounted) return;
    final item = data.item;
    if (item == null || data.chapters.isEmpty) {
      _toast('还没有拿到章节目录，无法导出');
      return;
    }
    if (item.type != MediaType.novel) {
      _toast('整书导出目前只支持小说');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(epub ? '正在导出 EPUB' : '正在导出 TXT'),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('准备正文中，已下载章节无需联网，锁定章节会自动跳过…'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == item.sourceId)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ContentProvider) {
        throw StateError('来源没有正文能力');
      }
      final directoryUri = await platformChannel.pickDirectory();
      final result = epub
          ? await NovelExportService.exportEpub(
              item: item,
              chapters: data.chapters,
              source: provider,
              localContent: (chapter) => ref
                  .read(downloadRepositoryProvider)
                  .localChapterContent(chapter.sourceId, chapter.remoteId),
              http: ref.read(sourceHttpClientProvider),
              onProgress: (completed, total) {},
              directoryUri: directoryUri,
              writeToTree: (uri, fileName, bytes) async {
                // D49：返回系统真实 document URI；null/空 → 服务层回退。
                return await platformChannel.writeToTree(
                      uri,
                      fileName,
                      Uint8List.fromList(bytes),
                      mime: 'application/epub+zip',
                    ) ??
                    '';
              },
            )
          : await NovelExportService.exportTxt(
              item: item,
              chapters: data.chapters,
              source: provider,
              localContent: (chapter) => ref
                  .read(downloadRepositoryProvider)
                  .localChapterContent(chapter.sourceId, chapter.remoteId),
              onProgress: (completed, total) {},
              directoryUri: directoryUri,
              writeToTree: (uri, fileName, bytes) async {
                return await platformChannel.writeToTree(
                      uri,
                      fileName,
                      Uint8List.fromList(bytes),
                      mime: 'text/plain',
                    ) ??
                    '';
              },
            );
      if (!mounted) return;
      navigator.pop();
      // D50：显式区分保存位置——授权目录成功 / 用户取消目录选择 /
      // 授权目录写入失败回退；回退是导出成功，不得报成导出失败。
      final location = result.savedToAuthorizedDirectory
          ? '已保存到授权目录'
          : (directoryUri == null
                ? '未选择授权目录，已保存到应用导出目录'
                : '授权目录写入失败，已保存到应用导出目录');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '导出完成：${result.exportedChapters} 章'
            '（跳过 ${result.skippedChapters}，含锁定章节）\n'
            '$location\n${result.path}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openRuleSession() async {
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final source = snapshot.enabledEntries
          .where(
            (e) => e.descriptor.id == (_playback?.item ?? widget.item).sourceId,
          )
          .firstOrNull
          ?.source;
      if (source is! KazumiSource) {
        _toast('来源已停用或没有可见验证能力');
        return;
      }
      final saved = await source.openWebSession();
      if (!mounted || !saved) return;
      final selected = _playback?.item;
      if (selected != null) {
        await _loadPlayback(selected);
      } else {
        final refreshed = _load();
        setState(() { _future = refreshed; });
      }
    } catch (_) {
      _toast('当前平台无法打开站点验证；未宣称验证成功');
    }
  }

  Future<void> _copyToSource() async {
    final target = await Navigator.of(context).push<MediaItem>(
      MaterialPageRoute(builder: (_) => SourceMigrationPage(item: widget.item)),
    );
    if (!mounted || target == null) return;
    _toast('已复制到本地书架：${target.title}');
    unawaited(context.push(AppRoutes.detailFor(target), extra: target));
  }

  Future<void> _showLnsDownloadPermission() async {
    var status = '暂时无法核实这本书的站点下载权限。';
    try {
      final sources = await ref.read(sourcesProvider.future);
      final source = sources.entries
          .where((e) => e.descriptor.id == LnsSource.id)
          .firstOrNull
          ?.source;
      if (source is LnsSource) {
        final permission = await source.officialDownloadPermission(widget.item);
        status = switch (permission.canDownload) {
          false => '上传者或管理员未开放这本书的文件下载。',
          true =>
            permission.downloadCost == null
                ? '站点已开放文件下载，实际费用请以站点确认页为准。'
                : '站点已开放文件下载，费用 ${permission.downloadCost} 金币。',
          null => '站点没有返回这本书的文件下载权限，不能据此认定可免费下载。',
        };
      }
    } catch (_) {}
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('轻书架站点下载'),
        content: Text(
          '$status\n\n整书 EPUB 请在轻书架网站确认费用并下载。已有正文缓存仍可离线阅读，暂不支持在应用内导出整书。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final item = data.item ?? widget.item;
    final playable = item.type == MediaType.anime ? _playback : data;
    return PageScaffold(
      title: item.title,
      actions: [
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) {
            switch (value) {
              case 'reload':
                final refreshed = _load();
                setState(() { _future = refreshed; });
              case 'download':
                unawaited(_downloadOffline());
              case 'epub':
                unawaited(_export(epub: true));
              case 'txt':
                unawaited(_export(epub: false));
              case 'site':
                unawaited(_openRuleSession());
              case 'merge':
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => MergedMangaPage(anchor: item),
                  ),
                );
              case 'copy':
                unawaited(_copyToSource());
              case 'tracking':
                unawaited(showTrackingBindSheet(context, item));
              case 'info':
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => AnimeInfoSheet(id: item.remoteId),
                );
              case 'local-favorite':
                showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (_) => SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: _FollowButton(item: item),
                    ),
                  ),
                );
              default:
                final kind = TrackingServiceKind.values
                    .where((kind) => 'sync:${kind.name}' == value)
                    .firstOrNull;
                if (kind != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => TrackingSyncPage(item: item, kind: kind),
                    ),
                  );
                }
            }
          },
          itemBuilder: (_) => [
            if (item.sourceId == 'bangumi-anime')
              const PopupMenuItem(value: 'info', child: Text('完整番剧资料')),
            if (item.type == MediaType.anime)
              const PopupMenuItem(value: 'local-favorite', child: Text('本机收藏')),
            if (playable != null &&
                playable.supportsContent &&
                playable.chapters.isNotEmpty &&
                item.sourceId != 'local-comic')
              const PopupMenuItem(value: 'download', child: Text('下载到本地')),
            if (item.type == MediaType.novel) ...[
              if (item.sourceId == LnsSource.id)
                const PopupMenuItem(value: 'download', child: Text('查看站点下载权限'))
              else ...[
                const PopupMenuItem(value: 'epub', child: Text('导出 EPUB')),
                const PopupMenuItem(value: 'txt', child: Text('导出 TXT')),
              ],
            ],
            if (item.type == MediaType.manga)
              const PopupMenuItem(value: 'merge', child: Text('多来源合并')),
            if (item.type != MediaType.anime)
              const PopupMenuItem(value: 'copy', child: Text('复制到其他来源')),
            if ((_playback?.item ?? item).sourceId.startsWith('kazumi:'))
              const PopupMenuItem(value: 'site', child: Text('打开站点人工验证')),
            const PopupMenuItem(value: 'tracking', child: Text('追踪绑定')),
            for (final kind in TrackingServiceKind.values)
              PopupMenuItem(
                value: 'sync:${kind.name}',
                child: Text('${kind.label}同步预览'),
              ),
            const PopupMenuItem(value: 'reload', child: Text('重新补全资料')),
          ],
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          if (item.type == MediaType.anime)
            _AnimeHero(item: item, onPlay: _continueAnime)
          else
            _Header(data: data),
          if (_metadataBusy)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('补全资料'),
            ),
          if (_metadataError != null)
            ListTile(
              title: Text(_metadataError!),
              trailing: TextButton(
                onPressed: () {
                  final refreshed = _load();
                  setState(() { _future = refreshed; });
                },
                child: const Text('重试资料'),
              ),
            ),
          if (item.type == MediaType.anime) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Text('播放'),
            ),
            ListTile(
              title: Text(
                _playback?.sourceName.isNotEmpty == true
                    ? _playback!.sourceName
                    : '尚未选择播放来源',
              ),
              subtitle: _playback?.item == null
                  ? null
                  : Text(_playback!.item!.title),
              trailing: TextButton(
                onPressed: _chooseSource,
                child: Text(_playback == null ? '选择来源' : '更换来源'),
              ),
            ),
          ],
          if (_directoryBusy)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('获取目录'),
            ),
          if (_directoryError != null)
            ListTile(
              title: Text(_directoryError!),
              trailing: TextButton(
                onPressed: () {
                  if (_playback?.item case final selected?) {
                    unawaited(_loadPlayback(selected));
                  } else {
                    final refreshed = _load();
                    setState(() { _future = refreshed; });
                  }
                },
                child: const Text('重试目录'),
              ),
            ),
          if (data.offline && !_metadataBusy)
            const ListTile(
              leading: Icon(Icons.offline_pin_outlined),
              title: Text('显示本机缓存；刷新失败不会清除已缓存资料或目录'),
            ),
          if (playable != null)
            _ChapterSection(
              item: playable.item,
              chapters: playable.chapters,
              supportsContent: playable.supportsContent,
              loadError: _directoryBusy ? '正在获取目录' : _directoryError,
              selectedChapterId: item.type == MediaType.anime
                  ? _selectedEpisodeId
                  : null,
              onSelected: item.type == MediaType.anime
                  ? (id) => setState(() => _selectedEpisodeId = id)
                  : null,
            ),
          if (item.sourceId == 'bangumi-anime')
            AnimeInfoSheet(
              key: ValueKey('anime-info:${item.remoteId}'),
              id: item.remoteId,
              item: item,
              overview: _animeOverview,
              embedded: true,
            )
          else if (item.description?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(item.description!),
            ),
          if (item.type == MediaType.manga && item.sourceId != 'local-comic')
            MangaRelatedSection(item: item),
          if (item.type == MediaType.novel && item.sourceId != 'local-comic')
            BookCommentsSection(item: item),
        ],
      ),
    );
  }

  Future<void> _continueAnime() async {
    if (_playback == null || _playback!.chapters.isEmpty) {
      await _chooseSource();
      return;
    }
    final data = _playback!;
    final item = data.item!;
    final history = await ref
        .read(libraryRepositoryProvider)
        .lastReadOf(item.sourceId, item.remoteId);
    if (!mounted) return;
    var index = data.chapters.indexWhere(
      (chapter) =>
          chapter.remoteId ==
              (_selectedEpisodeId ?? history?.chapterRemoteId) &&
          !chapter.locked,
    );
    if (index < 0) {
      index = data.chapters.indexWhere((chapter) => !chapter.locked);
    }
    if (index < 0) {
      _toast('当前目录没有可播放的未锁剧集');
      return;
    }
    _ChapterSection(
      item: item,
      chapters: data.chapters,
      supportsContent: true,
    )._openChapter(context, index);
  }
}

class _DetailData {
  const _DetailData({
    this.item,
    this.sourceName = '',
    this.chapters = const <Chapter>[],
    this.offline = false,
    this.supportsContent = true,
  });

  final MediaItem? item;
  final String sourceName;
  final List<Chapter> chapters;

  /// 来源取数失败、改用本地缓存渲染（下载过的作品断网仍可进入阅读）。
  final bool offline;
  final bool supportsContent;
}

class _AnimeHero extends StatelessWidget {
  const _AnimeHero({required this.item, required this.onPlay});
  final MediaItem item;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 104, height: 156, child: MediaCover(url: item.coverUrl)),
        ),
        const SizedBox(width: 16),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title, style: Theme.of(context).textTheme.titleLarge),
            if (item.status?.isNotEmpty == true) Text(item.status!),
            if (item.rating != null) Text('★ ${item.rating!.toStringAsFixed(1)} · Bangumi'),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: onPlay, icon: const Icon(Icons.play_arrow), label: const Text('开始 / 继续观看')),
            const SizedBox(height: 4),
            AnimeCollectionButton(item: item),
          ],
        )),
      ],
    ),
  );
}

class _Header extends ConsumerWidget {
  const _Header({required this.data});

  final _DetailData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final item = data.item;
    if (item == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: AppRadius.cardRadius,
            child: SizedBox(
              width: 120,
              height: 180,
              child: MediaCover(url: item.coverUrl),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  <String>[
                    if (data.sourceName.isNotEmpty) data.sourceName,
                    if (item.author != null && item.author!.isNotEmpty)
                      item.author!,
                    if (item.status != null && item.status!.isNotEmpty)
                      item.status!,
                  ].join('  ·  '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.mutedForeground,
                  ),
                ),
                if (item.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.xxs,
                    runSpacing: AppSpacing.xxs,
                    children: <Widget>[
                      for (final tag in item.tags)
                        ActionChip(
                          label: Text(tag),
                          onPressed: () => SearchPage.open(
                            context,
                            type: item.type,
                            sourceId: item.sourceId,
                            sourceOnly: true,
                            tags: [tag],
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                _FollowButton(item: item),
                if (data.chapters.isNotEmpty && data.supportsContent)
                  FutureBuilder(
                    future: ref
                        .read(libraryRepositoryProvider)
                        .lastReadOf(item.sourceId, item.remoteId),
                    builder: (context, snapshot) {
                      final index = data.chapters.indexWhere(
                        (c) => c.remoteId == snapshot.data?.chapterRemoteId,
                      );
                      final startIndex = index < 0 ? 0 : index;
                      return FilledButton.tonalIcon(
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                          '${index < 0 ? '开始' : '继续'}${item.type == MediaType.anime ? '观看' : '阅读'} · ${data.chapters[startIndex].title}',
                        ),
                        onPressed: () => _ChapterSection(
                          item: item,
                          chapters: data.chapters,
                          supportsContent: true,
                        )._openChapter(context, startIndex),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterSection extends StatelessWidget {
  const _ChapterSection({
    required this.item,
    required this.chapters,
    required this.supportsContent,
    this.loadError,
    this.selectedChapterId,
    this.onSelected,
  });

  final MediaItem? item;
  final List<Chapter> chapters;
  final bool supportsContent;

  /// 详情/目录加载失败的原因（null 表示请求成功）。空目录是否可操作
  /// 取决于它：成功但空 → 引导搜索；失败 → 不把失败伪装成空目录。
  final String? loadError;
  final String? selectedChapterId;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    if (item?.type == MediaType.anime &&
        supportsContent &&
        chapters.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: EpisodeSelector(
          key: ValueKey(
            '${item?.sourceId}:${item?.remoteId}:$selectedChapterId',
          ),
          currentIndex: chapters.indexWhere(
            (chapter) => chapter.remoteId == selectedChapterId,
          ),
          chapters: chapters,
          onSelected: (index) => _openChapter(context, index),
        ),
      );
    }

    if (chapters.isEmpty) {
      // D94：请求成功但目录为空（如该来源还没有中文章节）→ 明确说明并
      // 允许去搜索同来源的其他作品；绝不伪造章节，也不把失败说成空目录。
      if (loadError == null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            0,
          ),
          child: AppCard(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('当前中文目录为空', style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '请求成功了，但这个来源暂时没有这本作品的中文章节。可以去搜索同来源的其他作品。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.mutedForeground,
                    ),
                  ),
                  if (item != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: () => SearchPage.open(
                        context,
                        type: item!.type,
                        sourceId: item!.sourceId,
                      ),
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('搜索其他作品'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          0,
        ),
        child: Text(
          '未能取得章节目录（原因见上方错误）。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: palette.mutedForeground,
          ),
        ),
      );
    }

    return _ChapterCatalog(
      chapters: chapters,
      canOpen: item?.type != MediaType.anime || supportsContent,
      onSelected: (index) => _openChapter(context, index),
    );
  }

  /// 打开章节：漫画 → 漫画阅读器、番剧 → 播放器、小说 → 正文阅读器。
  void _openChapter(BuildContext context, int index) {
    final target = item;
    if (target == null || index < 0 || index >= chapters.length) return;
    if (target.type == MediaType.anime &&
        (!supportsContent || chapters[index].locked ||
            chapters[index].sourceId != target.sourceId)) {
      return;
    }
    onSelected?.call(chapters[index].remoteId);

    if (target.type == MediaType.manga) {
      context.push(
        AppRoutes.reader,
        extra: MangaReaderArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    if (target.type == MediaType.anime) {
      context.push(
        AppRoutes.player,
        extra: PlayerArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    context.push(
      AppRoutes.novelReader,
      extra: NovelReaderArgs(
        item: target,
        chapters: chapters,
        initialIndex: index,
      ),
    );
  }
}

/// Render one bounded chapter range while retaining original reader indices.
class _ChapterCatalog extends StatefulWidget {
  const _ChapterCatalog({
    required this.chapters,
    required this.canOpen,
    required this.onSelected,
  });
  final List<Chapter> chapters;
  final bool canOpen;
  final ValueChanged<int> onSelected;

  @override
  State<_ChapterCatalog> createState() => _ChapterCatalogState();
}

class _ChapterCatalogState extends State<_ChapterCatalog> {
  static const _pageSize = 50;
  final _groups = <String, List<int>>{};
  String? _volume;
  int _range = 0;

  void _group() {
    _groups.clear();
    for (var i = 0; i < widget.chapters.length; i++) {
      _groups
          .putIfAbsent(widget.chapters[i].volumeTitle ?? '', () => [])
          .add(i);
    }
    if (!_groups.containsKey(_volume)) {
      _volume = _groups.keys.first;
      _range = 0;
    }
    _range = _range.clamp(0, (_groups[_volume]!.length - 1) ~/ _pageSize);
  }

  @override
  void initState() {
    super.initState();
    _group();
  }

  @override
  void didUpdateWidget(_ChapterCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chapters, widget.chapters)) _group();
  }

  @override
  Widget build(BuildContext context) {
    final indices = _groups[_volume]!;
    final ranges = (indices.length + _pageSize - 1) ~/ _pageSize;
    final start = _range * _pageSize;
    final end = (start + _pageSize).clamp(0, indices.length);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '目录（${widget.chapters.length}）',
            style: theme.textTheme.titleMedium,
          ),
          if (!widget.canOpen)
            const Text(
              '此来源只提供番剧资料与目录，不提供播放地址；请导入具有 content.playSources 的番剧规则。',
            ),
          if (_groups.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _volume,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '分卷'),
              items: [
                for (final entry in _groups.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      '${entry.key.isEmpty ? '未分卷' : entry.key} · ${entry.value.length}章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() {
                _volume = value;
                _range = 0;
              }),
            )
          else if (_volume!.isNotEmpty)
            Text(_volume!, style: theme.textTheme.titleSmall),
          if (ranges > 1)
            DropdownButtonFormField<int>(
              key: ValueKey(_volume),
              initialValue: _range,
              decoration: const InputDecoration(labelText: '章节范围'),
              items: [
                for (var page = 0; page < ranges; page++)
                  DropdownMenuItem(
                    value: page,
                    child: Text(
                      '${page * _pageSize + 1}–${((page + 1) * _pageSize).clamp(1, indices.length)}',
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _range = value);
              },
            ),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var offset = start; offset < end; offset++) ...[
                  if (offset > start)
                    const Divider(height: 1, indent: AppSpacing.md),
                  ListTile(
                    dense: true,
                    title: Text(widget.chapters[indices[offset]].title),
                    trailing: widget.chapters[indices[offset]].locked
                        ? const Icon(Icons.lock_outline, size: 18)
                        : const Icon(Icons.chevron_right, size: 18),
                    onTap: !widget.canOpen
                        ? null
                        : () => widget.onSelected(indices[offset]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 加入 / 移出书架。
class _FollowButton extends ConsumerStatefulWidget {
  const _FollowButton({required this.item});

  final MediaItem item;

  @override
  ConsumerState<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends ConsumerState<_FollowButton> {
  bool _busy = false;
  MediaItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    if (item.type == MediaType.novel) return NovelCollectionButton(item: item);
    final anime = item.type == MediaType.anime;
    final identity = anime ? ref.watch(animeSubjectProvider(item)) : null;
    if (identity != null && !identity.hasValue) {
      return identity.hasError
          ? TextButton(
              onPressed: () => ref.invalidate(animeSubjectProvider(item)),
              child: const Text('重试作品身份'),
            )
          : const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
    }
    final followedItem = identity?.value ?? item;
    final membership = ref.watch(
      inLibraryProvider((
        sourceId: followedItem.sourceId,
        remoteId: followedItem.remoteId,
      )),
    );

    if (membership.isLoading || _busy) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (membership.hasError) {
      return OutlinedButton.icon(
        onPressed: () => ref.invalidate(
          inLibraryProvider((
            sourceId: followedItem.sourceId,
            remoteId: followedItem.remoteId,
          )),
        ),
        icon: const Icon(Icons.refresh),
        label: const Text('重试收藏状态'),
      );
    }

    if (membership.value ?? false) {
      return OutlinedButton.icon(
        onPressed: () => _setMembership(context, ref, add: false),
        icon: const Icon(Icons.check, size: 18),
        label: Text(anime ? '已在本机收藏 · 移除' : '已在书架'),
      );
    }

    return FilledButton.icon(
      onPressed: () => _setMembership(context, ref, add: true),
      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
      label: Text(anime ? '加入本机收藏' : '加入书架'),
    );
  }

  Future<void> _setMembership(
    BuildContext context,
    WidgetRef ref, {
    required bool add,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repository = ref.read(libraryRepositoryProvider);
      final followedItem = item.type == MediaType.anime
          ? await ref.read(animeIdentityRepositoryProvider).subjectFor(item) ??
                item
          : item;
      final anime = item.type == MediaType.anime;
      if (add) {
        if (anime) {
          await addAnimeFollow(ref, followedItem);
        } else {
          await repository.addToLibrary(item);
        }
      } else if (anime) {
        await removeAnimeFollow(ref, followedItem);
      } else {
        await repository.removeFromLibrary(
          followedItem.sourceId,
          followedItem.remoteId,
        );
      }
      if (!mounted) return;
      ref.invalidate(inLibraryProvider);
      ref.invalidate(libraryByTypeProvider(item.type));
      ref.invalidate(animeFollowsProvider);
      // 站点收藏尽力而为：来源支持远端书架且已登录时才写，失败只提示不回滚本地。
      String? syncFailure;
      if (!anime) {
        final snapshot = await ref.read(sourcesProvider.future);
        syncFailure = await syncShelfToSource(snapshot, item: item, add: add);
      }
      if (!context.mounted) return;
      final action = anime
          ? (add ? '已加入本机收藏' : '已移除本机收藏')
          : (add ? '已加入书架' : '已移出书架');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            syncFailure == null ? action : '$action（站点同步失败：$syncFailure）',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('收藏操作失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
