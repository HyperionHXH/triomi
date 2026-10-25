import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/media_item.dart';
import '../../../core/models/media_type.dart';
import '../../../core/platform/platform_channel.dart';
import '../../../core/source/source_api.dart';
import '../../../core/source/source_providers.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/text/zh_converter.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/image_viewer.dart';
import '../../../core/widgets/source_network_image.dart';
import '../../downloads/data/download_providers.dart';
import '../../library/data/library_providers.dart';
import '../../library/data/library_repository.dart';
import '../../tracking/data/tracking_providers.dart';
import '../data/lk/lk_source.dart';
import 'chapter_font.dart';
import 'novel_blocks.dart';
import 'novel_reader_settings.dart';
import 'user_font_store.dart';

/// 小说阅读器入参：作品 + 目录 + 从第几章开始。
class NovelReaderArgs {
  const NovelReaderArgs({
    required this.item,
    required this.chapters,
    required this.initialIndex,
  });

  final MediaItem item;
  final List<Chapter> chapters;
  final int initialIndex;
}

/// 小说阅读器：左右翻页、卡片翻页与上下滚动，共享稳定的正文位置。
class NovelReaderPage extends ConsumerStatefulWidget {
  const NovelReaderPage({super.key, required this.args});

  final NovelReaderArgs args;

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends ConsumerState<NovelReaderPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final LibraryRepository _libraryRepository;

  /// dispose 里不能用 ref：进度上报器同样提前取出。
  ProgressReporter? _trackingReporter;
  late NovelReaderSettings _settings;
  late int _chapterIndex;

  bool _loading = true;
  String? _error;
  bool _locked = false;

  List<ReaderBlock> _blocks = const <ReaderBlock>[];

  /// 来源下发的正文必需字体（轻书架 B7）：有它就必须用它渲染，否则字形是错的。
  String? _sourceFont;
  List<ReaderPage> _pages = const <ReaderPage>[];
  String? _layoutKey;

  /// 本章原始正文（繁简切换时重转换用，不重新请求网络）。
  ({String html, String text})? _rawContent;

  int _pageIndex = 0;
  final ItemScrollController _itemScroll = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  int _requestSeq = 0;
  double? _resumePosition;
  bool _restoring = true;
  bool _disposing = false;
  Future<void> _saveQueue = Future<void>.value();

  bool _chromeVisible = false;
  double _pageDrag = 0;
  int _turnDirection = 1;
  late final AnimationController _pageMotion;
  double _pageWidth = 1;
  bool _pageAnimating = false;
  bool _switchingChapter = false;
  Timer? _saveDebounce;
  bool _keepScreenOn = false;
  bool _scrollUpdateScheduled = false;
  double? _publishedScrollPosition;
  int? _publishedScrollPercent;

  bool get _hasReadableContent =>
      !_loading && _error == null && !_locked && _blocks.isNotEmpty;

  MediaItem get _item => widget.args.item;
  List<Chapter> get _chapters => widget.args.chapters;
  Chapter get _chapter => _chapters[_chapterIndex];

  @override
  void initState() {
    super.initState();
    _pageMotion = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (mounted) setState(() => _pageDrag = _pageMotion.value);
      });
    WidgetsBinding.instance.addObserver(this);
    _positions.itemPositions.addListener(_onScrollPositionsChanged);
    _libraryRepository = ref.read(libraryRepositoryProvider);
    _trackingReporter = ref.read(progressReporterProvider);
    _chapterIndex = widget.args.initialIndex.clamp(
      0,
      widget.args.chapters.length - 1,
    );
    _settings = NovelReaderSettings.load(ref.read(preferencesProvider));
    // 屏幕常亮（阅读期间），退出时关闭。
    _keepScreenOn = _settings.keepScreenOn;
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(true));
    }
    // 屏幕方向（B4）：进入锁定，退出恢复跟随系统。
    unawaited(_applyOrientation(_settings.orientation));
    // 自定义字体先进引擎（幂等），正文样式才能立刻生效。
    unawaited(UserFontStore.instance.ensureLoaded());
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposing = true;
    _pageMotion.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onScrollPositionsChanged);
    _saveDebounce?.cancel();
    // dispose 里不能用 ref；仓储已在 initState 里取出。
    unawaited(_persistProgress(commit: true));
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(false));
    }
    unawaited(SystemChrome.setPreferredOrientations(<DeviceOrientation>[]));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_persistProgress(commit: true));
    }
  }

  void _onScrollPositionsChanged() {
    if (!mounted ||
        _disposing ||
        _settings.mode != NovelReadingMode.scroll ||
        !_hasReadableContent ||
        _scrollUpdateScheduled) {
      return;
    }
    if (_publishedScrollPosition == _readingPosition &&
        _publishedScrollPercent == _percent) {
      return;
    }
    _scrollUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollUpdateScheduled = false;
      if (!mounted ||
          _disposing ||
          _settings.mode != NovelReadingMode.scroll ||
          !_hasReadableContent) {
        return;
      }
      _publishedScrollPosition = _readingPosition;
      _publishedScrollPercent = _percent;
      setState(() {});
      _saveDebounce?.cancel();
      _saveDebounce = Timer(const Duration(seconds: 1), () {
        unawaited(_persistProgress(commit: false));
      });
    });
    WidgetsBinding.instance.scheduleFrame();
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

  // ---------------------------------------------------------------- 加载

  /// 繁简转换器（首次加载章节时初始化）。
  ZhConverter? _zh;

  /// 按当前繁简设置转换文本；转换器未就绪时原样返回。
  String _localized(String text) {
    final zh = _zh;
    if (zh == null) return text;
    return zh.convert(text, _settings.zhMode);
  }

  /// 繁简设置变化后用缓存的原始正文重转换（不重新请求网络）。
  Future<void> _reconvert() async {
    final raw = _rawContent;
    if (raw == null) return;
    _zh ??= await ZhConverter.instance();
    final blocks = ReaderContentParser.parse(
      bodyHtml: _localized(raw.html),
      bodyText: _localized(raw.text),
    );
    if (mounted) setState(() => _blocks = blocks);
  }

  Future<void> _load() async {
    _pageMotion.stop();
    _pageDrag = 0;
    final seq = ++_requestSeq;
    final chapter = _chapter;
    _saveDebounce?.cancel();
    _restoring = true;
    _resumePosition = null;
    setState(() {
      _loading = true;
      _error = null;
      _locked = chapter.locked;
      _blocks = const <ReaderBlock>[];
      _pages = const <ReaderPage>[];
      _layoutKey = null;
      _rawContent = null;
      _pageIndex = 0;
    });

    if (_locked) {
      setState(() => _loading = false);
      return;
    }

    try {
      // 离线优先：下载过的章节直接读本地正文（不依赖来源可用）。
      final downloadRepository = ref.read(downloadRepositoryProvider);
      final saved = await _libraryRepository.chapterPositionOf(
        _item.sourceId,
        _item.remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      final local = await downloadRepository.localChapterContent(
        chapter.sourceId,
        chapter.remoteId,
      );
      if (!mounted || seq != _requestSeq) return;
      final ChapterContent content;
      if (local != null && !local.isEmpty) {
        content = local;
      } else {
        final snapshot = await ref.read(sourcesProvider.future);
        if (!mounted || seq != _requestSeq) return;
        final entry = snapshot.entries
            .where((candidate) => candidate.descriptor.id == _item.sourceId)
            .firstOrNull;
        if (entry == null || !entry.enabled) {
          throw StateError('来源已停用或移除，本章没有本地缓存');
        }
        final provider = entry.source;
        if (provider is! ContentProvider) {
          throw StateError('来源没有提供正文能力');
        }
        content = await provider.content(chapter);
      }
      if (!mounted || seq != _requestSeq) return;
      final raw = (html: content.html ?? '', text: content.text ?? '');
      if (raw.html.trim().isEmpty && raw.text.trim().isEmpty) {
        throw StateError('本章没有取到正文，请重试或切换来源');
      }
      _rawContent = raw;
      if (content.fontFamily != null &&
          content.fontData == null &&
          local != null) {
        throw StateError('旧下载缺少章节专用字体，请联网重新下载后阅读');
      }
      _sourceFont = content.fontData == null
          ? content.fontFamily
          : await ChapterFont.register(content.fontData!);
      _zh ??= await ZhConverter.instance();
      if (!mounted || seq != _requestSeq) return;
      final blocks = ReaderContentParser.parse(
        bodyHtml: _localized(raw.html),
        bodyText: _localized(raw.text),
      );
      if (mounted) {
        setState(() {
          _blocks = blocks;
          _resumePosition = saved ?? 0;
          _loading = false;
        });
      }
      // 章节打开即记历史；进度回传（登录来源）尽力而为。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || seq != _requestSeq) return;
        _finishRestore(seq);
      });
    } catch (error) {
      if (mounted && seq == _requestSeq) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  /// 正文样式：来源要求专用字体时（轻书架 B7）覆盖用户选的字体——
  /// 站点替换过字形，用别的字体渲染出来是乱码。
  void _finishRestore(int seq) {
    if (!mounted || seq != _requestSeq) return;
    if (_settings.mode == NovelReadingMode.scroll &&
        _resumePosition != null &&
        _blocks.isNotEmpty) {
      final saved = _resumePosition!;
      final index = saved.floor().clamp(0, _blocks.length - 1);
      final item = _positions.itemPositions.value
          .where((p) => p.index == index)
          .firstOrNull;
      if (_itemScroll.isAttached && item != null) {
        final fraction = (saved - saved.floor()).clamp(0.0, 0.999999);
        _itemScroll.jumpTo(
          index: index,
          alignment: -fraction * (item.itemTrailingEdge - item.itemLeadingEdge),
        );
      }
      _resumePosition = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || seq != _requestSeq) return;
        _restoring = false;
        unawaited(_persistProgress(commit: false));
      });
    } else {
      _restoring = false;
      unawaited(_persistProgress(commit: true));
    }
  }

  TextStyle _paragraphStyle(BuildContext context) =>
      _withSourceFont(_settings.paragraphStyle(context));

  TextStyle _headingStyle(BuildContext context) =>
      _withSourceFont(_settings.headingStyle(context));

  TextStyle _withSourceFont(TextStyle style) {
    final font = _sourceFont;
    return font == null ? style : style.copyWith(fontFamily: font);
  }

  Future<void> _unlock() async {
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == _item.sourceId)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ChapterUnlockProvider) {
        _toast('该来源不支持自动解锁，请到站点完成购买');
        return;
      }
      await provider.unlockChapter(_chapter);
      if (!mounted) return;
      _toast('解锁成功');
      setState(() => _locked = false);
      await _load();
    } catch (error) {
      _toast('解锁失败：$error');
    }
  }

  // ---------------------------------------------------------------- 进度

  void _scheduleSave() {
    unawaited(_persistProgress(commit: false));
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), () {
      unawaited(_persistProgress(commit: false));
    });
  }

  Future<void> _persistProgress({required bool commit}) {
    if (_loading ||
        _error != null ||
        _locked ||
        _restoring ||
        _blocks.isEmpty) {
      return Future<void>.value();
    }
    final percent = _percent.clamp(0, 100);
    final chapter = _chapter;
    final position = _readingPosition;
    final paragraph = _progressParagraph;
    final sourceFuture = commit && mounted && !_disposing
        ? ref.read(sourcesProvider.future)
        : null;
    return _saveQueue = _saveQueue.then((_) async {
      try {
        await _libraryRepository.updateProgress(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapterNumber: chapter.number ?? (chapter.sortIndex + 1).toDouble(),
        );
        await _libraryRepository.recordHistory(
          sourceId: _item.sourceId,
          remoteId: _item.remoteId,
          chapter: chapter,
          position: position,
        );
        // 进度上报（追踪服务）：尽力而为，失败不影响阅读。
        unawaited(
          _trackingReporter?.report(
                sourceId: _item.sourceId,
                remoteId: _item.remoteId,
                chapterNumber:
                    chapter.number ?? (chapter.sortIndex + 1).toDouble(),
                type: MediaType.novel,
              ) ??
              Future<void>.value(),
        );
        if (mounted) {
          ref.invalidate(libraryByTypeProvider);
          ref.invalidate(historyProvider);
          ref.invalidate(historyByTypeProvider);
        }
        // 登录来源（如轻之国度）同步进度到站点。
        if (sourceFuture != null) {
          unawaited(() async {
            try {
              final snapshot = await sourceFuture;
              final provider = snapshot.entries
                  .where((e) => e.descriptor.id == _item.sourceId)
                  .firstOrNull
                  ?.source;
              if (provider is LkSource && provider.isLoggedIn) {
                await provider.syncProgress(
                  item: _item,
                  chapter: chapter,
                  paragraphIndex: paragraph,
                  percent: percent,
                );
              }
            } catch (_) {
              /* Remote sync must not block local persistence. */
            }
          }());
        }
      } catch (_) {
        // 进度写失败不打断阅读。
      }
    });
  }

  double get _readingPosition {
    if (_settings.mode == NovelReadingMode.scroll) {
      final visible =
          _positions.itemPositions.value
              .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      if (visible.isEmpty) return _resumePosition ?? 0;
      final p = visible.first;
      final height = p.itemTrailingEdge - p.itemLeadingEdge;
      final fraction = height <= 0
          ? 0.0
          : (-p.itemLeadingEdge / height).clamp(0.0, 0.999999);
      return p.index + fraction;
    }
    if (_pages.isEmpty) return _resumePosition ?? 0;
    final page = _pages[_pageIndex.clamp(0, _pages.length - 1)];
    return page.elements.isEmpty
        ? 0
        : readerElementPosition(page.elements.first, _blocks);
  }

  /// 当前读到第几个排版块（进度回传用段落下标）。
  int get _progressParagraph {
    if (_blocks.isEmpty) return 0;
    if (_settings.mode == NovelReadingMode.scroll) {
      return _readingPosition.floor().clamp(0, _blocks.length - 1);
    }
    if (_pages.isEmpty) return 0;
    final page = _pages[_pageIndex.clamp(0, _pages.length - 1)];
    return page.elements.isEmpty ? 0 : page.elements.first.blockIndex;
  }

  int get _percent {
    if (_settings.mode == NovelReadingMode.scroll) {
      if (_blocks.isNotEmpty &&
          _positions.itemPositions.value.any(
            (position) =>
                position.index == _blocks.length - 1 &&
                position.itemTrailingEdge <= 1 &&
                position.itemTrailingEdge > 0,
          )) {
        return 100;
      }
      return _blocks.isEmpty
          ? 0
          : (_readingPosition / _blocks.length * 100).round().clamp(0, 100);
    }
    if (_pages.isEmpty) return 100;
    return ((_pageIndex + 1) / _pages.length * 100).round().clamp(0, 100);
  }

  // ---------------------------------------------------------------- 翻页/章节

  void _turnPage(int delta) {
    if (!_hasReadableContent ||
        _pages.isEmpty ||
        _pageAnimating ||
        _switchingChapter) {
      return;
    }
    final target = _pageIndex + delta;
    if (target < 0 || target >= _pages.length) {
      // MixN changes chapters at the edge, without animating a blank page.
      _commitPageTurn(delta);
      return;
    }
    unawaited(_settlePageTurn(delta));
  }

  Future<void> _settlePageTurn(int delta) async {
    if (_pageAnimating) return;
    _pageAnimating = true;
    if (delta != 0) _turnDirection = delta;
    try {
      _pageMotion.value = _pageDrag;
      await _pageMotion
          .animateTo(
            delta == 0 ? 0 : -delta * _pageWidth,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          )
          .orCancel;
      if (!mounted) return;
      if (delta != 0) _commitPageTurn(delta);
      _pageMotion.value = 0;
    } on TickerCanceled {
      // Leaving the reader cancels the turn without committing a new position.
    } finally {
      _pageAnimating = false;
    }
  }

  void _commitPageTurn(int delta) {
    final target = _pageIndex + delta;
    if (target < 0) {
      unawaited(_switchChapter(-1));
      return;
    }
    if (target >= _pages.length) {
      unawaited(_switchChapter(1));
      return;
    }
    setState(() {
      _turnDirection = delta;
      _pageIndex = target;
    });
    _scheduleSave();
  }

  Future<void> _switchChapter(int delta) async {
    if (_switchingChapter) return;
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) {
      _toast(delta > 0 ? '已经是最后一章' : '已经是第一章');
      return;
    }
    _switchingChapter = true;
    try {
      await _persistProgress(commit: false);
      if (!mounted) return;
      setState(() => _chapterIndex = target);
      await _load();
    } finally {
      _switchingChapter = false;
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_settings.mode == NovelReadingMode.scroll) {
      return KeyEventResult.ignored;
    }
    // 音量键翻页：默认关（防误触），开启后接管系统音量键。
    if (_settings.volumeKeyTurn) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.audioVolumeDown:
          _turnPage(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.audioVolumeUp:
          _turnPage(-1);
          return KeyEventResult.handled;
      }
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.pageDown:
        _turnPage(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.pageUp:
        _turnPage(-1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------- 设置

  Future<void> _showSettings({bool textOnly = false}) async {
    final updated = await showDialog<NovelReaderSettings>(
      context: context,
      builder: (context) => _SettingsSheet(
        settings: _settings,
        textOnly: textOnly,
        sourceFontRequired: _sourceFont != null,
      ),
    );
    if (!mounted || updated == null) return;
    final anchor = _readingPosition;
    _pageMotion.stop();
    _pageDrag = 0;
    final modeChanged = updated.mode != _settings.mode;
    final zhChanged = updated.zhMode != _settings.zhMode;
    if (updated.orientation != _settings.orientation) {
      unawaited(_applyOrientation(updated.orientation));
    }
    if (updated.keepScreenOn != _keepScreenOn) {
      _keepScreenOn = updated.keepScreenOn;
      unawaited(platformChannel.setKeepScreenOn(_keepScreenOn));
    }
    setState(() {
      _resumePosition = anchor;
      _settings = updated;
      _layoutKey = null;
      _restoring = true;
    });
    if (modeChanged && updated.mode == NovelReadingMode.scroll) _pageIndex = 0;
    // 先重转换再落盘：设置变更立即生效，持久化是尽力而为的收尾。
    if (zhChanged) await _reconvert();
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _finishRestore(_requestSeq),
    );
    unawaited(updated.save(ref.read(preferencesProvider)));
    // 分页结果随样式变化重建；滚动模式无需处理。
    setState(() {});
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final readerTheme = Theme.of(context).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _settings.theme.foreground,
        brightness: _settings.theme == NovelTheme.dark
            ? Brightness.dark
            : Brightness.light,
      ),
      textTheme: Theme.of(context).textTheme.apply(
        bodyColor: _settings.theme.foreground,
        displayColor: _settings.theme.foreground,
      ),
    );
    return Theme(
      data: readerTheme,
      child: Scaffold(
        backgroundColor: _settings.theme.background,
        body: SafeArea(
          child: Focus(
            autofocus: true,
            onKeyEvent: _handleKey,
            child: Stack(
              children: <Widget>[
                _buildBody(),
                if (_chromeVisible || !_hasReadableContent) _buildChrome(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    if (_locked) {
      return _LockedView(
        chapterTitle: _chapter.title,
        volumeTitle: _chapter.volumeTitle,
        onUnlock: _unlock,
      );
    }
    if (_blocks.isEmpty) {
      return const Center(child: Text('本章没有内容'));
    }
    if (_settings.mode == NovelReadingMode.scroll) {
      return _buildScrollView();
    }
    return _buildPagedView();
  }

  /// 页码行的高度（与下方渲染保持一致，否则分页会多放一行导致溢出）。
  static const double _pageIndicatorHeight = 22;

  Widget _buildPagedView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - _settings.pageMargin * 2;
        final contentHeight =
            constraints.maxHeight -
            _settings.pageMargin * 2 -
            _pageIndicatorHeight;
        // 分页很贵（TextPainter 逐段排版）：按布局键缓存，键不变不重排。
        final layoutKey =
            '$_chapterIndex|${_settings.mode}|'
            '${_settings.fontSize}|${_settings.lineHeight}|${_settings.pageMargin}|'
            '${_settings.zhMode.name}|${_settings.fontFamily ?? 'default'}|'
            '${_sourceFont ?? 'default'}|'
            '${contentWidth.round()}x${contentHeight.round()}';
        if (_layoutKey != layoutKey) {
          final anchor = _resumePosition ?? _readingPosition;
          // A resize/reflow keeps the committed character anchor, not a
          // partially animated target measured against the old viewport.
          _pageMotion.stop();
          _pageDrag = 0;
          _layoutKey = layoutKey;
          _pages = paginateReaderBlocks(
            _blocks,
            PaginationStyle(
              paragraphStyle: _paragraphStyle(context),
              headingStyle: _headingStyle(context),
              pageWidth: contentWidth,
              pageHeight: contentHeight,
              spacing: _settings.fontSize * 0.8,
            ),
          );
          _pageIndex = readerPageForPosition(_pages, _blocks, anchor);
          _resumePosition = null;
          if (_pageIndex >= _pages.length) {
            _pageIndex = _pages.isEmpty ? 0 : _pages.length - 1;
          }
          if (_pageIndex < 0) _pageIndex = 0;
        }

        if (_pages.isEmpty) {
          return const Center(child: Text('本章没有内容'));
        }
        final current = _pageIndex.clamp(0, _pages.length - 1);
        _pageWidth = _settings.mode == NovelReadingMode.card
            ? constraints.maxWidth
            : contentWidth;
        return Listener(
          onPointerCancel: (_) {
            // Flutter can end an accepted drag after pointer cancellation.
            // Roll back first so that terminal callback cannot commit a page.
            if (_pageDrag != 0) unawaited(_settlePageTurn(0));
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onTapUp: _handlePageTap,
            // Paged and card modes both follow the finger; their page composition
            // stays distinct (edge-to-edge slide versus a stationary under-page).
            onHorizontalDragUpdate: (details) {
              if (_pageAnimating) return;
              setState(() {
                _pageDrag = (_pageDrag + details.delta.dx).clamp(
                  -_pageWidth,
                  _pageWidth,
                );
                if (_pageDrag != 0) _turnDirection = _pageDrag < 0 ? 1 : -1;
              });
            },
            onHorizontalDragCancel: () {
              if (_pageDrag != 0) unawaited(_settlePageTurn(0));
            },
            onHorizontalDragEnd: (details) {
              if (_pageAnimating) return;
              final velocity = details.primaryVelocity ?? 0;
              final delta = _pageDrag.abs() > _pageWidth * 0.25
                  ? (_pageDrag < 0 ? 1 : -1)
                  : velocity.abs() > 500
                  ? (velocity < 0 ? 1 : -1)
                  : 0;
              unawaited(_settlePageTurn(delta));
            },
            child: Padding(
              padding: EdgeInsets.all(_settings.pageMargin),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_pageDrag != 0 &&
                              current + (_pageDrag < 0 ? 1 : -1) >= 0 &&
                              current + (_pageDrag < 0 ? 1 : -1) <
                                  _pages.length)
                            Transform.translate(
                              offset: Offset(
                                _settings.mode == NovelReadingMode.card
                                    ? 0
                                    : _pageDrag + _turnDirection * _pageWidth,
                                0,
                              ),
                              child: SizedBox.expand(
                                key: const ValueKey('novel-adjacent-page'),
                                child: _pageContent(
                                  current + (_pageDrag < 0 ? 1 : -1),
                                ),
                              ),
                            ),
                          Transform.translate(
                            offset: Offset(_pageDrag, 0),
                            child: Material(
                              elevation:
                                  _settings.mode == NovelReadingMode.card &&
                                      _pageDrag != 0
                                  ? 8
                                  : 0,
                              color: _settings.theme.background,
                              child: SizedBox.expand(
                                key: const ValueKey('novel-current-page'),
                                child: _pageContent(current),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: _pageIndicatorHeight,
                    child: Text(
                      '${current + 1} / ${_pages.length}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: _settings.theme.foreground.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pageContent(int index) => _PageContent(
    page: _pages[index],
    settings: _settings,
    sourceId: _item.sourceId,
    sourceFont: _sourceFont,
  );

  void _handlePageTap(TapUpDetails details) {
    final width =
        _pageWidth +
        (_settings.mode == NovelReadingMode.paged
            ? _settings.pageMargin * 2
            : 0);
    final x = details.localPosition.dx;
    if (x < width * 0.25) {
      _turnPage(-1);
    } else if (x > width * 0.75) {
      _turnPage(1);
    } else {
      setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  Widget _buildScrollView() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _chromeVisible = !_chromeVisible),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification) {
            _scheduleSave();
            setState(() {});
          }
          return false;
        },
        child: ScrollablePositionedList.separated(
          key: ValueKey('$_chapterIndex:$_requestSeq'),
          itemScrollController: _itemScroll,
          itemPositionsListener: _positions,
          initialScrollIndex: (_resumePosition ?? 0).floor().clamp(
            0,
            _blocks.length - 1,
          ),
          padding: EdgeInsets.all(_settings.pageMargin),
          itemCount: _blocks.length,
          separatorBuilder: (context, index) =>
              SizedBox(height: _settings.fontSize * 0.5),
          itemBuilder: (context, index) => _BlockView(
            block: _blocks[index],
            settings: _settings,
            sourceId: _item.sourceId,
            sourceFont: _sourceFont,
          ),
        ),
      ),
    );
  }

  Widget _buildChrome() {
    final scrolling = _settings.mode == NovelReadingMode.scroll;
    final canSeek =
        !_loading && !_locked && _error == null && _blocks.isNotEmpty;
    final max = scrolling
        ? (_blocks.length - 1).clamp(0, _blocks.length)
        : (_pages.length - 1).clamp(0, _pages.length);
    final position = scrolling ? _readingPosition : _pageIndex.toDouble();
    return Positioned.fill(
      child: Stack(
        children: [
          if (_hasReadableContent)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _chromeVisible = false),
              ),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: Material(
              color: _settings.theme.background,
              elevation: 2,
              child: Row(
                children: [
                  BackButton(onPressed: () => Navigator.of(context).maybePop()),
                  Expanded(
                    child: Text(
                      '${_item.title} · ${_chapter.title}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '阅读菜单',
                    onPressed: _showMenu,
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: _settings.theme.background,
              elevation: 4,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        scrolling
                            ? '${_chapter.title} · 已读 $_percent%'
                            : '${_chapter.title} · ${_pages.isEmpty ? 0 : _pageIndex + 1} / ${_pages.length}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Slider(
                      value: position.clamp(0, max).toDouble(),
                      max: max > 0 ? max.toDouble() : 1,
                      onChanged: canSeek && max > 0
                          ? (value) {
                              if (scrolling) {
                                if (_itemScroll.isAttached) {
                                  _itemScroll.jumpTo(index: value.round());
                                }
                              } else {
                                setState(() => _pageIndex = value.round());
                                _scheduleSave();
                              }
                            }
                          : null,
                    ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          onPressed: _chapterIndex > 0 && !_loading
                              ? () => unawaited(_switchChapter(-1))
                              : null,
                          child: const Text('上一章'),
                        ),
                        TextButton.icon(
                          onPressed: _showCatalog,
                          icon: const Icon(Icons.list),
                          label: const Text('目录'),
                        ),
                        TextButton.icon(
                          onPressed: () => _showSettings(textOnly: true),
                          icon: const Icon(Icons.text_fields),
                          label: const Text('文字样式'),
                        ),
                        TextButton.icon(
                          onPressed: _showSettings,
                          icon: const Icon(Icons.settings_outlined),
                          label: const Text('阅读设置'),
                        ),
                        TextButton(
                          onPressed:
                              _chapterIndex < _chapters.length - 1 && !_loading
                              ? () => unawaited(_switchChapter(1))
                              : null,
                          child: const Text('下一章'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMenu() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(_item.title),
                  subtitle: Text(
                    '${_chapter.title}\n${_settings.mode.label} · $_percent%',
                  ),
                ),
                for (final entry in const [
                  ('catalog', Icons.list, '打开章节目录', '选择其他章节'),
                  ('text', Icons.text_fields, '文字样式', '字体、字号、行距和页边距'),
                  ('settings', Icons.settings_outlined, '阅读设置', '翻页方式、阅读背景与屏幕'),
                  ('reload', Icons.refresh, '重新加载', '重新请求当前章节内容'),
                ])
                  ListTile(
                    leading: Icon(entry.$2),
                    title: Text(entry.$3),
                    subtitle: Text(entry.$4),
                    onTap: () => Navigator.pop(context, entry.$1),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'catalog':
        await _showCatalog();
      case 'text':
        await _showSettings(textOnly: true);
      case 'settings':
        await _showSettings();
      case 'reload':
        await _load();
    }
  }

  Future<void> _showCatalog() async {
    final target = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(padding: EdgeInsets.all(16), child: Text('章节目录')),
              Flexible(
                child: ScrollablePositionedList.builder(
                  initialScrollIndex: _chapterIndex,
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    return ListTile(
                      selected: index == _chapterIndex,
                      leading: chapter.locked
                          ? const Icon(Icons.lock_outline)
                          : null,
                      title: Text(chapter.title),
                      subtitle: chapter.volumeTitle == null
                          ? null
                          : Text(chapter.volumeTitle!),
                      onTap: () => Navigator.pop(context, index),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || target == null || target == _chapterIndex) return;
    await _switchChapter(target - _chapterIndex);
  }
}

/// 正文渲染样式：来源字体（轻书架 B7）优先，且**不与环境的 DefaultTextStyle 合并**
/// （`inherit: false`）。
///
/// 分页是把同一份样式直接交给 `TextPainter` 量高度的，而 `Text` 默认会再把环境
/// DefaultTextStyle 合并进来——Material 的 `bodyMedium` 带 `letterSpacing: 0.3` 与
/// `leadingDistribution: even`，于是同一个片段渲染时换行更多、整页比模型高，
/// 表现为「这页正好填满时」正文底部溢出（实测 10px）。渲染与测量必须是同一份样式。
@visibleForTesting
TextStyle readerTextStyle(TextStyle base, String? sourceFont) =>
    (sourceFont == null ? base : base.copyWith(fontFamily: sourceFont))
        .copyWith(inherit: false);

/// 一页内容：文本片段与插图的纵向排布。
class _PageContent extends ConsumerWidget {
  const _PageContent({
    required this.page,
    required this.settings,
    required this.sourceId,
    this.sourceFont,
  });
  final ReaderPage page;
  final NovelReaderSettings settings;
  final String sourceId;

  /// 来源要求的正文字体（轻书架 B7），有值时优先于用户设置。
  final String? sourceFont;

  TextStyle _style(TextStyle base) => readerTextStyle(base, sourceFont);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final http = ref.watch(sourceHttpClientProvider);
    final children = <Widget>[];
    for (var index = 0; index < page.elements.length; index++) {
      final element = page.elements[index];
      if (index > 0) {
        children.add(SizedBox(height: settings.fontSize * 0.8));
      }
      switch (element) {
        case TextElement(:final text, :final heading):
          children.add(
            Text(
              text,
              textScaler: TextScaler.noScaling,
              style: _style(
                heading
                    ? settings.headingStyle(context)
                    : settings.paragraphStyle(context),
              ),
            ),
          );
        case IllustrationElement(:final block, :final heightPx):
          children.add(
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: GestureDetector(
                onTap: () => unawaited(
                  showImageViewer(
                    context,
                    imageUrl: block.url,
                    sourceId: sourceId,
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: heightPx,
                  child: Image(
                    image: SourceNetworkImage(
                      block.url,
                      http: http,
                      sourceId: sourceId,
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => Container(
                      color: settings.theme.background.withValues(alpha: 0.5),
                      alignment: Alignment.center,
                      child: Text(
                        '插图加载失败',
                        style: TextStyle(
                          color: settings.theme.foreground.withValues(
                            alpha: 0.5,
                          ),
                          fontSize: 13,
                        ),
                      ),
                    ),
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : Container(
                            alignment: Alignment.center,
                            height: heightPx,
                            child: const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
      }
    }
    if (children.isEmpty) {
      return Text('本章没有内容', style: _style(settings.paragraphStyle(context)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// 滚动模式的一个排版块。
class _BlockView extends ConsumerWidget {
  const _BlockView({
    required this.block,
    required this.settings,
    required this.sourceId,
    this.sourceFont,
  });

  final ReaderBlock block;
  final NovelReaderSettings settings;
  final String sourceId;

  /// 来源要求的正文字体（轻书架 B7），有值时优先于用户设置。
  final String? sourceFont;

  TextStyle _style(TextStyle base) => readerTextStyle(base, sourceFont);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (block) {
      HeadingBlock(:final text) => Text(
        text,
        textScaler: TextScaler.noScaling,
        style: _style(settings.headingStyle(context)),
      ),
      ParagraphBlock(:final text, :final firstLineIndent) => Text(
        firstLineIndent ? '　　$text' : text,
        textScaler: TextScaler.noScaling,
        style: _style(settings.paragraphStyle(context)),
      ),
      IllustrationBlock(:final url, :final aspectRatio) => ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: GestureDetector(
          onTap: () => unawaited(
            showImageViewer(context, imageUrl: url, sourceId: sourceId),
          ),
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Image(
              image: SourceNetworkImage(
                url,
                http: ref.watch(sourceHttpClientProvider),
                sourceId: sourceId,
              ),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => Container(
                color: settings.theme.background.withValues(alpha: 0.5),
                alignment: Alignment.center,
                child: Text(
                  '插图加载失败',
                  style: TextStyle(
                    color: settings.theme.foreground.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    };
  }
}

/// 付费章节：只提供官方解锁入口，绝不绕过。
class _LockedView extends StatelessWidget {
  const _LockedView({
    required this.chapterTitle,
    required this.volumeTitle,
    required this.onUnlock,
  });

  final String chapterTitle;
  final String? volumeTitle;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final palette = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.lock_outline, size: 40, color: palette.primary),
            const SizedBox(height: AppSpacing.sm),
            Text('这一章是付费章节', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              volumeTitle == null || volumeTitle!.isEmpty
                  ? chapterTitle
                  : '$volumeTitle · $chapterTitle',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.key_outlined, size: 18),
              label: const Text('使用轻币解锁本章'),
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              '解锁通过站点官方接口完成，本应用不提供任何绕过方式。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: palette.onSurfaceVariant, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: AppSpacing.sm),
            Text('章节加载失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 限宽可滚动的阅读调整面板，文字与阅读操作分别组织。
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.settings,
    required this.textOnly,
    required this.sourceFontRequired,
  });

  final NovelReaderSettings settings;
  final bool textOnly;
  final bool sourceFontRequired;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late NovelReaderSettings _draft = widget.settings;
  List<UserFont> _fonts = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadFonts());
  }

  Future<void> _loadFonts() async {
    await UserFontStore.instance.ensureLoaded();
    final fonts = await UserFontStore.instance.list();
    if (mounted) setState(() => _fonts = fonts);
  }

  void _change(NovelReaderSettings next) => setState(() => _draft = next);

  Widget _section(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final value = _draft;
    return AlertDialog(
      title: Text(widget.textOnly ? '文字样式' : '阅读设置'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.textOnly) ...[
                if (widget.sourceFontRequired)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('本章使用来源专用字体以保证文字编码正确；字体选择将在普通章节生效。'),
                  ),
                _section(
                  '正文字体',
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: const Text('系统默认'),
                        selected: value.fontFamily == null,
                        onSelected: (_) =>
                            _change(value.copyWith(clearFontFamily: true)),
                      ),
                      for (final font in _fonts)
                        ChoiceChip(
                          label: Text(font.displayName),
                          selected: value.fontFamily == font.familyName,
                          onSelected: (_) => _change(
                            value.copyWith(fontFamily: font.familyName),
                          ),
                        ),
                      ActionChip(
                        label: const Text('导入字体'),
                        avatar: const Icon(Icons.add),
                        onPressed: () async {
                          try {
                            await UserFontStore.instance.pickAndImport();
                            await _loadFonts();
                          } catch (error) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('导入失败：$error')),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
                _section(
                  '字号 ${value.fontSize.round()}',
                  Slider(
                    value: value.fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    onChanged: (next) =>
                        _change(value.copyWith(fontSize: next)),
                  ),
                ),
                _section(
                  '行高 ${value.lineHeight.toStringAsFixed(1)}',
                  Slider(
                    value: value.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    onChanged: (next) =>
                        _change(value.copyWith(lineHeight: next)),
                  ),
                ),
                _section(
                  '页边距 ${value.pageMargin.round()}',
                  Slider(
                    value: value.pageMargin,
                    min: 8,
                    max: 48,
                    divisions: 10,
                    onChanged: (next) =>
                        _change(value.copyWith(pageMargin: next)),
                  ),
                ),
                _section(
                  '繁简转换',
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in const [
                        (ZhConversionMode.off, '原文'),
                        (ZhConversionMode.s2t, '简→繁'),
                        (ZhConversionMode.t2s, '繁→简'),
                      ])
                        ChoiceChip(
                          label: Text(entry.$2),
                          selected: value.zhMode == entry.$1,
                          onSelected: (_) =>
                              _change(value.copyWith(zhMode: entry.$1)),
                        ),
                    ],
                  ),
                ),
                Container(
                  color: value.theme.background,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '清晨的风吹过书页，故事从这里继续。',
                    textScaler: TextScaler.noScaling,
                    style: value.paragraphStyle(context),
                  ),
                ),
              ] else ...[
                _section(
                  '翻页方式',
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final mode in NovelReadingMode.values)
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: value.mode == mode,
                          onSelected: (_) =>
                              _change(value.copyWith(mode: mode)),
                        ),
                    ],
                  ),
                ),
                _section(
                  '阅读背景',
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final theme in NovelTheme.values)
                        ChoiceChip(
                          label: Text(theme.label),
                          selected: value.theme == theme,
                          avatar: CircleAvatar(
                            backgroundColor: theme.background,
                          ),
                          onSelected: (_) =>
                              _change(value.copyWith(theme: theme)),
                        ),
                    ],
                  ),
                ),
                _section(
                  '屏幕方向',
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in const [
                        (ReaderOrientation.system, '跟随系统'),
                        (ReaderOrientation.portrait, '竖屏'),
                        (ReaderOrientation.landscape, '横屏'),
                      ])
                        ChoiceChip(
                          label: Text(entry.$2),
                          selected: value.orientation == entry.$1,
                          onSelected: (_) =>
                              _change(value.copyWith(orientation: entry.$1)),
                        ),
                    ],
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('音量键翻页'),
                  subtitle: const Text('开启后音量键不再调节音量'),
                  value: value.volumeKeyTurn,
                  onChanged: (next) =>
                      _change(value.copyWith(volumeKeyTurn: next)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('保持屏幕常亮'),
                  value: value.keepScreenOn,
                  onChanged: (next) =>
                      _change(value.copyWith(keepScreenOn: next)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _draft),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
