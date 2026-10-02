import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../downloads/data/download_providers.dart';
import '../../library/data/library_providers.dart';
import '../../library/data/library_repository.dart';
import '../../tracking/data/tracking_providers.dart';
import '../data/lk/lk_source.dart';
import '../tts/flutter_tts_engine.dart';
import '../tts/tts_controller.dart';
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

/// 小说阅读器：分页（仿真翻页用简化平移）与滚动双模式。
class NovelReaderPage extends ConsumerStatefulWidget {
  const NovelReaderPage({super.key, required this.args});

  final NovelReaderArgs args;

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends ConsumerState<NovelReaderPage>
    with WidgetsBindingObserver {
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
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _blockKeys = <GlobalKey>[];

  bool _chromeVisible = true;
  Timer? _saveDebounce;
  bool _keepScreenOn = false;
  TtsController? _tts;
  bool _ttsBusy = false;

  MediaItem get _item => widget.args.item;
  List<Chapter> get _chapters => widget.args.chapters;
  Chapter get _chapter => _chapters[_chapterIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    _releaseTts();
    _saveDebounce?.cancel();
    // dispose 里不能用 ref；仓储已在 initState 里取出。
    unawaited(_persistProgress(commit: true));
    if (_keepScreenOn) {
      unawaited(platformChannel.setKeepScreenOn(false));
    }
    unawaited(SystemChrome.setPreferredOrientations(<DeviceOrientation>[]));
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _releaseTts();
      if (mounted) setState(() {});
    }
  }

  void _releaseTts() {
    _tts?.removeListener(_onTtsChanged);
    _tts?.dispose();
    _tts = null;
  }

  void _onTtsChanged() {
    if (!mounted) return;
    final anchor = _tts?.progress?.anchor;
    if (anchor != null && _settings.mode == NovelReadingMode.paged) {
      final index = _pages.indexWhere(
        (page) => page.elements.any((e) => e.blockIndex == anchor),
      );
      if (index >= 0) _pageIndex = index;
    } else if (anchor != null && _settings.mode == NovelReadingMode.scroll) {
      _scrollToBlock(anchor);
    }
    setState(() {});
    if (_tts?.state == TtsState.error) _toast('朗读失败，请检查系统语音引擎');
    _scheduleSave();
  }

  void _scrollToBlock(int blockIndex) {
    if (blockIndex < 0 || blockIndex >= _blockKeys.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _blockKeys[blockIndex].currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.18,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _toggleTts() async {
    if (_ttsBusy || _locked || _loading || _error != null || _blocks.isEmpty) {
      return;
    }
    setState(() => _ttsBusy = true);
    try {
      final current = _tts;
      if (current?.state == TtsState.playing) {
        await current!.pause();
      } else if (current?.state == TtsState.paused) {
        await current!.resume();
      } else {
        final anchor = _progressParagraph;
        _releaseTts();
        final engine = ref.read(ttsEngineFactoryProvider)();
        // 语音选项在会话开始前应用一次（D48：变更只影响下一次朗读）。
        await engine.applySpeechSettings(
          rate: _settings.ttsRate,
          voice: _settings.ttsVoice,
        );
        final controller = TtsController(engine: engine, blocks: _blocks);
        _tts = controller;
        controller.addListener(_onTtsChanged);
        final index = controller.plan.utterances.indexWhere(
          (u) => u.blockIndex >= anchor,
        );
        if (index >= 0) await controller.seekToUtterance(index);
      }
    } catch (_) {
      _toast('朗读失败，请检查系统语音引擎');
    } finally {
      if (mounted) setState(() => _ttsBusy = false);
    }
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
    _releaseTts();
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
    _releaseTts();
    setState(() {
      _loading = true;
      _error = null;
      _locked = _chapter.locked;
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
      final local = await downloadRepository.localChapterContent(
        _chapter.sourceId,
        _chapter.remoteId,
      );
      final ChapterContent content;
      if (local != null && !local.isEmpty) {
        content = local;
      } else {
        final snapshot = await ref.read(sourcesProvider.future);
        final entry = snapshot.entries
            .where((candidate) => candidate.descriptor.id == _item.sourceId)
            .firstOrNull;
        final provider = entry?.source;
        if (provider is! ContentProvider) {
          throw StateError('来源没有提供正文能力');
        }
        content = await provider.content(_chapter);
      }
      final raw = (html: content.html ?? '', text: content.text ?? '');
      _rawContent = raw;
      _sourceFont = content.fontFamily;
      _zh ??= await ZhConverter.instance();
      final blocks = ReaderContentParser.parse(
        bodyHtml: _localized(raw.html),
        bodyText: _localized(raw.text),
      );
      if (mounted) {
        setState(() {
          _blocks = blocks;
          _loading = false;
        });
      }
      // 章节打开即记历史；进度回传（登录来源）尽力而为。
      unawaited(_persistProgress(commit: true));
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  /// 正文样式：来源要求专用字体时（轻书架 B7）覆盖用户选的字体——
  /// 站点替换过字形，用别的字体渲染出来是乱码。
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
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), () {
      unawaited(_persistProgress(commit: false));
    });
  }

  Future<void> _persistProgress({required bool commit}) async {
    if (_loading || _error != null || _locked) return;
    final percent = _percent.clamp(0, 100);
    try {
      await _libraryRepository.updateProgress(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapterNumber: _chapter.number ?? (_chapter.sortIndex + 1).toDouble(),
      );
      await _libraryRepository.recordHistory(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: _chapter,
        position: _progressParagraph.toDouble(),
      );
      // 进度上报（追踪服务）：尽力而为，失败不影响阅读。
      unawaited(
        _trackingReporter?.report(
              sourceId: _item.sourceId,
              remoteId: _item.remoteId,
              chapterNumber:
                  _chapter.number ?? (_chapter.sortIndex + 1).toDouble(),
              type: MediaType.novel,
            ) ??
            Future<void>.value(),
      );
      if (mounted) {
        ref.invalidate(libraryProvider);
        ref.invalidate(historyProvider);
      }
      // 登录来源（如轻之国度）同步进度到站点。
      if (commit) {
        final snapshot = await ref.read(sourcesProvider.future);
        final entry = snapshot.entries
            .where((candidate) => candidate.descriptor.id == _item.sourceId)
            .firstOrNull;
        final provider = entry?.source;
        if (provider is LkSource && provider.isLoggedIn) {
          await provider.syncProgress(
            item: _item,
            chapter: _chapter,
            paragraphIndex: _progressParagraph,
            percent: percent,
          );
        }
      }
    } catch (_) {
      // 进度写失败不打断阅读。
    }
  }

  /// 当前读到第几个排版块（进度回传用段落下标）。
  int get _progressParagraph {
    if (_tts?.state == TtsState.playing || _tts?.state == TtsState.paused) {
      final anchor = _tts?.progress?.anchor;
      if (anchor != null) return anchor;
    }
    if (_settings.mode == NovelReadingMode.scroll) {
      if (!_scrollController.hasClients) return 0;
      final position = _scrollController.offset;
      final viewport = _scrollController.position.viewportDimension;
      final total = _scrollController.position.maxScrollExtent + viewport;
      if (total <= 0) return 0;
      return (_blocks.length * (position / total)).floor().clamp(
        0,
        _blocks.length - 1,
      );
    }
    if (_pages.isEmpty) return 0;
    final page = _pages[_pageIndex.clamp(0, _pages.length - 1)];
    return page.elements.isEmpty ? 0 : page.elements.first.blockIndex;
  }

  int get _percent {
    if (_settings.mode == NovelReadingMode.scroll) {
      if (!_scrollController.hasClients) return 0;
      final viewport = _scrollController.position.viewportDimension;
      final total = _scrollController.position.maxScrollExtent + viewport;
      if (total <= 0) return 0;
      return (_scrollController.offset / total * 100).round().clamp(0, 100);
    }
    if (_pages.isEmpty) return 100;
    return ((_pageIndex + 1) / _pages.length * 100).round().clamp(0, 100);
  }

  // ---------------------------------------------------------------- 翻页/章节

  void _turnPage(int delta) {
    if (_pages.isEmpty) return;
    final target = _pageIndex + delta;
    if (target < 0) {
      unawaited(_switchChapter(-1));
      return;
    }
    if (target >= _pages.length) {
      unawaited(_switchChapter(1));
      return;
    }
    setState(() => _pageIndex = target);
    _scheduleSave();
  }

  Future<void> _switchChapter(int delta) async {
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) {
      _toast(delta > 0 ? '已经是最后一章' : '已经是第一章');
      return;
    }
    setState(() => _chapterIndex = target);
    await _load();
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
    if (_settings.mode != NovelReadingMode.paged) return KeyEventResult.ignored;
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

  /// TTS 语音选项变更（D48）：先停止当前朗读，下次开始时应用；
  /// 本机设置即时落盘。
  void _applyTtsSettings(NovelReaderSettings next) {
    _releaseTts();
    setState(() => _settings = next);
    unawaited(next.save(ref.read(preferencesProvider)));
  }

  Future<void> _showTtsSettings() async {
    final engine = ref.read(ttsEngineFactoryProvider)();
    final voices = await engine.availableVoices();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _TtsSettingsSheet(
        settings: _settings,
        voices: voices,
        onSettingsChanged: _applyTtsSettings,
      ),
    );
  }

  Future<void> _showSettings() async {
    final updated = await showModalBottomSheet<NovelReaderSettings>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SettingsSheet(settings: _settings),
    );
    if (updated == null || updated == _settings) return;
    final zhChanged = updated.zhMode != _settings.zhMode;
    if (updated.orientation != _settings.orientation) {
      unawaited(_applyOrientation(updated.orientation));
    }
    setState(() => _settings = updated);
    // 先重转换再落盘：设置变更立即生效，持久化是尽力而为的收尾。
    if (zhChanged) await _reconvert();
    unawaited(updated.save(ref.read(preferencesProvider)));
    // 分页结果随样式变化重建；滚动模式无需处理。
    setState(() {});
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _settings.theme.background,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Stack(
            children: <Widget>[
              _buildBody(),
              if (_chromeVisible) _buildChrome(),
            ],
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
          if (_pageIndex >= _pages.length) {
            _pageIndex = _pages.isEmpty ? 0 : _pages.length - 1;
          }
          if (_pageIndex < 0) _pageIndex = 0;
        }

        if (_pages.isEmpty) {
          return const Center(child: Text('本章没有内容'));
        }
        final current = _pageIndex.clamp(0, _pages.length - 1);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _handlePageTap,
          child: Padding(
            padding: EdgeInsets.all(_settings.pageMargin),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: _PageContent(
                    page: _pages[current],
                    settings: _settings,
                    sourceId: _item.sourceId,
                    sourceFont: _sourceFont,
                  ),
                ),
                SizedBox(
                  height: _pageIndicatorHeight,
                  child: Text(
                    '${current + 1} / ${_pages.length}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: _settings.theme.foreground.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handlePageTap(TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
    if (x < width * 0.3) {
      _turnPage(-1);
    } else if (x > width * 0.7) {
      _turnPage(1);
    } else {
      setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  Widget _buildScrollView() {
    while (_blockKeys.length < _blocks.length) {
      _blockKeys.add(GlobalKey());
    }
    if (_blockKeys.length > _blocks.length) {
      _blockKeys.removeRange(_blocks.length, _blockKeys.length);
    }
    return Stack(
      children: <Widget>[
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollEndNotification) _scheduleSave();
            return false;
          },
          child: ListView.separated(
            controller: _scrollController,
            padding: EdgeInsets.symmetric(
              horizontal: _settings.pageMargin + 8,
              vertical: _settings.pageMargin,
            ),
            itemCount: _blocks.length,
            separatorBuilder: (context, index) =>
                SizedBox(height: _settings.fontSize * 0.5),
            itemBuilder: (context, index) => KeyedSubtree(
              key: _blockKeys[index],
              child: _BlockView(
                block: _blocks[index],
                settings: _settings,
                sourceId: _item.sourceId,
                sourceFont: _sourceFont,
              ),
            ),
          ),
        ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.md,
          child: FloatingActionButton.small(
            backgroundColor: _settings.theme.background,
            foregroundColor: _settings.theme.foreground,
            elevation: 2,
            onPressed: () => setState(() => _chromeVisible = !_chromeVisible),
            child: const Icon(Icons.menu, size: 20),
          ),
        ),
      ],
    );
  }

  Widget _buildChrome() {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: GestureDetector(
        // 半透明遮罩必须自己接管点击（ColoredBox 是 opaque 命中测试，
        // 否则会吞掉整个屏幕的触摸）：点空白处收起控制条，按钮优先命中。
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _chromeVisible = !_chromeVisible),
        child: Container(
          color: Colors.black54,
          child: SafeArea(
            child: Column(
              children: <Widget>[
                // 顶栏
                Row(
                  children: <Widget>[
                    BackButton(
                      color: Colors.white,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        '${_item.title} · ${_chapter.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '阅读设置',
                      onPressed: _showSettings,
                      icon: const Icon(Icons.text_format, color: Colors.white),
                    ),
                  ],
                ),
                const Spacer(),
                if (ttsPlatformSupported &&
                    !_locked &&
                    !_loading &&
                    _error == null)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: _tts?.state == TtsState.playing
                            ? '暂停朗读'
                            : '朗读',
                        onPressed: _ttsBusy ? null : _toggleTts,
                        icon: Icon(
                          _tts?.state == TtsState.playing
                              ? Icons.pause
                              : Icons.volume_up_outlined,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        tooltip: '停止朗读',
                        onPressed: _tts == null || _ttsBusy
                            ? null
                            : () {
                                _releaseTts();
                                setState(() {});
                              },
                        icon: const Icon(Icons.stop, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: '朗读设置',
                        onPressed: _showTtsSettings,
                        icon: const Icon(Icons.tune, color: Colors.white),
                      ),
                    ],
                  ),
                // 底栏
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_settings.mode == NovelReadingMode.paged &&
                        _pages.isNotEmpty)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                        ),
                        child: Slider(
                          value: _pageIndex
                              .clamp(0, _pages.length - 1)
                              .toDouble(),
                          max: (_pages.length - 1).toDouble().clamp(
                            0,
                            double.infinity,
                          ),
                          onChanged: (value) =>
                              setState(() => _pageIndex = value.round()),
                        ),
                      ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => unawaited(_switchChapter(-1)),
                          child: const Text(
                            '上一章',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.lg),
                        TextButton(
                          onPressed: () => unawaited(_switchChapter(1)),
                          child: const Text(
                            '下一章',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
class _PageContent extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var index = 0; index < page.elements.length; index++) {
      final element = page.elements[index];
      switch (element) {
        case TextElement(:final text, :final heading):
          if (index > 0 && !heading) {
            // 段间距取 0.7×字号，分页模型按 0.8×字号预留（略多留一点当余量）。
            children.add(SizedBox(height: settings.fontSize * 0.7));
          }
          children.add(
            Text(
              text,
              style: _style(
                heading
                    ? settings.headingStyle(context)
                    : settings.paragraphStyle(context),
              ),
            ),
          );
        case IllustrationElement(:final block, :final heightPx):
          children.add(SizedBox(height: settings.fontSize * 0.6));
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
                  child: Image.network(
                    block.url,
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
class _BlockView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return switch (block) {
      HeadingBlock(:final text) => Text(
        text,
        style: _style(settings.headingStyle(context)),
      ),
      ParagraphBlock(:final text, :final firstLineIndent) => Text(
        firstLineIndent ? '　　$text' : text,
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
            child: Image.network(
              url,
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

/// 阅读设置抽屉：模式 / 主题 / 字号 / 行距 / 边距 / 繁简 / 字体。
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.settings});

  final NovelReaderSettings settings;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late NovelReaderSettings _draft = widget.settings;

  NovelReaderSettings get value => _draft;

  List<UserFont> _fonts = const <UserFont>[];

  /// 拖动过程只改草稿（视觉即时反馈），松手才提交生效。
  void commit(NovelReaderSettings next) => Navigator.of(context).pop(next);
  @override
  void initState() {
    super.initState();
    unawaited(_loadFonts());
  }

  Future<void> _loadFonts() async {
    await UserFontStore.instance.ensureLoaded();
    final fonts = await UserFontStore.instance.list();
    if (!mounted) return;
    setState(() => _fonts = fonts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget title(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, 0, 0),
      child: Text(text, style: theme.textTheme.titleSmall),
    );

    void commitDraft(NovelReaderSettings next) {
      setState(() => _draft = next);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, AppSpacing.lg),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            title('阅读模式'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SegmentedButton<NovelReadingMode>(
                segments: const <ButtonSegment<NovelReadingMode>>[
                  ButtonSegment(
                    value: NovelReadingMode.paged,
                    icon: Icon(Icons.auto_stories_outlined, size: 18),
                    label: Text('分页'),
                  ),
                  ButtonSegment(
                    value: NovelReadingMode.scroll,
                    icon: Icon(Icons.swap_vert, size: 18),
                    label: Text('滚动'),
                  ),
                ],
                selected: {value.mode},
                onSelectionChanged: (selection) =>
                    commit(value.copyWith(mode: selection.first)),
              ),
            ),
            title('主题'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  for (final candidate in NovelTheme.values)
                    ChoiceChip(
                      label: Text(candidate.label),
                      selected: value.theme == candidate,
                      onSelected: (_) =>
                          commit(value.copyWith(theme: candidate)),
                    ),
                ],
              ),
            ),
            title('字号 ${value.fontSize.round()}'),
            Slider(
              value: value.fontSize,
              min: 12,
              max: 32,
              divisions: 20,
              label: value.fontSize.round().toString(),
              onChanged: (next) => commitDraft(value.copyWith(fontSize: next)),
              onChangeEnd: (next) => commit(value.copyWith(fontSize: next)),
            ),
            title('行距 ${value.lineHeight.toStringAsFixed(1)}'),
            Slider(
              value: value.lineHeight,
              min: 1.2,
              max: 2.4,
              divisions: 12,
              label: value.lineHeight.toStringAsFixed(1),
              onChanged: (next) =>
                  commitDraft(value.copyWith(lineHeight: next)),
              onChangeEnd: (next) => commit(value.copyWith(lineHeight: next)),
            ),
            title('页边距 ${value.pageMargin.round()}'),
            Slider(
              value: value.pageMargin,
              min: 8,
              max: 48,
              divisions: 10,
              label: value.pageMargin.round().toString(),
              onChanged: (next) =>
                  commitDraft(value.copyWith(pageMargin: next)),
              onChangeEnd: (next) => commit(value.copyWith(pageMargin: next)),
            ),
            title('繁简转换'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: SegmentedButton<ZhConversionMode>(
                segments: const <ButtonSegment<ZhConversionMode>>[
                  ButtonSegment(value: ZhConversionMode.off, label: Text('原文')),
                  ButtonSegment(
                    value: ZhConversionMode.s2t,
                    label: Text('简→繁'),
                  ),
                  ButtonSegment(
                    value: ZhConversionMode.t2s,
                    label: Text('繁→简'),
                  ),
                ],
                selected: {value.zhMode},
                onSelectionChanged: (selection) =>
                    commit(value.copyWith(zhMode: selection.first)),
              ),
            ),
            title('阅读操作'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('音量键翻页'),
                    subtitle: const Text('开启后音量键不再调节音量'),
                    value: value.volumeKeyTurn,
                    onChanged: (next) =>
                        commit(value.copyWith(volumeKeyTurn: next)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('屏幕常亮'),
                    value: value.keepScreenOn,
                    onChanged: (next) =>
                        commit(value.copyWith(keepScreenOn: next)),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: SegmentedButton<ReaderOrientation>(
                      segments: const <ButtonSegment<ReaderOrientation>>[
                        ButtonSegment(
                          value: ReaderOrientation.system,
                          label: Text('跟随系统'),
                        ),
                        ButtonSegment(
                          value: ReaderOrientation.portrait,
                          label: Text('竖屏'),
                        ),
                        ButtonSegment(
                          value: ReaderOrientation.landscape,
                          label: Text('横屏'),
                        ),
                      ],
                      selected: {value.orientation},
                      onSelectionChanged: (selection) =>
                          commit(value.copyWith(orientation: selection.first)),
                    ),
                  ),
                ],
              ),
            ),
            title('正文字体'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('系统默认'),
                    selected: value.fontFamily == null,
                    onSelected: (_) =>
                        commit(value.copyWith(clearFontFamily: true)),
                  ),
                  for (final font in _fonts)
                    ChoiceChip(
                      label: Text(font.displayName),
                      selected: value.fontFamily == font.familyName,
                      onSelected: (_) =>
                          commit(value.copyWith(fontFamily: font.familyName)),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: const Text('导入'),
                    onPressed: () async {
                      final sheetMessenger = ScaffoldMessenger.of(context);
                      try {
                        await UserFontStore.instance.pickAndImport();
                        await _loadFonts();
                      } catch (error) {
                        sheetMessenger.showSnackBar(
                          SnackBar(content: Text('导入失败：$error')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// TTS 语音选项小面板（D48）：语速三档 + 系统音色（仅列引擎返回的可用项）。
///
/// 变更即通过 [onSettingsChanged] 提交（阅读器负责停止当前朗读并落盘）。
class _TtsSettingsSheet extends StatelessWidget {
  const _TtsSettingsSheet({
    required this.settings,
    required this.voices,
    required this.onSettingsChanged,
  });

  final NovelReaderSettings settings;
  final List<TtsVoiceInfo> voices;
  final void Function(NovelReaderSettings next) onSettingsChanged;

  String _rateLabel(double rate) => switch (rate) {
    0.3 => '慢速 0.3',
    0.7 => '快速 0.7',
    _ => '正常 0.5',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('朗读设置'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('语速', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              children: <Widget>[
                for (final rate in NovelReaderSettings.ttsRateChoices)
                  ChoiceChip(
                    label: Text(_rateLabel(rate)),
                    selected: settings.ttsRate == rate,
                    onSelected: (_) =>
                        onSettingsChanged(settings.copyWith(ttsRate: rate)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('音色', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            if (voices.isEmpty)
              Text(
                '系统未返回可用音色，将使用系统默认音色',
                style: theme.textTheme.bodySmall,
              )
            else
              Builder(
                builder: (context) {
                  // 重启后系统音色列表可能变化：已保存但系统不再返回的
                  // 音色保留为独立选项（显示「不可用」），避免 Dropdown 断言。
                  final saved = settings.ttsVoice;
                  final savedUnavailable =
                      saved != null && !voices.contains(saved);
                  return DropdownButton<TtsVoiceInfo?>(
                    isExpanded: true,
                    value: saved,
                    items: <DropdownMenuItem<TtsVoiceInfo?>>[
                      const DropdownMenuItem<TtsVoiceInfo?>(
                        value: null,
                        child: Text('系统默认'),
                      ),
                      if (savedUnavailable)
                        DropdownMenuItem<TtsVoiceInfo?>(
                          value: saved,
                          child: Text(
                            '${saved.label}（不可用）',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      for (final voice in voices)
                        DropdownMenuItem<TtsVoiceInfo?>(
                          value: voice,
                          child: Text(
                            voice.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (voice) => onSettingsChanged(
                      voice == null
                          ? settings.copyWith(clearTtsVoice: true)
                          : settings.copyWith(
                              ttsVoiceName: voice.name,
                              ttsVoiceLocale: voice.locale,
                            ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
