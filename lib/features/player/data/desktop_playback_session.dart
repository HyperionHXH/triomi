import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// One owner for native open/stop, per-media readiness and terminal failures.
/// Decoder diagnostic logs are not failure states. No readiness Future is
/// shared between episodes, and superseded opens cannot publish completion.
class DesktopPlaybackSession {
  DesktopPlaybackSession(this.player, {required this.onFailure});

  final Player player;
  final void Function(String) onFailure;
  StreamSubscription<String>? _errors;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;
  bool _active = false;
  bool _observed = false;
  bool _loaded = false;
  bool _unloaded = false;
  String? _message;
  Completer<void>? _ready;
  Completer<void>? _cancelled;

  NativePlayer get _native => player.platform as NativePlayer;

  Future<void> initialize() async {
    await _native.waitForPlayerInitialization;
    _native.onLoadHooks.add(_onLoad);
    _native.onUnloadHooks.add(_onUnload);
    _errors = player.stream.error.listen((message) {
      if (!_active || _disposed) return;
      _message = message;
      unawaited(_check());
    });
    await _native.observeProperty('idle-active', (_) => _check());
    await _native.observeProperty('time-pos', (_) => _check());
    _observed = true;
  }

  Future<void> _onLoad() async {
    if (_disposed || !_active) return;
    _loaded = true;
    _unloaded = false;
    _message = null;
  }

  Future<void> _onUnload() async {
    if (_disposed || !_active || !_loaded) return;
    _unloaded = true;
  }

  void reset() {
    _generation++;
    _active = false;
    _message = null;
    _loaded = false;
    _unloaded = false;
    if (!(_cancelled?.isCompleted ?? true)) _cancelled!.complete();
  }

  Future<void> open(
    Media media, {
    Duration timeout = const Duration(seconds: 30),
    String? mimeType,
  }) {
    reset();
    final generation = _generation;
    final cancelled = _cancelled = Completer<void>();
    final operation = _tail.then((_) async {
      if (_disposed || generation != _generation) return;
      // stop is a command barrier. The old file must not provide time-pos or
      // diagnostics while readiness for the new media is being established.
      await player.stop();
      if (_disposed || generation != _generation) return;
      // Extensionless HLS endpoints can be mistaken for a generic playlist.
      // Set the demux hint per open, and clear it before a later MP4/local file.
      await _native.setProperty(
        'demuxer-lavf-format',
        mimeType == 'application/vnd.apple.mpegurl' ? 'hls' : '',
      );
      if (_disposed || generation != _generation) return;
      final ready = _ready = Completer<void>();
      ready.future.ignore(); // Attach before asynchronous native open can fail.
      _active = true;
      await player.open(media);
      if (_disposed || generation != _generation) return;
      await _check();
      await Future.any([ready.future, cancelled.future]).timeout(
        timeout,
        onTimeout: () {
          if (generation == _generation) reset();
          throw TimeoutException('视频准备超时，请重试或更换播放来源');
        },
      );
    });
    _tail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<void> _check() async {
    final generation = _generation;
    if (_disposed || !_active || !_loaded) return;
    final idle = await _native.getProperty('idle-active');
    if (_disposed || !_active || generation != _generation) return;
    final time = await _native.getProperty('time-pos');
    if (_disposed || !_active || generation != _generation) return;
    if (idle != 'yes' && double.tryParse(time) != null) {
      if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      return;
    }
    if (idle != 'yes' ||
        !_unloaded ||
        _message == null ||
        player.state.completed) {
      return;
    }
    _active = false;
    // Keep errors in the open Future until ready; a failed open must not be
    // mistaken for success by the page's final loading-state transition.
    if (!(_ready?.isCompleted ?? true)) {
      _ready!.completeError(StateError(_message!));
    } else {
      onFailure(_message!);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    reset();
    await _errors?.cancel();
    _native.onLoadHooks.remove(_onLoad);
    _native.onUnloadHooks.remove(_onUnload);
    await _tail;
    if (_observed) {
      await _native.unobserveProperty('idle-active');
      await _native.unobserveProperty('time-pos');
    }
  }
}
