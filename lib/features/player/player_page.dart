import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/models/video_resolve_cancellation.dart';
import '../../core/router/app_router.dart';
import '../../core/source/http_client.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/storage/secure_store.dart';
import '../../core/theme/app_tokens.dart';
import '../detail/anime_source_sheet.dart';
import '../downloads/data/download_providers.dart';
import '../library/data/anime_identity_repository.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../tracking/data/tracking_providers.dart';
import 'data/dandanplay_client.dart';
import 'data/danmaku_overlay.dart';
import 'data/danmaku_settings.dart';
import 'data/player_settings.dart';
import 'episode_selector.dart';
import 'windows_video_resolver.dart';

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

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver {
  late final Player _player;
  VideoController? _videoController;
  late final _NativeAndroidVideoController _nativeVideoController;

  bool get _useNativeAndroidVideo =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// initState 里从 ref 取出保存；dispose 里写最后一次进度时用。
  LibraryRepository? _libraryRepository;

  /// 同上：dispose 里不能用 ref，进度上报器也提前握住。
  ProgressReporter? _trackingReporter;
  AnimeIdentityRepository? _animeIdentity;
  bool _resetCrossSitePosition = false;

  late final Preferences _preferences;
  late final DanmakuController _danmaku;
  late DanmakuSettings _danmakuSettings;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _progressTimer;
  StreamSubscription<String>? _playerErrorSub;
  Timer? _prepareTimer;
  StreamSubscription<bool>? _completedSub;
  late PlayerSettings _settings;
  bool _advancing = false;
  bool _inPip = false;
  double _brightness = .5;
  bool _holdingSpeed = false;

  late int _chapterIndex;

  int _loadSeq = 0;
  int _resolveSeq = 0;
  final String _resolverOwner = UniqueKey().toString();
  VideoResolveCancellation? _desktopResolve;
  bool _loading = true;
  String? _error;
  bool _awaitingPlaybackStart = true;

  List<PlaySource> _lines = const <PlaySource>[];
  int _lineIndex = 0;

  bool _chromeVisible = true;
  bool _danmakuOn = true;
  bool _fullscreen = false;
  bool _episodesOpen = false;
  bool _scrubbing = false;
  Timer? _chromeTimer;
  Timer? _seekFeedbackTimer;
  int? _seekFeedbackSeconds;
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 播放倍速（0.5~3.0）。
  double _speed = 1.0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chapterIndex = widget.args.initialIndex;

    // dispose() 里不能用 ref（Riverpod 3 会在卸载时封禁），
    // 退出播放器时还要写最后一次进度，所以提前把仓储握在手里。
    _libraryRepository = ref.read(libraryRepositoryProvider);
    _animeIdentity = ref.read(animeIdentityRepositoryProvider);
    _preferences = ref.read(preferencesProvider);
    _settings = PlayerSettings.load(_preferences);
    _speed = _settings.speed;
    _trackingReporter = ref.read(progressReporterProvider);
    _danmakuSettings = DanmakuSettings.load(_preferences);
    _danmaku = DanmakuController(settings: _danmakuSettings);
    _danmakuOn = _danmakuSettings.enabled;

    _nativeVideoController = _NativeAndroidVideoController(
      onState: _onNativeVideoState,
      onPrepared: (state) {
        _prepareTimer?.cancel();
        _awaitingPlaybackStart = false;
        _onNativeVideoState(state);
        unawaited(_applyControls());
        _scheduleChromeHide();
      },
      onError: _onNativeVideoError,
      onCompleted: () => unawaited(_onCompleted()),
      onPip: (enabled) {
        if (mounted) setState(() => _inPip = enabled);
      },
    );
    if (!_useNativeAndroidVideo) {
      _player = Player();
      // Android uses a native SurfaceView because API35 x86_64 emulators
      // render media_kit's Flutter external texture as black. Desktop keeps
      // the media_kit/libmpv path.
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
        if (mounted) {
          setState(() => _playing = playing);
          _scheduleChromeHide();
        }
      });
      _completedSub = _player.stream.completed.listen((completed) {
        if (completed) unawaited(_onCompleted());
      });
      _playerErrorSub = _player.stream.error.listen(_onNativeVideoError);
    }

    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_persistProgress());
    });

    unawaited(_load());
  }

  MediaItem get _item => widget.args.item;
  List<Chapter> get _chapters => widget.args.chapters;
  Chapter get _chapter => _chapters[_chapterIndex];
  bool get _validSelection =>
      _item.type == MediaType.anime &&
      _chapterIndex >= 0 &&
      _chapterIndex < _chapters.length &&
      !_chapters[_chapterIndex].locked &&
      _chapters[_chapterIndex].sourceId == _item.sourceId;

  void _onPosition(Duration position) {
    if (_awaitingPlaybackStart || _scrubbing) return;
    _position = position;
    _danmaku.update(position, playing: _playing);
    if (mounted) setState(() {});
  }

  void _onNativeVideoState(_NativeVideoState state) {
    if (_awaitingPlaybackStart || _scrubbing) return;
    final playingChanged = _playing != state.playing;
    _position = state.position;
    _duration = state.duration;
    _playing = state.playing;
    // Keep the danmaku clock driven by the same position source as the
    // Android native player.  Desktop receives this through media_kit's
    // position stream; the TextureView path reports it over the method
    // channel instead. Without this update, Android danmaku would remain
    // frozen at the position where the stream was initially loaded.
    _danmaku.update(state.position, playing: state.playing);
    if (mounted) setState(() {});
    if (playingChanged) _scheduleChromeHide();
  }

  void _onNativeVideoError(String message) {
    if (!mounted) return;
    _prepareTimer?.cancel();
    setState(() {
      _loading = false;
      _error = SourceException.sanitizeMessage(message);
    });
  }

  // ---------------------------------------------------------------- 加载

  Future<void> _load() async {
    if (!_validSelection) {
      setState(() {
        _loading = false;
        _error = '尚未选择有效的本站剧集，请返回选择播放来源和剧集';
      });
      return;
    }
    final seq = ++_loadSeq;
    ++_resolveSeq;
    final chapter = _chapter;
    _awaitingPlaybackStart = true;
    setState(() {
      _loading = true;
      _error = null;
      _lines = const <PlaySource>[];
      _lineIndex = 0;
    });

    try {
      if (_useNativeAndroidVideo) {
        await _nativeVideoController.pause();
      } else {
        await _player.pause();
      }
      if (!mounted || seq != _loadSeq) return;
      final savedSeconds = await _libraryRepository?.chapterPositionOf(
        _item.sourceId,
        _item.remoteId,
        chapter.remoteId,
      );
      if (!mounted || seq != _loadSeq) return;
      final resetCrossSite =
          await _animeIdentity?.shouldResetPosition(_item) ?? false;
      _resetCrossSitePosition = _resetCrossSitePosition || resetCrossSite;
      if (!mounted || seq != _loadSeq) return;
      final startPosition =
          !_resetCrossSitePosition &&
              savedSeconds != null &&
              savedSeconds.isFinite &&
              savedSeconds > 0
          ? Duration(milliseconds: (savedSeconds * 1000).round())
          : Duration.zero;
      // 离线优先：已下载到本地就直接播文件，不依赖来源与网络。
      final localPath = await ref
          .read(downloadRepositoryProvider)
          .localVideoPath(_item.sourceId, chapter.remoteId);
      if (!mounted || seq != _loadSeq) return;
      if (localPath != null) {
        _lines = const <PlaySource>[];
        await _openLine(
          Uri.file(localPath).toString(),
          startPosition: startPosition,
        );
        if (mounted && seq == _loadSeq) {
          setState(() {
            _loading = false;
            _chromeVisible = true;
          });
          _scheduleChromeHide();
        }
        return;
      }

      final snapshot = await ref.read(sourcesProvider.future);
      final entry = snapshot.entries
          .where((candidate) => candidate.descriptor.id == _item.sourceId)
          .firstOrNull;
      if (!mounted || seq != _loadSeq) return;
      if (entry == null || !entry.enabled) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.permission,
          message: '播放来源已停用或移除，请更换来源',
        );
      }
      final provider = entry.source;
      if (provider is! ContentProvider) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '来源没有提供正文能力，无法取播放地址',
        );
      }

      final content = await provider.content(chapter);
      if (!mounted || seq != _loadSeq) return;
      if (content.playSources.isEmpty) {
        throw SourceException(
          sourceId: _item.sourceId,
          type: SourceErrorType.parse,
          message: '这一集没有解析到播放地址：请检查规则的 content.playSources',
        );
      }

      _lines = content.playSources;
      await _openLine(
        _lines.first.url,
        line: _lines.first,
        startPosition: startPosition,
      );
      if (danmakuFeatureEnabled) {
        unawaited(_loadDanmaku(content.danmakuUrl));
      }

      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _chromeVisible = true;
        });
        _scheduleChromeHide();
      }
    } on SourceException catch (error) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _error = SourceRegistry.describeError(error, _item.sourceId);
        });
      }
    } catch (error) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _error = SourceException.sanitizeMessage(error is PlatformException
              ? (error.message ?? '播放暂不可用，请重试或更换播放来源')
              : '$error'.replaceFirst('Bad state: ', ''));
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_persistProgress());
  }

  Future<void> _onCompleted() async {
    if (!_validSelection ||
        _loading ||
        _error != null ||
        _awaitingPlaybackStart ||
        _advancing) {
      return;
    }
    _advancing = true;
    try {
      if (_duration > Duration.zero) _position = _duration;
      await _persistProgress();
      if (!mounted || !_settings.autoNext) return;
      final target = adjacentEpisodeIndex(_chapters, _chapterIndex, 1);
      if (target == null) return;
      setState(() => _chapterIndex = target);
      await _load();
    } finally {
      _advancing = false;
    }
  }

  Future<void> _applyControls() async {
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.setRate(_speed);
      await _nativeVideoController.setVolume(_settings.volume);
      await _nativeVideoController.setAspectRatio(_settings.aspectRatio.ratio);
      await _nativeVideoController.setBackgroundAudio(
        _settings.backgroundAudio,
      );
      await const MethodChannel('triomi/platform')
          .invokeMethod<void>('videoPolicy', {
            'owner': _resolverOwner,
            'active': true,
            'pip': true,
            'backgroundAudio': _settings.backgroundAudio,
          });
    } else {
      await _player.setRate(_speed);
      await _player.setVolume(_settings.volume * 100);
    }
  }

  Future<void> _openLine(
    String url, {
    PlaySource? line,
    Duration startPosition = Duration.zero,
  }) async {
    _prepareTimer?.cancel();
    _awaitingPlaybackStart = true;
    final seq = ++_resolveSeq;
    _desktopResolve?.cancel('已切换播放线路');
    _desktopResolve = null;
    var headers = line?.headers ?? const <String, String>{};
    if (line?.webPage == true) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        final owner = _desktopResolve = VideoResolveCancellation();
        late final ResolvedDesktopVideo result;
        try {
          result = await resolveWindowsVideo(
            context,
            line!,
            cancellation: owner,
          );
        } finally {
          if (identical(_desktopResolve, owner)) _desktopResolve = null;
          owner.dispose();
        }
        if (!mounted || seq != _resolveSeq) return;
        url = result.url;
        headers = result.headers;
      } else if (!_useNativeAndroidVideo) {
        throw StateError('此来源的网页播放解析目前支持 Android，请选择直链来源');
      } else {
        final result = await const MethodChannel('triomi/platform')
            .invokeMapMethod<String, Object?>('resolveVideo', {
              'url': url,
              'requestId': _resolverOwner,
              'headers': headers,
              'unavailableVideoUrls': line!.unavailableVideoUrls,
            });
        if (!mounted || seq != _resolveSeq) return;
        final resolved = result?['url']?.toString();
        if (resolved == null || resolved.isEmpty) {
          throw StateError('播放页未解析到视频地址');
        }
        url = resolved;
        final rawHeaders = result?['headers'];
        headers = {
          if (rawHeaders is Map)
            for (final e in rawHeaders.entries)
              e.key.toString(): e.value.toString(),
        };
      }
    }
    if (!mounted || seq != _resolveSeq) return;
    final mediaUri = Uri.tryParse(url);
    if (mediaUri == null ||
        !const {'https', 'http', 'file', 'content'}.contains(mediaUri.scheme) ||
        ((mediaUri.scheme == 'http' || mediaUri.scheme == 'https') &&
            mediaUri.host.isEmpty)) {
      throw StateError('播放来源没有返回有效的视频地址，请更换来源或剧集');
    }
    _position = startPosition;
    _duration = Duration.zero;
    _danmaku.seek(startPosition);
    if (_useNativeAndroidVideo) {
      _prepareTimer?.cancel();
      _prepareTimer = Timer(const Duration(seconds: 30), () {
        if (mounted && seq == _resolveSeq && _awaitingPlaybackStart) {
          _onNativeVideoError('视频准备超时，请重试或更换播放来源');
        }
      });
      await _nativeVideoController.setUrl(
        url,
        headers: headers,
        startPosition: startPosition,
        title: '${_item.title} · ${_chapter.title}',
      );
    } else {
      await _player.open(
        Media(url, httpHeaders: headers, start: startPosition),
      );
      if (!mounted || seq != _resolveSeq) return;
      await _player.play();
      await _videoController!.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('视频首帧等待超时，请重试或更换播放来源'),
      );
      if (!mounted || seq != _resolveSeq) return;
      _awaitingPlaybackStart = false;
    }
    await _applyControls();
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
    if (!_validSelection ||
        _loading ||
        _error != null ||
        _awaitingPlaybackStart) {
      return;
    }
    final repository = _libraryRepository;
    if (repository == null) return;
    final chapter = _chapter;
    final position = _position;
    try {
      await _animeIdentity?.recordSelection(_item, chapter);
      final subject = await _animeIdentity?.subjectFor(_item);
      if (subject != null && subject.sourceId != _item.sourceId) {
        await repository.updateProgress(
          sourceId: subject.sourceId,
          remoteId: subject.remoteId,
          chapterNumber: chapter.number ?? (chapter.sortIndex + 1).toDouble(),
        );
      }
      await repository.updateProgress(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapterNumber: chapter.number ?? (chapter.sortIndex + 1).toDouble(),
      );
      await repository.recordHistory(
        sourceId: _item.sourceId,
        remoteId: _item.remoteId,
        chapter: chapter,
        position: position.inSeconds.toDouble(),
      );
      _resetCrossSitePosition = false;
      // 进度上报（追踪服务）：尽力而为，失败不影响播放。
      unawaited(
        _trackingReporter?.report(
              sourceId: subject?.sourceId ?? _item.sourceId,
              remoteId: subject?.remoteId ?? _item.remoteId,
              chapterNumber:
                  chapter.number ?? (chapter.sortIndex + 1).toDouble(),
              type: MediaType.anime,
            ) ??
            Future<void>.value(),
      );
      // dispose 时 mounted 已为 false，ref 不可用；书架与历史页
      // 会在下次进入时自动取最新数据。
      if (mounted) {
        ref.invalidate(libraryByTypeProvider);
        ref.invalidate(historyProvider);
        ref.invalidate(historyByTypeProvider);
      }
    } catch (_) {
      // 进度写失败不应该打断播放。
    }
  }

  // ---------------------------------------------------------------- 章节切换

  Future<void> _switchChapter(int delta) async {
    final target = adjacentEpisodeIndex(_chapters, _chapterIndex, delta);
    if (target == null) {
      _toast(delta > 0 ? '已经是最后一集' : '已经是第一集');
      return;
    }
    await _persistProgress();
    if (!mounted) return;
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
    _scaffoldKey.currentState?.closeEndDrawer();
    setState(() {
      _fullscreen = value;
      _episodesOpen = false;
    });
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
    if (!_validSelection) {
      return Scaffold(
        appBar: AppBar(title: const Text('选择剧集')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('尚未选择有效的本站剧集'),
                TextButton.icon(
                  onPressed: () =>
                      showAnimeSources(context, _item, replacePlayer: true),
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('选择播放来源与剧集'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final video = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _VideoArea(
          controller: _videoController,
          nativeController: _nativeVideoController,
          aspectRatio: _settings.aspectRatio.ratio,
          backgroundAudio: _settings.backgroundAudio,
          loading: _loading || _awaitingPlaybackStart,
          error: _error,
          onRetry: _load,
          onEpisodes: _showEpisodes,
        ),
        if (danmakuFeatureEnabled &&
            !_loading &&
            !_awaitingPlaybackStart &&
            _error == null)
          DanmakuOverlay(controller: _danmaku),
        if (!_loading && !_awaitingPlaybackStart && _error == null && !_inPip)
          _buildGestureArea(),
        if (_holdingSpeed && !_inPip)
          Align(
            alignment: Alignment.topCenter,
            child: Text(
              '长按 ${_settings.holdSpeed}x',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        if (!_inPip)
          IgnorePointer(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: _seekFeedbackSeconds == null
                  ? const SizedBox.shrink()
                  : Align(
                      key: ValueKey(_seekFeedbackSeconds),
                      alignment: Alignment(
                        _seekFeedbackSeconds! < 0 ? -.65 : .65, 0,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10,
                          ),
                          child: Text(
                            '${_seekFeedbackSeconds! < 0 ? '后退' : '快进'} ${_seekFeedbackSeconds!.abs()} 秒',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        if (!_inPip) _buildChrome(),
      ],
    );
    final episodes = Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: _changeSource,
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('更换来源'),
                ),
              ],
            ),
            Text('正在选择：${_chapter.title}'),
            EpisodeSelector(
              chapters: _chapters,
              currentIndex: _chapterIndex,
              onSelected: _selectEpisode,
            ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: !_fullscreen && !_episodesOpen,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_episodesOpen) {
          _scaffoldKey.currentState?.closeEndDrawer();
        } else if (_fullscreen) {
          await _setFullscreen(false);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        endDrawerEnableOpenDragGesture: false,
        onEndDrawerChanged: (open) {
          setState(() => _episodesOpen = open);
          if (!open) _scheduleChromeHide();
        },
        endDrawer: Drawer(
          width: (MediaQuery.sizeOf(context).width * .85).clamp(0, 380),
          child: SafeArea(
            child: Column(
              children: [
                ListTile(
                  title: const Text('选集'),
                  trailing: IconButton(
                    tooltip: '关闭选集',
                    onPressed: () => _scaffoldKey.currentState?.closeEndDrawer(),
                    icon: const Icon(Icons.close),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: episodes),
              ],
            ),
          ),
        ),
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final fillsWindow = _fullscreen ||
                _inPip ||
                constraints.maxWidth > constraints.maxHeight;
            return SafeArea(
              top: !_fullscreen && !_inPip,
              bottom: !_fullscreen && !_inPip,
              left: !_fullscreen && !_inPip,
              right: !_fullscreen && !_inPip,
              child: Column(
                children: [
                      Flexible(
                        flex: fillsWindow ? 1 : 0,
                        child: SizedBox(
                          width: double.infinity,
                          height: fillsWindow
                              ? double.infinity
                              : (constraints.maxWidth * 9 / 16)
                                  .clamp(0.0, constraints.maxHeight * .6),
                          child: MouseRegion(
                            onHover: (_) => _revealChrome(),
                            child: video,
                          ),
                        ),
                      ),
                      if (!fillsWindow) Expanded(child: episodes),
                    ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _selectEpisode(int index) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    if (index == _chapterIndex ||
        index < 0 ||
        index >= _chapters.length ||
        _chapters[index].locked ||
        _chapters[index].sourceId != _item.sourceId) {
      return;
    }
    await _persistProgress();
    if (!mounted) return;
    setState(() => _chapterIndex = index);
    await _load();
  }

  Future<void> _changeSource() async {
    await _persistProgress();
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.pause();
    } else {
      await _player.pause();
    }
    if (_fullscreen) await _setFullscreen(false);
    if (!mounted) return;
    setState(() => _playing = false);
    await showAnimeSources(context, _item, replacePlayer: true);
  }

  /// Single tap reveals controls; the outer quarters double tap to seek.
  Widget _buildGestureArea() {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (_) => _holdSpeed(true),
              onLongPressEnd: (_) => _holdSpeed(false),
              onVerticalDragUpdate: (details) =>
                  _adjustBrightness(details.delta.dy, constraints.maxHeight),
              onTap: _toggleChrome,
              onDoubleTap: () => _seekBy(const Duration(seconds: -15)),
            ),
          ),
          Expanded(
            flex: 2,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (_) => _holdSpeed(true),
              onLongPressEnd: (_) => _holdSpeed(false),
              onTap: _toggleChrome,
              onDoubleTap: _togglePlay,
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (_) => _holdSpeed(true),
              onLongPressEnd: (_) => _holdSpeed(false),
              onVerticalDragUpdate: (details) =>
                  _adjustVolume(details.delta.dy, constraints.maxHeight),
              onVerticalDragEnd: (_) =>
                  unawaited(_settings.save(_preferences)),
              onTap: _toggleChrome,
              onDoubleTap: () => _seekBy(const Duration(seconds: 15)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _seekBy(Duration delta) async {
    if (_loading || _awaitingPlaybackStart || _error != null ||
        _sliderMax <= 1) {
      return;
    }
    final sequence = _loadSeq;
    final target = Duration(
      milliseconds: (_position + delta).inMilliseconds
          .clamp(0, _sliderMax.toInt()),
    );
    _revealChrome();
    _seekFeedbackTimer?.cancel();
    setState(() {
      _position = target;
      _seekFeedbackSeconds = delta.inSeconds;
    });
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _seekFeedbackSeconds = null);
    });
    try {
      if (_useNativeAndroidVideo) {
        await _nativeVideoController.seek(target);
      } else {
        await _player.seek(target);
      }
      if (mounted && sequence == _loadSeq) _danmaku.seek(target);
    } catch (_) {
      if (mounted && sequence == _loadSeq) _toast('跳转未成功，请重试');
    }
  }


  Future<void> _togglePlay() async {
    if (_loading || _awaitingPlaybackStart || _error != null) return;
    _revealChrome();
    if (_useNativeAndroidVideo) {
      _playing
          ? await _nativeVideoController.pause()
          : await _nativeVideoController.play();
    } else {
      _playing ? await _player.pause() : await _player.play();
    }
  }

  void _toggleChrome() {
    _chromeTimer?.cancel();
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) _scheduleChromeHide();
  }

  void _revealChrome() {
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _scheduleChromeHide();
  }

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_playing || _loading || _awaitingPlaybackStart || _error != null || _episodesOpen || _scrubbing) return;
    _chromeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_episodesOpen && !_scrubbing) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  Widget _buildChrome() {
    final theme = Theme.of(context);
    final positionText = _format(_position);
    final durationText = _format(
      _duration == Duration.zero && !_useNativeAndroidVideo
          ? _player.state.duration
          : _duration,
    );
    final previous = adjacentEpisodeIndex(_chapters, _chapterIndex, -1);
    final next = adjacentEpisodeIndex(_chapters, _chapterIndex, 1);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttonSize = ((constraints.maxWidth - 24) / 8)
              .clamp(32.0, 48.0);
          Widget button(
            String label, IconData icon, VoidCallback? onPressed, {
            bool prominent = false,
          }) => IconButton(
            tooltip: label,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: prominent
                  ? Colors.white.withValues(alpha: .16) : null,
              shape: const StadiumBorder(),
            ),
            onPressed: onPressed,
            constraints: BoxConstraints.tightFor(
              width: buttonSize, height: 44,
            ),
            padding: EdgeInsets.zero,
            color: Colors.white,
            disabledColor: Colors.white38,
            iconSize: prominent ? 30 : 26,
            icon: Icon(icon),
          );

          final visible = _chromeVisible || _loading || _awaitingPlaybackStart || _error != null;
          return IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
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
                      button(
                        '播放设置', Icons.tune_rounded, _controlsSheet,
                      ),
                      if (danmakuFeatureEnabled)
                        button(
                          _danmakuOn ? '关闭弹幕' : '开启弹幕',
                          _danmakuOn
                              ? Icons.speaker_notes_outlined
                              : Icons.speaker_notes_off_outlined,
                          () {
                            setState(() => _danmakuOn = !_danmakuOn);
                            _danmaku.enabled = _danmakuOn;
                          },
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    bottom: _fullscreen,
                    left: false,
                    right: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 32,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    trackShape: const RoundedRectSliderTrackShape(),
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white30,
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.white12,
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                                  ),
                                  child: Slider(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    value: _sliderValue,
                                    max: _sliderMax,
                                    onChangeStart: _loading || _awaitingPlaybackStart || _error != null
                                        ? null : (_) {
                                            _chromeTimer?.cancel();
                                            setState(() => _scrubbing = true);
                                          },
                                    onChanged: _loading || _awaitingPlaybackStart || _error != null
                                        ? null : (value) => setState(() =>
                                            _position = Duration(milliseconds: value.round())),
                                    onChangeEnd: (value) async {
                                      final target = Duration(milliseconds: value.round());
                                      try {
                                        if (_useNativeAndroidVideo) {
                                          await _nativeVideoController.seek(target);
                                        } else {
                                          await _player.seek(target);
                                        }
                                        _danmaku.seek(target);
                                      } finally {
                                        if (mounted) {
                                          setState(() => _scrubbing = false);
                                          _scheduleChromeHide();
                                        }
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              '$positionText / $durationText',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white, fontSize: 12,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            button(
                              '上一集',
                              Icons.skip_previous_rounded,
                              previous == null
                                  ? null
                                  : () => _switchChapter(-1),
                            ),
                            button(
                              _playing ? '暂停' : '播放',
                              _playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              _togglePlay,
                              prominent: true,
                            ),
                            button(
                              '下一集',
                              Icons.skip_next_rounded,
                              next == null ? null : () => _switchChapter(1),
                            ),
                            Tooltip(
                              message: '跳过 ${_settings.skipSeconds} 秒（长按设置）',
                              child: GestureDetector(
                                onLongPress: _pickSkipSeconds,
                                onSecondaryTap: _pickSkipSeconds,
                                child: SizedBox(
                                  width: buttonSize,
                                  height: 44,
                                  child: TextButton(
                                    key: const ValueKey('player-skip'),
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: Size.zero,
                                      foregroundColor: Colors.white,
                                      shape: const StadiumBorder(),
                                    ),
                                    onPressed: _loading || _awaitingPlaybackStart ||
                                            _error != null || _sliderMax <= 1
                                        ? null
                                        : () => _seekBy(
                                            Duration(seconds: _settings.skipSeconds),
                                          ),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text('+${_settings.skipSeconds}s',
                                        style: const TextStyle(
                                          fontSize: 13, fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            button(
                              '视频比例', Icons.aspect_ratio_rounded, _pickAspectRatio,
                            ),
                            button(
                              '剧集', Icons.playlist_play_rounded, _showEpisodes,
                            ),
                            button(
                              '倍速 · ${_speed}x', Icons.speed_rounded, _pickSpeed,
                            ),
                            button(
                              _fullscreen ? '退出全屏' : '全屏',
                              _fullscreen
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded,
                              () => _setFullscreen(!_fullscreen),
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
        },
      ),
    );
  }

  double get _sliderValue =>
      _position.inMilliseconds.clamp(0, _sliderMax).toDouble();

  double get _sliderMax {
    final duration = _duration == Duration.zero && !_useNativeAndroidVideo
        ? _player.state.duration
        : _duration;
    return duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds.toDouble();
  }

  Future<void> _pickSkipSeconds() async {
    _chromeTimer?.cancel();
    var input = '${_settings.skipSeconds}';
    String? error;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submit() {
            final seconds = int.tryParse(input);
            if (seconds == null || seconds < 1 || seconds > 3600) {
              update(() => error = '请输入 1–3600 之间的整数');
              return;
            }
            Navigator.pop(context, seconds);
          }

          return AlertDialog(
            title: const Text('跳过秒数'),
            content: TextFormField(
              initialValue: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '每次跳过', suffixText: '秒',
                helperText: '单击跳过，长按按钮可再次修改',
                errorText: error,
              ),
              onChanged: (value) => input = value,
              onFieldSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(onPressed: submit, child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    if (selected != null) {
      setState(() => _settings = _settings.copyWith(skipSeconds: selected));
      await _settings.save(_preferences);
    }
    if (mounted) _scheduleChromeHide();
  }

  Future<void> _pickAspectRatio() async {
    _chromeTimer?.cancel();
    final selected = await showModalBottomSheet<VideoAspectRatio>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('视频比例')),
              for (final ratio in VideoAspectRatio.values)
                ListTile(
                  selected: _settings.aspectRatio == ratio,
                  leading: Icon(_settings.aspectRatio == ratio
                      ? Icons.radio_button_checked : Icons.radio_button_off),
                  title: Text(ratio.label),
                  onTap: () => Navigator.pop(context, ratio),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (selected != null) {
      setState(() => _settings = _settings.copyWith(aspectRatio: selected));
      await _settings.save(_preferences);
      if (_useNativeAndroidVideo) {
        await _nativeVideoController.setAspectRatio(selected.ratio);
      }
    }
    if (mounted) _scheduleChromeHide();
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
    if (!mounted || selected == null || selected == _lineIndex) return;
    final seq = _loadSeq;
    setState(() {
      _lineIndex = selected;
      _loading = true;
      _error = null;
    });
    try {
      await _openLine(
        _lines[selected].url,
        line: _lines[selected],
        startPosition: _position,
      );
      if (mounted && seq == _loadSeq) {
        setState(() => _loading = false);
        _scheduleChromeHide();
      }
    } catch (error) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _loading = false;
          _error = SourceException.sanitizeMessage('$error');
        });
      }
    }
  }

  Future<void> _showEpisodes() async {
    _chromeTimer?.cancel();
    setState(() => _chromeVisible = true);
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isEndDrawerOpen == true) {
      scaffold?.closeEndDrawer();
    } else {
      scaffold?.openEndDrawer();
    }
  }

  /// 当前弹幕对应的弹弹play 剧集（手动搜索匹配后才有，用于发送弹幕）。
  int? _danmakuEpisodeId;

  // ---------------------------------------------------------------- 倍速

  static const List<double> _speedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  Future<void> _pickSpeed() async {
    final selected = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                '播放倍速',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Wrap(
              spacing: AppSpacing.xs,
              children: <Widget>[
                for (final option in _speedOptions)
                  ChoiceChip(
                    label: Text('${option}x'),
                    selected: _speed == option,
                    onSelected: (_) => Navigator.of(context).pop(option),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
    if (selected == null) return;
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.setRate(selected);
    } else {
      await _player.setRate(selected);
    }
    if (mounted) setState(() => _speed = selected);
    _settings = _settings.copyWith(speed: selected);
    await _settings.save(_preferences);
  }

  Future<void> _holdSpeed(bool enabled) async {
    if (_holdingSpeed == enabled) return;
    _holdingSpeed = enabled;
    final speed = enabled ? _settings.holdSpeed : _speed;
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.setRate(speed);
    } else {
      await _player.setRate(speed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _adjustVolume(double delta, double height) async {
    final volume = (_settings.volume - delta / height).clamp(0.0, 1.0);
    _settings = _settings.copyWith(volume: volume);
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.setVolume(volume);
    } else {
      await _player.setVolume(volume * 100);
    }
    if (mounted) setState(() {});
  }

  Future<void> _adjustBrightness(double delta, double height) async {
    if (!_useNativeAndroidVideo) return;
    _brightness = (_brightness - delta / height).clamp(.05, 1.0);
    await const MethodChannel('triomi/platform')
        .invokeMethod<void>('videoPolicy', {
          'owner': _resolverOwner,
          'active': true,
          'pip': true,
          'backgroundAudio': _settings.backgroundAudio,
          'brightness': _brightness,
        });
  }

  Future<void> _enterPip() async {
    final result = await const MethodChannel('triomi/platform')
        .invokeMethod<bool>('enterVideoPip');
    if (result != true) _toast('此设备不支持画中画');
  }

  Future<void> _controlsSheet() async {
    _chromeTimer?.cancel();
    var settings = _settings;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(title: Text('播放设置')),
                ListTile(
                  leading: const Icon(Icons.fast_forward_rounded),
                  title: const Text('跳过秒数'),
                  subtitle: Text('每次 ${settings.skipSeconds} 秒 · 也可长按跳过按钮修改'),
                  onTap: () => Navigator.pop(context, 'skip'),
                ),
                ListTile(
                  leading: const Icon(Icons.subtitles_rounded),
                  title: const Text('字幕'),
                  onTap: () => Navigator.pop(context, 'subtitles'),
                ),
                if (_useNativeAndroidVideo)
                  ListTile(
                    leading: const Icon(Icons.picture_in_picture_alt_rounded),
                    title: const Text('画中画'),
                    onTap: () => Navigator.pop(context, 'pip'),
                  ),
                if (_lines.length > 1)
                  ListTile(
                    leading: const Icon(Icons.alt_route_rounded),
                    title: Text('线路 · ${_lines[_lineIndex].name}'),
                    onTap: () => Navigator.pop(context, 'line'),
                  ),
                if (danmakuFeatureEnabled) ...[
                  ListTile(
                    title: const Text('弹幕设置'),
                    onTap: () => Navigator.pop(context, 'danmakuSettings'),
                  ),
                  ListTile(
                    title: const Text('搜索弹幕'),
                    onTap: () => Navigator.pop(context, 'searchDanmaku'),
                  ),
                  ListTile(
                    title: const Text('发送弹幕'),
                    onTap: () => Navigator.pop(context, 'sendDanmaku'),
                  ),
                ],
                const Divider(height: 24),
                SwitchListTile(
                  title: const Text('同列表自动播放下一集'),
                  value: settings.autoNext,
                  onChanged: (value) => update(
                    () => settings = settings.copyWith(autoNext: value),
                  ),
                ),
                SwitchListTile(
                  title: const Text('后台音频'),
                  subtitle: Text(
                    _useNativeAndroidVideo
                        ? '系统媒体通知与锁屏控制；退出播放器后停止'
                        : '最小化时继续音频；退出播放器后停止',
                  ),
                  value: settings.backgroundAudio,
                  onChanged: (value) => update(
                    () => settings = settings.copyWith(backgroundAudio: value),
                  ),
                ),
                ListTile(
                  title: const Text('画面比例'),
                  trailing: DropdownButton<VideoAspectRatio>(
                    value: settings.aspectRatio,
                    items: [
                      for (final ratio in VideoAspectRatio.values)
                        DropdownMenuItem(
                          value: ratio, child: Text(ratio.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(() => settings = settings.copyWith(aspectRatio: value));
                      }
                    },
                  ),
                ),
                ListTile(
                  title: const Text('长按倍速'),
                  trailing: DropdownButton<double>(
                    value: settings.holdSpeed,
                    items: [
                      for (final speed in [1.0, 1.5, 2.0, 2.5, 3.0])
                        DropdownMenuItem(
                          value: speed,
                          child: Text('${speed}x'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(
                          () => settings = settings.copyWith(holdSpeed: value),
                        );
                      }
                    },
                  ),
                ),
                ListTile(title: Text('音量 ${(settings.volume * 100).round()}%')),
                Slider(
                  value: settings.volume,
                  onChanged: (value) =>
                      update(() => settings = settings.copyWith(volume: value)),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('应用设置'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _settings = settings;
    await _settings.save(_preferences);
    await _applyControls();
    if (!mounted) return;
    setState(() {});
    switch (action) {
      case 'skip': await _pickSkipSeconds();
      case 'subtitles': await _pickSubtitles();
      case 'pip': await _enterPip();
      case 'line': await _pickLine();
      case 'danmakuSettings': await _showDanmakuSettings();
      case 'searchDanmaku': await _searchDanmaku();
      case 'sendDanmaku': await _sendDanmaku();
    }
    if (mounted) _scheduleChromeHide();
  }

  Future<void> _pickSubtitles() async {
    final native = _useNativeAndroidVideo
        ? await _nativeVideoController.subtitleTracks()
        : null;
    if (!mounted) return;
    final desktop = _useNativeAndroidVideo
        ? <SubtitleTrack>[]
        : _player.state.tracks.subtitle
              .where((t) => t.id != 'no' && t.id != 'auto')
              .toList();
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('字幕轨道')),
            ListTile(
              title: const Text('关闭字幕'),
              onTap: () => Navigator.pop(context, 'no'),
            ),
            if ((native?.isEmpty ?? desktop.isEmpty))
              const ListTile(title: Text('当前媒体没有可用字幕轨道')),
            if (native != null)
              for (final track in native)
                ListTile(
                  title: Text('${track['title']}'),
                  onTap: () => Navigator.pop(context, '${track['id']}'),
                )
            else
              for (final track in desktop)
                ListTile(
                  title: Text(track.title ?? track.language ?? track.id),
                  onTap: () => Navigator.pop(context, track.id),
                ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (_useNativeAndroidVideo) {
      await _nativeVideoController.selectSubtitle(
        selected == 'no' ? null : selected,
      );
    } else {
      await _player.setSubtitleTrack(
        selected == 'no'
            ? SubtitleTrack.no()
            : desktop.firstWhere((t) => t.id == selected),
      );
    }
  }

  // ---------------------------------------------------------------- 弹幕设置

  /// 手动搜索弹幕（弹弹play）：按番剧名匹配，选中剧集后载入并记住 episodeId。
  Future<void> _searchDanmaku() async {
    final credentials = DandanplayCredentials.load(
      _preferences,
      ref.read(secureStoreProvider),
    );
    if (!credentials.isConfigured) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('需要弹弹play 凭据'),
          content: const Text('弹幕搜索与发送需要在「我的 → 弹幕设置」填写你自己的 AppId 与 AppSecret。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('知道了'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await context.push(AppRoutes.danmakuSettings);
      }
      return;
    }

    final keyword = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索弹幕'),
        content: TextField(
          autofocus: true,
          controller: TextEditingController(text: _item.title),
          decoration: const InputDecoration(hintText: '番剧名称'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_item.title),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    if (keyword == null || keyword.trim().isEmpty) return;

    final client = ref.read(dandanplayClientProvider);
    try {
      final matches = await client.search(knowledgeKeyword(keyword));
      if (!mounted) return;
      if (matches.isEmpty) {
        _toast('没有匹配到弹幕，换个关键词试试');
        return;
      }
      // 把所有剧集摊平成一列，用户直接选集。
      final options = <({int episodeId, String label})>[
        for (final match in matches)
          for (final episode in match.episodes)
            (
              episodeId: episode.episodeId,
              label: '${match.title} · ${episode.title}',
            ),
      ];
      if (options.isEmpty) {
        _toast('匹配结果里没有剧集');
        return;
      }
      final selected = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, index) => ListTile(
              leading: const Icon(Icons.comment_outlined),
              title: Text(options[index].label),
              onTap: () => Navigator.of(context).pop(options[index].episodeId),
            ),
          ),
        ),
      );
      if (selected == null) return;
      final comments = await client.comments(selected);
      if (!mounted) return;
      _danmakuEpisodeId = selected;
      _danmaku.load(comments);
      _danmaku.seek(_position);
      _toast('已载入 ${comments.length} 条弹幕');
    } catch (error) {
      _toast('弹幕搜索失败：$error');
    }
  }

  /// 关键词清洗：去掉季/集等后缀，提升匹配率。
  static String knowledgeKeyword(String raw) => raw
      .replaceAll(RegExp(r'第\s*\d+\s*[集话話]'), '')
      .replaceAll(RegExp(r'[【\[（(].*?[】\]）)]'), '')
      .trim();

  Future<void> _showDanmakuSettings() async {
    final updated = await showModalBottomSheet<DanmakuSettings>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _DanmakuSettingsSheet(settings: _danmakuSettings),
    );
    if (updated == null) return;
    setState(() {
      _danmakuSettings = updated;
      _danmakuOn = updated.enabled;
    });
    _danmaku.applySettings(updated);
    await updated.save(_preferences);
  }

  /// 发送弹幕（需要弹弹play 凭据；未配置时给出明确指引）。
  Future<void> _sendDanmaku() async {
    final credentials = DandanplayCredentials.load(
      _preferences,
      ref.read(secureStoreProvider),
    );
    if (!credentials.canSend) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发送弹幕需要账号'),
          content: const Text(
            '弹弹play 要求用你自己的 AppId / AppSecret 与账号 token 发送弹幕。'
            '到「我的 → 弹幕设置」填写后即可发送。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('知道了'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('去设置'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await context.push(AppRoutes.danmakuSettings);
      }
      return;
    }

    final episodeId = _danmakuEpisodeId;
    if (episodeId == null) {
      _toast('当前剧集没有匹配到弹弹play 剧集，无法发送');
      return;
    }

    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送弹幕'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(
            hintText: '在此输入弹幕内容',
            counterText: '',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;

    try {
      await ref
          .read(dandanplayClientProvider)
          .sendComment(
            episodeId: episodeId,
            text: text.trim(),
            timeSeconds: _position.inMilliseconds / 1000,
            token: credentials.token,
          );
      _toast('弹幕已发送');
    } catch (error) {
      _toast('发送失败：$error');
    }
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
    _desktopResolve?.cancel('播放器已关闭');
    WidgetsBinding.instance.removeObserver(this);
    _chromeTimer?.cancel();
    _prepareTimer?.cancel();
    _playerErrorSub?.cancel();
    _completedSub?.cancel();
    if (_useNativeAndroidVideo) {
      unawaited(
        const MethodChannel('triomi/platform')
            .invokeMethod<void>('videoPolicy', {
              'owner': _resolverOwner,
              'active': false,
              'pip': false,
              'backgroundAudio': false,
              'brightness': -1,
            }),
      );
    }
    unawaited(_persistProgress());
    _progressTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    ++_loadSeq;
    ++_resolveSeq;
    if (_useNativeAndroidVideo) {
      unawaited(
        const MethodChannel('triomi/platform').invokeMethod<void>(
          'cancelVideoResolve',
          {'requestId': _resolverOwner},
        ),
      );
    }
    _nativeVideoController.dispose();
    if (!_useNativeAndroidVideo) _player.dispose();
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
    required this.nativeController,
    required this.aspectRatio,
    required this.backgroundAudio,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onEpisodes,
  });

  final VideoController? controller;
  final _NativeAndroidVideoController nativeController;
  final bool loading;
  final double? aspectRatio;
  final bool backgroundAudio;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onEpisodes;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
        LayoutBuilder(builder: (context, constraints) {
          // Own frame geometry while retaining the same native view/controller.
          // media_kit_video 2.0.1 cannot clear its cached aspectRatio via null.
          final width = aspectRatio == null
              ? constraints.maxWidth
              : min(constraints.maxWidth, constraints.maxHeight * aspectRatio!);
          return Center(
            child: SizedBox(
              width: width,
              height: aspectRatio == null ? constraints.maxHeight : width / aspectRatio!,
              child: controller == null
                  ? _NativeAndroidVideoView(controller: nativeController)
                  : Video(
                      controller: controller!,
                      controls: null,
                      fit: aspectRatio == null ? BoxFit.contain : BoxFit.fill,
                      pauseUponEnteringBackgroundMode: !backgroundAudio,
                      resumeUponEnteringForegroundMode: !backgroundAudio,
                    ),
            ),
          );
        }),
      if (error != null) ...[
        const ColoredBox(color: Colors.black87),
        Positioned.fill(
          top: 48,
          bottom: 76,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('播放加载失败',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
                const SizedBox(height: 8),
                Text(error!, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                    TextButton.icon(
                      onPressed: onEpisodes,
                      icon: const Icon(Icons.list),
                      label: const Text('选择其他集数 / 线路'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ] else if (loading)
        const ColoredBox(
          color: Colors.black54,
          child: Center(
            child: SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
            ),
          ),
        ),
    ],
  );
}

class _NativeVideoState {
  const _NativeVideoState({
    required this.position,
    required this.duration,
    required this.playing,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
}

class _NativeAndroidVideoController {
  _NativeAndroidVideoController({
    required this.onState,
    required this.onPrepared,
    required this.onError,
    required this.onCompleted,
    required this.onPip,
  });

  final void Function(_NativeVideoState state) onState;
  final void Function(_NativeVideoState state) onPrepared;
  final void Function(String message) onError;
  final VoidCallback onCompleted;
  String _pendingTitle = 'Triomi';
  final void Function(bool enabled) onPip;
  MethodChannel? _channel;
  int? _viewId;
  String? _pendingUrl;
  Map<String, String> _pendingHeaders = const {};
  Duration _pendingStartPosition = Duration.zero;
  bool _disposed = false;

  void attach(int id) {
    if (_disposed) return;
    _channel?.setMethodCallHandler(null);
    _viewId = id;
    final channel = MethodChannel('triomi/native-video/$id');
    _channel = channel;
    channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map
          ? Map<Object?, Object?>.from(call.arguments as Map)
          : const <Object?, Object?>{};
      switch (call.method) {
        case 'state':
          onState(_stateFrom(args));
          _pendingStartPosition = _stateFrom(args).position;
        case 'prepared':
          onPrepared(_stateFrom(args));
          _pendingStartPosition = _stateFrom(args).position;
        case 'completed':
          onState(_stateFrom(args));
          onCompleted();
        case 'pip':
          onPip(args['enabled'] == true);
        case 'error':
          final details = args['message']?.toString().trim();
          final code = '${args['what'] ?? ''}/${args['extra'] ?? ''}';
          onError(
            details != null && details.isNotEmpty
                ? '原生播放器错误：$details（$code）'
                : '原生播放器错误：$code',
          );
      }
    });
    final url = _pendingUrl;
    if (url != null) {
      unawaited(
        setUrl(
          url,
          headers: _pendingHeaders,
          startPosition: _pendingStartPosition,
          title: _pendingTitle,
        ).catchError((Object error) => onError('打开视频失败：$error')),
      );
    }
  }

  _NativeVideoState _stateFrom(Map<Object?, Object?> args) {
    int number(String key) => (args[key] as num?)?.toInt() ?? 0;
    return _NativeVideoState(
      position: Duration(milliseconds: number('position')),
      duration: Duration(milliseconds: number('duration')),
      playing: args['playing'] == true,
    );
  }

  Future<void> setUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration startPosition = Duration.zero,
    String title = 'Triomi',
  }) async {
    if (_disposed) return;
    _pendingUrl = url;
    _pendingHeaders = headers;
    _pendingStartPosition = startPosition;
    _pendingTitle = title;
    final channel = _channel;
    if (channel == null) return;
    await channel.invokeMethod<void>('setUrl', <String, Object?>{
      'url': url,
      'headers': headers,
      'startMilliseconds': startPosition.inMilliseconds,
      'title': title,
    });
  }

  Future<void> play() async => _invoke('play');
  Future<void> pause() async => _invoke('pause');

  Future<void> seek(Duration position) => _invoke('seek', <String, Object?>{
    'milliseconds': position.inMilliseconds,
  });

  Future<void> setRate(double rate) =>
      _invoke('setRate', <String, Object?>{'rate': rate});

  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume});
  Future<void> setAspectRatio(double? ratio) =>
      _invoke('setAspectRatio', {'ratio': ratio});
  Future<void> setBackgroundAudio(bool enabled) =>
      _invoke('setBackgroundAudio', {'enabled': enabled});
  Future<List<Map<Object?, Object?>>> subtitleTracks() async {
    final raw =
        await _channel?.invokeListMethod<Object?>('subtitleTracks') ?? [];
    return [
      for (final row in raw)
        if (row is Map) Map<Object?, Object?>.from(row),
    ];
  }

  Future<void> selectSubtitle(String? id) =>
      _invoke('selectSubtitle', {'id': id});

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    final channel = _channel;
    if (_disposed || channel == null) return;
    await channel.invokeMethod<void>(method, args);
  }

  void detach(int id) {
    if (_viewId != id) return;
    _channel?.setMethodCallHandler(null);
    _channel = null;
    _viewId = null;
  }

  void dispose() {
    _disposed = true;
    _channel?.setMethodCallHandler(null);
    _channel = null;
  }
}

class _NativeAndroidVideoView extends StatefulWidget {
  const _NativeAndroidVideoView({required this.controller});

  final _NativeAndroidVideoController controller;

  @override
  State<_NativeAndroidVideoView> createState() =>
      _NativeAndroidVideoViewState();
}

class _NativeAndroidVideoViewState extends State<_NativeAndroidVideoView> {
  int? _viewId;
  @override
  void dispose() {
    final id = _viewId;
    if (id != null) widget.controller.detach(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the native TextureView in Android's view hierarchy so Media3 and
    // Flutter controls are composed together without a virtual-display copy.
    return PlatformViewLink(
      viewType: 'triomi/native-video',
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (params) {
        // Retain the same hybrid-composition controller across layout changes.
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'triomi/native-video',
          layoutDirection: TextDirection.ltr,
          creationParams: null,
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller.addOnPlatformViewCreatedListener((id) {
          if (!mounted) return;
          _viewId = id;
          widget.controller.attach(id);
          params.onPlatformViewCreated(id);
        });
        controller.create();
        return controller;
      },
    );
  }
}

/// 弹幕设置抽屉：开关 / 不透明度 / 字号 / 速度 / 显示类型 / 屏蔽词。
class _DanmakuSettingsSheet extends StatefulWidget {
  const _DanmakuSettingsSheet({required this.settings});

  final DanmakuSettings settings;

  @override
  State<_DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<_DanmakuSettingsSheet> {
  late DanmakuSettings _draft = widget.settings;
  late final TextEditingController _wordController = TextEditingController();

  @override
  void dispose() {
    _wordController.dispose();
    super.dispose();
  }

  void _addWord() {
    final word = _wordController.text.trim();
    if (word.isEmpty) return;
    if (_draft.blockedWords.contains(word)) {
      _wordController.clear();
      return;
    }
    setState(() {
      _draft = _draft.copyWith(
        blockedWords: <String>[..._draft.blockedWords, word],
      );
    });
    _wordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('弹幕设置', style: theme.textTheme.titleSmall),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_draft),
                  child: const Text('应用'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _draft.enabled,
              title: const Text('显示弹幕'),
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(enabled: value)),
            ),
            Text('不透明度 ${(_draft.opacity * 100).round()}%'),
            Slider(
              value: _draft.opacity,
              min: 0.2,
              max: 1.0,
              divisions: 8,
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(opacity: value)),
            ),
            Text('字号 ${_draft.fontScale.toStringAsFixed(1)}x'),
            Slider(
              value: _draft.fontScale,
              min: 0.6,
              max: 1.6,
              divisions: 10,
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(fontScale: value)),
            ),
            Text('速度 ${_draft.speedScale.toStringAsFixed(1)}x'),
            Slider(
              value: _draft.speedScale,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(speedScale: value)),
            ),
            Wrap(
              spacing: AppSpacing.xs,
              children: <Widget>[
                FilterChip(
                  label: const Text('滚动'),
                  selected: _draft.showScroll,
                  onSelected: (value) => setState(
                    () => _draft = _draft.copyWith(showScroll: value),
                  ),
                ),
                FilterChip(
                  label: const Text('顶部'),
                  selected: _draft.showTop,
                  onSelected: (value) =>
                      setState(() => _draft = _draft.copyWith(showTop: value)),
                ),
                FilterChip(
                  label: const Text('底部'),
                  selected: _draft.showBottom,
                  onSelected: (value) => setState(
                    () => _draft = _draft.copyWith(showBottom: value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('屏蔽词（弹幕包含即隐藏）', style: theme.textTheme.bodySmall),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _wordController,
                    decoration: const InputDecoration(hintText: '输入屏蔽词'),
                    onSubmitted: (_) => _addWord(),
                  ),
                ),
                IconButton(onPressed: _addWord, icon: const Icon(Icons.add)),
              ],
            ),
            Wrap(
              spacing: AppSpacing.xs,
              children: <Widget>[
                for (final word in _draft.blockedWords)
                  InputChip(
                    label: Text(word),
                    onDeleted: () => setState(
                      () => _draft = _draft.copyWith(
                        blockedWords: <String>[
                          for (final item in _draft.blockedWords)
                            if (item != word) item,
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
