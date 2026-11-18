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
import 'manga_layout.dart';
import 'manga_page_image.dart';
import 'manga_reader_options.dart';
import 'manga_reader_settings.dart';
import 'manga_reader_settings_sheet.dart';
import 'manga_reading_order.dart';
import 'manga_zoom_view.dart';
import 'reader_settings.dart';

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
  MangaViewSettings get _viewSettings => ref.read(mangaViewSettingsProvider);
  MangaReaderOptions get _options => _viewSettings.options;
  bool get _doublePage =>
      _viewSettings.doublePage &&
      MediaQuery.sizeOf(context).width >= 600 &&
      _isPaged &&
      (_options.choice('pageLayout', ['width', 'landscape']) != 'landscape' ||
          MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height);
  MangaLayout? _cachedLayout;
  Object? _cachedLayoutKey, _renderedLayoutKey;
  final Map<int, Size> _geometry = {};
  int _geometryRevision = 0;
  bool _geometryPending = false;
  bool _geometryDeferred = false;
  int _part = 0;
  MangaLayout get _layout {
    final key = (
      _requestSeq,
      _images.length,
      _geometryRevision,
      _doublePage,
      _mode,
      _viewSettings.soloCover,
      _options.flag(_isPaged ? 'splitWide' : 'splitWebtoon'),
      _options.flag('reverseSplit'),
      _options.flag(_isPaged ? 'rotateWide' : 'rotateWebtoon'),
      _options.flag('rotateCounterclockwise'),
    );
    if (_cachedLayoutKey != key) {
      _cachedLayoutKey = key;
      _cachedLayout = MangaLayout(
        _images.length,
        doublePage: _doublePage,
        soloCover: _viewSettings.soloCover,
        splitWide: _options.flag(_isPaged ? 'splitWide' : 'splitWebtoon'),
        reverseSplit: _options.flag('reverseSplit'),
        rtl: _mode == ReadingMode.rtl,
        rotateWide: _options.flag(_isPaged ? 'rotateWide' : 'rotateWebtoon'),
        rotateCounterclockwise: _options.flag('rotateCounterclockwise'),
        geometry: _geometry,
      );
    }
    return _cachedLayout!;
  }

  int get _screen => _layout.screenOf(_page, _part);
  int _layoutRevision = 0;
  Future<void> _saveQueue = Future<void>.value();
  ({String chapter, double page, int part})? _lastQueuedProgress;
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
  final Set<String> _alreadyRead = {};

  /// 放大状态由当前页自己维护；翻页/换章后复位，避免把放大带到下一页。
  bool _zoomed = false;
  int _zoomResetToken = 0;
  final Map<int, GlobalKey<MangaZoomViewState>> _zoomKeys = {};
  ScrollPosition? _webtoonScroll;

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
  bool get _verticalSeek =>
      _options.flag('verticalSeekbar') &&
      MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
  bool _volumeKeyTurn = false;
  MangaReaderOptions _lastOptions = const MangaReaderOptions();
  Timer? _menuTimer, _introTimer, _flashTimer;
  bool _showIntro = false, _flash = false;
  int _turns = 0;
  String get _pageLabel =>
      '${_page + 1}/${_images.length}${_part == 0
          ? ''
          : _part == 1
          ? ' · 左半'
          : ' · 右半'}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _libraryRepository = ref.read(libraryRepositoryProvider);
    if (_item.sourceId != 'local-comic') {
      _trackingReporter = ref.read(progressReporterProvider);
    }
    _positions.itemPositions.addListener(_onScroll);
    final view = _viewSettings;
    _lastOptions = view.options;
    _keepScreenOn = view.options.flag('keepScreenOn');
    unawaited(_setImmersive(immersive: view.options.flag('fullscreen')));
    _showIntro =
        view.options.flag('showReadingMode') ||
        view.options.flag('showTapZones');
    _introTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showIntro = false);
    });
    _volumeKeyTurn = view.volumeKeys;
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
      if (_mode == ReadingMode.webtoon && settings.autoScroll > 0 && !_zoomed) {
        if (_options.flag('smoothAutoScroll')) {
          unawaited(
            _scrollOffset.animateScroll(
              offset: settings.autoScroll * .3,
              duration: const Duration(milliseconds: 300),
            ),
          );
        } else {
          _webtoonScroll?.jumpTo(
            (_webtoonScroll!.pixels + settings.autoScroll * .3).clamp(
              _webtoonScroll!.minScrollExtent,
              _webtoonScroll!.maxScrollExtent,
            ),
          );
        }
      }
    });
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(true, owner: _screenOwner));
    }
    unawaited(_applyOrientation(view.orientation));
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
    _menuTimer?.cancel();
    _introTimer?.cancel();
    _flashTimer?.cancel();
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
    _geometry.clear();
    _geometryRevision++;
    _geometryPending = false;
    _part = 0;
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
      _alreadyRead.clear();
      for (final owner in {_item, ...widget.args.chapterOwners.values}) {
        final states = await _libraryRepository
            .watchMangaChapterStates(owner.sourceId, owner.remoteId)
            .first;
        for (final state in states.where((s) => s.isRead)) {
          _alreadyRead.add(
            '${state.chapterSourceId}\u0000${state.chapterRemoteId}',
          );
        }
      }
      if (!mounted || seq != _requestSeq) return;
      final saved = await _libraryRepository.chapterPositionOf(
        _owner(chapter).sourceId,
        _owner(chapter).remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      final savedPart = await _libraryRepository.chapterMangaPartOf(
        _owner(chapter).sourceId,
        _owner(chapter).remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      _part = savedPart;
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
    // Keep the original image and half anchor while geometry is still loading.
    if (_layout.count > 0 &&
        (_geometry.containsKey(_page) ||
            !_options.flag(_isPaged ? 'splitWide' : 'splitWebtoon'))) {
      final leaf = _layout.firstAt(_screen);
      _page = leaf.source;
      _part = leaf.part;
    }
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
    final part = _part;
    final progress = (
      chapter: mangaChapterKey(chapter),
      page: page,
      part: part,
    );
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
          mangaPart: part,
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
    final layout = _cachedLayout;
    if ((_lastOptions.flag('splitWide') || _lastOptions.flag('splitWebtoon')) &&
        !_geometry.containsKey(_page)) {
      return;
    }
    final recordCount = _knownPageCounts.add(countKey);
    final markRead =
        layout != null &&
        layout.finishesChapter(layout.screenOf(_page, _part)) &&
        _completedChapters.add(key);
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
    if (index == _layout.count && _localComplete) {
      _showChapterTransition();
      return;
    }
    if (index < 0 || index >= _layout.count) return;
    final leaf = _layout.firstAt(index);
    if (leaf.source != _page || leaf.part != _part) {
      setState(() {
        _page = leaf.source;
        _part = leaf.part;
      });
      _pageTurnFeedback();
      unawaited(_persistProgress());
    }
  }

  void _onPageChanged(int index) {
    if (!mounted || _restoring || _loading || _images.isEmpty) return;
    if (index >= _layout.count && _localComplete) {
      _showChapterTransition();
      return;
    }
    if (index >= _layout.count) return;
    final leaf = _layout.firstAt(index);
    if (_page == leaf.source && _part == leaf.part) return;
    _pendingLocalPage = null;
    setState(() {
      _page = leaf.source;
      _part = leaf.part;
      _resetZoom();
    });
    _pageTurnFeedback();
    unawaited(_persistProgress());
  }

  void _pageTurnFeedback() {
    _turns++;
    if (!_options.flag('flashPage') ||
        _turns % _options.number('flashInterval', 1, 1, 10).round() != 0) {
      return;
    }
    _flashTimer?.cancel();
    setState(() => _flash = true);
    _flashTimer = Timer(
      Duration(
        milliseconds: _options.number('flashDuration', 100, 100, 1000).round(),
      ),
      () {
        if (mounted) setState(() => _flash = false);
      },
    );
  }

  void _goToPage(int index) {
    if (!_canTurnPage) return;
    if (index < 0 || index >= _images.length) return;
    _goToScreen(_layout.screenOf(index));
  }

  void _goToScreen(int screen) {
    if (!_canTurnPage || screen < 0 || screen >= _layout.count) return;
    final leaf = _layout.firstAt(screen);
    if (_isPaged) {
      if (!_pageController.hasClients) return;
      if (_options.flag('pageAnimation')) {
        _pageController.animateToPage(
          screen,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        _pageController.jumpToPage(screen);
      }
    } else if (_itemScroll.isAttached) {
      _itemScroll.jumpTo(index: screen);
    } else {
      return;
    }
    _pendingLocalPage = null;
    _resetZoom();
    setState(() {
      _page = leaf.source;
      _part = leaf.part;
    });
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
    if (_screen + 1 < _layout.count) {
      _goToScreen(_screen + 1);
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
    if (_screen > 0) {
      _goToScreen(_screen - 1);
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

  bool _chapterRead(Chapter chapter) =>
      _alreadyRead.contains('${chapter.sourceId}\u0000${chapter.remoteId}') ||
      _completedChapters.contains(mangaChapterKey(chapter));

  bool _chapterFiltered(Chapter chapter, MangaReaderOptions options) =>
      switch (options.choice('chapterFilter', ['all', 'unread', 'read'])) {
        'unread' => _chapterRead(chapter),
        'read' => !_chapterRead(chapter),
        _ => false,
      };

  int _nextChapter(int origin, int delta) {
    final previousNumber = _chapters[origin].number;
    var target = origin + delta;
    while (target >= 0 && target < _chapters.length) {
      final candidate = _chapters[target];
      final read = _chapterRead(candidate);
      final filtered = _chapterFiltered(candidate, _options);
      final duplicate =
          previousNumber != null && candidate.number == previousNumber;
      if (!(_options.flag('skipRead') && read) &&
          !(_options.flag('skipDuplicates') && duplicate) &&
          !(_options.flag('skipFiltered') && filtered)) {
        break;
      }
      target += delta;
    }
    return target;
  }

  void _showChapterTransition() {
    if (!_canTurnPage || !_localComplete || _transitionOrigin != null) return;
    unawaited(_persistProgress());
    setState(() {
      _transitionOrigin = _chapterIndex;
      _chromeVisible = false;
    });
    if (!_options.flag('chapterTransition') &&
        _nextChapter(_chapterIndex, 1) < _chapters.length) {
      _continueChapter();
    }
  }

  void _continueChapter() {
    final origin = _transitionOrigin;
    if (origin == null || _loading && _openingNextChapter) return;
    final target = _nextChapter(origin, 1);
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
    _pageController = PageController(initialPage: _screen, keepPage: false);
    _zoomKeys.clear();
    _resetZoom();
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool get _isPaged => _mode != ReadingMode.webtoon;

  ReadingMode get _mode {
    if (_options.flag('autoWebtoon') &&
        _item.tags.any(
          (tag) => const {
            'webtoon',
            'long strip',
            '条漫',
          }.contains(tag.toLowerCase().trim()),
        )) {
      return ReadingMode.webtoon;
    }
    return _viewSettings.base.mode;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    _menuTimer?.cancel();
    final seconds = _options.number('menuHideSeconds', 0, 0, 15).round();
    if (_chromeVisible && seconds > 0) {
      _menuTimer = Timer(Duration(seconds: seconds), () {
        if (mounted) setState(() => _chromeVisible = false);
      });
    }
  }

  void _handleTap(TapUpDetails details) {
    final size = MediaQuery.sizeOf(context);
    var x = details.globalPosition.dx / size.width;
    var y = details.globalPosition.dy / size.height;
    final invert = _options.choice('tapInvert', [
      'none',
      'horizontal',
      'vertical',
      'both',
    ]);
    if (invert == 'horizontal' || invert == 'both') x = 1 - x;
    if (invert == 'vertical' || invert == 'both') y = 1 - y;
    final edge = _options.flag('smallerTapZones') ? .25 : .3;
    final layout = _options.choice('tapLayout', [
      'existing',
      'l',
      'kindle',
      'edge',
      'disabled',
    ]);
    final zones = _viewSettings.tapZones;
    if (zones == ReaderTapZones.centerOnly || layout == 'disabled') {
      _toggleChrome();
      return;
    }
    int action = 0;
    if (layout == 'l') {
      action = x < edge
          ? -1
          : y > 1 - edge
          ? 1
          : 0;
    } else if (layout == 'kindle') {
      action = y < edge
          ? 0
          : x < edge
          ? -1
          : 1;
    } else if (layout == 'edge') {
      action = x < edge || x > 1 - edge
          ? 1
          : y > 1 - edge
          ? -1
          : 0;
    } else {
      action = x < edge
          ? -1
          : x > 1 - edge
          ? 1
          : 0;
      if (zones == ReaderTapZones.nextBoth && action != 0) {
        action = 1;
      } else if (_mode == ReadingMode.rtl) {
        action = -action;
      }
    }
    if (action == 0) {
      _toggleChrome();
      return;
    }
    if (_zoomed && _options.flag('navigatePan') && _panCurrentPage(x > .5)) {
      return;
    }
    action > 0 ? _nextPage() : _previousPage();
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
        _options.flag('invertVolume') ? _previousPage() : _nextPage();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.audioVolumeUp) {
        _options.flag('invertVolume') ? _nextPage() : _previousPage();
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
    final view = ref.watch(mangaViewSettingsProvider);
    _lastOptions = view.options;
    final settings = view.base;
    ref.listen(mangaViewSettingsProvider, (previous, next) {
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          next.cacheMiB * 1024 * 1024;
      _volumeKeyTurn = next.volumeKeys;
      if (previous?.options.flag('keepScreenOn') !=
          next.options.flag('keepScreenOn')) {
        _keepScreenOn = next.options.flag('keepScreenOn');
        unawaited(
          platformChannel.setKeepScreenOn(_keepScreenOn, owner: _screenOwner),
        );
      }
      if (previous?.options.flag('fullscreen') !=
          next.options.flag('fullscreen')) {
        unawaited(_setImmersive(immersive: next.options.flag('fullscreen')));
      }
      if (previous?.orientation != next.orientation) {
        unawaited(_applyOrientation(next.orientation));
      }
    });
    _layout;
    if (_renderedLayoutKey != _cachedLayoutKey) {
      final initialized = _renderedLayoutKey != null;
      _renderedLayoutKey = _cachedLayoutKey;
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
                    if (_zoomed && _panCurrentPage(event.scrollDelta.dy > 0)) {
                      return;
                    }
                    event.scrollDelta.dy > 0 ? _nextPage() : _previousPage();
                  },
                  child: _options.flag('cutout')
                      ? _buildBody(settings)
                      : SafeArea(child: _buildBody(settings)),
                ),
              ),
              if (view.night.scrimAlpha > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    key: const ValueKey('manga-night-scrim'),
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: view.night.scrimAlpha,
                      ),
                    ),
                  ),
                ),
              if (_transitionOrigin == null) _buildChrome(settings),
              if (_verticalSeek && _chromeVisible && _images.isNotEmpty)
                Positioned(
                  left: _options.flag('leftSeekbar') ? 0 : null,
                  right: _options.flag('leftSeekbar') ? null : 0,
                  top: 100,
                  bottom: 90,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SizedBox(
                      height: 48,
                      child: Slider(
                        value: (_page + 1).clamp(1, _images.length).toDouble(),
                        min: 1,
                        max: _images.length.toDouble(),
                        divisions: _images.length > 1
                            ? _images.length - 1
                            : null,
                        label: _pageLabel,
                        onChanged: (v) => _goToPage(v.round() - 1),
                      ),
                    ),
                  ),
                ),
              if (!_chromeVisible &&
                  _options.flag('showPageNumber') &&
                  _images.isNotEmpty)
                Positioned(
                  bottom: 12,
                  right: 16,
                  child: IgnorePointer(
                    child: Text(
                      _pageLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                ),
              if (_showIntro)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Text(
                        '${_options.flag('showReadingMode') ? _mode.label : ''}${_options.flag('showTapZones') ? '\n点按导航：${MangaReaderOptions.choices['tapLayout']!.$2[_options.choice('tapLayout', ['existing', 'l', 'kindle', 'edge', 'disabled'])]}\n中间呼出菜单；双击放大/还原' : ''}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          backgroundColor: Colors.black87,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_flash)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color:
                          _options.choice('flashColor', [
                                    'black',
                                    'white',
                                    'alternate',
                                  ]) ==
                                  'white' ||
                              (_options.choice('flashColor', [
                                        'black',
                                        'white',
                                        'alternate',
                                      ]) ==
                                      'alternate' &&
                                  _turns.isOdd)
                          ? Colors.white
                          : Colors.black,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double _webtoonWidth(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final ratio = switch (_options.choice('webtoonWidth', [
      'fit',
      '4:3',
      '3:2',
      '16:9',
      '20:9',
    ])) {
      '4:3' => 3 / 4,
      '3:2' => 2 / 3,
      '16:9' => 9 / 16,
      '20:9' => 9 / 20,
      _ => 0.0,
    };
    return ratio == 0
        ? size.width
        : (size.height * ratio).clamp(1, size.width).toDouble();
  }

  Widget _buildBody(ReaderSettings settings) {
    final layout = _layout;
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
      return _zoomContent(
        -1,
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null) _pendingLocalPage = null;
            if (notification.dragDetails != null &&
                _chromeVisible &&
                _options.choice('hideOnScroll', ['off', 'high', 'low']) !=
                    'off' &&
                (notification.scrollDelta?.abs() ?? 0) >
                    (_options.choice('hideOnScroll', ['off', 'high', 'low']) ==
                            'high'
                        ? 5
                        : 31)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _chromeVisible = false);
              });
            }
            return false;
          },
          child: ScrollablePositionedList.builder(
            key: ValueKey((_chapterIndex, _requestSeq, _layoutRevision)),
            physics: const NeverScrollableScrollPhysics(),
            itemScrollController: _itemScroll,
            itemPositionsListener: _positions,
            initialScrollIndex: _screen,
            itemCount: layout.count + (_localComplete ? 1 : 0),
            scrollOffsetController: _scrollOffset,
            itemBuilder: (context, index) => Builder(
              builder: (itemContext) {
                _webtoonScroll = Scrollable.of(itemContext).position;
                return index == layout.count
                    ? SizedBox(
                        height: MediaQuery.sizeOf(itemContext).height,
                        child: const Center(child: Icon(Icons.arrow_downward)),
                      )
                    : Padding(
                        padding:
                            EdgeInsets.symmetric(
                              horizontal:
                                  MediaQuery.sizeOf(itemContext).width *
                                  _options.number('webtoonPadding', 0, 0, 25) /
                                  100,
                            ).copyWith(
                              bottom: _options.number('webtoonGap', 0, 0, 48),
                            ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: _webtoonWidth(itemContext),
                            ),
                            child: _renderLeaf(
                              layout.firstAt(index),
                              BoxFit.fitWidth,
                            ),
                          ),
                        ),
                      );
              },
            ),
          ),
        ),
      );
    }

    return _zoomContent(
      0,
      PageView.builder(
        key: ValueKey((settings.mode, _layoutRevision)),
        controller: _pageController,
        reverse: settings.mode == ReadingMode.rtl,
        // 单指翻页仍走原生 ScrollPosition.drag/ballistic；不另设竞争识别器。
        physics: const NeverScrollableScrollPhysics(),
        scrollDirection: settings.mode == ReadingMode.vertical
            ? Axis.vertical
            : Axis.horizontal,
        onPageChanged: _onPageChanged,
        itemCount: layout.count + (_localComplete ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= layout.count) {
            return const Center(child: Icon(Icons.navigate_next));
          }
          final leaves = layout.screens[index];
          if (leaves.length == 1) {
            return _renderLeaf(leaves.first, settings.fit.boxFit);
          }
          final pages = [
            for (final leaf in leaves)
              Expanded(child: _renderLeaf(leaf, BoxFit.contain)),
          ];
          final reverse =
              (settings.mode == ReadingMode.rtl) !=
              _options.flag('invertDoublePages');
          final gap = switch (_options.choice('centerMargin', [
            'none',
            'small',
            'large',
          ])) {
            'small' => 8.0,
            'large' => 24.0,
            _ => 0.0,
          };
          final ordered = reverse ? pages.reversed.toList() : pages;
          return Row(
            children: [
              ordered.first,
              if (gap > 0) SizedBox(width: gap),
              ordered.last,
            ],
          );
        },
      ),
    );
  }

  /// 整个可见画面只用一个仲裁者，包括左右双页与条漫跨图捏合。
  Widget _zoomContent(int index, Widget child) {
    final settings = _viewSettings;
    final key = _zoomKeys.putIfAbsent(index, GlobalKey<MangaZoomViewState>.new);
    return MangaZoomView(
      key: key,
      enabled: settings.zoom && (_isPaged || _options.flag('webtoonZoom')),
      doubleTapZoom:
          settings.doubleTapZoom &&
          (_isPaged || _options.flag('webtoonDoubleTap')),
      doubleTapScale: settings.doubleTapScale,
      duration: settings.zoomDuration,
      resetToken: _zoomResetToken,
      zoomStart: _options.choice('zoomStart', [
        'auto',
        'left',
        'right',
        'center',
      ]),
      scrollPosition: () => index == -1
          ? _webtoonScroll
          : _pageController.hasClients
          ? _pageController.position
          : null,
      onTapUp: _handleTap,
      onZoomChanged: (zoomed) {
        if (!mounted || zoomed == _zoomed) return;
        setState(() => _zoomed = zoomed);
        if (!zoomed) _flushDeferredGeometry();
      },
      onPointersReleased: _flushDeferredGeometry,
      child: child,
    );
  }

  /// 放大状态不跨页：翻页或换章时复位，避免下一页带着旧倍数和偏移。
  void _resetZoom() {
    _zoomResetToken++;
    if (_zoomed) _zoomed = false;
  }

  /// 放大时滚轮/音量先平移；到边界才翻页。
  bool _panCurrentPage(bool forward) {
    if (!_options.flag('navigatePan')) return false;
    final state = _zoomKeys[_isPaged ? 0 : -1]?.currentState;
    if (state == null || !state.zoomed) return false;
    return state.panBy(forward ? -120 : 120);
  }

  Widget _buildChapterTransition(ReaderSettings settings) {
    final origin = _transitionOrigin!;
    final current = _chapters[origin];
    final nextIndex = _nextChapter(origin, 1);
    final next = nextIndex < _chapters.length ? _chapters[nextIndex] : null;
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

  Widget _renderLeaf(MangaLeaf leaf, BoxFit fit) =>
      _imagePage(leaf.source, fit, part: leaf.part, turns: leaf.turns);

  bool get _pointersActive =>
      _zoomKeys.values.any((key) => key.currentState?.hasPointers ?? false);

  void _flushDeferredGeometry() {
    if (!_geometryDeferred || _zoomed || _pointersActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_geometryDeferred || _zoomed || _pointersActive) return;
      setState(() {
        _geometryDeferred = false;
        _geometryRevision++;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeZoomWide());
    });
  }

  void _geometryOf(int index, Size size, int seq) {
    if (!mounted || seq != _requestSeq || _geometry[index] == size) return;
    final wasWide =
        _geometry[index] != null &&
        _geometry[index]!.width > _geometry[index]!.height;
    _geometry[index] = size;
    final layoutChanges =
        wasWide != (size.width > size.height) &&
        (_doublePage ||
            _options.flag(_isPaged ? 'splitWide' : 'splitWebtoon') ||
            _options.flag(_isPaged ? 'rotateWide' : 'rotateWebtoon'));
    if (!layoutChanges) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeZoomWide());
      return;
    }
    if (_geometryPending) return;
    _geometryPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || seq != _requestSeq) return;
      _geometryPending = false;
      if (_zoomed || _pointersActive) {
        _geometryDeferred = true;
        return;
      }
      setState(() => _geometryRevision++);
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeZoomWide());
    });
  }

  void _maybeZoomWide() {
    if (!mounted ||
        !_isPaged ||
        !_options.flag('landscapeZoom') ||
        _part != 0) {
      return;
    }
    final size = _geometry[_page];
    if (size == null ||
        size.width <= size.height ||
        _options.flag('splitWide') ||
        _options.flag('rotateWide')) {
      return;
    }
    final state = _zoomKeys[0]?.currentState;
    if (state == null || state.zoomed) return;
    final view = MediaQuery.sizeOf(context);
    final scale =
        _options.choice('wideZoomType', ['double', 'height']) == 'height'
        ? view.height / (view.width * size.height / size.width)
        : 2.0;
    final start = _options.choice('zoomStart', [
      'auto',
      'left',
      'right',
      'center',
    ]);
    state.zoomTo(
      scale,
      start: start == 'auto'
          ? (_mode == ReadingMode.rtl ? 'right' : 'left')
          : start,
    );
  }

  Widget _imagePage(int index, BoxFit fit, {int part = 0, int turns = 0}) {
    final imageSeq = _requestSeq;
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
                MediaQuery.devicePixelRatioOf(context))
            .round();
    return MangaPageImage(
      key: ValueKey((url, part, turns)),
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
      part: part,
      turns: turns,
      trimOverride: _isPaged ? null : _options.flag('trimWebtoon'),
      onGeometry: (size) => _geometryOf(index, size, imageSeq),
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
                        child: _verticalSeek
                            ? const SizedBox.shrink()
                            : Slider(
                                value: (_page + 1)
                                    .clamp(1, _images.length)
                                    .toDouble(),
                                min: 1,
                                max: _images.length.toDouble(),
                                divisions: _images.length > 1
                                    ? _images.length - 1
                                    : null,
                                label: _pageLabel,
                                onChanged: (value) =>
                                    _goToPage(value.round() - 1),
                              ),
                      ),
                      Text(
                        _pageLabel,
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
        builder: (_) => const MangaReaderSettingsSheet(),
      );

  Future<void> _showChapterList() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Consumer(
        builder: (context, sheetRef, _) {
          final options = sheetRef.watch(mangaViewSettingsProvider).options;
          final indices = [
            for (var i = 0; i < _chapters.length; i++)
              if (!_chapterFiltered(_chapters[i], options)) i,
          ];
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .75,
              child: ListView.builder(
                itemCount: indices.length + 1,
                itemBuilder: (context, slot) {
                  if (slot == 0) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: DropdownButtonFormField<String>(
                        initialValue: options.choice('chapterFilter', [
                          'all',
                          'unread',
                          'read',
                        ]),
                        decoration: const InputDecoration(labelText: '章节目录筛选'),
                        items: const [
                          DropdownMenuItem(value: 'all', child: Text('全部章节')),
                          DropdownMenuItem(
                            value: 'unread',
                            child: Text('仅未读章节'),
                          ),
                          DropdownMenuItem(value: 'read', child: Text('仅已读章节')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(
                              sheetRef
                                  .read(mangaReaderPreferencesProvider)
                                  .set('chapterFilter', value),
                            );
                          }
                        },
                      ),
                    );
                  }
                  final index = indices[slot - 1];
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
        },
      ),
    );
  }
}
