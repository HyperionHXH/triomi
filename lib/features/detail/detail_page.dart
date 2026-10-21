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
import '../discover/widgets/media_item_card.dart';
import '../downloads/data/download_providers.dart';
import '../downloads/data/download_repository.dart';
import '../library/data/anime_identity_repository.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../library/merged_manga_page.dart';
import '../library/source_migration_page.dart';
import '../manga/manga_item_actions.dart';
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
import 'chapter_download_picker.dart';
import 'manga_related_section.dart';

part 'detail_presentations.dart';
part 'detail_catalog.dart';

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
  int _readRevision = 0;
  bool _metadataBusy = false, _directoryBusy = false;
  String? _selectedEpisodeId;
  String? _metadataError, _directoryError;
  Map<String, Object?>? _animeOverview;
  String _animeSection = 'info';
  final _scrollController = ScrollController();

  void _selectAnimeSection(String section) {
    setState(() => _animeSection = section);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

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
    _scrollController.dispose();
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
        preferredChapterId:
            selected?.item.sourceId == widget.item.sourceId &&
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

  Future<_DetailData> _load({bool refresh = false}) async {
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
          () => ref
              .read(animeInfoRepositoryProvider)
              .section(item.remoteId, 'info', refresh: refresh),
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
      if (entry == null) throw StateError('该来源已移除');
      if (entry.descriptor.type != item.type) throw StateError('来源不属于当前工作区');
      _publish(
        _DetailData(
          item: _data.item ?? item,
          sourceName: entry.descriptor.name,
          chapters: _data.chapters,
          offline: _data.offline,
          supportsContent: _data.supportsContent,
        ),
        generation,
      );
      if (!entry.enabled) throw StateError('该来源已停用');
      final provider = entry.source;
      if (provider is! DetailProvider) throw StateError('来源不支持详情');
      var detail = item;
      final metadata = owner.run(() async {
        try {
          detail = await provider.detail(item.sourceSnapshot);
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
        () => (entry.source as DetailProvider).chapters(item.sourceSnapshot),
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
    if (!mounted ||
        _playback?.item?.sourceId != selected.sourceId ||
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
              unawaited(
                _ChapterSection(
                  item: playback.item,
                  chapters: playback.chapters,
                  supportsContent: true,
                  onSelected: (id) => setState(() => _selectedEpisodeId = id),
                )._openChapter(context, index),
              );
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
        final detail = await source.detail(cachedItem.sourceSnapshot);
        if (detail.sourceId != item.sourceId ||
            detail.remoteId != item.remoteId ||
            detail.type != MediaType.anime) {
          throw StateError('播放来源返回的作品身份不一致');
        }
        final chapters = await source.chapters(detail.sourceSnapshot);
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

  // Download selected readable chapters; whole-book file downloads remain a
  // separate, source-owned permission flow (notably for LNS).
  Future<void> _downloadOffline() async {
    if (widget.item.sourceId == 'local-comic') {
      _toast('本地漫画无需网络下载；图片缺失时请恢复包含媒体的备份或重新导入原始文件');
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
    final catalogGeneration = item.type == MediaType.anime
        ? _directoryGeneration
        : _generation;
    final origin = ref
        .read(sourcesProvider)
        .asData
        ?.value
        .enabledEntries
        .where(
          (entry) =>
              entry.descriptor.id == item.sourceId &&
              entry.descriptor.type == item.type &&
              entry.supports(SourceCapability.content),
        )
        .firstOrNull;
    if (origin == null || !data.supportsContent) {
      _toast('当前来源不可下载，请启用来源并刷新目录后再试');
      return;
    }
    final unit = item.type == MediaType.anime ? '集' : '章';
    final downloadable = await showChapterDownloadPicker(
      context,
      item: item,
      chapters: data.chapters,
      supportsContent: data.supportsContent,
    );
    if (!mounted || downloadable == null || downloadable.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          item.type == MediaType.novel
              ? '缓存所选章节'
              : '下载所选${item.type == MediaType.anime ? '剧集' : '章节'}',
        ),
        content: Text(
          '将下载 ${downloadable.length} $unit。\n'
          '${switch (item.type) {
            MediaType.novel => '小说正文（含来源要求的字体）会存进本地数据库。',
            MediaType.anime => '剧集视频会存到应用目录（只下明文线路）。',
            MediaType.manga => '漫画图片会存到应用目录。',
          }}\n'
          '锁定章节不会入队；下载在后台进行，可在「下载管理」查看进度。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('detail-download-start'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final snapshot = await ref.read(sourcesProvider.future);
    if (!mounted) return;
    final current = item.type == MediaType.anime ? _playback : _data;
    if (catalogGeneration !=
            (item.type == MediaType.anime
                ? _directoryGeneration
                : _generation) ||
        current?.item?.sourceId != item.sourceId ||
        current?.item?.remoteId != item.remoteId ||
        !identical(current?.chapters, data.chapters) ||
        !snapshot.enabledEntries.any(
          (entry) =>
              entry.descriptor.id == item.sourceId &&
              entry.descriptor.type == item.type &&
              entry.supports(SourceCapability.content) &&
              identical(entry.source, origin.source),
        )) {
      _toast('来源或目录已改变，请重新选择下载章节');
      return;
    }
    final queued = await ref
        .read(downloadsProvider.notifier)
        .enqueue(
          item: item,
          chapters: data.chapters,
          selectedChapterIds: downloadable,
        );
    _toast('已加入下载队列：$queued $unit');
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
        final refreshed = _load(refresh: true);
        setState(() {
          _future = refreshed;
        });
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
          '$status\n\n整书 EPUB 请在轻书架网站确认费用并下载；应用不代扣金币、不导出整书。逐章离线缓存请使用目录旁的「缓存章节」，仍受正常正文阅读权限限制。',
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

  void _refreshDetails() {
    final refreshed = _load(refresh: true);
    setState(() {
      _future = refreshed;
    });
    if (widget.item.type == MediaType.anime && _playback?.item != null) {
      unawaited(
        _loadPlayback(_playback!.item!, preferredChapterId: _selectedEpisodeId),
      );
    }
  }

  void _refreshReadHistory() {
    if (mounted) setState(() => _readRevision++);
  }

  @override
  Widget build(BuildContext context) {
    final rawItem = _data.item ?? widget.item;
    final metadata = rawItem.type == MediaType.manga
        ? ref.watch(
            mangaItemMetadataProvider((rawItem.sourceId, rawItem.remoteId)),
          )
        : null;
    final item = rawItem.type == MediaType.manga
        ? rawItem.withMangaMetadata(
            metadata?.asData?.value ?? rawItem.localMangaMetadata,
          )
        : rawItem;
    final data = _DetailData(
      item: item,
      sourceName: _data.sourceName,
      chapters: _data.chapters,
      offline: _data.offline,
      supportsContent: _data.supportsContent,
    );
    final playable = item.type == MediaType.anime ? _playback : data;
    final association = item.type == MediaType.anime
        ? ref.watch(animeSubjectProvider(item))
        : null;
    final associated = item.sourceId == 'bangumi-anime'
        ? item
        : association?.asData?.value;
    final commentSubject = associated?.sourceId == 'bangumi-anime' &&
            associated?.type == MediaType.anime &&
            (int.tryParse(associated?.remoteId ?? '') ?? 0) > 0
        ? associated
        : null;
    return PageScaffold(
      title: item.title,
      actions: [
        IconButton(
          tooltip: '刷新资料和目录',
          onPressed: _metadataBusy || _directoryBusy ? null : _refreshDetails,
          icon: const Icon(Icons.refresh),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (value) {
            switch (value) {
              case 'editManga':
                unawaited(showMangaMetadataEditor(context, ref, item));
              case 'epub':
                unawaited(_export(epub: true));
              case 'txt':
                unawaited(_export(epub: false));
              case 'officialDownload':
                unawaited(_showLnsDownloadPermission());
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
            if (item.type == MediaType.manga)
              const PopupMenuItem(value: 'editManga', child: Text('编辑漫画资料')),
            if (item.sourceId == 'bangumi-anime')
              const PopupMenuItem(value: 'info', child: Text('完整番剧资料')),
            if (item.type == MediaType.novel) ...[
              if (item.sourceId == LnsSource.id)
                const PopupMenuItem(
                  value: 'officialDownload',
                  child: Text('站点整书下载权限'),
                )
              else if (data.supportsContent && data.chapters.isNotEmpty) ...[
                const PopupMenuItem(value: 'epub', child: Text('导出 EPUB')),
                const PopupMenuItem(value: 'txt', child: Text('导出 TXT')),
              ],
            ],
            if (item.type == MediaType.manga) ...[
              const PopupMenuItem(value: 'merge', child: Text('多来源合并')),
              const PopupMenuItem(value: 'copy', child: Text('复制到其他来源')),
            ],
            if (item.type == MediaType.novel)
              const PopupMenuItem(value: 'copy', child: Text('更换来源')),
            if (item.type == MediaType.novel)
              const PopupMenuItem(value: 'tracking', child: Text('阅读追踪')),
            if ((_playback?.item ?? item).sourceId.startsWith('kazumi:'))
              const PopupMenuItem(value: 'site', child: Text('打开站点人工验证')),
            if (item.type != MediaType.novel) ...[
              const PopupMenuItem(value: 'tracking', child: Text('追踪绑定')),
              for (final kind in TrackingServiceKind.values)
                PopupMenuItem(
                  value: 'sync:${kind.name}',
                  child: Text('${kind.label}同步预览'),
                ),
            ],
          ],
        ),
      ],
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (item.type == MediaType.anime)
            SliverPersistentHeader(
              pinned: true,
              delegate: _AnimeDetailTabs(
                context: context,
                section: _animeSection,
                onSelected: _selectAnimeSection,
              ),
            ),
          if (item.type == MediaType.anime && _animeSection != 'info')
            SliverToBoxAdapter(
              child: commentSubject != null
                  ? AnimeInfoSheet(
                      key: ValueKey('anime-section:${commentSubject.remoteId}'),
                      id: commentSubject.remoteId,
                      item: commentSubject,
                      embedded: true,
                      showSectionSelector: false,
                      initialSection: _animeSection,
                    )
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(association?.isLoading == true
                              ? '正在读取 Bangumi 条目关联…'
                              : association?.hasError == true
                              ? 'Bangumi 条目关联读取失败，请重试。'
                              : '尚未关联 Bangumi 动画条目，不能确定这部作品的评论与评分。'),
                          if (association?.hasError == true)
                            TextButton(
                              onPressed: () => ref.invalidate(animeSubjectProvider(item)),
                              child: const Text('重试条目关联'),
                            ),
                          if (association?.isLoading != true) ...[
                            const SizedBox(height: 12),
                            const Text('在 Bangumi 搜索并打开正确季度的动画条目，再通过「选择来源」选择本站作品，即可保存关联。'),
                            TextButton.icon(
                              onPressed: () => SearchPage.open(context,
                                type: MediaType.anime, sourceId: 'bangumi-anime',
                                query: item.title),
                              icon: const Icon(Icons.search),
                              label: const Text('查找 Bangumi 动画条目'),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          if (item.type != MediaType.anime || _animeSection == 'info') ...[
          for (final section in <Widget>[
            if (item.type == MediaType.anime)
              _AnimeHero(
                item: item,
                onPlay: _continueAnime,
                onComments: () => _selectAnimeSection('comments'),
              )
            else if (item.type == MediaType.manga)
              _MangaHeader(
                data: data,
                historyRevision: _readRevision,
                onReturned: _refreshReadHistory,
              )
            else
              _NovelBookHeader(
                data: data,
                historyRevision: _readRevision,
                onReturned: _refreshReadHistory,
              ),
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
              _DetailLoadFailure(
                title: '资料暂不可用',
                error: _metadataError!,
                retryLabel: '重试资料',
                onRetry: () {
                  final refreshed = _load(refresh: true);
                  setState(() {
                    _future = refreshed;
                  });
                },
              ),
            if (item.type == MediaType.anime) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '播放来源',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _playback == null
                            ? '尚未选择播放来源'
                            : _playback!.sourceName.isNotEmpty
                            ? _playback!.sourceName
                            : '已选择播放来源',
                      ),
                      if (_playback?.item != null) Text(_playback!.item!.title),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _chooseSource,
                          icon: const Icon(Icons.video_library_outlined),
                          label: Text(_playback == null ? '选择来源' : '更换来源'),
                        ),
                      ),
                    ],
                  ),
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
              _DetailLoadFailure(
                title: '目录更新失败',
                error: _directoryError!,
                retryLabel: '重试目录',
                onRetry: () {
                  if (_playback?.item case final selected?) {
                    unawaited(_loadPlayback(selected));
                  } else {
                    final refreshed = _load(refresh: true);
                    setState(() {
                      _future = refreshed;
                    });
                  }
                },
              ),
            if (data.offline && !_metadataBusy)
              const ListTile(
                leading: Icon(Icons.offline_pin_outlined),
                title: Text('显示本机缓存；刷新失败不会清除已缓存资料或目录'),
              ),
          ])
            SliverToBoxAdapter(child: section),
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
              onDownload:
                  playable.supportsContent &&
                      playable.chapters.isNotEmpty &&
                      item.sourceId != 'local-comic'
                  ? _downloadOffline
                  : null,
              historyRevision: _readRevision,
              onReturned: _refreshReadHistory,
            ),
          for (final section in <Widget>[
            if (item.sourceId == 'bangumi-anime')
              AnimeInfoSheet(
                key: ValueKey('anime-info:${item.remoteId}'),
                id: item.remoteId,
                item: item,
                overview: _animeOverview,
                embedded: true,
                showSectionSelector: false,
              )
            else if (item.type == MediaType.anime &&
                item.description?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.all(16),
                child: _ExpandableSynopsis(text: item.description!),
              ),
            if (item.type == MediaType.manga && item.sourceId != 'local-comic')
              MangaRelatedSection(item: item),
            if (item.type == MediaType.novel && item.sourceId != 'local-comic')
              BookCommentsSection(item: item),
          ])
            SliverToBoxAdapter(child: section),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
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
    await _ChapterSection(
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

class _ChapterSection extends StatelessWidget {
  const _ChapterSection({
    required this.item,
    required this.chapters,
    required this.supportsContent,
    this.loadError,
    this.selectedChapterId,
    this.onSelected,
    this.onDownload,
    this.onReturned,
    this.historyRevision = 0,
  });

  final MediaItem? item;
  final List<Chapter> chapters;
  final bool supportsContent;

  /// 详情/目录加载失败的原因（null 表示请求成功）。空目录是否可操作
  /// 取决于它：成功但空 → 引导搜索；失败 → 不把失败伪装成空目录。
  final String? loadError;
  final String? selectedChapterId;
  final ValueChanged<String>? onSelected;
  final VoidCallback? onDownload;
  final VoidCallback? onReturned;
  final int historyRevision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;

    if (item?.type == MediaType.anime &&
        supportsContent &&
        chapters.isNotEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (onDownload != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    key: const ValueKey('detail-chapter-download'),
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('选择剧集下载'),
                  ),
                ),
              EpisodeSelector(
                key: ValueKey(
                  '${item?.sourceId}:${item?.remoteId}:$selectedChapterId',
                ),
                currentIndex: chapters.indexWhere(
                  (chapter) => chapter.remoteId == selectedChapterId,
                ),
                chapters: chapters,
                onSelected: (index) => _openChapter(context, index),
              ),
            ],
          ),
        ),
      );
    }

    if (chapters.isEmpty) {
      // Only a successful directory request may offer an empty-state search.
      if (loadError == null) {
        return SliverToBoxAdapter(
          key: const ValueKey('detail-directory-empty'),
          child: Padding(
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
                    Text(switch (item?.type) {
                      MediaType.anime => '暂无剧集目录',
                      MediaType.novel => '暂无章节目录',
                      _ => '当前来源暂无章节',
                    }, style: theme.textTheme.titleSmall),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '当前来源暂未提供这部作品的章节，可以搜索同来源的其他作品。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.mutedForeground,
                      ),
                    ),
                    if (item != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.sm),
                      OutlinedButton.icon(
                        key: const ValueKey('detail-directory-search'),
                        onPressed: () => SearchPage.open(
                          context,
                          type: item!.type,
                          sourceId: item!.sourceId,
                          sourceOnly: true,
                        ),
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('搜索其他作品'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return SliverToBoxAdapter(
        key: const ValueKey('detail-directory-unavailable'),
        child: Padding(
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
        ),
      );
    }

    if (item == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return _ChapterCatalog(
      item: item!,
      chapters: chapters,
      canOpen: supportsContent,
      onSelected: (index) async {
        await _openChapter(context, index);
        onReturned?.call();
      },
      onDownload: onDownload,
      historyRevision: historyRevision,
    );
  }

  /// 打开章节：漫画 → 漫画阅读器、番剧 → 播放器、小说 → 正文阅读器。
  Future<void> _openChapter(BuildContext context, int index) async {
    final target = item;
    if (target == null || index < 0 || index >= chapters.length) return;
    if (!supportsContent ||
        (chapters[index].locked && target.type != MediaType.novel) ||
        chapters[index].sourceId != target.sourceId) {
      return;
    }
    onSelected?.call(chapters[index].remoteId);

    if (target.type == MediaType.manga) {
      await context.push<void>(
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
      await context.push<void>(
        AppRoutes.player,
        extra: PlayerArgs(
          item: target,
          chapters: chapters,
          initialIndex: index,
        ),
      );
      return;
    }

    await context.push<void>(
      AppRoutes.novelReader,
      extra: NovelReaderArgs(
        item: target,
        chapters: chapters,
        initialIndex: index,
      ),
    );
  }
}

/// 加入 / 移出书架。
class _MangaCollectionButton extends ConsumerStatefulWidget {
  const _MangaCollectionButton({required this.item});

  final MediaItem item;

  @override
  ConsumerState<_MangaCollectionButton> createState() =>
      _MangaCollectionButtonState();
}

class _MangaCollectionButtonState
    extends ConsumerState<_MangaCollectionButton> {
  bool _busy = false;
  MediaItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    final membership = ref.watch(
      inLibraryProvider((sourceId: item.sourceId, remoteId: item.remoteId)),
    );

    if (membership.isLoading || _busy) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(_busy ? '保存书架状态' : '读取书架状态'),
      );
    }

    if (membership.hasError) {
      return OutlinedButton.icon(
        onPressed: () => ref.invalidate(
          inLibraryProvider((sourceId: item.sourceId, remoteId: item.remoteId)),
        ),
        icon: const Icon(Icons.refresh),
        label: const Text('重试收藏状态'),
      );
    }

    if (membership.value ?? false) {
      return OutlinedButton.icon(
        onPressed: () => _setMembership(context, ref, add: false),
        icon: const Icon(Icons.check, size: 18),
        label: const Text('已在书架'),
      );
    }

    return FilledButton.icon(
      onPressed: () => _setMembership(context, ref, add: true),
      icon: const Icon(Icons.bookmark_add_outlined, size: 18),
      label: const Text('加入书架'),
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
      if (add) {
        await repository.addToLibrary(item);
      } else {
        await repository.removeFromLibrary(item.sourceId, item.remoteId);
      }
      if (!mounted) return;
      ref.invalidate(inLibraryProvider);
      ref.invalidate(libraryByTypeProvider(item.type));
      // 站点收藏尽力而为：来源支持远端书架且已登录时才写，失败只提示不回滚本地。
      final snapshot = await ref.read(sourcesProvider.future);
      final syncFailure = await syncShelfToSource(
        snapshot,
        item: item,
        add: add,
      );
      if (!context.mounted) return;
      final action = add ? '已加入书架' : '已移出书架';
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
