import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// media_kit's error stream contains decoder/network log messages, not just
/// terminal failures. Only an idle decoder with an error is a failed playback.
class DesktopPlaybackErrors {
  DesktopPlaybackErrors(this.player, {required this.onFailure});

  final Player player;
  final void Function(String) onFailure;
  StreamSubscription<String>? _errors;
  int _generation = 0;
  bool _disposed = false;
  bool _active = false;
  bool _observed = false;
  String? _message;

  NativePlayer get _native => player.platform as NativePlayer;

  Future<void> initialize() async {
    _errors = player.stream.error.listen((message) {
      if (!_active || _disposed) return;
      _message = message;
      unawaited(_check());
    });
    await _native.observeProperty('idle-active', (_) => _check());
    _observed = true;
  }

  /// Invalidate diagnostics and property reads belonging to the previous media.
  void reset() {
    _generation++;
    _active = false;
    _message = null;
  }

  void opening() => _active = true;

  Future<void> _check() async {
    final generation = _generation;
    final message = _message;
    if (_disposed || !_active || message == null) return;
    final idle = await _native.getProperty('idle-active');
    if (_disposed ||
        !_active ||
        generation != _generation ||
        message != _message ||
        idle != 'yes' ||
        player.state.completed) {
      return;
    }
    _active = false;
    onFailure(message);
  }

  Future<void> dispose() async {
    _disposed = true;
    reset();
    await _errors?.cancel();
    if (_observed) await _native.unobserveProperty('idle-active');
  }
}
