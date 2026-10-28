import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/chapter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_type.dart';
import '../../core/models/source_exception.dart';
import '../../core/models/video_resolve_cancellation.dart';
import '../../core/source/source_api.dart';
import '../../core/source/source_providers.dart';
import '../../core/source/source_registry.dart';
import '../../core/storage/preferences.dart';
import '../../core/theme/app_tokens.dart';
import '../detail/anime_source_sheet.dart';
import '../downloads/data/download_providers.dart';
import '../library/data/anime_identity_repository.dart';
import '../library/data/library_providers.dart';
import '../library/data/library_repository.dart';
import '../search/search_page.dart';
import '../tracking/data/tracking_providers.dart';
import 'danmaku_settings_page.dart';
import 'danmaku_sources_panel.dart';
import 'data/danmaku_overlay.dart';
import 'data/danmaku_session.dart';
import 'data/danmaku_settings.dart';
import 'data/hybrid_danmaku_client.dart';
import 'data/playback_buffer_policy.dart';
import 'data/player_settings.dart';
import 'episode_comments_panel.dart';
import 'episode_selector.dart';
import 'ios_video_controller.dart';
import 'player_interaction_surface.dart';
import 'player_menu.dart';
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

/// 番剧播放器：Android/iOS 原生内核、桌面 media_kit + 共用控件与弹幕层。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.args});

  final PlayerArgs args;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final Player _player;
  VideoController? _videoController;
  late final IosVideoController _iosVideoController;
  late final _NativeAndroidVideoController _nativeVideoController;

  bool get _useNativeAndroidVideo =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _useNativeVideo => _useNativeAndroidVideo || _isIOS;
  VideoPlatformController get _activeNativeController =>
      _isIOS ? _iosVideoController : _nativeVideoController;
  /// initState 里从 ref 取出保存；dispose 里写最后一次进度时用。
  LibraryRepository? _libraryRepository;

  /// 同上：dispose 里不能用 ref，进度上报器也提前握住。
  ProgressReporter? _trackingReporter;
  AnimeIdentityRepository? _animeIdentity;
  bool _resetCrossSitePosition = false;
  bool _progressSaveFailureShown = false;

  late final Preferences _preferences;
  late final DanmakuController _danmaku;
  late DanmakuSettings _danmakuSettings;
  late final DanmakuSession _danmakuSession;
  ProviderSubscription<AsyncValue<MediaItem>>? _danmakuAssociation;
  ProviderSubscription<HybridDanmakuClient>? _danmakuClient;
  ProviderSubscription<DanmakuSettings>? _danmakuDisplay;
  MediaItem? _danmakuSubject;
  String? _danmakuAssociationError;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _bufferSub;
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
  bool _brightnessReady = false;
  int _brightnessRevision = 0;
  MediaVolumeState _mediaVolume = const MediaVolumeState();

  PlayerSettings get _displaySettings => _useNativeVideo
      ? _settings.copyWith(volume: _mediaVolume.volume ?? 0)
      : _settings;

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
  bool _menuOpen = false;
  bool _menuActionActive = false;
  final _menuController = MenuController();
  bool _scrubbing = false;
  Duration? _scrubOrigin;
  int _scrubRevision = 0;
  Timer? _chromeTimer;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final TabController _contentTabs;
  int _panelSection = 0;
  bool _commentsVisited = false;
  bool _sidePanelLayout = false;

  /// 播放倍速（0.5~3.0）。
  double _speed = 1.0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _contentTabs = TabController(length: 2, vsync: this);
    _contentTabs.addListener(() {
      if (_contentTabs.index == _panelSection) return;
      setState(() {
        _panelSection = _contentTabs.index;
        if (_panelSection == 1) _commentsVisited = true;
      });
    });
    _chapterIndex = widget.args.initialIndex;

    // dispose() 里不能用 ref（Riverpod 3 会在卸载时封禁），
    // 退出播放器时还要写最后一次进度，所以提前把仓储握在手里。
    _libraryRepository = ref.read(libraryRepositoryProvider);
    _animeIdentity = ref.read(animeIdentityRepositoryProvider);
    _preferences = ref.read(preferencesProvider);
    _settings = PlayerSettings.load(_preferences);
    _speed = _settings.speed;
    _trackingReporter = ref.read(progressReporterProvider);
    _danmakuSettings = ref.read(danmakuSettingsProvider);
    _danmaku = DanmakuController(settings: _danmakuSettings);
    _danmakuOn = _danmakuSettings.enabled;
    _danmakuSession = DanmakuSession(
      client: ref.read(hybridDanmakuClientProvider),
      preferences: _preferences,
    );
    _danmakuSession.addListener(_refreshDanmaku);
    _danmakuSession.setEnabled(_danmakuOn);
    _danmakuDisplay = ref.listenManual(danmakuSettingsProvider, (_, settings) {
      if (!mounted) return;
      setState(() {
        _danmakuSettings = settings;
        _danmakuOn = settings.enabled;
      });
      _danmaku.applySettings(settings);
      _danmakuSession.setEnabled(settings.enabled);
    });
    _danmakuClient = ref.listenManual(hybridDanmakuClientProvider, (_, client) {
      _danmakuSession.replaceClient(client);
    });
    _danmakuAssociation = ref.listenManual(animeSubjectProvider(_item), (
      _,
      next,
    ) {
      _danmakuSubject = next.asData?.value;
      _danmakuAssociationError = next.hasError
          ? 'Bangumi 条目关联读取失败，请重新查找关联'
          : null;
      _configureDanmaku();
    }, fireImmediately: true);

    _nativeVideoController = _NativeAndroidVideoController(
      onState: _onNativeVideoState,
      onMediaVolume: _onMediaVolume,
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
        if (enabled) _clearTransientInput();
        if (mounted) setState(() => _inPip = enabled);
      },
    );
    _iosVideoController = IosVideoController(
      onState: _onNativeVideoState,
      onMediaVolume: _onMediaVolume,
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
        if (enabled) _clearTransientInput();
        if (mounted) setState(() => _inPip = enabled);
      },
    );
    if (!_useNativeVideo) {
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: playbackForwardBufferBytes,
        ),
      );
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
      _bufferSub = _player.stream.buffer.listen((buffer) {
        if (mounted) setState(() => _bufferedPosition = buffer);
      });
      _playingSub = _player.stream.playing.listen((playing) {
        if (mounted) {
          setState(() => _playing = playing);
          _updateDanmakuClock();
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

    if (_useNativeVideo) unawaited(_readBrightness());

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
    _danmaku.update(
      position,
      playing: _playing,
      rate: _holdingSpeed ? _settings.holdSpeed : _speed,
    );
    if (mounted) setState(() {});
  }

  void _onMediaVolume(MediaVolumeState state) {
    if (!mounted) return;
    setState(() => _mediaVolume = state);
  }

  void _onNativeVideoState(NativeVideoState state) {
    final volume = state.mediaVolume;
    if (volume != null) _onMediaVolume(volume);
    if (_awaitingPlaybackStart || _scrubbing) return;
    final playingChanged = _playing != state.playing;
    _position = state.position;
    _duration = state.duration;
    _bufferedPosition = state.bufferedPosition;
    _playing = state.playing;
    // Mobile platform views report the same playback clock used by desktop's
    // media_kit position stream, so danmaku follows play, pause and hold speed.
    _danmaku.update(
      state.position,
      playing: state.playing,
      rate: _holdingSpeed ? _settings.holdSpeed : _speed,
    );
    if (mounted) setState(() {});
    if (playingChanged) _scheduleChromeHide();
  }

  void _onNativeVideoError(String message) {
    if (!mounted) return;
    _prepareTimer?.cancel();
    _clearTransientInput();
    setState(() {
      _loading = false;
      _error = SourceException.sanitizeMessage(message);
    });
  }

  // ---------------------------------------------------------------- 加载

  Future<void> _load() async {
    _clearTransientInput();
    _configureDanmaku(force: true);
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
    _danmaku.clear();

    try {
      if (_useNativeVideo) {
        await _activeNativeController.pause();
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
          _error = SourceException.sanitizeMessage(
            error is PlatformException
                ? (error.message ?? '播放暂不可用，请重试或更换播放来源')
                : '$error'.replaceFirst('Bad state: ', ''),
          );
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (mounted) setState(_clearTransientInput);
      unawaited(_persistProgress());
    } else if (_useNativeVideo) {
      unawaited(_readBrightness());
    }
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _usesSidePanel || !_episodesOpen) return;
      _scaffoldKey.currentState?.closeEndDrawer();
      setState(() => _episodesOpen = false);
    });
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
    if (!mounted) return;
    _updateDanmakuClock();
    if (_useNativeVideo) {
      await _activeNativeController.setRate(_speed);
      await _activeNativeController.setAspectRatio(_settings.aspectRatio.ratio);
      await _activeNativeController.setBackgroundAudio(
        _settings.backgroundAudio,
      );
      if (!mounted) return;
      await const MethodChannel('triomi/platform')
          .invokeMethod<void>('videoPolicy', {
            'owner': _resolverOwner,
            'active': true,
            'pip': true,
            'backgroundAudio': _settings.backgroundAudio,
          });
    } else {
      await _player.setRate(_speed);
      if (!mounted) return;
      await _player.setVolume(_settings.volume * 100);
    }
  }

  Future<void> _openLine(
    String url, {
    PlaySource? line,
    Duration startPosition = Duration.zero,
  }) async {
    _clearTransientInput();
    _prepareTimer?.cancel();
    _awaitingPlaybackStart = true;
    final seq = ++_resolveSeq;
    _desktopResolve?.cancel('已切换播放线路');
    _desktopResolve = null;
    var headers = line?.headers ?? const <String, String>{};
    String? mimeType = line?.mimeType;
    var omitCookies = line?.omitCookies ?? false;
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
        mimeType = result.mimeType;
        omitCookies = omitCookies || result.omitCookies;
      } else if (!_useNativeVideo) {
        throw StateError('此平台未提供网页播放解析，请选择直链来源');
      } else {
        final result = await const MethodChannel('triomi/platform')
            .invokeMapMethod<String, Object?>('resolveVideo', {
              'url': url,
              'requestId': _resolverOwner,
              'headers': headers,
              'unavailableVideoUrls': line!.unavailableVideoUrls,
              'useLegacyParser': line.useLegacyParser,
              if (_isIOS && omitCookies) 'omitCookies': true,
            });
        if (!mounted || seq != _resolveSeq) return;
        final resolved = result?['url']?.toString();
        if (resolved == null || resolved.isEmpty) {
          throw StateError('播放页未解析到视频地址');
        }
        url = resolved;
        omitCookies = omitCookies || result?['omitCookies'] == true;
        if (result?['mimeType'] == 'application/vnd.apple.mpegurl') {
          mimeType = 'application/vnd.apple.mpegurl';
        }
        final rawHeaders = result?['headers'];
        headers = {
          if (rawHeaders is Map)
            for (final e in rawHeaders.entries)
              e.key.toString(): e.value.toString(),
        };
      }
    }
    if (omitCookies) {
      headers = {
        for (final entry in headers.entries)
          if (entry.key.toLowerCase() != 'cookie') entry.key: entry.value,
      };
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
    _bufferedPosition = startPosition;
    _danmaku.seek(startPosition);
    if (_useNativeVideo) {
      _prepareTimer?.cancel();
      _prepareTimer = Timer(const Duration(seconds: 30), () {
        if (mounted && seq == _resolveSeq && _awaitingPlaybackStart) {
          _onNativeVideoError('视频准备超时，请重试或更换播放来源');
        }
      });
      await _activeNativeController.setUrl(
        url,
        headers: headers,
        mimeType: mimeType,
        omitCookies: omitCookies,
        startPosition: startPosition,
        title: '${_item.title} · ${_chapter.title}',
      );
    } else {
      await applyDesktopPlaybackBufferPolicy(_player.platform as NativePlayer);
      if (!mounted || seq != _resolveSeq) return;
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

  void _configureDanmaku({bool force = false}) {
    if (!_validSelection) return;
    final subject = _danmakuSubject;
    final id =
        subject?.sourceId == 'bangumi-anime' &&
            subject?.type == MediaType.anime &&
            (int.tryParse(subject?.remoteId ?? '') ?? 0) > 0
        ? subject!.remoteId
        : null;
    final unique =
        _chapter.number != null &&
        _chapters
                .where(
                  (chapter) =>
                      chapter.number == _chapter.number &&
                      !DanmakuSession.specialChapter(chapter),
                )
                .length ==
            1;
    _danmakuSession.configure(
      item: _item,
      chapter: _chapter,
      canonicalSubjectId: id,
      allowAutomatic: unique,
      error: _danmakuAssociationError,
      force: force,
    );
  }

  void _updateDanmakuClock() => _danmaku.update(
    _position,
    playing: _playing,
    rate: _holdingSpeed ? _settings.holdSpeed : _speed,
  );

  void _refreshDanmaku() {
    // Anchor before loading: late responses may not replay already passed text.
    _danmaku.seek(_position);
    _danmaku.load(_danmakuSession.comments);
  }

  Future<void> _setDanmakuEnabled(bool enabled) async {
    if (!mounted) return;
    await ref
        .read(danmakuSettingsProvider.notifier)
        .update(_danmakuSettings.copyWith(enabled: enabled));
  }

  Future<void> _showDanmakuSources() => _showDanmakuPanel(
    (context) => DanmakuSourcesPanel(
      session: _danmakuSession,
      onEnabledChanged: _setDanmakuEnabled,
      onAssociate: () {
        Navigator.pop(context);
        SearchPage.open(
          this.context,
          type: MediaType.anime,
          sourceId: 'bangumi-anime',
          query: _item.title,
        );
      },
    ),
  );

  Future<void> _showDanmakuPanel(WidgetBuilder builder) {
    final size = MediaQuery.sizeOf(context);
    if (size.width >= 600 && size.width > size.height) {
      return showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          alignment: Alignment.centerRight,
          insetPadding: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(left: Radius.circular(28)),
          ),
          child: SizedBox(
            width: min(440, size.width * .46),
            height: double.infinity,
            child: SafeArea(
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '关闭弹幕面板',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  Expanded(child: builder(context)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: builder,
    );
  }

  // ---------------------------------------------------------------- 进度

  Future<void> _persistProgress() async {
    if (!_validSelection ||
        _loading ||
        _scrubbing ||
        _error != null ||
        _awaitingPlaybackStart) {
      return;
    }
    final repository = _libraryRepository;
    final identity = _animeIdentity;
    if (repository == null || identity == null) return;
    final chapter = _chapter;
    final position = _position;
    try {
      final subject = await identity.db.transaction(() async {
        await identity.recordSelection(_item, chapter);
        final subject = await identity.subjectFor(_item);
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
        return subject;
      });
      _resetCrossSitePosition = false;
      _progressSaveFailureShown = false;
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
      if (mounted && !_progressSaveFailureShown) {
        _progressSaveFailureShown = true;
        _toast('观看进度暂未保存，将在播放中自动重试；请检查可用空间');
      }
    }
  }

  // ---------------------------------------------------------------- 章节切换

  Future<void> _switchChapter(int delta) async {
    final target = adjacentEpisodeIndex(_chapters, _chapterIndex, delta);
    if (target == null) {
      _toast(delta > 0 ? '已经是最后一集' : '已经是第一集');
      return;
    }
    _danmakuSession.restart(fetch: false);
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
    final video = PlayerInteractionSurface(
      enabled:
          !_loading &&
          !_awaitingPlaybackStart &&
          _error == null &&
          !_inPip &&
          !_episodesOpen,
      session: _loadSeq,
      position: _position,
      duration: Duration(milliseconds: _sliderMax.toInt()),
      volume: _displaySettings.volume,
      volumeEnabled: !_useNativeVideo || _mediaVolume.canSet,
      volumeFollowsDevice: _useNativeVideo,
      brightness: _brightness,
      brightnessEnabled: _useNativeVideo && _brightnessReady,
      holdSpeed: _settings.holdSpeed,
      onTap: _toggleChrome,
      onTogglePlay: () => unawaited(_togglePlay()),
      onSeek: (target) => unawaited(_seekTo(target)),
      onScrubStart: _beginScrub,
      onScrubUpdate: _previewScrub,
      onScrubEnd: (target) => unawaited(_endScrub(target)),
      onVolumeChanged: (value) => unawaited(_setAppVolume(value)),
      onVolumeEnd: () {
        if (!_useNativeVideo) unawaited(_settings.save(_preferences));
      },
      onBrightnessChanged: (value) => unawaited(_setBrightness(value)),
      seekHudTop: _chromeVisible ? 58 : 25,
      onHoldChanged: (enabled) => unawaited(_holdSpeed(enabled)),
      controls: !_inPip ? _buildChrome() : null,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _VideoArea(
            controller: _videoController,
            nativeController: _nativeVideoController,
            iosController: _iosVideoController,
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
        ],
      ),
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
    return LayoutBuilder(
      builder: (context, layout) {
        _sidePanelLayout = _fullscreen || layout.maxWidth > layout.maxHeight;
        return PopScope(
          canPop: !_fullscreen && !_episodesOpen && !_menuOpen,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (_menuOpen) {
              _menuController.close();
              return;
            }
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
              if (open) _clearTransientInput();
              setState(() => _episodesOpen = open);
              if (!open) _scheduleChromeHide();
            },
            endDrawer: _usesSidePanel
                ? Drawer(
                    width: (MediaQuery.sizeOf(context).width * .85).clamp(
                      0,
                      380,
                    ),
                    child: SafeArea(
                      child: Column(
                        children: [
                          ListTile(
                            title: const Text('选集 / 评论'),
                            trailing: IconButton(
                              tooltip: '关闭选集',
                              onPressed: () =>
                                  _scaffoldKey.currentState?.closeEndDrawer(),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(child: _buildContentPanel(episodes)),
                        ],
                      ),
                    ),
                  )
                : null,
            backgroundColor: Colors.black,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final fillsWindow =
                    _fullscreen ||
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
                              : (constraints.maxWidth * 9 / 16).clamp(
                                  0.0,
                                  constraints.maxHeight * .6,
                                ),
                          child: MouseRegion(
                            onHover: (_) => _revealChrome(),
                            child: video,
                          ),
                        ),
                      ),
                      if (!fillsWindow)
                        Expanded(child: _buildContentPanel(episodes)),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildContentPanel(Widget episodes) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      children: [
        TabBar(
          controller: _contentTabs,
          tabs: const [
            Tab(key: ValueKey('player-episodes-tab'), text: '选集'),
            Tab(key: ValueKey('player-comments-tab'), text: '评论'),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: _panelSection,
            children: [
              episodes,
              if (_commentsVisited)
                EpisodeCommentsPanel(item: _item, chapter: _chapter)
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    ),
  );

  Future<void> _selectEpisode(int index) async {
    _scaffoldKey.currentState?.closeEndDrawer();
    if (index == _chapterIndex ||
        index < 0 ||
        index >= _chapters.length ||
        _chapters[index].locked ||
        _chapters[index].sourceId != _item.sourceId) {
      return;
    }
    _danmakuSession.restart(fetch: false);
    await _persistProgress();
    if (!mounted) return;
    setState(() => _chapterIndex = index);
    await _load();
  }

  Future<void> _changeSource() async {
    _danmakuSession.restart(fetch: false);
    await _persistProgress();
    if (_useNativeVideo) {
      await _activeNativeController.pause();
    } else {
      await _player.pause();
    }
    if (_fullscreen) await _setFullscreen(false);
    if (!mounted) return;
    setState(() => _playing = false);
    await showAnimeSources(context, _item, replacePlayer: true);
  }

  void _beginScrub() {
    if (_loading || _awaitingPlaybackStart || _error != null) return;
    _chromeTimer?.cancel();
    ++_scrubRevision;
    setState(() {
      _scrubOrigin = _position;
      _scrubbing = true;
    });
  }

  void _previewScrub(Duration target) {
    if (_scrubbing) setState(() => _position = target);
  }

  void _cancelScrub() {
    if (!_scrubbing) return;
    ++_scrubRevision;
    _position = _scrubOrigin ?? _position;
    _scrubOrigin = null;
    _scrubbing = false;
  }

  void _clearTransientInput() {
    _cancelScrub();
    if (_holdingSpeed) unawaited(_holdSpeed(false));
  }

  Future<void> _endScrub(Duration? target) async {
    if (!_scrubbing) return;
    if (target == null) {
      setState(_cancelScrub);
      _scheduleChromeHide();
      return;
    }
    final sequence = _loadSeq;
    final revision = _scrubRevision;
    try {
      await _seekTo(target);
    } finally {
      if (mounted && sequence == _loadSeq && revision == _scrubRevision) {
        setState(() {
          _scrubbing = false;
          _scrubOrigin = null;
        });
        _scheduleChromeHide();
      }
    }
  }

  Future<void> _seekBy(Duration delta) => _seekTo(_position + delta);

  Future<void> _seekTo(Duration position) async {
    if (_loading ||
        _awaitingPlaybackStart ||
        _error != null ||
        _sliderMax <= 1) {
      return;
    }
    final sequence = _loadSeq;
    final target = Duration(
      milliseconds: position.inMilliseconds.clamp(0, _sliderMax.toInt()),
    );
    _revealChrome();
    setState(() => _position = target);
    try {
      if (_useNativeVideo) {
        await _activeNativeController.seek(target);
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
    if (_useNativeVideo) {
      _playing
          ? await _activeNativeController.pause()
          : await _activeNativeController.play();
    } else {
      _playing ? await _player.pause() : await _player.play();
    }
  }

  void _toggleChrome() {
    if (_menuOpen || _menuActionActive) return;
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
    if (!_playing ||
        _loading ||
        _awaitingPlaybackStart ||
        _error != null ||
        _episodesOpen ||
        _menuOpen ||
        _menuActionActive ||
        _scrubbing) {
      return;
    }
    _chromeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          !_episodesOpen &&
          !_scrubbing &&
          !_menuOpen &&
          !_menuActionActive) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  Widget _buildChrome() {
    final theme = Theme.of(context);
    final positionText = _format(_position);
    final durationText = _format(
      _duration == Duration.zero && !_useNativeVideo
          ? _player.state.duration
          : _duration,
    );
    final previous = adjacentEpisodeIndex(_chapters, _chapterIndex, -1);
    final next = adjacentEpisodeIndex(_chapters, _chapterIndex, 1);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttonSize = ((constraints.maxWidth - 24) / 8).clamp(
            32.0,
            48.0,
          );
          Widget button(
            String label,
            IconData icon,
            VoidCallback? onPressed, {
            bool prominent = false,
          }) => IconButton(
            tooltip: label,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: prominent
                  ? Colors.white.withValues(alpha: .16)
                  : null,
              shape: const StadiumBorder(),
            ),
            onPressed: onPressed,
            constraints: BoxConstraints.tightFor(width: buttonSize, height: 44),
            padding: EdgeInsets.zero,
            color: Colors.white,
            disabledColor: Colors.white38,
            iconSize: prominent ? 30 : 26,
            icon: Icon(icon),
          );

          final visible =
              _chromeVisible ||
              _loading ||
              _awaitingPlaybackStart ||
              _error != null;
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
                          '分集评论',
                          Icons.chat_bubble_outline_rounded,
                          _showComments,
                        ),
                        PlayerMenu(
                          controller: _menuController,
                          settings: _displaySettings,
                          volumeEnabled:
                              !_useNativeVideo || _mediaVolume.canSet,
                          volumeStatus: _useNativeVideo
                              ? _mediaVolume.status
                              : null,
                          onVolumeChanged: _useNativeVideo
                              ? _changeMenuVolume
                              : null,
                          nativeVideo: _useNativeVideo,
                          lineName: _lines.length > 1
                              ? _lines[_lineIndex].name
                              : null,
                          danmakuEnabled: danmakuFeatureEnabled,
                          danmakuOn: _danmakuOn,
                          onSettingsChanged: _changeMenuSettings,
                          onAction: _runMenuAction,
                          onVisibilityChanged: _menuVisibilityChanged,
                          builder: (context, toggle) =>
                              button('播放设置', Icons.tune_rounded, toggle),
                        ),
                        if (danmakuFeatureEnabled)
                          button(
                            _danmakuOn ? '关闭弹幕' : '开启弹幕',
                            _danmakuOn
                                ? Icons.speaker_notes_outlined
                                : Icons.speaker_notes_off_outlined,
                            () => unawaited(_setDanmakuEnabled(!_danmakuOn)),
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
                                      trackShape:
                                          const RoundedRectSliderTrackShape(),
                                      activeTrackColor: Colors.white,
                                      secondaryActiveTrackColor: Colors.white54,
                                      inactiveTrackColor: Colors.white30,
                                      thumbColor: Colors.white,
                                      overlayColor: Colors.white12,
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                            overlayRadius: 18,
                                          ),
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 8,
                                      ),
                                    ),
                                    child: Slider(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      value: _sliderValue,
                                      secondaryTrackValue: _bufferedSliderValue,
                                      max: _sliderMax,
                                      onChangeStart:
                                          _loading ||
                                              _awaitingPlaybackStart ||
                                              _error != null
                                          ? null
                                          : (_) => _beginScrub(),
                                      onChanged:
                                          _loading ||
                                              _awaitingPlaybackStart ||
                                              _error != null
                                          ? null
                                          : (value) => _previewScrub(
                                              Duration(
                                                milliseconds: value.round(),
                                              ),
                                            ),
                                      onChangeEnd: (value) => _endScrub(
                                        Duration(milliseconds: value.round()),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '$positionText / $durationText',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
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
                                      onPressed:
                                          _loading ||
                                              _awaitingPlaybackStart ||
                                              _error != null ||
                                              _sliderMax <= 1
                                          ? null
                                          : () => _seekBy(
                                              Duration(
                                                seconds: _settings.skipSeconds,
                                              ),
                                            ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          '+${_settings.skipSeconds}s',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const Spacer(),
                              button(
                                '视频比例',
                                Icons.aspect_ratio_rounded,
                                _pickAspectRatio,
                              ),
                              button(
                                '剧集',
                                Icons.playlist_play_rounded,
                                _showEpisodes,
                              ),
                              button(
                                '倍速 · ${_speed}x',
                                Icons.speed_rounded,
                                _pickSpeed,
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

  double get _bufferedSliderValue => _bufferedPosition.inMilliseconds
      .clamp(_sliderValue, _sliderMax)
      .toDouble();
  double get _sliderMax {
    final duration = _duration == Duration.zero && !_useNativeVideo
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
                labelText: '每次跳过',
                suffixText: '秒',
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
                  leading: Icon(
                    _settings.aspectRatio == ratio
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
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
      if (_useNativeVideo) {
        await _activeNativeController.setAspectRatio(selected.ratio);
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
    _configureDanmaku(force: true);
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

  bool get _usesSidePanel => !_inPip && _sidePanelLayout;

  Future<void> _showEpisodes() async {
    _contentTabs.index = 0;
    if (_usesSidePanel) _openContentDrawer();
  }

  void _showComments() {
    _contentTabs.index = 1;
    if (_usesSidePanel) _openContentDrawer();
  }

  void _openContentDrawer() {
    _chromeTimer?.cancel();
    _clearTransientInput();
    setState(() {
      _chromeVisible = true;
      _episodesOpen = true;
    });
    _scaffoldKey.currentState?.openEndDrawer();
  }

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
    if (_useNativeVideo) {
      await _activeNativeController.setRate(selected);
    } else {
      await _player.setRate(selected);
    }
    if (mounted) setState(() => _speed = selected);
    if (mounted) _updateDanmakuClock();
    _settings = _settings.copyWith(speed: selected);
    await _settings.save(_preferences);
  }

  Future<void> _holdSpeed(bool enabled) async {
    if (_holdingSpeed == enabled) return;
    _holdingSpeed = enabled;
    final speed = enabled ? _settings.holdSpeed : _speed;
    _updateDanmakuClock();
    if (_useNativeVideo) {
      await _activeNativeController.setRate(speed);
    } else {
      await _player.setRate(speed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _setAppVolume(double value) async {
    if (!mounted) return;
    final volume = value.clamp(0.0, 1.0);
    if (_useNativeVideo) {
      if (!_mediaVolume.canSet) return;
      try {
        final state = await _activeNativeController.setMediaVolume(volume);
        if (state == null || !mounted) return;
        _onMediaVolume(state);
        if (state.error != null) _toast(state.status!);
      } on PlatformException {
        if (mounted) _toast('设备音量暂不可用');
      } on MissingPluginException {
        if (mounted) _toast('设备音量暂不可用');
      }
    } else {
      setState(() => _settings = _settings.copyWith(volume: volume));
      await _player.setVolume(volume * 100);
    }
  }

  Future<void> _readBrightness() async {
    final revision = _brightnessRevision;
    try {
      final value = await const MethodChannel('triomi/platform')
          .invokeMethod<double>('getVideoBrightness');
      if (!mounted || revision != _brightnessRevision || value == null) return;
      setState(() {
        _brightness = value.clamp(.05, 1.0);
        _brightnessReady = true;
      });
    } on PlatformException {
      // Brightness remains unavailable rather than displaying an invented value.
    } on MissingPluginException {
      // Unsupported platforms do not mutate system brightness.
    }
  }

  Future<void> _setBrightness(double value) async {
    if (!_useNativeVideo || !_brightnessReady) return;
    ++_brightnessRevision;
    setState(() => _brightness = value.clamp(.05, 1.0));
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
    final result = _isIOS
        ? await _iosVideoController.enterPip()
        : await const MethodChannel('triomi/platform').invokeMethod<bool>('enterVideoPip');
    if (result != true) _toast('此设备不支持画中画');
  }

  void _menuVisibilityChanged(bool open) {
    if (!mounted) return;
    _chromeTimer?.cancel();
    setState(() {
      _menuOpen = open;
      _chromeVisible = true;
    });
    if (!open) _scheduleChromeHide();
  }

  Future<double> _changeMenuVolume(double volume) async {
    if (!_mediaVolume.canSet) {
      throw StateError(_mediaVolume.status ?? '设备音量暂不可用');
    }
    final state = await _activeNativeController.setMediaVolume(volume);
    if (!mounted || state == null) throw StateError('设备音量暂不可用');
    _onMediaVolume(state);
    if (state.volume == null) throw StateError(state.status ?? '设备音量暂不可用');
    return state.volume!;
  }

  Future<void> _changeMenuSettings(PlayerSettings settings) async {
    if (!mounted) return;
    final previous = _settings;
    // Native device volume is transient. Preserve the desktop gain preference
    // when saving speed/aspect/background settings from the same menu.
    final persisted = _useNativeVideo
        ? settings.copyWith(volume: previous.volume)
        : settings;
    setState(() {
      _settings = persisted;
      _speed = settings.speed;
    });
    try {
      await _applyControls();
      if (!mounted) return;
      await persisted.save(_preferences);
    } catch (_) {
      if (mounted) {
        setState(() {
          _settings = previous;
          _speed = previous.speed;
        });
      }
      rethrow;
    }
  }

  Future<void> _runMenuAction(PlayerMenuAction action) async {
    if (!mounted || _menuActionActive) return;
    _chromeTimer?.cancel();
    setState(() => _menuActionActive = true);
    try {
      // Let the anchor close and restore focus before presenting another route.
      await Future<void>.value();
      if (!mounted) return;
      switch (action) {
        case PlayerMenuAction.skip:
          await _pickSkipSeconds();
        case PlayerMenuAction.subtitles:
          await _pickSubtitles();
        case PlayerMenuAction.pip:
          await _enterPip();
        case PlayerMenuAction.line:
          await _pickLine();
        case PlayerMenuAction.episodes:
          await _showEpisodes();
        case PlayerMenuAction.retry:
          await _load();
        case PlayerMenuAction.danmakuSettings:
          await _showDanmakuSettings();
        case PlayerMenuAction.danmakuSources:
          await _showDanmakuSources();
        case PlayerMenuAction.toggleDanmaku:
          await _setDanmakuEnabled(!_danmakuOn);
      }
    } catch (_) {
      if (mounted) _toast('操作未能完成，请重试');
    } finally {
      if (mounted) {
        setState(() => _menuActionActive = false);
        _scheduleChromeHide();
      }
    }
  }

  Future<void> _pickSubtitles() async {
    final native = _useNativeVideo
        ? await _activeNativeController.subtitleTracks()
        : null;
    if (!mounted) return;
    final desktop = _useNativeVideo
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
    if (_useNativeVideo) {
      await _activeNativeController.selectSubtitle(selected == 'no' ? null : selected);
    } else {
      await _player.setSubtitleTrack(
        selected == 'no'
            ? SubtitleTrack.no()
            : desktop.firstWhere((t) => t.id == selected),
      );
    }
  }

  // ---------------------------------------------------------------- 弹幕设置

  Future<void> _showDanmakuSettings() => _showDanmakuPanel(
    (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .82,
      child: const DanmakuSettingsPanel(inPlayer: true),
    ),
  );

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
    _danmakuAssociation?.close();
    _danmakuClient?.close();
    _danmakuDisplay?.close();
    _danmakuSession.removeListener(_refreshDanmaku);
    _danmakuSession.dispose();
    _contentTabs.dispose();
    _cancelScrub();
    if (_holdingSpeed) unawaited(_holdSpeed(false));
    ++_brightnessRevision;
    _desktopResolve?.cancel('播放器已关闭');
    WidgetsBinding.instance.removeObserver(this);
    _chromeTimer?.cancel();
    _prepareTimer?.cancel();
    _playerErrorSub?.cancel();
    _completedSub?.cancel();
    if (_useNativeVideo) {
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
    _positionSub?.cancel();
    _durationSub?.cancel();
    _bufferSub?.cancel();
    _playingSub?.cancel();
    ++_resolveSeq;
    if (_useNativeVideo) {
      unawaited(
        const MethodChannel('triomi/platform').invokeMethod<void>(
          'cancelVideoResolve',
          {'requestId': _resolverOwner},
        ),
      );
    }
    _nativeVideoController.dispose();
    _iosVideoController.dispose();
    if (!_useNativeVideo) _player.dispose();
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
    required this.iosController,
    required this.aspectRatio,
    required this.backgroundAudio,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onEpisodes,
  });

  final VideoController? controller;
  final _NativeAndroidVideoController nativeController;
  final IosVideoController iosController;
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
      LayoutBuilder(
        builder: (context, constraints) {
          // Own frame geometry while retaining the same native view/controller.
          // media_kit_video 2.0.1 cannot clear its cached aspectRatio via null.
          final width = aspectRatio == null
              ? constraints.maxWidth
              : min(constraints.maxWidth, constraints.maxHeight * aspectRatio!);
          return Center(
            child: SizedBox(
              width: width,
              height: aspectRatio == null ? constraints.maxHeight : width / aspectRatio!,
              child: isIosVideoPlatform
                  ? iosController.buildView()
                  : controller == null
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
        },
      ),
      if (error != null)
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.78),
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xF21B1D22),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 32,
                            offset: Offset(0, 16),
                          ),
                        ],
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.error
                                    .withValues(alpha: 0.16),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.play_disabled_rounded,
                                color: Theme.of(context).colorScheme.error,
                                size: 28,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              '这一集暂时无法播放',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '检查网络后重试，或切换到其他线路与剧集。',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: Colors.white70),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                error!,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.white70),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                FilledButton.icon(
                                  onPressed: onRetry,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重新加载'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: onEpisodes,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.32,
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.video_library_outlined,
                                  ),
                                  label: const Text('选择其他集数 / 线路'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
      else if (loading)
        const ColoredBox(
          color: Colors.black54,
          child: Center(
            child: SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          ),
        ),
    ],
  );
}

class _NativeAndroidVideoController implements VideoPlatformController {
  _NativeAndroidVideoController({
    required this.onState,
    required this.onMediaVolume,
    required this.onPrepared,
    required this.onError,
    required this.onCompleted,
    required this.onPip,
  });

  final void Function(NativeVideoState state) onState;
  final void Function(MediaVolumeState state) onMediaVolume;
  final void Function(NativeVideoState state) onPrepared;
  final void Function(String message) onError;
  final VoidCallback onCompleted;
  String _pendingTitle = 'Triomi';
  final void Function(bool enabled) onPip;
  MethodChannel? _channel;
  int? _viewId;
  String? _pendingUrl;
  String? _pendingMimeType;
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
      if (_disposed || _channel != channel) return;
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
    unawaited(_readMediaVolume(channel));
    final url = _pendingUrl;
    if (url != null) {
      unawaited(
        setUrl(
          url,
          headers: _pendingHeaders,
          mimeType: _pendingMimeType,
          startPosition: _pendingStartPosition,
          title: _pendingTitle,
        ).catchError((Object error) => onError('打开视频失败：$error')),
      );
    }
  }

  Future<void> _readMediaVolume(MethodChannel channel) async {
    try {
      final raw = await channel.invokeMapMethod<Object?, Object?>(
        'getMediaVolume',
      );
      if (_disposed || _channel != channel) return;
      onMediaVolume(MediaVolumeState.fromMap(raw ?? const {}));
    } on PlatformException {
      if (!_disposed && _channel == channel) {
        onMediaVolume(const MediaVolumeState());
      }
    } on MissingPluginException {
      if (!_disposed && _channel == channel) {
        onMediaVolume(const MediaVolumeState());
      }
    }
  }

  NativeVideoState _stateFrom(Map<Object?, Object?> args) {
    int number(String key) => (args[key] as num?)?.toInt() ?? 0;
    return NativeVideoState(
      position: Duration(milliseconds: number('position')),
      duration: Duration(milliseconds: number('duration')),
      bufferedPosition: Duration(milliseconds: number('bufferedPosition')),
      playing: args['playing'] == true,
      mediaVolume: args.containsKey('mediaVolume')
          ? MediaVolumeState.fromMap(args)
          : null,
    );
  }

  @override
  Future<void> setUrl(
    String url, {
    Map<String, String> headers = const {},
    String? mimeType,
    bool omitCookies = false,
    Duration startPosition = Duration.zero,
    String title = 'Triomi',
  }) async {
    if (_disposed) return;
    _pendingUrl = url;
    _pendingHeaders = omitCookies
        ? {
            for (final entry in headers.entries)
              if (entry.key.toLowerCase() != 'cookie') entry.key: entry.value,
          }
        : headers;
    _pendingMimeType = mimeType;
    _pendingStartPosition = startPosition;
    _pendingTitle = title;
    final channel = _channel;
    if (channel == null) return;
    await channel.invokeMethod<void>('setUrl', <String, Object?>{
      'url': url,
      'headers': _pendingHeaders,
      'mimeType': ?mimeType,
      'startMilliseconds': startPosition.inMilliseconds,
      'title': title,
    });
  }

  @override
  Future<void> play() async => _invoke('play');
  @override
  Future<void> pause() async => _invoke('pause');

  @override
  Future<void> seek(Duration position) => _invoke('seek', <String, Object?>{
    'milliseconds': position.inMilliseconds,
  });

  @override
  Future<void> setRate(double rate) =>
      _invoke('setRate', <String, Object?>{'rate': rate});

  @override
  Future<MediaVolumeState?> setMediaVolume(double volume) async {
    final channel = _channel;
    if (_disposed || channel == null) return null;
    final raw = await channel.invokeMapMethod<Object?, Object?>(
      'setMediaVolume',
      {'volume': volume},
    );
    if (_disposed || _channel != channel) return null;
    return MediaVolumeState.fromMap(raw ?? const {});
  }

  @override
  Future<void> setAspectRatio(double? ratio) =>
      _invoke('setAspectRatio', {'ratio': ratio});
  @override
  Future<void> setBackgroundAudio(bool enabled) =>
      _invoke('setBackgroundAudio', {'enabled': enabled});
  @override
  Future<List<Map<Object?, Object?>>> subtitleTracks() async {
    final raw =
        await _channel?.invokeListMethod<Object?>('subtitleTracks') ?? [];
    return [
      for (final row in raw)
        if (row is Map) Map<Object?, Object?>.from(row),
    ];
  }

  @override
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

  @override
  Widget buildView() => _NativeAndroidVideoView(controller: this);

  @override
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
