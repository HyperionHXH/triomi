import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/platform/platform_channel.dart';
import '../../core/source/mihon_source.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/storage/preferences.dart';
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
  late int _chapterIndex = widget.args.initialIndex.clamp(
    0,
    _chapters.length - 1,
  );
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
  int _layoutSpreadSize = 1;
  Future<void> _saveQueue = Future<void>.value();
  ({String chapter, double page})? _lastQueuedProgress;
  bool _restoring = true;
  final FocusNode _focusNode = FocusNode();

  List<String> _images = const <String>[];
  String? _error;
  bool _loading = true;
  bool _chromeVisible = true;
  int _page = 0;
  int _requestSeq = 0;
  bool _chaptersCached = false;

  List<Chapter> get _chapters => widget.args.chapters;
  Chapter get _chapter => _chapters[_chapterIndex];
  MediaItem get _item => widget.args.item;
  MediaItem _owner(Chapter chapter) =>
      widget.args.chapterOwners[mangaChapterKey(chapter)] ?? _item;

  /// dispose 里不能用 ref（Riverpod 3 会在卸载时封禁）：
  /// 仓储与追踪上报器提前握在手里，退出时才补得进最后一次进度。
  late final LibraryRepository _libraryRepository;

  ProgressReporter? _trackingReporter;
  bool _keepScreenOn = false;
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
          !_itemScroll.isAttached) {
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
      unawaited(platformChannel.setKeepScreenOn(true));
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
    PaintingBinding.instance.imageCache.maximumSizeBytes = _previousCacheBytes;
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onScroll);
    _pageController.dispose();
    _focusNode.dispose();
    unawaited(_persistProgress());
    unawaited(_setImmersive(immersive: false));
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(false));
    }
    unawaited(SystemChrome.setPreferredOrientations(<DeviceOrientation>[]));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) unawaited(_persistProgress());
  }

  // ------------------------------------------------------------------ 加载

  Future<void> _load() async {
    final seq = ++_requestSeq;
    _restoring = true;
    setState(() {
      _loading = true;
      _error = null;
      _images = const <String>[];
      _page = 0;
    });

    try {
      final chapter = _chapter;
      if (chapter.locked) {
        throw StateError('章节已锁定，不能打开或缓存');
      }
      final saved = await _libraryRepository.chapterPositionOf(
        _owner(chapter).sourceId,
        _owner(chapter).remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      // 离线优先：下载过的章节直接读本地图片目录。
      final localImages = await _localImagesOf(chapter);
      if (!mounted || seq != _requestSeq) return;
      if (localImages.isNotEmpty) {
        setState(() {
          _images = localImages;
          _page = (saved?.floor() ?? 0).clamp(0, _images.length - 1);
          _loading = false;
        });
        unawaited(_cacheChapters());
        _restorePage(seq);
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

      unawaited(_cacheChapters());
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

  void _restorePage(int seq) {
    _resetPageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || seq != _requestSeq) return;
      _restoring = false;
      unawaited(_persistProgress());
    });
  }

  /// 已下载章节的本地图片路径（file:// 形式）；没下载过返回空列表。
  Future<List<String>> _localImagesOf(Chapter chapter) async {
    final directory = await ref
        .read(downloadRepositoryProvider)
        .localImageDir(chapter.sourceId, chapter.remoteId);
    if (directory == null || directory.isEmpty) return const <String>[];
    final manifest = await DownloadManifest.read(directory);
    if (manifest == null || manifest.files.isEmpty) return const <String>[];
    return <String>[
      for (final name in manifest.files)
        Uri.file('$directory${Platform.pathSeparator}$name').toString(),
    ];
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
  Future<void> _cacheChapters() async {
    if (_chaptersCached || widget.args.chapterOwners.isNotEmpty) return;
    _chaptersCached = true;
    await ref
        .read(libraryRepositoryProvider)
        .saveChapters(
          itemSourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: _chapters,
        );
  }

  Future<void> _persistProgress() {
    if (_loading || _error != null || _images.isEmpty || _restoring) {
      return Future<void>.value();
    }
    final repository = _libraryRepository;
    final chapter = _chapter;
    final page = _page.toDouble();
    final progress = (chapter: mangaChapterKey(chapter), page: page);
    if (_lastQueuedProgress == progress) return _saveQueue;
    _lastQueuedProgress = progress;
    return _saveQueue = _saveQueue.then((_) async {
      try {
        await repository.updateProgress(
          sourceId: _owner(chapter).sourceId,
          remoteId: _owner(chapter).remoteId,
          chapterNumber: chapter.number ?? (chapter.sortIndex + 1).toDouble(),
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
                chapterNumber:
                    chapter.number ?? (chapter.sortIndex + 1).toDouble(),
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
    if (!mounted || _isPaged || _restoring || _loading) {
      return;
    }
    final visible =
        _positions.itemPositions.value
            .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final index = visible.first.index;
    if (index != _page) {
      setState(() => _page = index);
      unawaited(_persistProgress());
    }
  }

  void _onPageChanged(int index) {
    if (_restoring || _loading) return;
    final page = index * _spreadSize;
    if (_page == page) return;
    setState(() => _page = page);
    unawaited(_persistProgress());
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _images.length) return;
    if (_isPaged) index = index ~/ _spreadSize * _spreadSize;
    if (_page == index) return;
    if (_isPaged) {
      _pageController.animateToPage(
        index ~/ _spreadSize,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (_itemScroll.isAttached) {
      _itemScroll.jumpTo(index: index);
    }
    setState(() => _page = index);
    unawaited(_persistProgress());
  }

  void _nextPage() {
    if (_page + _spreadSize < _images.length) {
      _goToPage(_page + _spreadSize);
    } else {
      _switchChapter(1);
    }
  }

  void _previousPage() {
    if (_page > 0) {
      _goToPage((_page - _spreadSize).clamp(0, _images.length - 1));
    } else {
      _switchChapter(-1);
    }
  }

  void _switchChapter(int delta) {
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) {
      _toast(delta > 0 ? '已经是最后一章' : '已经是第一章');
      return;
    }
    unawaited(_persistProgress());
    setState(() {
      _chapterIndex = target;
      _page = 0;
    });
    _resetPageController();
    unawaited(_load());
  }

  /// 换章 / 切模式后重建 PageController。
  ///
  /// 旧的控制器要等本帧渲染完再释放：立即 dispose 会被仍在树上的 PageView 引用。
  void _resetPageController() {
    final old = _pageController;
    _pageController = PageController(initialPage: _page ~/ _spreadSize);
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

  /// 图片加载失败后重试：先把缓存里的失败结果清掉，再重建。
  void _retryImage(String url) {
    unawaited(
      SourceNetworkImage(
        url,
        http: ref.read(sourceHttpClientProvider),
        sourceId: _chapter.sourceId,
      ).evict(),
    );
    if (mounted) setState(() {});
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
      Navigator.of(context).maybePop();
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
      if (previous?.base.mode != next.base.mode ||
          previous?.doublePage != next.doublePage) {
        _resetPageController();
      }
    });
    if (_layoutSpreadSize != _spreadSize) {
      _layoutSpreadSize = _spreadSize;
      _resetPageController();
    }

    return Scaffold(
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
                  if (!_isPaged) return;
                  event.scrollDelta.dy > 0 ? _nextPage() : _previousPage();
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _handleTap,
                  child: _buildBody(settings),
                ),
              ),
            ),
            _buildChrome(settings),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ReaderSettings settings) {
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
      return ScrollablePositionedList.builder(
        key: ValueKey('$_chapterIndex:$_requestSeq'),
        itemScrollController: _itemScroll,
        itemPositionsListener: _positions,
        initialScrollIndex: _page,
        itemCount: _images.length,
        scrollOffsetController: _scrollOffset,
        itemBuilder: (context, index) => _imagePage(index, BoxFit.fitWidth),
      );
    }

    return PageView.builder(
      key: ValueKey<ReadingMode>(settings.mode),
      controller: _pageController,
      reverse: settings.mode == ReadingMode.rtl,
      scrollDirection: settings.mode == ReadingMode.vertical
          ? Axis.vertical
          : Axis.horizontal,
      onPageChanged: _onPageChanged,
      itemCount: (_images.length / _spreadSize).ceil(),
      itemBuilder: (context, index) {
        final first = index * _spreadSize;
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

  Widget _imagePage(int index, BoxFit fit) {
    final url = _images[index];
    final ImageProvider provider = url.startsWith('file://')
        ? FileImage(File(Uri.parse(url).toFilePath()))
        : !url.contains('://')
        ? FileImage(File(url))
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
      onRetry: () => _retryImage(url),
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
                            _chapter.title,
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
