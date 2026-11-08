import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models/chapter.dart';
import '../../core/models/manga_chapter_number.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/storage_paths.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/widgets/source_network_image.dart';
import '../downloads/data/download_providers.dart';
import '../downloads/data/download_repository.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../library/data/merged_manga_repository.dart';
import '../novel/reader/novel_reader_settings.dart';
import '../tracking/data/tracking_providers.dart';
import 'manga_page_image.dart';
import 'manga_reading_order.dart';
import 'reader_settings.dart';
import 'reader_work_settings.dart';
import 'reader_work_settings_sheet.dart';

/// 打开阅读器所需的上下文。
class MangaReaderArgs {
  const MangaReaderArgs({
    required this.item,
    required this.chapters,
    required this.initialIndex,
    this.chapterOwners = const {},
  });

  final MediaItem item;
  final List<Chapter> chapters;
  final int initialIndex;

  /// Nonempty for confirmed merged directories; [chapters] is already ordered.
  final Map<String, MediaItem> chapterOwners;
}

/// 漫画阅读器。
///
/// 四种模式（对齐 Komikku）：从左到右 / 从右到左 / 上下翻页 / 条漫滚动。
/// 交互（同样对齐 Komikku）：点击左右区域翻页、点击中间呼出控制条、
/// 键盘方向键、鼠标滚轮、双指滑动（由 PageView 处理）。
class MangaReaderPage extends ConsumerStatefulWidget {
  const MangaReaderPage({super.key, required this.args});

  final MangaReaderArgs args;

  @override
  ConsumerState<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends ConsumerState<MangaReaderPage>
    with WidgetsBindingObserver {
  late final List<Chapter> _chapters = canonicalMangaReadingOrder(
    widget.args.chapters,
    preserveOrder: widget.args.chapterOwners.isNotEmpty,
    mangaTitle: widget.args.item.sourceTitle,
  );
  late int _chapterIndex = _initialChapterIndex();
  PageController _pageController = PageController();
  final ItemScrollController _itemScroll = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final ScrollOffsetController _scrollOffset = ScrollOffsetController();
  Timer? _autoScrollTimer;
  bool _foreground = true;
  late final int _previousCacheBytes;
  ReaderWorkKey get _workKey =>
      (sourceId: _item.sourceId, remoteId: _item.remoteId);
  MangaViewSettings get _viewSettings =>
      ref.read(readerWorkSettingsProvider(_workKey));
  bool get _doublePage =>
      _viewSettings.doublePage &&
      MediaQuery.sizeOf(context).width >= 600 &&
      _mode != ReadingMode.webtoon;
  int get _spreadSize => _doublePage ? 2 : 1;
  // Last rendered spread also remains safe to use while persisting in dispose.
  int _layoutSpreadSize = 1;
  ReadingMode? _layoutMode;
  int _layoutRevision = 0;
  Future<void> _saveQueue = Future<void>.value();
  ({String chapter, double page})? _lastQueuedProgress;
  bool _restoring = true;
  final FocusNode _focusNode = FocusNode();

  List<String> _images = const <String>[];
  StreamSubscription<String?>? _localImagesSubscription;
  bool _localComplete = true;
  int? _localTotalPages;
  int? _pendingLocalPage;
  int _localRefreshRevision = 0;
  String? _error;
  bool _loading = true;
  bool _chromeVisible = true;
  int _page = 0;
  int _requestSeq = 0;
  Future<void>? _chapterCacheFuture;
  int? _transitionOrigin;
  bool _openingNextChapter = false;
  final Set<String> _knownPageCounts = {};
  final Set<String> _completedChapters = {};

  int _initialChapterIndex() {
    if (_chapters.isEmpty) return 0;
    final original =
        widget.args.chapters[widget.args.initialIndex.clamp(
          0,
          widget.args.chapters.length - 1,
        )];
    return mangaReadingIndexOf(
      _chapters,
      original,
    ).clamp(0, _chapters.length - 1);
  }

  Chapter get _chapter => _chapters[_chapterIndex];
  MediaItem get _item => widget.args.item;
  MediaItem _owner(Chapter chapter) =>
      widget.args.chapterOwners[mangaChapterKey(chapter)] ?? _item;

  /// dispose 里不能用 ref（Riverpod 3 会在卸载时封禁）：
  /// 仓储与追踪上报器提前握在手里，退出时才补得进最后一次进度。
  late final LibraryRepository _libraryRepository;

  ProgressReporter? _trackingReporter;
  bool _keepScreenOn = false;
  final _screenOwner = 'manga-${UniqueKey()}';
  bool _volumeKeyTurn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _libraryRepository = ref.read(libraryRepositoryProvider);
    if (_item.sourceId != 'local-comic') {
      _trackingReporter = ref.read(progressReporterProvider);
    }
    _positions.itemPositions.addListener(_onScroll);
    unawaited(_setImmersive(immersive: true));
    // 屏幕常亮与屏幕方向（B4），退出时恢复。
    final readerPrefs = NovelReaderSettings.load(ref.read(preferencesProvider));
    _keepScreenOn = readerPrefs.keepScreenOn;
    _volumeKeyTurn = readerPrefs.volumeKeyTurn;
    final view = _viewSettings;
    _volumeKeyTurn = view.hasOverrides ? view.volumeKeys : _volumeKeyTurn;
    _previousCacheBytes = PaintingBinding.instance.imageCache.maximumSizeBytes;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        view.cacheMiB * 1024 * 1024;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted ||
          !_foreground ||
          _loading ||
          _restoring ||
          _chromeVisible ||
          !_itemScroll.isAttached ||
          _transitionOrigin != null) {
        return;
      }
      final settings = _viewSettings;
      if (settings.base.mode == ReadingMode.webtoon &&
          settings.autoScroll > 0) {
        unawaited(
          _scrollOffset.animateScroll(
            offset: settings.autoScroll * .3,
            duration: const Duration(milliseconds: 300),
          ),
        );
      }
    });
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(true, owner: _screenOwner));
    }
    unawaited(
      _applyOrientation(
        view.hasOverrides ? view.orientation : readerPrefs.orientation,
      ),
    );
    unawaited(_load());
  }

  /// 应用屏幕方向（B4）；空列表 = 跟随系统。
  Future<void> _applyOrientation(ReaderOrientation orientation) async {
    await SystemChrome.setPreferredOrientations(switch (orientation) {
      ReaderOrientation.system => <DeviceOrientation>[],
      ReaderOrientation.portrait => <DeviceOrientation>[
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      ReaderOrientation.landscape => <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    });
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    unawaited(_localImagesSubscription?.cancel());
    PaintingBinding.instance.imageCache.maximumSizeBytes = _previousCacheBytes;
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onScroll);
    _pageController.dispose();
    _focusNode.dispose();
    unawaited(_persistProgress());
    unawaited(_setImmersive(immersive: false));
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(false, owner: _screenOwner));
    }
    unawaited(SystemChrome.setPreferredOrientations(<DeviceOrientation>[]));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (Platform.isWindows && _keepScreenOn) {
      final visible =
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive;
      unawaited(platformChannel.setKeepScreenOn(visible, owner: _screenOwner));
    }
    if (state != AppLifecycleState.resumed) unawaited(_persistProgress());
  }

  // ------------------------------------------------------------------ 加载

  Future<void> _load() async {
    final seq = ++_requestSeq;
    unawaited(_localImagesSubscription?.cancel());
    _localImagesSubscription = null;
    _localComplete = true;
    _localTotalPages = null;
    _pendingLocalPage = null;
    _localRefreshRevision++;
    _restoring = true;
    setState(() {
      _loading = true;
      _error = null;
      _images = const <String>[];
      _page = 0;
    });

    try {
      if (_chapters.isEmpty) throw StateError('没有可阅读的章节');
      final chapter = _chapter;
      if (chapter.locked) {
        throw StateError('章节已锁定，不能打开或缓存');
      }
      await _saveQueue;
      await _cacheChapters();
      if (!mounted || seq != _requestSeq) return;
      final saved = await _libraryRepository.chapterPositionOf(
        _owner(chapter).sourceId,
        _owner(chapter).remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      // 离线优先：下载过的章节直接读本地图片目录。
      final local = await _localImagesOf(chapter);
      if (!mounted || seq != _requestSeq) return;
      if (local != null) {
        setState(() {
          _images = local.images;
          _localComplete = local.complete;
          _localTotalPages = local.totalPages;
          final savedPage = saved?.floor() ?? 0;
          if (!local.complete && savedPage >= _images.length) {
            _pendingLocalPage = savedPage;
          }
          _page = (saved?.floor() ?? 0).clamp(0, _images.length - 1);
          _loading = false;
        });
        _finishChapterLoad();
        _restorePage(seq);
        if (!local.complete) {
          _localImagesSubscription = ref
              .read(downloadRepositoryProvider)
              .watchLocalImageDir(chapter.sourceId, chapter.remoteId)
              .listen((directory) {
                if (directory != null) {
                  unawaited(_refreshLocalImages(directory, seq));
                }
              });
        }
        return;
      }
      if (chapter.sourceId == 'local-comic') {
        throw StateError('本地漫画图片未恢复或已缺失；请恢复包含媒体的备份，或移除此目录后重新导入原始文件。不能从网络重新下载。');
      }

      final snapshot = widget.args.chapterOwners.isEmpty
          ? await ref.read(sourcesProvider.future)
          : await ref.read(sourceRegistryProvider).load();
      if (!mounted || seq != _requestSeq) return;
      final entry = snapshot.entries
          .where(
            (candidate) =>
                candidate.descriptor.id == chapter.sourceId &&
                candidate.enabled,
          )
          .firstOrNull;
      if (entry == null) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.notFound,
          message: '来源已被移除，无法打开正文',
        );
      }

      final provider = entry.source;
      if (provider is! ContentProvider) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '该来源没有声明 content 能力',
        );
      }

      if (chapter.url == null || chapter.url!.isEmpty) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '章节缺少地址，规则里应给章节补上 url 字段',
        );
      }

      final content = provider is MihonSource
          ? await provider.content(chapter, item: _owner(chapter))
          : await provider.content(chapter);
      if (!mounted || seq != _requestSeq) return;

      if (content.images.isEmpty) {
        setState(() {
          _loading = false;
          _error = _unsupportedMessage(content);
        });
        return;
      }

      setState(() {
        _images = content.images;
        _page = (saved?.floor() ?? 0).clamp(0, _images.length - 1);
        _loading = false;
      });
      _finishChapterLoad();

      _restorePage(seq);
      unawaited(_preloadNeighbour());
    } catch (error) {
      if (!mounted || seq != _requestSeq) return;
      final message = error is SourceException ? error.userMessage : '$error';
      setState(() {
        _loading = false;
        _error = message;
      });
    }
  }

  void _finishChapterLoad() {
    if (_openingNextChapter) {
      setState(() {
        _transitionOrigin = null;
        _openingNextChapter = false;
        _chromeVisible = true;
      });
    }
  }

  void _restorePage(int seq) {
    final revision = ++_layoutRevision;
    _restoring = true;
    if (_isPaged) _page = _page ~/ _spreadSize * _spreadSize;
    _resetPageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || seq != _requestSeq || revision != _layoutRevision) return;
      _restoring = false;
      unawaited(_persistProgress());
    });
  }

  /// Only verified manifest pages are eligible, including a running download.
  Future<({List<String> images, bool complete, int? totalPages})?>
  _localImagesOf(Chapter chapter) async {
    final directory = await ref
        .read(downloadRepositoryProvider)
        .localImageDir(chapter.sourceId, chapter.remoteId);
    if (directory == null || directory.isEmpty) return null;
    return _readLocalImages(directory);
  }

  Future<({List<String> images, bool complete, int? totalPages})?>
  _readLocalImages(String directory) async {
    final manifest = await DownloadManifest.read(directory);
    if (manifest == null || manifest.files.isEmpty) return null;
    return (
      images: [
        for (final name in manifest.files)
          Uri.file(
            storagePathIdentity('$directory${Platform.pathSeparator}$name'),
          ).toString(),
      ],
      complete: manifest.complete,
      totalPages: manifest.totalPages,
    );
  }

  Future<void> _refreshLocalImages(String directory, int seq) async {
    if (!mounted || seq != _requestSeq) return;
    final revision = ++_localRefreshRevision;
    final local = await _readLocalImages(directory);
    if (!mounted ||
        seq != _requestSeq ||
        revision != _localRefreshRevision ||
        local == null) {
      return;
    }
    // A slower earlier notification must not shrink or replace visible pages.
    if (local.images.length < _images.length) return;
    for (var index = 0; index < _images.length; index++) {
      if (_images[index] != local.images[index]) return;
    }
    final complete = _localComplete || local.complete;
    if (local.images.length == _images.length &&
        complete == _localComplete &&
        local.totalPages == _localTotalPages) {
      return;
    }
    final pending = _pendingLocalPage;
    final restorePending =
        pending != null && (pending < local.images.length || complete);
    setState(() {
      _images = local.images;
      _localComplete = complete;
      _localTotalPages = local.totalPages;
      if (restorePending) {
        _page = pending.clamp(0, _images.length - 1);
        _pendingLocalPage = null;
      }
    });
    if (restorePending) _restorePage(seq);
    if (complete) {
      if (!_restoring) unawaited(_persistProgress());
      final subscription = _localImagesSubscription;
      _localImagesSubscription = null;
      unawaited(subscription?.cancel());
    }
  }

  /// 内容形态不对时给出可执行的下一步，而不是一句"加载失败"。
  String _unsupportedMessage(ChapterContent content) {
    if (content.text != null && content.text!.isNotEmpty) {
      return '这一章是文字内容：请用小说源打开它的详情页阅读。';
    }
    if (content.playSources.isNotEmpty) {
      return '这一集是视频内容：请用番剧源打开它的详情页播放。';
    }
    return '这一章没有取到图片：请检查规则的 content.images 选择器是否匹配该站的懒加载属性。';
  }

  /// 缓存目录：历史记录要显示章节标题，没缓存就只能显示"目录未缓存"。
  Future<void> _cacheChapters() {
    // Merged chapters are already cached under their real owners. Never write
    // them into the anchor work's directory or change their source identities.
    if (widget.args.chapterOwners.isNotEmpty) return Future<void>.value();
    return _chapterCacheFuture ??= _cacheSingleWork();
  }

  Future<void> _cacheSingleWork() async {
    try {
      await _libraryRepository.cacheItem(_item);
      await _libraryRepository.saveChapters(
        itemSourceId: _item.sourceId,
        itemRemoteId: _item.remoteId,
        chapters: widget.args.chapters,
      );
    } catch (_) {
      _chapterCacheFuture = null;
      rethrow;
    }
  }

  Future<void> _persistProgress() {
    if (_loading ||
        _error != null ||
        _images.isEmpty ||
        _restoring ||
        _pendingLocalPage != null) {
      return Future<void>.value();
    }
    final repository = _libraryRepository;
    final chapter = _chapter;
    _queueChapterState(chapter);
    final page = _page.toDouble();
    final progress = (chapter: mangaChapterKey(chapter), page: page);
    if (_lastQueuedProgress == progress) return _saveQueue;
    _lastQueuedProgress = progress;
    final chapterNumber =
        recognizeMangaChapterNumber(
          mangaTitle: _owner(chapter).sourceTitle,
          chapterTitle: chapter.title,
          providedNumber: chapter.number,
        ) ??
        (chapter.sortIndex + 1).toDouble();
    return _saveQueue = _saveQueue.then((_) async {
      try {
        await repository.updateProgress(
          sourceId: _owner(chapter).sourceId,
          remoteId: _owner(chapter).remoteId,
          chapterNumber: chapterNumber,
        );
        await repository.recordHistory(
          sourceId: _owner(chapter).sourceId,
          remoteId: _owner(chapter).remoteId,
          chapter: chapter,
          position: page,
        );
        // 进度上报（追踪服务）：尽力而为，失败不影响阅读。
        unawaited(
          _trackingReporter?.report(
                sourceId: _owner(chapter).sourceId,
                remoteId: _owner(chapter).remoteId,
                chapterNumber: chapterNumber,
                type: MediaType.manga,
              ) ??
              Future<void>.value(),
        );
        // 书架与历史页要立刻反映进度；dispose 时 mounted 已为 false。
        if (mounted) {
          ref.invalidate(libraryByTypeProvider);
          ref.invalidate(historyProvider);
          ref.invalidate(historyByTypeProvider);
        }
      } catch (_) {
        if (_lastQueuedProgress == progress) _lastQueuedProgress = null;
        // 进度写失败不应该打断阅读
      }
    });
  }

  void _queueChapterState(Chapter chapter) {
    if (!_localComplete) return;
    final owner = _owner(chapter);
    final key = mangaChapterKey(chapter);
    final count = _images.length;
    final countKey = '$key:$count';
    final recordCount = _knownPageCounts.add(countKey);
    final markRead =
        _page + _layoutSpreadSize >= count && _completedChapters.add(key);
    if (!recordCount && !markRead) return;
    _saveQueue = _saveQueue.then((_) async {
      try {
        if (recordCount) {
          await _libraryRepository.recordMangaChapterPageCount(
            sourceId: owner.sourceId,
            itemRemoteId: owner.remoteId,
            chapter: chapter,
            totalPages: count,
          );
        }
        if (markRead) {
          await _libraryRepository.setChapterRead(
            sourceId: owner.sourceId,
            itemRemoteId: owner.remoteId,
            chapters: [chapter],
            read: true,
          );
        }
      } catch (_) {
        if (recordCount) _knownPageCounts.remove(countKey);
        if (markRead) _completedChapters.remove(key);
      }
    });
  }

  /// 预取下一章的前几张图，翻到下一章时不至于白屏。
  Future<void> _preloadNeighbour() async {
    final next = _chapterIndex + 1;
    if (_item.sourceId == 'local-comic') return;
    final seq = _requestSeq;
    final count = _viewSettings.preload;
    if (count == 0 || !mounted) return;
    if (next >= _chapters.length) return;
    try {
      final snapshot = widget.args.chapterOwners.isEmpty
          ? await ref.read(sourcesProvider.future)
          : await ref.read(sourceRegistryProvider).load();
      final entry = snapshot.entries
          .where(
            (candidate) =>
                candidate.descriptor.id == _chapters[next].sourceId &&
                candidate.enabled,
          )
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ContentProvider ||
          _chapters[next].locked ||
          seq != _requestSeq ||
          !mounted) {
        return;
      }
      final content = provider is MihonSource
          ? await provider.content(
              _chapters[next],
              item: _owner(_chapters[next]),
            )
          : await provider.content(_chapters[next]);
      if (seq != _requestSeq || !mounted) return;
      for (final url in content.images.take(count)) {
        if (!mounted) return;
        // 本地文件（file://）不走 NetworkImage 且加载即时，无需预取；
        // 对它发起 NetworkImage 只会产生必然失败的请求。
        if (url.startsWith('file://') ||
            (!url.contains('://') && url.length > 1)) {
          continue;
        }
        final width =
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(480, 2400);
        await precacheImage(
          ResizeImage(
            SourceNetworkImage(
              url,
              http: ref.read(sourceHttpClientProvider),
              sourceId: _chapters[next].sourceId,
            ),
            width: width,
            height: 8192,
            policy: ResizeImagePolicy.fit,
          ),
          context,
        ).catchError((Object _) {});
      }
    } catch (_) {
      // 预取失败无所谓，真正翻页时会再试一次
    }
  }

  Future<void> _setImmersive({required bool immersive}) async {
    await SystemChrome.setEnabledSystemUIMode(
      immersive ? SystemUiMode.immersive : SystemUiMode.edgeToEdge,
    );
  }

  // ------------------------------------------------------------------ 翻页

  void _onScroll() {
    if (!mounted ||
        _isPaged ||
        _restoring ||
        _loading ||
        _transitionOrigin != null) {
      return;
    }
    final visible =
        _positions.itemPositions.value
            .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final index = visible.first.index;
    if (index == _images.length && _localComplete) {
      _page = (_images.length - 1) ~/ _spreadSize * _spreadSize;
      _showChapterTransition();
      return;
    }
    if (index < 0 || index >= _images.length) return;
    if (index != _page) {
      setState(() => _page = index);
      unawaited(_persistProgress());
    }
  }

  void _onPageChanged(int index) {
    if (!mounted || _restoring || _loading || _images.isEmpty) return;
    if (index * _spreadSize >= _images.length && _localComplete) {
      _page = (_images.length - 1) ~/ _spreadSize * _spreadSize;
      _showChapterTransition();
      return;
    }
    final page = (index * _spreadSize).clamp(0, _images.length - 1);
    if (_page == page) return;
    _pendingLocalPage = null;
    setState(() => _page = page);
    unawaited(_persistProgress());
  }

  void _goToPage(int index) {
    if (!_canTurnPage) return;
    if (index < 0 || index >= _images.length) return;
    if (_isPaged) index = index ~/ _spreadSize * _spreadSize;
    if (_page == index) return;
    if (_isPaged) {
      if (!_pageController.hasClients) return;
      _pageController.animateToPage(
        index ~/ _spreadSize,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (_itemScroll.isAttached) {
      _itemScroll.jumpTo(index: index);
    } else {
      return;
    }
    _pendingLocalPage = null;
    setState(() => _page = index);
    unawaited(_persistProgress());
  }

  bool get _canTurnPage =>
      !_loading && !_restoring && _error == null && _images.isNotEmpty;

  void _nextPage() {
    if (_transitionOrigin != null) {
      _continueChapter();
      return;
    }
    if (!_canTurnPage) return;
    if (_page + _spreadSize < _images.length) {
      _goToPage(_page + _spreadSize);
    } else if (!_localComplete) {
      _toast('已到已下载页面，等待后续下载');
    } else {
      _showChapterTransition();
    }
  }

  void _previousPage() {
    if (_transitionOrigin != null) {
      _cancelChapterTransition();
      return;
    }
    if (!_canTurnPage) return;
    if (_page > 0) {
      _goToPage((_page - _spreadSize).clamp(0, _images.length - 1));
    } else {
      _switchChapter(-1);
    }
  }

  void _switchChapter(int delta) {
    if (_chapters.isEmpty) return;
    // Manual chapter navigation may leave a partial download without claiming
    // it is finished. Page-forward EOF still waits for the remaining pages.
    if (delta > 0 && _canTurnPage && _localComplete) {
      _showChapterTransition();
      return;
    }
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) {
      _toast(delta > 0 ? '已经是最后一章' : '已经是第一章');
      return;
    }
    unawaited(_persistProgress());
    _transitionOrigin = null;
    _openingNextChapter = false;
    setState(() {
      _chapterIndex = target;
      _page = 0;
    });
    _resetPageController();
    unawaited(_load());
  }

  void _showChapterTransition() {
    if (!_canTurnPage || !_localComplete || _transitionOrigin != null) return;
    unawaited(_persistProgress());
    setState(() {
      _transitionOrigin = _chapterIndex;
      _chromeVisible = false;
    });
  }

  void _continueChapter() {
    final origin = _transitionOrigin;
    if (origin == null || _loading && _openingNextChapter) return;
    final target = origin + 1;
    if (target >= _chapters.length || _chapters[target].locked) return;
    setState(() {
      _chapterIndex = target;
      _openingNextChapter = true;
    });
    _resetPageController();
    unawaited(_load());
  }

  void _cancelChapterTransition() {
    final origin = _transitionOrigin;
    if (origin == null) return;
    final reload = _openingNextChapter;
    ++_requestSeq; // A cancelled target may still finish its local/network read.
    setState(() {
      _chapterIndex = origin;
      _transitionOrigin = null;
      _openingNextChapter = false;
      _chromeVisible = true;
    });
    if (reload) {
      unawaited(_load());
    } else {
      _restorePage(_requestSeq);
    }
  }

  /// 换章 / 切模式后重建 PageController。
  ///
  /// 旧的控制器要等本帧渲染完再释放：立即 dispose 会被仍在树上的 PageView 引用。
  void _resetPageController() {
    final old = _pageController;
    _pageController = PageController(
      initialPage: _page ~/ _spreadSize,
      keepPage: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool get _isPaged => _mode != ReadingMode.webtoon;

  ReadingMode get _mode => _viewSettings.base.mode;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  void _handleTap(TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    final zones = _viewSettings.tapZones;
    if (zones == ReaderTapZones.centerOnly) {
      setState(() => _chromeVisible = !_chromeVisible);
      return;
    }
    if (zones == ReaderTapZones.nextBoth &&
        (x < width * .3 || x > width * .7)) {
      _nextPage();
      return;
    }
    if (x < width * 0.3) {
      // 左三分之一：RTL 下是「上一页」的反面
      if (_mode == ReadingMode.rtl) {
        _nextPage();
      } else {
        _previousPage();
      }
    } else if (x > width * 0.7) {
      if (_mode == ReadingMode.rtl) {
        _previousPage();
      } else {
        _nextPage();
      }
    } else {
      setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final rtl = _mode == ReadingMode.rtl;
    if (_transitionOrigin != null && key == LogicalKeyboardKey.enter) {
      _continueChapter();
      return KeyEventResult.handled;
    }

    // 音量键翻页（默认关，防误触；设置与小说阅读器共用）。
    if (_volumeKeyTurn) {
      if (key == LogicalKeyboardKey.audioVolumeDown) {
        _nextPage();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.audioVolumeUp) {
        _previousPage();
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (rtl) {
        _previousPage();
      } else {
        _nextPage();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (rtl) {
        _nextPage();
      } else {
        _previousPage();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      _nextPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
      _previousPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_transitionOrigin != null) {
        _cancelChapterTransition();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ 渲染

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(readerWorkSettingsProvider(_workKey));
    final settings = view.base;
    ref.listen(readerWorkSettingsProvider(_workKey), (previous, next) {
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          next.cacheMiB * 1024 * 1024;
      _volumeKeyTurn = next.volumeKeys;
      if (previous?.orientation != next.orientation) {
        unawaited(_applyOrientation(next.orientation));
      }
    });
    if (_layoutMode != settings.mode || _layoutSpreadSize != _spreadSize) {
      final initialized = _layoutMode != null;
      _layoutMode = settings.mode;
      _layoutSpreadSize = _spreadSize;
      if (initialized && !_loading && _images.isNotEmpty) {
        _restorePage(_requestSeq);
      }
    }

    if (_chapters.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(_item.title)),
        body: const Center(child: Text('没有可阅读的章节')),
      );
    }
    return PopScope(
      canPop: _transitionOrigin == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _transitionOrigin != null) _cancelChapterTransition();
      },
      child: Scaffold(
        backgroundColor: settings.background.color,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (node, event) => _handleKey(event),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is! PointerScrollEvent) return;
                    if (!_isPaged) {
                      _pendingLocalPage = null;
                      return;
                    }
                    event.scrollDelta.dy > 0 ? _nextPage() : _previousPage();
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _handleTap,
                    child: _buildBody(settings),
                  ),
                ),
              ),
              if (_transitionOrigin == null) _buildChrome(settings),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ReaderSettings settings) {
    if (_transitionOrigin != null) return _buildChapterTransition(settings);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white70,
                size: 40,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.tonal(
                onPressed: () => unawaited(_load()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (settings.mode == ReadingMode.webtoon) {
      return NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          if (notification.dragDetails != null) _pendingLocalPage = null;
          return false;
        },
        child: ScrollablePositionedList.builder(
          key: ValueKey((_chapterIndex, _requestSeq, _layoutRevision)),
          itemScrollController: _itemScroll,
          itemPositionsListener: _positions,
          initialScrollIndex: _page,
          itemCount: _images.length + (_localComplete ? 1 : 0),
          scrollOffsetController: _scrollOffset,
          itemBuilder: (context, index) => index == _images.length
              ? SizedBox(
                  height: MediaQuery.sizeOf(context).height,
                  child: const Center(child: Icon(Icons.arrow_downward)),
                )
              : _imagePage(index, BoxFit.fitWidth),
        ),
      );
    }

    return PageView.builder(
      key: ValueKey((settings.mode, _layoutRevision)),
      controller: _pageController,
      reverse: settings.mode == ReadingMode.rtl,
      scrollDirection: settings.mode == ReadingMode.vertical
          ? Axis.vertical
          : Axis.horizontal,
      onPageChanged: _onPageChanged,
      itemCount:
          (_images.length / _spreadSize).ceil() + (_localComplete ? 1 : 0),
      itemBuilder: (context, index) {
        final first = index * _spreadSize;
        if (first >= _images.length) {
          return const Center(child: Icon(Icons.navigate_next));
        }
        if (!_doublePage) return _imagePage(first, settings.fit.boxFit);
        final pages = [
          Expanded(child: _imagePage(first, BoxFit.contain)),
          Expanded(
            child: first + 1 < _images.length
                ? _imagePage(first + 1, BoxFit.contain)
                : const SizedBox.shrink(),
          ),
        ];
        return Row(
          children: settings.mode == ReadingMode.rtl
              ? pages.reversed.toList()
              : pages,
        );
      },
    );
  }

  Widget _buildChapterTransition(ReaderSettings settings) {
    final origin = _transitionOrigin!;
    final current = _chapters[origin];
    final next = origin + 1 < _chapters.length ? _chapters[origin + 1] : null;
    final completed = _completedChapters.contains(mangaChapterKey(current));
    final loading = _openingNextChapter && _loading;
    final error = _openingNextChapter ? _error : null;
    final foreground = settings.background.color.computeLuminance() > .5
        ? Colors.black87
        : Colors.white;
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: DefaultTextStyle(
              style: theme.textTheme.titleLarge!.copyWith(color: foreground),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(completed ? '已读完：' : '当前章节：'),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        completed ? Icons.check_circle : Icons.menu_book,
                        color: foreground,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(current.title)),
                    ],
                  ),
                  const SizedBox(height: 56),
                  if (next != null) ...[
                    const Text('下一章：'),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          next.locked
                              ? Icons.lock_outline
                              : Icons.arrow_forward,
                          color: foreground,
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(next.title)),
                      ],
                    ),
                    if (next.locked) ...[
                      const SizedBox(height: 16),
                      const Text('下一章已锁定'),
                    ],
                  ] else
                    const Text('已经是最后一章'),
                  if (loading) ...[
                    const SizedBox(height: 24),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text('正在加载下一章…'),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      error,
                      style: TextStyle(color: foreground, fontSize: 16),
                    ),
                  ],
                  const SizedBox(height: 32),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      if (next != null)
                        FilledButton(
                          onPressed: loading || next.locked
                              ? null
                              : _continueChapter,
                          child: Text(error == null ? '继续阅读' : '重试下一章'),
                        ),
                      OutlinedButton(
                        onPressed: _cancelChapterTransition,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: foreground,
                        ),
                        child: const Text('返回本章'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _imagePage(int index, BoxFit fit) {
    final url = _images[index];
    final ImageProvider provider = url.startsWith('file://')
        ? FileImage(File(storageFilePath(Uri.parse(url).toFilePath())))
        : !url.contains('://')
        ? FileImage(File(storageFilePath(url)))
        : SourceNetworkImage(
            url,
            http: ref.watch(sourceHttpClientProvider),
            sourceId: _chapter.sourceId,
          );
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context) /
                _spreadSize)
            .round();
    return MangaPageImage(
      key: ValueKey(url),
      provider: ResizeImage(
        provider,
        width: width.clamp(480, 2400),
        height: 8192,
        policy: ResizeImagePolicy.fit,
      ),
      url: url,
      sourceId: _chapter.sourceId,
      fit: fit,
      settings: _viewSettings,
    );
  }

  Widget _buildChrome(ReaderSettings settings) {
    final theme = Theme.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: _chromeVisible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_chromeVisible,
        child: Column(
          children: <Widget>[
            Container(
              color: Colors.black.withValues(alpha: 0.72),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs,
                vertical: AppSpacing.xxs,
              ),
              child: SafeArea(
                bottom: false,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            _localComplete
                                ? _chapter.title
                                : '${_chapter.title} · 已下载 ${_images.length}/${_localTotalPages ?? '?'} 页',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '目录',
                      onPressed: _showChapterList,
                      icon: const Icon(Icons.list, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: '阅读设置',
                      onPressed: () => _showSettings(settings),
                      icon: const Icon(Icons.tune, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Container(
              color: Colors.black.withValues(alpha: 0.72),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: '上一章',
                      onPressed: () => _switchChapter(-1),
                      icon: const Icon(
                        Icons.skip_previous,
                        color: Colors.white,
                      ),
                    ),
                    if (!_loading && _error == null && _images.isNotEmpty) ...[
                      Expanded(
                        child: Slider(
                          value: (_page + 1)
                              .clamp(1, _images.length)
                              .toDouble(),
                          min: 1,
                          max: _images.length.toDouble(),
                          divisions: _images.length > 1
                              ? _images.length - 1
                              : null,
                          label: '${_page + 1}/${_images.length}',
                          onChanged: (value) => _goToPage(value.round() - 1),
                        ),
                      ),
                      Text(
                        '${_page + 1}/${_images.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ] else
                      Expanded(
                        child: Text(
                          _loading ? '正在加载章节…' : '章节未加载',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    IconButton(
                      tooltip: '下一章',
                      onPressed: () => _switchChapter(1),
                      icon: const Icon(Icons.skip_next, color: Colors.white),
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

  Future<void> _showSettings(ReaderSettings settings) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ReaderWorkSettingsSheet(workKey: _workKey),
      );

  Future<void> _showChapterList() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _chapters.length,
          itemBuilder: (context, index) {
            final chapter = _chapters[index];
            final selected = index == _chapterIndex;
            return ListTile(
              dense: true,
              selected: selected,
              title: Text(chapter.title),
              subtitle: chapter.volumeTitle == null
                  ? null
                  : Text(chapter.volumeTitle!),
              trailing: chapter.locked
                  ? const Icon(Icons.lock_outline, size: 18)
                  : null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (index == _chapterIndex) return;
                unawaited(_persistProgress());
                _transitionOrigin = null;
                _openingNextChapter = false;
                setState(() {
                  _chapterIndex = index;
                  _page = 0;
                });
                _resetPageController();
                unawaited(_load());
              },
            );
          },
        ),
      ),
    );
  }
}
