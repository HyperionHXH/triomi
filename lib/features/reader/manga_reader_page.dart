import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/theme/app_tokens.dart';
import '../downloads/data/download_providers.dart';
import '../downloads/data/download_repository.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../tracking/data/tracking_providers.dart';
import 'reader_settings.dart';

/// 打开阅读器所需的上下文。
class MangaReaderArgs {
  const MangaReaderArgs({
    required this.item,
    required this.chapters,
    required this.initialIndex,
  });

  final MediaItem item;
  final List<Chapter> chapters;
  final int initialIndex;
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

class _MangaReaderPageState extends ConsumerState<MangaReaderPage> {
  late int _chapterIndex = widget.args.initialIndex;
  PageController _pageController = PageController();
  final ScrollController _scrollController = ScrollController();
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

  /// dispose 里不能用 ref（Riverpod 3 会在卸载时封禁）：
  /// 仓储与追踪上报器提前握在手里，退出时才补得进最后一次进度。
  late final LibraryRepository _libraryRepository;

  ProgressReporter? _trackingReporter;

  @override
  void initState() {
    super.initState();
    _libraryRepository = ref.read(libraryRepositoryProvider);
    _trackingReporter = ref.read(progressReporterProvider);
    _scrollController.addListener(_onScroll);
    unawaited(_setImmersive(immersive: true));
    unawaited(_load());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pageController.dispose();
    _focusNode.dispose();
    unawaited(_persistProgress());
    unawaited(_setImmersive(immersive: false));
    super.dispose();
  }

  // ------------------------------------------------------------------ 加载

  Future<void> _load() async {
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
      _images = const <String>[];
      _page = 0;
    });

    try {
      final chapter = _chapter;
      // 离线优先：下载过的章节直接读本地图片目录。
      final localImages = await _localImagesOf(chapter);
      if (seq != _requestSeq) return;
      if (localImages.isNotEmpty) {
        setState(() {
          _images = localImages;
          _loading = false;
        });
        unawaited(_cacheChapters());
        unawaited(_persistProgress());
        return;
      }

      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == _item.sourceId)
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

      final content = await provider.content(chapter);
      if (seq != _requestSeq) return;

      if (content.images.isEmpty) {
        setState(() {
          _loading = false;
          _error = _unsupportedMessage(content);
        });
        return;
      }

      setState(() {
        _images = content.images;
        _loading = false;
      });

      unawaited(_cacheChapters());
      unawaited(_persistProgress());
      unawaited(_preloadNeighbour());
    } catch (error) {
      if (seq != _requestSeq) return;
      final message = error is SourceException ? error.userMessage : '$error';
      setState(() {
        _loading = false;
        _error = message;
      });
    }
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
    if (_chaptersCached) return;
    _chaptersCached = true;
    await ref
        .read(libraryRepositoryProvider)
        .saveChapters(
          itemSourceId: _item.sourceId,
          itemRemoteId: _item.remoteId,
          chapters: _chapters,
        );
  }

  Future<void> _persistProgress() async {
    final repository = _libraryRepository;
    final chapter = _chapter;
    try {
      await repository.updateProgress(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapterNumber: chapter.number ?? (chapter.sortIndex + 1).toDouble(),
      );
      await repository.recordHistory(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: chapter,
        position: _page.toDouble(),
      );
      // 进度上报（追踪服务）：尽力而为，失败不影响阅读。
      unawaited(
        _trackingReporter?.report(
              sourceId: _item.sourceId,
              remoteId: _item.remoteId,
              chapterNumber:
                  chapter.number ?? (chapter.sortIndex + 1).toDouble(),
              type: MediaType.manga,
            ) ??
            Future<void>.value(),
      );
      // 书架与历史页要立刻反映进度；dispose 时 mounted 已为 false。
      if (mounted) {
        ref.invalidate(libraryProvider);
        ref.invalidate(historyProvider);
      }
    } catch (_) {
      // 进度写失败不应该打断阅读
    }
  }

  /// 预取下一章的前几张图，翻到下一章时不至于白屏。
  Future<void> _preloadNeighbour() async {
    final next = _chapterIndex + 1;
    if (next >= _chapters.length) return;
    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == _item.sourceId)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ContentProvider) return;
      final content = await provider.content(_chapters[next]);
      for (final url in content.images.take(3)) {
        if (!mounted) return;
        unawaited(
          precacheImage(NetworkImage(url), context).catchError((Object _) {}),
        );
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
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0 || _images.length < 2) return;
    final ratio = (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
    final index = (ratio * (_images.length - 1)).round();
    if (index != _page) setState(() => _page = index);
  }

  void _onPageChanged(int index) {
    setState(() => _page = index);
    unawaited(_persistProgress());
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _images.length) return;
    if (_isPaged) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    setState(() => _page = index);
  }

  void _nextPage() {
    if (_page < _images.length - 1) {
      _goToPage(_page + 1);
    } else {
      _switchChapter(1);
    }
  }

  void _previousPage() {
    if (_page > 0) {
      _goToPage(_page - 1);
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
    _pageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool get _isPaged => _mode != ReadingMode.webtoon;

  ReadingMode get _mode => ref.read(readerSettingsProvider).mode;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  /// 图片加载失败后重试：先把缓存里的失败结果清掉，再重建。
  void _retryImage(String url) {
    unawaited(NetworkImage(url).evict());
    if (mounted) setState(() {});
  }

  void _handleTap(TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.localPosition.dx;
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
    final settings = ref.watch(readerSettingsProvider);

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
      return ListView.builder(
        controller: _scrollController,
        itemCount: _images.length,
        itemBuilder: (context, index) => _ImagePage(
          url: _images[index],
          fit: BoxFit.fitWidth,
          onRetry: () => _retryImage(_images[index]),
        ),
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
      itemCount: _images.length,
      itemBuilder: (context, index) => _ImagePage(
        url: _images[index],
        fit: settings.fit.boxFit,
        onRetry: () => _retryImage(_images[index]),
      ),
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
                    Expanded(
                      child: Slider(
                        value: _images.isEmpty
                            ? 0
                            : (_page + 1).clamp(1, _images.length).toDouble(),
                        min: 1,
                        max: _images.isEmpty ? 1 : _images.length.toDouble(),
                        divisions: _images.length > 1
                            ? _images.length - 1
                            : null,
                        label: '${_page + 1}/${_images.length}',
                        onChanged: (value) => _goToPage(value.round() - 1),
                      ),
                    ),
                    Text(
                      '${_images.isEmpty ? 0 : _page + 1}/${_images.length}',
                      style: const TextStyle(color: Colors.white70),
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

  Future<void> _showSettings(ReaderSettings settings) async {
    final controller = ref.read(readerSettingsProvider.notifier);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('阅读模式', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final mode in ReadingMode.values)
                  ChoiceChip(
                    label: Text(mode.label),
                    selected: settings.mode == mode,
                    onSelected: (_) {
                      unawaited(controller.setMode(mode));
                      if (mode == ReadingMode.webtoon) {
                        _resetPageController();
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('图片适配', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final fit in ImageFit.values)
                  ChoiceChip(
                    label: Text(fit.label),
                    selected: settings.fit == fit,
                    onSelected: (_) => unawaited(controller.setFit(fit)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('背景', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                for (final background in ReaderBackground.values)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: background.color),
                    label: Text(background.label),
                    selected: settings.background == background,
                    onSelected: (_) =>
                        unawaited(controller.setBackground(background)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

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

/// 单页图片：加载中显示进度、失败可点击重试。
class _ImagePage extends StatelessWidget {
  const _ImagePage({
    required this.url,
    required this.fit,
    required this.onRetry,
  });

  final String url;
  final BoxFit fit;
  final VoidCallback onRetry;

  /// 本地文件（下载后的离线图片）走 file:// 或绝对路径。
  bool get _isLocal =>
      url.startsWith('file://') || (!url.contains('://') && url.length > 1);

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Center(
        child: _isLocal
            ? Image.file(
                File(Uri.parse(url).toFilePath()),
                fit: fit,
                width: double.infinity,
                errorBuilder: _errorBuilder(context),
              )
            : Image.network(
                url,
                fit: fit,
                width: double.infinity,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  final expected = progress.expectedTotalBytes;
                  return Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: expected == null
                            ? null
                            : progress.cumulativeBytesLoaded / expected,
                      ),
                    ),
                  );
                },
                errorBuilder: _errorBuilder(context),
              ),
      ),
    );
  }

  Widget Function(BuildContext, Object, StackTrace?) _errorBuilder(
    BuildContext context,
  ) =>
      (context, error, stack) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.broken_image_outlined, color: Colors.white54),
            const SizedBox(height: AppSpacing.xs),
            TextButton(onPressed: onRetry, child: const Text('重新加载')),
          ],
        ),
      );
}
