import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import 'data/dandanplay_client.dart';
import 'data/danmaku_overlay.dart';

/// 播放器入参：作品 + 目录 + 从第几集开始。
class PlayerArgs {
  const PlayerArgs({
    required this.item,
    required this.chapters,
    required this.initialIndex,
  });

  final MediaItem item;
  final List<Chapter> chapters;
  final int initialIndex;
}

/// 番剧播放器：media_kit（libmpv）内核 + 自绘弹幕层。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.args});

  final PlayerArgs args;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final Player _player;
  late final VideoController _videoController;

  /// initState 里从 ref 取出保存；dispose 里写最后一次进度时用。
  LibraryRepository? _libraryRepository;

  late final DanmakuController _danmaku = DanmakuController();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _progressTimer;

  late int _chapterIndex;

  bool _loading = true;
  String? _error;

  List<PlaySource> _lines = const <PlaySource>[];
  int _lineIndex = 0;

  bool _chromeVisible = true;
  bool _danmakuOn = true;
  bool _fullscreen = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.args.initialIndex.clamp(
      0,
      widget.args.chapters.length - 1,
    );

    // dispose() 里不能用 ref（Riverpod 3 会在卸载时封禁），
    // 退出播放器时还要写最后一次进度，所以提前把仓储握在手里。
    _libraryRepository = ref.read(libraryRepositoryProvider);

    _player = Player();
    // 模拟器上 media_kit 会自动降级到 S/W 渲染，其外部纹理在部分
    // 模拟器（Impeller + x86_64）上无法合成；真机默认路径没问题，
    // 这里显式开硬件加速以保证模拟器调试时画面可见。
    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _positionSub = _player.stream.position.listen(_onPosition);
    _durationSub = _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });

    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _persistProgress(),
    );

    unawaited(_load());
  }

  MediaItem get _item => widget.args.item;
  List<Chapter> get _chapters => widget.args.chapters;
  Chapter get _chapter => _chapters[_chapterIndex];

  void _onPosition(Duration position) {
    _position = position;
    _danmaku.update(position, playing: _playing);
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- 加载

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _lines = const <PlaySource>[];
      _lineIndex = 0;
    });

    try {
      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == _item.sourceId)
          .firstOrNull;
      final provider = entry?.source;
      if (provider is! ContentProvider) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '来源没有提供正文能力，无法取播放地址',
        );
      }

      final content = await provider.content(_chapter);
      if (content.playSources.isEmpty) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '这一集没有解析到播放地址：请检查规则的 content.playSources',
        );
      }

      _lines = content.playSources;
      await _openLine(_lines.first.url);

      unawaited(_loadDanmaku(content.danmakuUrl));

      if (mounted) {
        setState(() {
          _loading = false;
          _chromeVisible = true;
        });
      }
    } on SourceException catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = SourceRegistry.describeError(error, _item.sourceId);
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _openLine(String url) async {
    _danmaku.seek(Duration.zero);
    await _player.open(Media(url));
    await _player.play();
  }

  Future<void> _loadDanmaku(String? danmakuUrl) async {
    if (danmakuUrl == null || danmakuUrl.isEmpty) return;
    try {
      final response = await ref
          .read(sourceHttpClientProvider)
          .send(SourceRequest(url: danmakuUrl), sourceId: _item.sourceId);
      final comments = DandanplayClient.parseCommentsBody(response.body);
      if (mounted) _danmaku.load(comments);
    } catch (_) {
      // 弹幕拿不到不影响播放；入口仍在，用户可以手动重试。
    }
  }

  // ---------------------------------------------------------------- 进度

  Future<void> _persistProgress() async {
    if (_loading || _error != null) return;
    final repository = _libraryRepository;
    if (repository == null) return;
    try {
      await repository.updateProgress(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapterNumber: _chapter.number ?? (_chapter.sortIndex + 1).toDouble(),
      );
      await repository.recordHistory(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: _chapter,
        position: _position.inSeconds.toDouble(),
      );
      // dispose 时 mounted 已为 false，ref 不可用；书架与历史页
      // 会在下次进入时自动取最新数据。
      if (mounted) {
        ref.invalidate(libraryProvider);
        ref.invalidate(historyProvider);
      }
    } catch (_) {
      // 进度写失败不应该打断播放。
    }
  }

  // ---------------------------------------------------------------- 章节切换

  Future<void> _switchChapter(int delta) async {
    final target = _chapterIndex + delta;
    if (target < 0 || target >= _chapters.length) {
      _toast(delta > 0 ? '已经是最后一集' : '已经是第一集');
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

  // ---------------------------------------------------------------- 全屏

  Future<void> _setFullscreen(bool value) async {
    setState(() => _fullscreen = value);
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _fullscreen) {
          await _setFullscreen(false);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: !_fullscreen,
          bottom: !_fullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _VideoArea(
                controller: _videoController,
                loading: _loading,
                error: _error,
                onRetry: _load,
              ),
              if (!_loading && _error == null)
                DanmakuOverlay(controller: _danmaku),
              if (!_loading && _error == null) _buildGestureArea(),
              if (!_loading && _error == null && _chromeVisible) _buildChrome(),
            ],
          ),
        ),
      ),
    );
  }

  /// 手势：中间单击切换控制条；两侧单击 = ±10 秒；双击 = 播放/暂停。
  Widget _buildGestureArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _skip(-10),
                onDoubleTap: _togglePlay,
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _chromeVisible = !_chromeVisible),
              onDoubleTap: _togglePlay,
              child: SizedBox(width: width * 0.34),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _skip(10),
                onDoubleTap: _togglePlay,
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _skip(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero ? Duration.zero : target;
    await _player.seek(clamped);
    _danmaku.seek(clamped);
  }

  Future<void> _togglePlay() async {
    _playing ? await _player.pause() : await _player.play();
  }

  Widget _buildChrome() {
    final theme = Theme.of(context);
    final positionText = _format(_position);
    final durationText = _format(
      _duration == Duration.zero ? _player.state.duration : _duration,
    );

    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _chromeVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Column(
          children: <Widget>[
            // 顶栏
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs,
                AppSpacing.xs,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Colors.black54, Colors.transparent],
                ),
              ),
              child: Row(
                children: <Widget>[
                  BackButton(
                    color: Colors.white,
                    onPressed: () async {
                      if (_fullscreen) {
                        await _setFullscreen(false);
                      } else if (context.mounted) {
                        Navigator.of(context).maybePop();
                      }
                    },
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
                    tooltip: _danmakuOn ? '关闭弹幕' : '开启弹幕',
                    onPressed: () {
                      setState(() => _danmakuOn = !_danmakuOn);
                      _danmaku.enabled = _danmakuOn;
                    },
                    icon: Icon(
                      _danmakuOn
                          ? Icons.speaker_notes_outlined
                          : Icons.speaker_notes_off_outlined,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // 底栏
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.xs,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: <Color>[Colors.black54, Colors.transparent],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        IconButton(
                          onPressed: _togglePlay,
                          icon: Icon(
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          '$positionText / $durationText',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        if (_lines.length > 1)
                          TextButton(
                            onPressed: _pickLine,
                            child: Text(
                              _lines[_lineIndex].name,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        TextButton(
                          onPressed: _showEpisodes,
                          child: const Text(
                            '剧集',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        IconButton(
                          tooltip: '全屏',
                          onPressed: () => _setFullscreen(!_fullscreen),
                          icon: const Icon(
                            Icons.fullscreen_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                      ),
                      child: Slider(
                        value: _sliderValue,
                        max: _sliderMax,
                        onChanged: (value) {
                          final target = Duration(milliseconds: value.round());
                          setState(() => _position = target);
                        },
                        onChangeEnd: (value) async {
                          final target = Duration(milliseconds: value.round());
                          await _player.seek(target);
                          _danmaku.seek(target);
                        },
                      ),
                    ),
                    Row(
                      children: <Widget>[
                        const Spacer(),
                        TextButton(
                          onPressed: () => _switchChapter(-1),
                          child: const Text(
                            '上一集',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _switchChapter(1),
                          child: const Text(
                            '下一集',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
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

  double get _sliderValue =>
      _position.inMilliseconds.clamp(0, _sliderMax).toDouble();

  double get _sliderMax {
    final duration = _duration == Duration.zero
        ? _player.state.duration
        : _duration;
    return duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds.toDouble();
  }

  Future<void> _pickLine() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var index = 0; index < _lines.length; index++)
              ListTile(
                leading: Icon(
                  index == _lineIndex
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(_lines[index].name),
                onTap: () => Navigator.of(context).pop(index),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == _lineIndex) return;
    setState(() => _lineIndex = selected);
    await _openLine(_lines[selected].url);
  }

  Future<void> _showEpisodes() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _chapters.length,
          itemBuilder: (context, index) => ListTile(
            leading: index == _chapterIndex
                ? const Icon(Icons.play_circle_fill_rounded)
                : const Icon(Icons.play_circle_outline),
            title: Text(
              _chapters[index].title,
              style: index == _chapterIndex
                  ? TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: AppTypography.medium,
                    )
                  : null,
            ),
            onTap: () => Navigator.of(context).pop(index),
          ),
        ),
      ),
    );
    if (selected == null || selected == _chapterIndex) return;
    setState(() => _chapterIndex = selected);
    await _load();
  }

  static String _format(Duration duration) {
    final total = duration.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    final hours = minutes ~/ 60;
    if (hours > 0) {
      return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    unawaited(_persistProgress());
    _progressTimer?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _player.dispose();
    _danmaku.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
    }
    super.dispose();
  }
}

class _VideoArea extends StatelessWidget {
  const _VideoArea({
    required this.controller,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final VideoController controller;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 40, color: Colors.white70),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '播放加载失败',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.white70),
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

    // 缓冲占位放在 Video 下面一层，画面出来前不会黑得不明所以。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (loading)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        Video(controller: controller),
      ],
    );
  }
}
